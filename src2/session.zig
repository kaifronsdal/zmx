//! Daemon-side session: owns the ghostty Terminal, the protocol Scanner, and
//! the shell-integration state machine.
//!
//! Pure logic — no fds, no socket I/O. The daemon poll loop reads from the PTY
//! master and calls `feedPtyOutput()`; it drains `pendingPtyInput()` to write
//! back to the PTY master; it reads `completions()` to reply to clients.

const std = @import("std");
const assert = std.debug.assert;
const vt = @import("ghostty-vt");
const protocol = @import("protocol.zig");

/// Floor for the line-acceptance window: nanoseconds the daemon waits, after
/// typing a `run` command, for any acceptance signal (preexec/done/prompt).
/// Past this, the shell is assumed to be at a continuation prompt and the line
/// is rejected with ^C. See repros/poc-hooks/RESULTS.md "incomplete input".
///
/// The actual window is `max(this, 3 * last_preexec_latency_ns)`: a nested
/// hooked shell over SSH can need a full network RTT for the preexec OSC, so
/// the floor alone would spuriously ^C every command on a slow link. 1s is
/// generous for the local continuation-prompt case this was built for while
/// giving margin to sluggish PTYs.
const ACCEPT_TIMEOUT_NS: i128 = 1000 * std.time.ns_per_ms;

/// `ReadonlyStream` is not re-exported from lib_vt; derive it.
const VtStream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());

const RunCompletion = struct {
    /// null when no exit code is knowable (prompt-fallback / line-rejected).
    exit_code: ?i32,
    via: @import("ipc.zig").RunDoneWire.Via,
    dur_ms: u64,
};

const Completion = struct {
    client_id: u32,
    result: RunCompletion,
};

/// One pending `zmx run` request.
const RunRequest = struct {
    /// Owned by Session.
    cmd: []u8,
    /// Opaque; daemon maps it back to a socket.
    client_id: u32,
    /// nanoTimestamp when queued (for the prompt-wait timeout).
    queued_ns: i128,
    /// Bytes queued into pty_input?
    sent: bool = false,
    /// preexec OSC seen?
    accepted: bool = false,
    /// 5s prompt-wait warning already sent to this client?
    warned: bool = false,
    /// nanoTimestamp when typed.
    started_ns: i128 = 0,
    /// nanoTimestamp when pty_input drained to empty after typing (i.e. the
    /// bytes have actually hit the PTY). 0 = not yet. Acceptance timeout is
    /// measured from here, not started_ns.
    flushed_ns: i128 = 0,
};

pub const PromptWait = union(enum) {
    none,
    /// Front request has waited >5s for the first prompt-ready signal.
    warn: u32, // client_id
    /// Front request has waited >30s; daemon should send an explanatory
    /// `.err` to this client (the request has already been completed with
    /// `.prompt_fallback`/null and removed from the queue).
    timeout: u32, // client_id
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    /// Self-referential: `stream.handler.terminal` must point at `self.term`.
    /// Since Session is returned by value from init(), the pointer is fixed up
    /// at the top of every method that touches the stream.
    stream: VtStream,
    scanner: protocol.Scanner,
    nonce: [16]u8,

    // Shell-integration state — orthogonal flags, not an FSM.
    shell: protocol.Shell = .unknown,
    /// A `hello` arrived naming a shell we can't hook (e.g. bash <4 announces
    /// as `bash-pre4`). `run` should fail fast rather than wait 30s.
    unhookable: bool = false,
    /// First `done` OSC seen → hook is installed and emitting.
    hooked: bool = false,
    /// nanoTimestamp when `hooked` flipped false→true. checkAcceptanceTimeout
    /// only applies to requests typed at-or-after this point, so a command
    /// typed in degraded mode isn't ^C'd when a nested shell later hooks.
    hooked_since_ns: i128 = 0,
    /// At least one `?2004h` seen → degraded "back at prompt" detection works.
    seen_prompt: bool = false,
    /// Count of hook injections whose preexec/done echo we're still waiting to
    /// swallow. Usually 0 or 1, but a nested shell can `hello` before the
    /// outer inject's `done` arrives, so this must be a counter, not a bool.
    inject_echo_pending: u8 = 0,
    /// preexec seen, done not yet.
    cmd_running: bool = false,
    /// Observed flush→preexec latency for the most recent accepted request.
    /// Scales the acceptance-timeout window so a nested hook over a slow SSH
    /// link isn't ^C'd just because the OSC took a network RTT to arrive.
    last_preexec_latency_ns: i128 = 0,
    last_exit: ?i32 = null,
    last_cwd: [std.fs.max_path_bytes]u8 = undefined,
    last_cwd_len: usize = 0,

    // I/O queues — daemon drains/fills these.
    /// Bytes to write to PTY master.
    pty_input: std.ArrayList(u8),
    run_queue: std.ArrayList(RunRequest),
    completed: std.ArrayList(Completion),
    /// Scratch reused across feedPtyOutput calls.
    events: std.ArrayList(protocol.Event),

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Session {
        var nonce: [16]u8 = undefined;
        _ = protocol.genNonce(&nonce);

        var term = try vt.Terminal.init(allocator, .{
            .cols = @max(1, cols),
            .rows = @max(1, rows),
        });
        errdefer term.deinit(allocator);

        return .{
            .gpa = allocator,
            .term = term,
            // Handler pointer is patched at the top of feedPtyOutput().
            .stream = VtStream.initAlloc(allocator, .{ .terminal = undefined }),
            .scanner = try protocol.Scanner.init(allocator, &nonce),
            .nonce = nonce,
            .pty_input = .empty,
            .run_queue = .empty,
            .completed = .empty,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.stream.deinit();
        self.term.deinit(self.gpa);
        self.scanner.deinit();
        self.pty_input.deinit(self.gpa);
        for (self.run_queue.items) |*r| self.gpa.free(r.cmd);
        self.run_queue.deinit(self.gpa);
        self.completed.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.* = undefined;
    }

    /// Feed bytes read from PTY master. Updates the Terminal, runs the
    /// Scanner, and processes events: hello → inject hook, preexec → mark
    /// accepted, done → complete front run request, prompt → fallback-complete
    /// when not hooked. May queue bytes into pty_input (hook injection, next
    /// queued command) and append to completions.
    pub fn feedPtyOutput(self: *Session, bytes: []const u8) !void {
        // See doc on the `stream` field.
        self.stream.handler.terminal = &self.term;
        self.stream.nextSlice(bytes);

        self.events.clearRetainingCapacity();
        try self.scanner.feed(bytes, &self.events);

        for (self.events.items) |ev| switch (ev) {
            .hello => |sh| {
                self.shell = sh;
                if (sh == .unknown) {
                    self.unhookable = true;
                    continue;
                }
                self.unhookable = false;
                const inj = try protocol.buildInject(self.gpa, sh, &self.nonce);
                defer self.gpa.free(inj);
                try self.pty_input.appendSlice(self.gpa, inj);
                self.inject_echo_pending +|= 1;
            },
            .preexec => {
                self.cmd_running = true;
                if (self.inject_echo_pending > 0) continue;
                if (self.front()) |r| if (r.sent) {
                    if (r.flushed_ns != 0) {
                        self.last_preexec_latency_ns =
                            std.time.nanoTimestamp() - r.flushed_ns;
                    }
                    r.accepted = true;
                };
            },
            .done => |d| {
                if (!self.hooked) self.hooked_since_ns = std.time.nanoTimestamp();
                self.hooked = true;
                self.cmd_running = false;
                self.last_exit = d.exit_code;
                const n = @min(d.cwd.len, self.last_cwd.len);
                @memcpy(self.last_cwd[0..n], d.cwd[0..n]);
                self.last_cwd_len = n;

                if (self.inject_echo_pending > 0) {
                    self.inject_echo_pending -= 1;
                    continue;
                }
                if (self.front()) |r| if (r.sent) {
                    const req = self.popFront();
                    try self.complete(req, .{
                        .exit_code = d.exit_code,
                        .via = .osc_done,
                        .dur_ms = d.dur_ms,
                    });
                };
            },
            .prompt => {
                self.seen_prompt = true;
                if (self.hooked or self.inject_echo_pending > 0) continue;
                if (self.front()) |r| if (r.sent) {
                    const req = self.popFront();
                    try self.complete(req, .{
                        .exit_code = null,
                        .via = .prompt_fallback,
                        .dur_ms = msSince(req.started_ns, std.time.nanoTimestamp()),
                    });
                };
            },
        };

        // Type the next queued request only after all events from this chunk
        // are processed, so a trailing event in the same chunk can't be
        // misattributed to a request we haven't actually written yet.
        try self.tryTypeNext();
    }

    /// Queue a `zmx run` request. If the shell is idle, types it immediately;
    /// otherwise it waits for the next done/prompt.
    pub fn queueRun(self: *Session, client_id: u32, cmd: []const u8) !void {
        const owned = try self.gpa.dupe(u8, cmd);
        errdefer self.gpa.free(owned);
        try self.run_queue.append(self.gpa, .{
            .cmd = owned,
            .client_id = client_id,
            .queued_ns = std.time.nanoTimestamp(),
        });
        try self.tryTypeNext();
    }

    /// Drop any not-yet-typed run requests from `client_id`. Requests already
    /// typed into the PTY can't be recalled and will complete (and be dropped
    /// at routing time when the client is gone).
    pub fn cancelClientRuns(self: *Session, client_id: u32) void {
        var i: usize = 0;
        while (i < self.run_queue.items.len) {
            const r = &self.run_queue.items[i];
            if (r.client_id == client_id and !r.sent) {
                self.gpa.free(r.cmd);
                _ = self.run_queue.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Max bytes buffered for the PTY master before further input is dropped.
    /// The PTY's kernel buffer is a few KB; if we've queued megabytes the
    /// shell is wedged and accepting more would only OOM the daemon.
    pub const pty_input_cap = 1 * 1024 * 1024;

    /// Queue raw bytes to PTY (zmx send). No waiting, no wrapping.
    pub fn queueSend(self: *Session, bytes: []const u8) !void {
        if (self.pty_input.items.len + bytes.len > pty_input_cap)
            return error.PtyInputOverflow;
        try self.pty_input.appendSlice(self.gpa, bytes);
    }

    /// Bytes the daemon should write to the PTY master.
    pub fn pendingPtyInput(self: *Session) []const u8 {
        return self.pty_input.items;
    }

    /// Discard the first `n` bytes of pending PTY input (after a successful
    /// write to the master).
    pub fn consumePtyInput(self: *Session, n: usize) void {
        assert(n <= self.pty_input.items.len);
        const rem = self.pty_input.items.len - n;
        std.mem.copyForwards(u8, self.pty_input.items[0..rem], self.pty_input.items[n..]);
        self.pty_input.shrinkRetainingCapacity(rem);
        // The acceptance-timeout window opens once the typed bytes have
        // actually reached the PTY.
        if (rem == 0) {
            if (self.front()) |r| if (r.sent and r.flushed_ns == 0) {
                r.flushed_ns = std.time.nanoTimestamp();
            };
        }
    }

    /// Completed run requests since the last clearCompletions().
    pub fn completions(self: *Session) []const Completion {
        return self.completed.items;
    }

    pub fn clearCompletions(self: *Session) void {
        self.completed.clearRetainingCapacity();
    }

    /// PTY master hit EOF. Complete every queued request with `.pty_eof`
    /// and the waitpid-derived exit code.
    pub fn onPtyEof(self: *Session, wait_status: u32) void {
        const W = std.posix.W;
        const ec: i32 = if (W.IFEXITED(wait_status))
            @intCast(W.EXITSTATUS(wait_status))
        else if (W.IFSIGNALED(wait_status))
            128 + @as(i32, @intCast(W.TERMSIG(wait_status)))
        else
            -1;
        const now = std.time.nanoTimestamp();
        while (self.run_queue.items.len > 0) {
            const req = self.popFront();
            self.complete(req, .{
                .exit_code = if (req.sent) ec else null,
                .via = .pty_eof,
                .dur_ms = if (req.sent) msSince(req.started_ns, now) else 0,
            }) catch {};
        }
    }

    /// Called periodically by the daemon (e.g. after poll timeout). If the
    /// front request was typed >ACCEPT_TIMEOUT ago and no acceptance signal
    /// arrived, send ^C and complete with `.line_rejected`. Returns true if
    /// action was taken.
    pub fn checkAcceptanceTimeout(self: *Session, now_ns: i128) bool {
        // No preexec signal exists in degraded mode; can't distinguish
        // "running" from "continuation" so don't ^C real commands.
        if (!self.hooked) return false;
        const r = self.front() orelse return false;
        if (!r.sent or r.accepted) return false;
        // Typed before the hook went live (degraded path) → no preexec was
        // ever expected for this request, so absence of acceptance is not a
        // continuation-prompt signal. Don't ^C it.
        if (r.started_ns < self.hooked_since_ns) return false;
        if (r.flushed_ns == 0) return false;
        // Adaptive window: 3x the last observed flush→preexec round-trip,
        // floored at ACCEPT_TIMEOUT_NS. First command after hooking uses the
        // floor (latency is 0); subsequent ones scale to the link.
        const window = @max(ACCEPT_TIMEOUT_NS, 3 * self.last_preexec_latency_ns);
        if (now_ns - r.flushed_ns < window) return false;

        // Shell is at a continuation prompt (unclosed quote, etc.). Abort.
        self.pty_input.append(self.gpa, 0x03) catch {};
        const req = self.popFront();
        self.complete(req, .{
            .exit_code = null,
            .via = .line_rejected,
            .dur_ms = msSince(req.started_ns, now_ns),
        }) catch {};
        return true;
    }

    /// Soft-warn / hard-fail for a queued request that can't be typed. Two
    /// causes: (a) the shell hasn't reached its first prompt yet (slow rc,
    /// nested unrecognized shell) — warns at 5s, hard-fails at 30s; (b) the
    /// request is queued behind a still-running previous command (e.g. front
    /// request is `ssh remote`) — warns at 5s, never hard-fails. Caller should
    /// send an `.err` to the returned client_id. On `.timeout` the request has
    /// already been completed with `.prompt_fallback`/null.
    pub fn checkPromptWait(self: *Session, now_ns: i128) PromptWait {
        // Wedge recovery: a nested inject was queued but its `done` never
        // arrived (shell died, hook failed). canType() is stuck false and the
        // `hooked` gate below would suppress the normal timeout. Force-clear
        // after 5s so the queue can drain.
        if (self.hooked and self.inject_echo_pending > 0) {
            if (self.front()) |r| if (!r.sent and now_ns - r.queued_ns >= 5 * std.time.ns_per_s) {
                std.log.warn(
                    "inject echo never completed ({d} pending); forcing clear",
                    .{self.inject_echo_pending},
                );
                self.inject_echo_pending = 0;
                self.tryTypeNext() catch {};
                return .{ .warn = r.client_id };
            };
        }
        // First not-yet-typed request. Not necessarily front(): when hooked,
        // front may be a long-running command (e.g. `ssh remote`) with a
        // second request queued behind it — that second client deserves a
        // "still waiting" notice rather than silence.
        const r: *RunRequest = for (self.run_queue.items) |*rq| {
            if (!rq.sent) break rq;
        } else return .none;
        const waited = now_ns - r.queued_ns;

        // Hard timeout only applies before the shell has ever signalled
        // readiness. Once hooked/seen_prompt, an unsent request is queued
        // behind a running command which may legitimately take hours — never
        // fail it, just warn below. If the shell has explicitly announced as
        // unhookable (e.g. bash <4), fail immediately rather than wait 30s.
        if (!self.hooked and !self.seen_prompt and
            (self.unhookable or waited >= 30 * std.time.ns_per_s))
        {
            // Nothing can be sent before readiness, so r is front().
            const req = self.popFront();
            const cid = req.client_id;
            self.complete(req, .{
                .exit_code = null,
                .via = .prompt_fallback,
                .dur_ms = msSince(req.queued_ns, now_ns),
            }) catch {};
            return .{ .timeout = cid };
        }
        if (waited >= 5 * std.time.ns_per_s and !r.warned) {
            r.warned = true;
            return .{ .warn = r.client_id };
        }
        return .none;
    }

    pub fn isAltScreen(self: *Session) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// A typed run is awaiting its acceptance signal (preexec). Only the
    /// front request can be in this state.
    pub fn pendingAcceptance(self: *Session) bool {
        const r = self.front() orelse return false;
        return r.sent and !r.accepted;
    }

    pub fn resize(self: *Session, rows: u16, cols: u16) !void {
        // ghostty-vt panics on 0 and OOMs on absurd sizes; clamp both ends.
        try self.term.resize(
            self.gpa,
            std.math.clamp(cols, 1, 1000),
            std.math.clamp(rows, 1, 500),
        );
    }

    pub fn lastCwd(self: *const Session) []const u8 {
        return self.last_cwd[0..self.last_cwd_len];
    }

    // ───────────────────────── internals ─────────────────────────

    fn front(self: *Session) ?*RunRequest {
        if (self.run_queue.items.len == 0) return null;
        return &self.run_queue.items[0];
    }

    /// Remove and return the front request. Caller must pass it to complete()
    /// (which frees cmd) or free cmd itself.
    fn popFront(self: *Session) RunRequest {
        assert(self.run_queue.items.len > 0);
        return self.run_queue.orderedRemove(0);
    }

    fn complete(self: *Session, req: RunRequest, result: RunCompletion) !void {
        self.gpa.free(req.cmd);
        try self.completed.append(self.gpa, .{
            .client_id = req.client_id,
            .result = result,
        });
    }

    /// Can a queued command be typed right now?
    fn canType(self: *Session) bool {
        if (self.cmd_running) return false;
        if (self.isAltScreen()) return false;
        // Hook injection in flight: wait for its `done` (which sets `hooked`)
        // so the request lands on a hooked prompt. Matters for fish, where
        // `?2004h` precedes `fish_prompt` and would otherwise look like a
        // ready-but-unhooked prompt.
        if (self.inject_echo_pending > 0) return false;
        // Need at least one prompt-readiness signal: either the hook is live
        // or we've seen bracketed-paste-on (degraded path).
        if (!self.hooked and !self.seen_prompt) return false;
        // Don't type over an already-in-flight request.
        if (self.front()) |r| if (r.sent) return false;
        return true;
    }

    fn tryTypeNext(self: *Session) !void {
        if (self.run_queue.items.len == 0) return;
        if (!self.canType()) return;
        try self.typeCommand(&self.run_queue.items[0]);
    }

    /// Ctrl-U, bracketed-paste, cmd, end-paste, CR.
    fn typeCommand(self: *Session, req: *RunRequest) !void {
        try self.pty_input.appendSlice(self.gpa, "\x15\x1b[200~");
        try self.pty_input.appendSlice(self.gpa, req.cmd);
        try self.pty_input.appendSlice(self.gpa, "\x1b[201~\r");
        req.sent = true;
        req.started_ns = std.time.nanoTimestamp();
    }

    fn msSince(start_ns: i128, now_ns: i128) u64 {
        const d = now_ns - start_ns;
        if (d <= 0) return 0;
        return @intCast(@divTrunc(d, std.time.ns_per_ms));
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn doneOsc(buf: []u8, nonce: []const u8, ec: i32, cwd: []const u8, dur: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "\x1b]2718;done;{s};{d};{d};{s}\x07",
        .{ nonce, ec, dur, cwd },
    ) catch unreachable;
}

fn preexecOsc(buf: []u8, nonce: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b]2718;preexec;{s}\x07", .{nonce}) catch unreachable;
}

/// Bring a fresh session to the hooked+idle state (hello, drain inject, done).
fn hookAndIdle(s: *Session) !void {
    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/", 0));
    s.clearCompletions();
}

test "hello queues hook injection" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    try testing.expectEqual(protocol.Shell.bash, s.shell);
    try testing.expect(!s.hooked);

    const inp = s.pendingPtyInput();
    try testing.expect(std.mem.startsWith(u8, inp, "\x15\x1b[200~"));
    try testing.expect(std.mem.indexOf(u8, inp, "__ZMX_HOOKED") != null);
    try testing.expect(std.mem.endsWith(u8, inp, "\x1b[201~\r"));
}

test "first done sets hooked + last_exit" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    s.consumePtyInput(s.pendingPtyInput().len);

    var b: [128]u8 = undefined;
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 42, "/tmp", 7));

    try testing.expect(s.hooked);
    try testing.expect(!s.cmd_running);
    try testing.expectEqual(@as(?i32, 42), s.last_exit);
    try testing.expectEqualStrings("/tmp", s.lastCwd());
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "queueRun while idle: type, preexec, done -> completion" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "echo hi");
    const want = "\x15\x1b[200~echo hi\x1b[201~\r";
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), want));
    try testing.expect(s.run_queue.items[0].sent);

    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try testing.expect(s.cmd_running);
    try testing.expect(s.run_queue.items[0].accepted);

    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/tmp", 5));
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expectEqual(@as(?i32, 0), comps[0].result.exit_code);
    try testing.expect(comps[0].result.via == .osc_done);
    try testing.expectEqual(@as(u64, 5), comps[0].result.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "queueRun while busy waits for done" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    try s.queueRun(1, "first");
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try testing.expect(s.cmd_running);

    // Second request arrives mid-command.
    try s.queueRun(2, "second");
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expect(!s.run_queue.items[1].sent);

    // First done -> complete #1 and type #2.
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/", 1));
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(u32, 1), s.completions()[0].client_id);
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "second\x1b[201~\r"));
    try testing.expect(s.run_queue.items[0].sent);
}

test "prompt-fallback when not hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    // No hello/hook. First ?2004h marks the prompt as ready (degraded path).
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expect(s.seen_prompt);
    try testing.expect(!s.hooked);

    try s.queueRun(7, "echo hi");
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "echo hi\x1b[201~\r"));

    // Shell echoes the command, returns to prompt -> ?2004h again.
    try s.feedPtyOutput("\x1b[?2004h");
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 7), comps[0].client_id);
    try testing.expectEqual(@as(?i32, null), comps[0].result.exit_code);
    try testing.expect(comps[0].result.via == .prompt_fallback);
}

test "prompt ignored when hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "x");
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    // Hooked: ?2004h is not authoritative, done is.
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 3, "/", 1));
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(?i32, 3), s.completions()[0].result.exit_code);
}

test "alt-screen gates typing" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.feedPtyOutput("\x1b[?1049h");
    try testing.expect(s.isAltScreen());

    try s.queueRun(1, "echo hi");
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    try testing.expect(!s.run_queue.items[0].sent);

    var b: [128]u8 = undefined;
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b[?1049l");
    try seq.appendSlice(testing.allocator, doneOsc(&b, &s.nonce, 0, "/", 1));
    try s.feedPtyOutput(seq.items);

    try testing.expect(!s.isAltScreen());
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "echo hi\x1b[201~\r"));
    // The done belonged to the TUI's wrapping shell, not our command.
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "checkAcceptanceTimeout sends ^C and rejects" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(9, "echo \"unclosed");
    try testing.expect(s.run_queue.items[0].sent);

    // Window doesn't open until bytes hit the PTY.
    try testing.expect(!s.checkAcceptanceTimeout(std.math.maxInt(i64)));

    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    try testing.expect(tf != 0);

    // Not yet.
    try testing.expect(!s.checkAcceptanceTimeout(tf + @divTrunc(ACCEPT_TIMEOUT_NS, 2)));
    try testing.expectEqual(@as(usize, 0), s.completions().len);

    // Past the threshold.
    try testing.expect(s.checkAcceptanceTimeout(tf + ACCEPT_TIMEOUT_NS + 100 * std.time.ns_per_ms));
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "\x03"));
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expect(comps[0].result.via == .line_rejected);
    try testing.expectEqual(@as(?i32, null), comps[0].result.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "checkAcceptanceTimeout disabled when not hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(1, "sleep 5");
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expect(!s.checkAcceptanceTimeout(std.math.maxInt(i64)));
}

test "two dones in one chunk don't misattribute" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "a");
    try s.queueRun(2, "b");
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));

    // One chunk: done(a, ec=7) immediately followed by a stray done(ec=99).
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(testing.allocator);
    try chunk.appendSlice(testing.allocator, doneOsc(&b, &s.nonce, 7, "/", 1));
    try chunk.appendSlice(testing.allocator, doneOsc(&b, &s.nonce, 99, "/", 1));
    try s.feedPtyOutput(chunk.items);

    // Only req#1 completed; req#2 was typed at end-of-chunk, NOT completed.
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expectEqual(@as(?i32, 7), comps[0].result.exit_code);
    try testing.expect(s.run_queue.items.len == 1 and s.run_queue.items[0].sent);
}

test "checkAcceptanceTimeout ignored once accepted" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "sleep 10");
    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));

    try testing.expect(!s.checkAcceptanceTimeout(tf + 10 * std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "onPtyEof completes all queued" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "exec true");
    try s.queueRun(2, "never runs");
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);

    // Exit code 5 in the high byte of wait status.
    s.onPtyEof(5 << 8);
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expect(comps[0].result.via == .pty_eof);
    try testing.expectEqual(@as(?i32, 5), comps[0].result.exit_code);
    // Never-sent request: no exit code, zero duration.
    try testing.expectEqual(@as(u32, 2), comps[1].client_id);
    try testing.expectEqual(@as(?i32, null), comps[1].result.exit_code);
    try testing.expectEqual(@as(u64, 0), comps[1].result.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "resize clamps zero" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.resize(0, 0);
    try testing.expect(s.term.screens.active.pages.rows >= 1);
    try testing.expect(s.term.screens.active.pages.cols >= 1);
}

test "queueSend is raw passthrough" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.queueSend("jk\x1b");
    try testing.expectEqualStrings("jk\x1b", s.pendingPtyInput());
    s.consumePtyInput(2);
    try testing.expectEqualStrings("\x1b", s.pendingPtyInput());
}

test "hello with unknown shell skips inject" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b]2718;hello;powershell\x07");
    try testing.expectEqual(protocol.Shell.unknown, s.shell);
    try testing.expect(s.unhookable);
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
}

test "unhookable hello fails queued run immediately (bash <4 path)" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    // Cold-start race: run arrives before hello.
    try s.queueRun(5, "true");
    try testing.expect(!s.run_queue.items[0].sent);
    // bash 3.2 rc shim announces as bash-pre4 → .unknown → unhookable.
    try s.feedPtyOutput("\x1b]2718;hello;bash-pre4\x07");
    try testing.expect(s.unhookable);
    // checkPromptWait should fail it now, not in 30s.
    const r = s.checkPromptWait(s.run_queue.items[0].queued_ns + std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 5), r.timeout);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "resize clamps absurd dimensions" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.resize(65535, 65535);
    try testing.expect(s.term.screens.active.pages.rows <= 500);
    try testing.expect(s.term.screens.active.pages.cols <= 1000);
    try testing.expect(s.term.screens.active.pages.rows >= 1);
}

test "queueRun with 2MB command is buffered without leak" {
    // typeCommand() does NOT enforce pty_input_cap (only queueSend() does), so
    // an oversized run command is simply buffered. This test pins that there
    // is no panic and no leak: the duped cmd is owned by run_queue and freed
    // on deinit (testing.allocator asserts). The daemon is expected to reject
    // pathological run payloads at the IPC layer before they reach here.
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    const big = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try s.queueRun(1, big);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expect(s.pendingPtyInput().len > Session.pty_input_cap);
    // cmd slice is the duped copy, distinct from `big`.
    try testing.expect(s.run_queue.items[0].cmd.ptr != big.ptr);
}

test "cancelClientRuns drops only unsent for that client" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "a"); // typed immediately (idle, hooked)
    try s.queueRun(2, "b"); // queued, unsent
    try s.queueRun(1, "c"); // queued, unsent
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expect(!s.run_queue.items[1].sent);
    try testing.expect(!s.run_queue.items[2].sent);

    s.cancelClientRuns(1);

    // "a" is already in the PTY and can't be recalled; "c" is dropped; "b"
    // (different client) survives.
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expectEqualStrings("a", s.run_queue.items[0].cmd);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expectEqualStrings("b", s.run_queue.items[1].cmd);
    try testing.expectEqual(@as(u32, 2), s.run_queue.items[1].client_id);
}

test "two hellos before first done: second inject's echo not misattributed" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    // Outer shell announces, then a nested shell announces before the outer
    // inject's done arrives.
    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    try testing.expectEqual(@as(u8, 2), s.inject_echo_pending);
    s.consumePtyInput(s.pendingPtyInput().len);

    try s.queueRun(1, "real");
    try testing.expect(!s.run_queue.items[0].sent);

    var b: [128]u8 = undefined;
    // First inject's done: counter 2→1. Request must NOT be typed yet (with
    // the old bool this would have flipped to false and typed it).
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/", 0));
    try testing.expectEqual(@as(u8, 1), s.inject_echo_pending);
    try testing.expect(!s.run_queue.items[0].sent);
    try testing.expectEqual(@as(usize, 0), s.completions().len);

    // Second inject's preexec+done: swallowed, counter 1→0, THEN request is
    // typed. With the old bool the preexec/done here would have been credited
    // to the (prematurely-typed) request.
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 99, "/", 0));
    try testing.expectEqual(@as(u8, 0), s.inject_echo_pending);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expectEqual(@as(usize, 0), s.completions().len);

    // Real command's preexec+done.
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 7, "/", 3));
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(?i32, 7), s.completions()[0].result.exit_code);
}

test "stuck inject_echo_pending recovers after 5s" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    // Nested shell hellos; we queue an inject and bump the counter — but the
    // shell dies before emitting `done`, so the counter never drains.
    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expectEqual(@as(u8, 1), s.inject_echo_pending);

    try s.queueRun(5, "echo hi");
    const t0 = s.run_queue.items[0].queued_ns;
    try testing.expect(!s.run_queue.items[0].sent); // wedged

    // Before 5s: still wedged, no warn (hooked gate would normally suppress).
    try testing.expect(s.checkPromptWait(t0 + 2 * std.time.ns_per_s) == .none);
    try testing.expect(!s.run_queue.items[0].sent);

    // After 5s: recovery forces the counter to 0, types the request, warns.
    const pw = s.checkPromptWait(t0 + 6 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 5), pw.warn);
    try testing.expectEqual(@as(u8, 0), s.inject_echo_pending);
    try testing.expect(s.run_queue.items[0].sent);

    // Subsequent ticks are quiet.
    try testing.expect(s.checkPromptWait(t0 + 7 * std.time.ns_per_s) == .none);
}

test "degraded->hooked transition does not ^C pre-hook request" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    // Degraded mode: prompt seen, no hook. Request is typed without preexec.
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(3, "sleep 60");
    try testing.expect(s.run_queue.items[0].sent);
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expect(s.run_queue.items[0].flushed_ns != 0);

    // While that command runs, a nested shell announces and its inject's
    // `done` flips hooked=true.
    try s.feedPtyOutput("\x1b]2718;hello;bash\x07");
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/", 0));
    try testing.expect(s.hooked);
    try testing.expect(s.run_queue.items[0].started_ns < s.hooked_since_ns);

    // The request was typed before the hook went live, so the acceptance
    // timeout must NOT ^C it even though accepted=false and hooked=true.
    try testing.expect(!s.run_queue.items[0].accepted);
    try testing.expect(!s.checkAcceptanceTimeout(std.math.maxInt(i64)));
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);
}

test "acceptance timeout adapts to observed preexec latency" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First command: backdate flushed_ns so the preexec that follows records
    // a ~800ms round-trip (simulating a hooked shell behind a slow SSH link).
    try s.queueRun(1, "a");
    s.consumePtyInput(s.pendingPtyInput().len);
    s.run_queue.items[0].flushed_ns = std.time.nanoTimestamp() - 800 * std.time.ns_per_ms;
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try testing.expect(s.last_preexec_latency_ns >= 800 * std.time.ns_per_ms);
    try s.feedPtyOutput(doneOsc(&b, &s.nonce, 0, "/", 1));
    s.clearCompletions();

    // Second command: window is now max(1s, 3 * ~800ms) ≈ 2.4s.
    try s.queueRun(2, "b");
    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    const window = @max(ACCEPT_TIMEOUT_NS, 3 * s.last_preexec_latency_ns);
    try testing.expect(window > ACCEPT_TIMEOUT_NS);
    // Past the 1s floor but inside the adaptive window: must NOT reject.
    try testing.expect(!s.checkAcceptanceTimeout(tf + ACCEPT_TIMEOUT_NS + 200 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    // Past the adaptive window: rejects.
    try testing.expect(s.checkAcceptanceTimeout(tf + window + 100 * std.time.ns_per_ms));
    try testing.expect(s.completions()[0].result.via == .line_rejected);
}

test "checkPromptWait warns for request queued behind a running command" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First request: typed and accepted; runs indefinitely (e.g. ssh with no
    // remote announce → cmd_running stays true, no `done` ever arrives).
    try s.queueRun(1, "ssh remote");
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, &s.nonce));
    try testing.expect(s.cmd_running);

    // Second request: blocked on cmd_running.
    try s.queueRun(2, "ls");
    try testing.expect(!s.run_queue.items[1].sent);
    const t0 = s.run_queue.items[1].queued_ns;

    // Before 5s: silent.
    try testing.expect(s.checkPromptWait(t0 + 2 * std.time.ns_per_s) == .none);
    // At 5s: warn fires for client 2 (not client 1 — front is sent).
    try testing.expectEqual(@as(u32, 2), s.checkPromptWait(t0 + 6 * std.time.ns_per_s).warn);
    // One-shot.
    try testing.expect(s.checkPromptWait(t0 + 7 * std.time.ns_per_s) == .none);
    // No hard timeout even past 60s — previous command may run for hours.
    try testing.expect(s.checkPromptWait(t0 + 90 * std.time.ns_per_s) == .none);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "checkPromptWait: warn at 5s, timeout at 30s, none once ready" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    // No hello/done/?2004h yet — shell is "starting".
    try s.queueRun(7, "echo hi");
    const t0 = s.run_queue.items[0].queued_ns;
    try testing.expect(!s.run_queue.items[0].sent);

    try testing.expect(s.checkPromptWait(t0 + 1 * std.time.ns_per_s) == .none);
    try testing.expectEqual(@as(u32, 7), s.checkPromptWait(t0 + 6 * std.time.ns_per_s).warn);
    // Warn fires once.
    try testing.expect(s.checkPromptWait(t0 + 7 * std.time.ns_per_s) == .none);
    // Hard timeout completes the request.
    try testing.expectEqual(@as(u32, 7), s.checkPromptWait(t0 + 31 * std.time.ns_per_s).timeout);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expect(s.completions()[0].result.via == .prompt_fallback);
    s.clearCompletions();

    // Once the prompt-ready signal arrives, no more warns/timeouts.
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(8, "echo hi");
    try testing.expect(s.checkPromptWait(std.time.nanoTimestamp() + 60 * std.time.ns_per_s) == .none);
}
