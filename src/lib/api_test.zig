//! Embedder-POV tests for the public `lib.zig` surface.
//!
//! These exercise `Session` the way a consumer would: only through the
//! re-exported names, with a virtual clock, simulating the seven-call
//! event loop. They're deliberately redundant with session.zig's internal
//! tests — the point is to pin the *public* shape so a refactor that keeps
//! internal tests green but breaks the API still fails here.

const std = @import("std");
const testing = std.testing;
const lib = @import("root.zig");

const Session = lib.Session;
const SessionEvent = lib.SessionEvent;
const Via = lib.Via;
const Shell = lib.Shell;

const ms = std.time.ns_per_ms;
const sec = std.time.ns_per_s;

/// Virtual-clock harness wrapping a Session in the embedder's seven-call
/// loop. `pty_out` is what the simulated PTY emits; `step()` is one loop
/// iteration: write pending input to /dev/null (we don't model the shell),
/// feed `pty_out`, tick, drain.
const Harness = struct {
    s: Session,
    now: i128 = 0,
    evs: std.ArrayList(SessionEvent) = .empty,

    fn init() !Harness {
        return .{ .s = try Session.init(testing.allocator, .{ .rows = 24, .cols = 80 }) };
    }
    fn deinit(h: *Harness) void {
        h.s.deinit();
        h.evs.deinit(testing.allocator);
    }

    fn advance(h: *Harness, dt: i128) void {
        h.now += dt;
    }

    /// One event-loop iteration: drain pendingInput, feed `pty_out` as if
    /// read from the PTY master, tick, accumulate events into `h.evs`.
    fn step(h: *Harness, pty_out: []const u8) !void {
        h.s.consumeInput(h.s.pendingInput().len, h.now);
        try h.s.feedPty(pty_out, h.now);
        h.s.tick(h.now);
        try h.evs.appendSlice(testing.allocator, h.s.drainEvents());
    }

    fn pop(h: *Harness) ?SessionEvent {
        if (h.evs.items.len == 0) return null;
        return h.evs.orderedRemove(0);
    }
};

fn done(buf: []u8, pid: i32, ec: i32, cwd: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "\x1b]2718;done;{d};{d};0;b;{s}\x07",
        .{ pid, ec, cwd },
    ) catch unreachable;
}

fn preexec(buf: []u8, pid: i32) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b]2718;preexec;{d}\x07", .{pid}) catch unreachable;
}

// ───────────────────── seven-call loop, golden path ─────────────────────

test "API: golden path — hook announces, run completes via osc_done" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;

    // t=0: shell hasn't started yet. nextDeadline=null (nothing pending).
    try testing.expect(h.s.nextDeadline() == null);
    const st0 = h.s.state();
    try testing.expectEqual(@as(u8, 0), st0.depth);
    try testing.expect(st0.idle);

    // t=10ms: shell rc loads the hook → first `done` arrives.
    h.advance(10 * ms);
    try h.step(done(&b, 100, 0, "/home/u"));
    const st1 = h.s.state();
    try testing.expect(st1.hooked);
    try testing.expect(st1.idle);
    try testing.expectEqual(Shell.bash, st1.shell);
    try testing.expectEqualStrings("/home/u", st1.cwd);
    try testing.expectEqual(@as(?i32, 0), st1.last_exit);
    try testing.expect(h.pop() == null);

    // Embedder issues `run("exit 7")` with cookie=42.
    try h.s.run(42, "exit 7", .{}, h.now);
    try testing.expect(!h.s.state().idle);
    // pendingInput now has the paste-wrapped command.
    try testing.expect(std.mem.indexOf(u8, h.s.pendingInput(), "exit 7") != null);
    // nextDeadline is set (acceptance window armed).
    try testing.expect(h.s.nextDeadline() != null);

    // t=20ms: PTY accepts our bytes; shell emits preexec.
    h.advance(10 * ms);
    try h.step(preexec(&b, 100));
    try testing.expect(h.s.state().cmd_running);
    try testing.expectEqual(@as(u64, 1), h.s.state().preexec_gen);
    try testing.expect(h.pop() == null);

    // t=30ms: shell emits done(7).
    h.advance(10 * ms);
    try h.step(done(&b, 100, 7, "/home/u"));
    const ev = h.pop().?;
    try testing.expectEqual(@as(u32, 42), ev.cookie());
    try testing.expectEqual(@as(?i32, 7), ev.run_done.exit_code);
    try testing.expectEqual(Via.osc_done, ev.run_done.via);
    try testing.expect(h.pop() == null);

    // Idle again; nextDeadline back to null.
    try testing.expect(h.s.state().idle);
    try testing.expect(h.s.nextDeadline() == null);
}

test "API: run -i into nested shell, then layer pop" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;

    try h.step(done(&b, 100, 0, "/"));
    try h.s.run(1, "ssh remote", .{ .interactive = true }, h.now);
    h.advance(5 * ms);
    try h.step(preexec(&b, 100));

    // Remote unhooked: bare ?2004h → at_prompt + degraded layer.
    h.advance(50 * ms);
    try h.step("\x1b[?2004h");
    try testing.expectEqual(Via.at_prompt, h.pop().?.run_done.via);
    try testing.expectEqual(@as(u8, 2), h.s.state().depth);
    try testing.expect(!h.s.state().hooked);

    // Run in the nested layer; completes via prompt_fallback.
    try h.s.run(2, "ls", .{}, h.now);
    h.advance(5 * ms);
    try h.step("\x1b[?2004h");
    try testing.expectEqual(Via.prompt_fallback, h.pop().?.run_done.via);

    // ssh exits → outer's done pops back to depth 1.
    try h.step(done(&b, 100, 0, "/"));
    try testing.expectEqual(@as(u8, 1), h.s.state().depth);
    try testing.expect(h.s.state().hooked);
}

// ───────────────────── tick: every timeout path ─────────────────────

test "API: tick fires line_rejected past acceptance window" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    // First, observe an RTT so the lower floor applies.
    try h.s.run(1, "true", .{}, h.now);
    h.advance(2 * ms);
    try h.step(preexec(&b, 100));
    try h.step(done(&b, 100, 0, "/"));
    _ = h.pop();

    try h.s.run(2, "echo \"unclosed", .{}, h.now);
    h.advance(1 * ms);
    try h.step(""); // flush
    try testing.expect(h.pop() == null);

    // Advance past accept_timeout_ns; nextDeadline told us when.
    const dl = h.s.nextDeadline().?;
    try testing.expect(dl > h.now);
    h.now = dl + 1;
    try h.step("");
    const ev = h.pop().?;
    try testing.expectEqual(Via.line_rejected, ev.run_done.via);
    try testing.expect(ev.run_done.exit_code == null);
    // ^C was queued.
    try testing.expect(std.mem.indexOf(u8, h.s.pendingInput(), "\x03") != null);
}

test "API: tick fires hook deadline as .hook_done(.err)" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    try testing.expect((try h.s.installHook(9, h.now)) == null);
    const dl = h.s.nextDeadline().?;
    h.now = dl - 1;
    try h.step("");
    try testing.expect(h.pop() == null);
    h.now = dl;
    try h.step("");
    try testing.expect(h.pop().?.hook_done.result == .err);
}

test "API: tick fires .warn then .run_done for slow shell startup" {
    var h = try Harness.init();
    defer h.deinit();

    // Queue before any layer exists.
    try h.s.run(5, "echo hi", .{}, h.now);

    // nextDeadline points at the warn threshold.
    const dl = h.s.nextDeadline().?;
    try testing.expectEqual(h.s.opts.prompt_warn_ns, dl);
    h.now = dl;
    try h.step("");
    const w = h.pop().?;
    try testing.expectEqual(@as(u32, 5), w.warn.cookie);
    try testing.expect(h.pop() == null);

    // Hard timeout: warn(reason) + run_done.
    h.now = h.s.opts.prompt_timeout_ns;
    try h.step("");
    try testing.expect(h.pop().? == .warn);
    try testing.expectEqual(Via.prompt_fallback, h.pop().?.run_done.via);
}

// ───────────────────── nextDeadline correctness ─────────────────────

test "API: nextDeadline tracks the soonest of all armed timers" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    // Hook probe arms a 5s deadline.
    _ = try h.s.installHook(1, h.now);
    const d1 = h.s.nextDeadline().?;
    try testing.expectEqual(h.now + h.s.opts.hook_probe_timeout_ns, d1);

    // A queued (unsent) run arms a 5s warn. Earlier of the two wins.
    h.advance(1 * sec);
    try h.s.run(2, "ls", .{}, h.now);
    const d2 = h.s.nextDeadline().?;
    try testing.expect(d2 <= d1);

    // Cancel both → no deadline.
    h.s.cancel(1);
    h.s.cancel(2);
    try testing.expect(h.s.nextDeadline() == null);
}

test "API: nextDeadline → tick at that instant always emits" {
    // Invariant: if nextDeadline()==t, then tick(t) emits ≥1 event (or the
    // deadline moves forward). Otherwise an embedder polling exactly at the
    // deadline would spin.
    var h = try Harness.init();
    defer h.deinit();

    try h.s.run(1, "x", .{}, h.now);
    var spins: u32 = 0;
    while (h.s.nextDeadline()) |dl| : (spins += 1) {
        try testing.expect(dl >= h.now);
        h.now = dl;
        try h.step("");
        if (h.evs.items.len > 0) break;
        // No event: deadline must have advanced strictly forward.
        try testing.expect(h.s.nextDeadline().? > dl);
        if (spins > 10) return error.DeadlineSpin;
    }
    try testing.expect(h.evs.items.len > 0);
}

// ───────────────────── drainEvents semantics ─────────────────────

test "API: drainEvents is one-shot and preserves order across calls" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    // Two runs complete in one feed (preexec/done × 2 in one chunk).
    try h.s.run(1, "a", .{}, h.now);
    h.advance(1 * ms);
    h.s.consumeInput(h.s.pendingInput().len, h.now);
    try h.s.feedPty(preexec(&b, 100), h.now);
    try h.s.feedPty(done(&b, 100, 0, "/"), h.now);
    try h.s.run(2, "b", .{}, h.now);
    h.s.consumeInput(h.s.pendingInput().len, h.now);
    try h.s.feedPty(preexec(&b, 100), h.now);
    // Drain mid-stream: only #1 so far.
    const evs1 = h.s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs1.len);
    try testing.expectEqual(@as(u32, 1), evs1[0].run_done.cookie);
    // Slice stays valid until the next drain.
    try h.s.feedPty(done(&b, 100, 3, "/"), h.now);
    const evs2 = h.s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs2.len);
    try testing.expectEqual(@as(u32, 2), evs2[0].run_done.cookie);
    try testing.expectEqual(@as(?i32, 3), evs2[0].run_done.exit_code);
    // Third drain: empty.
    try testing.expectEqual(@as(usize, 0), h.s.drainEvents().len);
}

test "API: SessionEvent.cookie() works for all variants" {
    const evs = [_]SessionEvent{
        .{ .run_done = .{ .cookie = 1, .exit_code = 0, .via = .osc_done, .dur_ms = 0 } },
        .{ .hook_done = .{ .cookie = 2, .result = .{ .err = "" } } },
        .{ .warn = .{ .cookie = 3, .msg = "" } },
    };
    try testing.expectEqual(@as(u32, 1), evs[0].cookie());
    try testing.expectEqual(@as(u32, 2), evs[1].cookie());
    try testing.expectEqual(@as(u32, 3), evs[2].cookie());
}

// ───────────────────── Classifier (input direction) ─────────────────────

test "API: Classifier — keystroke vs report, configurable detach" {
    var c = lib.Classifier.init(.{ .detach_key = ']' });
    // User keystrokes:
    try testing.expect(c.feed("hello").user_input);
    try testing.expect(c.feed("\x1b[A").user_input); // arrow
    // Terminal reports:
    try testing.expect(!c.feed("\x1b[?1;2c").user_input); // DA
    try testing.expect(!c.feed("\x1b[<0;5;5M").user_input); // SGR mouse
    // Configured detach (Ctrl-] = 0x1d):
    try testing.expect(c.feed("\x1d").detach);
    try testing.expect(!c.feed("\x1c").detach); // default Ctrl-\ no longer
    // Disabled detach still classifies:
    var c2 = lib.Classifier.init(.{ .detach_key = null });
    try testing.expect(!c2.feed("\x1d").detach);
    try testing.expect(c2.feed("\x1d").user_input);
}

// ───────────────────── tier-3: posix + spawnSpec wiring ─────────────────────

test "API: posix.Pty + hook.spawnSpec — embedder spawns a hooked bash" {
    // The actual "build your own daemon" recipe: open a PTY, ask spawnSpec
    // what to write/exec, do it, drive Session from the master fd. Skipped
    // if bash isn't available.
    const bash = "/bin/bash";
    std.fs.accessAbsolute(bash, .{}) catch return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rc_dir = try tmp.dir.realpathAlloc(arena, ".");

    const spec = try lib.hook.spawnSpec(arena, .bash, .{
        .shell_path = bash,
        .rc_dir = rc_dir,
        .body = lib.hook.body(.bash),
    });
    for (spec.files) |f| try tmp.dir.writeFile(.{ .sub_path = f.name, .data = f.content });

    var p = try lib.posix.Pty.open();
    defer p.close();
    try lib.posix.setWinsize(p.master, .{ .rows = 24, .cols = 80 });
    const pid = try lib.posix.forkExec(&p, spec.argv, &.{
        "TERM=xterm-256color",
        try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{rc_dir}, 0),
        "PATH=/usr/bin:/bin",
    });
    defer {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        _ = std.posix.waitpid(pid, 0);
    }
    try lib.posix.setNonBlock(p.master, true);

    // Drive a Session until the hook announces (or 3s budget).
    var s = try Session.init(testing.allocator, .{ .rows = 24, .cols = 80 });
    defer s.deinit();
    var buf: [4096]u8 = undefined;
    const deadline = std.time.nanoTimestamp() + 3 * sec;
    while (std.time.nanoTimestamp() < deadline) {
        const now = std.time.nanoTimestamp();
        const n = std.posix.read(p.master, &buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => return e,
        };
        if (n > 0) try s.feedPty(buf[0..n], now);
        s.tick(now);
        if (s.state().hooked) break;
        std.Thread.sleep(5 * ms);
    }
    try testing.expect(s.state().hooked);
    try testing.expectEqual(Shell.bash, s.state().shell);
}

// ───────────────────── state() snapshot ─────────────────────

test "API: state() reflects feedPty side-effects" {
    var h = try Harness.init();
    defer h.deinit();

    try h.step("\x1b]2;vim\x07\x1b[?1049h\x1b[?1002h");
    const st = h.s.state();
    try testing.expectEqualStrings("vim", st.title.?);
    try testing.expect(st.alt_screen);
    try testing.expect(st.mouse_tracking);
    try testing.expectEqual(@as(u8, 0), st.depth);

    try h.step("\x1b[?1049l\x1b[?1002l");
    try testing.expect(!h.s.state().alt_screen);
    try testing.expect(!h.s.state().mouse_tracking);
}

test "API: setLeaderAttached gates headless DSR replies" {
    var h = try Harness.init();
    defer h.deinit();

    // Headless: ghostty answers `\e[6n` (cursor position report).
    try h.step("\x1b[6n");
    try testing.expect(std.mem.indexOf(u8, h.s.pendingInput(), "\x1b[") != null);
    h.s.consumeInput(h.s.pendingInput().len, h.now);

    // Leader attached: real terminal answers; ghostty stays silent.
    h.s.setLeaderAttached(true);
    try h.step("\x1b[6n");
    try testing.expectEqual(@as(usize, 0), h.s.pendingInput().len);

    h.s.setLeaderAttached(false);
    try h.step("\x1b[6n");
    try testing.expect(h.s.pendingInput().len > 0);
}

// ───────────────────── Options tunability ─────────────────────

test "API: Options timeouts are honoured" {
    var s = try Session.init(testing.allocator, .{
        .rows = 24,
        .cols = 80,
        .accept_timeout_ns = 100,
        .accept_timeout_first_ns = 100,
        .prompt_warn_ns = 50,
        .prompt_timeout_ns = 200,
        .hook_probe_timeout_ns = 75,
    });
    defer s.deinit();

    // Hook deadline = 75.
    var b: [128]u8 = undefined;
    try s.feedPty(done(&b, 1, 0, "/"), 0);
    _ = try s.installHook(1, 0);
    try testing.expectEqual(@as(?i128, 75), s.nextDeadline());
    s.tick(75);
    try testing.expect(s.drainEvents()[0].hook_done.result == .err);
}

// ───────────────────── send / cancel / onPtyEof ─────────────────────

test "API: send queues raw bytes; capped" {
    var h = try Harness.init();
    defer h.deinit();
    try h.s.send("hello\n");
    try testing.expectEqualStrings("hello\n", h.s.pendingInput());
    // Cap.
    const big = try testing.allocator.alloc(u8, Session.pty_input_cap);
    defer testing.allocator.free(big);
    try testing.expectError(lib.Error.PtyInputCapExceeded, h.s.send(big));
}

test "API: cancel drops unsent runs and in-flight hooks by cookie" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    try h.s.run(1, "a", .{}, h.now); // sent (idle)
    try h.s.run(1, "b", .{}, h.now); // unsent
    try h.s.run(2, "c", .{}, h.now); // unsent
    h.s.cancel(1);
    // Sent "a" survives (can't recall PTY bytes); unsent "b" dropped;
    // cookie-2 "c" survives.
    try testing.expectEqual(@as(usize, 2), h.s.state().queued_runs);

    // Hook in flight cancellable by cookie even though sent.
    h.s.cancel(2); // clear "c" so installHook isn't refused
    h.advance(1 * ms);
    try h.step(preexec(&b, 100));
    try h.step(done(&b, 100, 0, "/")); // complete "a"
    _ = h.pop();
    _ = try h.s.installHook(9, h.now);
    h.s.cancel(9);
    try testing.expectEqual(@as(usize, 0), h.s.state().queued_runs);
}

test "API: onPtyEof completes everything with .pty_eof / hook .err" {
    var h = try Harness.init();
    defer h.deinit();
    var b: [128]u8 = undefined;
    try h.step(done(&b, 100, 0, "/"));

    try h.s.run(1, "x", .{}, h.now);
    try h.s.run(2, "y", .{}, h.now);
    h.s.onPtyEof(5 << 8, h.now);
    const evs = h.s.drainEvents();
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(Via.pty_eof, evs[0].run_done.via);
    try testing.expectEqual(@as(?i32, 5), evs[0].run_done.exit_code); // sent
    try testing.expect(evs[1].run_done.exit_code == null); // unsent
}

// ───────────────────── dump ─────────────────────

test "API: dump renders terminal state" {
    var h = try Harness.init();
    defer h.deinit();
    try h.step("hello world\r\n");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try h.s.dump(&buf.writer, .screen);
    try testing.expect(std.mem.indexOf(u8, buf.writer.buffered(), "hello world") != null);

    buf.clearRetainingCapacity();
    try h.s.dump(&buf.writer, .{ .scrollback = null });
    try testing.expect(std.mem.indexOf(u8, buf.writer.buffered(), "hello world") != null);

    buf.clearRetainingCapacity();
    try h.s.dump(&buf.writer, .attach);
    // Attach dump is control sequences; just check it's non-empty.
    try testing.expect(buf.writer.buffered().len > 0);
}

// ───────────────────── tier-1: Scanner standalone ─────────────────────

test "API: Scanner emits events without a Session" {
    var sc = lib.Scanner.init(testing.allocator);
    defer sc.deinit();
    var evs: std.ArrayList(lib.Event) = .empty;
    defer evs.deinit(testing.allocator);

    var b: [128]u8 = undefined;
    try sc.feed(preexec(&b, 42), &evs);
    try sc.feed(done(&b, 42, 7, "/tmp"), &evs);
    try sc.feed("\x1b[?2004h", &evs);

    try testing.expectEqual(@as(usize, 3), evs.items.len);
    try testing.expectEqual(@as(i32, 42), evs.items[0].preexec);
    try testing.expectEqual(@as(i32, 7), evs.items[1].done.exit_code);
    try testing.expectEqualStrings("/tmp", evs.items[1].done.cwd);
    try testing.expect(evs.items[2] == .prompt);
}

test "API: hook namespace exposes assets and builders" {
    try testing.expect(lib.hook.version >= 2);
    try testing.expect(std.mem.indexOf(u8, lib.hook.probe_line, "2718;probe") != null);
    try testing.expect(std.mem.indexOf(u8, lib.hook.body(.bash), "preexec") != null);
    try testing.expect(std.mem.indexOf(u8, lib.hook.body(.zsh), "preexec") != null);
    try testing.expect(std.mem.indexOf(u8, lib.hook.body(.fish), "preexec") != null);

    const inst = try lib.hook.buildInstall(testing.allocator, .bash);
    defer testing.allocator.free(inst);
    try testing.expect(std.mem.indexOf(u8, inst, ".bashrc") != null);

    const wrapped = try lib.hook.wrapPaste(testing.allocator, "ls");
    defer testing.allocator.free(wrapped);
    try testing.expect(std.mem.startsWith(u8, wrapped, "\x15\x1b[200~"));
    try testing.expect(std.mem.endsWith(u8, wrapped, "\x1b[201~\r"));
}

// ───────────────────── clock-purity invariant ─────────────────────

test "API: identical inputs + identical clocks → identical state (determinism)" {
    // Drive two sessions with the exact same byte/time sequence; their
    // observable state and event streams must match. This is the property
    // F2 (clock-purity) buys: replay/record/fuzz reproducibility.
    var b: [128]u8 = undefined;
    const script = [_]struct { t: i128, bytes: []const u8 }{
        .{ .t = 0, .bytes = "\x1b]2718;done;1;0;0;b;/\x07" },
        .{ .t = 5 * ms, .bytes = "" }, // run("x") issued here
        .{ .t = 10 * ms, .bytes = "\x1b]2718;preexec;1\x07" },
        .{ .t = 50 * ms, .bytes = "\x1b]2718;done;1;0;0;b;/\x07" },
    };

    var sa = try Session.init(testing.allocator, .{ .rows = 10, .cols = 40 });
    defer sa.deinit();
    var sb = try Session.init(testing.allocator, .{ .rows = 10, .cols = 40 });
    defer sb.deinit();

    inline for (.{ &sa, &sb }) |s| {
        for (script, 0..) |step, i| {
            if (i == 1) try s.run(7, "x", .{}, step.t);
            s.consumeInput(s.pendingInput().len, step.t);
            try s.feedPty(step.bytes, step.t);
            s.tick(step.t);
        }
    }

    const ea = sa.drainEvents();
    const eb = sb.drainEvents();
    try testing.expectEqual(ea.len, eb.len);
    for (ea, eb) |a, c| try testing.expectEqualDeep(a, c);
    try testing.expectEqualDeep(sa.state(), sb.state());
    _ = &b;
}
