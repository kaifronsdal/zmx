//! OSC-2718 shell-integration protocol.
//!
//! Wire format (terminator is BEL `\x07` or ST `\x1b\\`):
//!   ESC ] 2718;hello;<shell>;<pid> BEL
//!   ESC ] 2718;preexec;<pid> BEL
//!   ESC ] 2718;done;<pid>;<ec>;<dur_ms>;<cwd> BEL   (cwd last: may contain ';')
//!   ESC ] 2718;probe;b=<bash_v>,z=<zsh_v>,f=<fish_v>,h=<hook_v> BEL
//!
//! Also detects:
//!   ESC [ ? 2004 h   bracketed-paste on  -> .prompt (fallback "back at prompt")
//!
//! `<pid>` is the emitting shell's PID; the daemon uses it to disambiguate
//! nested layers (the local shell vs. an inner `ssh remote`). There is no
//! per-session nonce — child-process OSC forgery is not in the threat model
//! and pid serves the disambiguation purpose.
//!
//! This file is the *parser* (PTY output → events). What zmyth *types into*
//! a shell (hook inject, install, probe) lives in `shell.zig`.

const std = @import("std");
const assert = std.debug.assert;

// We scan for *any* OSC introducer, then dispatch on the body prefix in
// parsePayload. Unrecognised OSCs (titles, hyperlinks, clipboard, …) are
// cheap to skip: find terminator, drop. This keeps the boundary-safe scan
// logic uniform across 2718/7/133 instead of one indexOf per number.
const OSC_START = "\x1b]";
const BEL = "\x07";
const ST = "\x1b\\";
const BP_ON = "\x1b[?2004h";

/// Longest possible partial prefix of any marker we scan for. Used to bound
/// the tail we keep when no marker is found.
const MAX_TAIL = 32;
/// Hard cap on an unterminated OSC payload before we give up and skip it.
const MAX_OSC_PAYLOAD = 4096;

pub const Shell = enum {
    bash,
    zsh,
    fish,
    unknown,

    pub fn parse(s: []const u8) Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        return .unknown;
    }
};

pub const Hello = struct { shell: Shell, pid: i32 };
pub const Done = struct { pid: i32, exit_code: i32, cwd: []const u8, dur_ms: u64 };
/// Response to `probe_line`. `shell` is whichever of b=/z=/f= was non-empty
/// (`.unknown` if none — sh/dash/ksh ran the printf with all vars empty).
/// `shell_major` is the leading integer of that shell's `*_VERSION`.
/// `hook_v` is the reported `$__ZMYTH_HOOK_V` (0 if unset).
pub const ProbeResult = struct { shell: Shell, shell_major: u32, hook_v: u32 };

pub const Event = union(enum) {
    hello: Hello,
    preexec: i32, // pid
    done: Done,
    probe: ProbeResult,
    /// CSI ?2004h (bracketed-paste on) — shell is back at the prompt
    prompt,
    /// OSC 7 `file://<host>/<path>`: shell-reported cwd. Path component only,
    /// percent-encoding left intact. Slice valid until next feed().
    pwd: []const u8,
    /// OSC 133;D[;<exit_code>]: FinalTerm/iTerm2 "command finished". Emitted
    /// by starship/oh-my-posh independently of our hook, so it gives degraded
    /// `run` a real exit code. null when no code argument was present.
    osc133_end: ?i32,
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    /// Accumulator for boundary-safe scanning.
    buf: std.ArrayList(u8),
    /// Backing storage for `done.cwd` slices emitted during the current feed().
    /// Cleared at the top of each feed(); all cwd slices in one batch point at
    /// disjoint ranges of this buffer.
    cwd_storage: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Scanner {
        return .{ .gpa = allocator, .buf = .empty, .cwd_storage = .empty };
    }

    pub fn deinit(self: *Scanner) void {
        self.buf.deinit(self.gpa);
        self.cwd_storage.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append `data` to the internal buffer and emit any complete events into
    /// `out`. Slices inside emitted events (currently only `done.cwd`) point
    /// into scanner-owned storage valid until the next feed() call.
    pub fn feed(self: *Scanner, data: []const u8, out: *std.ArrayList(Event)) !void {
        // ensureTotalCapacity up front so appended cwd slices don't move.
        self.cwd_storage.clearRetainingCapacity();
        try self.cwd_storage.ensureTotalCapacity(self.gpa, self.buf.items.len + data.len);
        try self.buf.appendSlice(self.gpa, data);

        while (true) {
            const b = self.buf.items;

            // Find the earliest marker.
            var best: usize = std.math.maxInt(usize);
            var which: enum { none, osc, prompt } = .none;
            if (std.mem.indexOf(u8, b, OSC_START)) |i| if (i < best) {
                best = i;
                which = .osc;
            };
            if (std.mem.indexOf(u8, b, BP_ON)) |i| if (i < best) {
                best = i;
                which = .prompt;
            };

            switch (which) {
                .none => {
                    // No marker. Keep at most a tail that could be a partial
                    // prefix of any marker.
                    if (b.len > MAX_TAIL) self.consume(b.len - MAX_TAIL);
                    return;
                },
                .prompt => {
                    try out.append(self.gpa, .prompt);
                    self.consume(best + BP_ON.len);
                },
                .osc => {
                    const tail = b[best + OSC_START.len ..];
                    const t_bel = std.mem.indexOf(u8, tail, BEL);
                    const t_st = std.mem.indexOf(u8, tail, ST);
                    const t_csi = std.mem.indexOf(u8, tail, "\x1b[");
                    const term: struct { off: usize, len: usize } = blk: {
                        // A CSI introducer inside the payload means the OSC
                        // was never terminated. Real VT parsers abort the OSC
                        // on ESC-then-[ and dispatch the CSI; do the same so
                        // a malformed hook emission can't trap a following
                        // ?2004h and suppress .prompt forever.
                        if (t_csi) |tc| {
                            const before_bel = if (t_bel) |tb| tc < tb else true;
                            const before_st = if (t_st) |ts| tc < ts else true;
                            if (before_bel and before_st) {
                                self.consume(best + OSC_START.len + tc);
                                continue;
                            }
                        }
                        if (t_bel) |tb| {
                            if (t_st) |ts| {
                                break :blk if (tb < ts) .{ .off = tb, .len = 1 } else .{ .off = ts, .len = 2 };
                            }
                            break :blk .{ .off = tb, .len = 1 };
                        }
                        if (t_st) |ts| break :blk .{ .off = ts, .len = 2 };
                        // Incomplete OSC. Keep from the OSC start onward and
                        // wait for more data — unless the payload has grown
                        // implausibly large, in which case skip the start
                        // bytes so we don't wedge.
                        if (tail.len > MAX_OSC_PAYLOAD) {
                            self.consume(best + OSC_START.len);
                            continue;
                        }
                        self.consume(best);
                        return;
                    };
                    const payload = tail[0..term.off];
                    self.parsePayload(payload, out) catch {};
                    self.consume(best + OSC_START.len + term.off + term.len);
                },
            }
        }
    }

    fn parsePayload(self: *Scanner, body: []const u8, out: *std.ArrayList(Event)) !void {
        // body is everything between `\e]` and the terminator.
        if (std.mem.startsWith(u8, body, "2718;"))
            return self.parse2718(body[5..], out);
        if (std.mem.startsWith(u8, body, "7;"))
            return self.parsePwd(body[2..], out);
        if (std.mem.startsWith(u8, body, "133;D"))
            return out.append(self.gpa, .{ .osc133_end = parse133D(body[5..]) });
        // Everything else (OSC 0/2/8/52/133;A-C/…) is handled by ghostty's
        // Terminal directly; nothing to surface here.
    }

    /// `file://[host]/path` → emit `.pwd = "/path"`. Host ignored. Percent-
    /// encoding left intact (consumer can decode; we just want a display cwd).
    fn parsePwd(self: *Scanner, uri: []const u8, out: *std.ArrayList(Event)) !void {
        const rest = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else return;
        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse return;
        const path = rest[path_start..];
        const off = self.cwd_storage.items.len;
        self.cwd_storage.appendSliceAssumeCapacity(path);
        try out.append(self.gpa, .{ .pwd = self.cwd_storage.items[off..] });
    }

    fn parse2718(self: *Scanner, payload: []const u8, out: *std.ArrayList(Event)) !void {
        var it = std.mem.splitScalar(u8, payload, ';');
        const kind = it.next() orelse return;
        if (std.mem.eql(u8, kind, "hello")) {
            const sh = it.next() orelse return;
            const pid = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            try out.append(self.gpa, .{ .hello = .{ .shell = Shell.parse(sh), .pid = pid } });
        } else if (std.mem.eql(u8, kind, "preexec")) {
            const pid = std.fmt.parseInt(i32, it.next() orelse return, 10) catch return;
            try out.append(self.gpa, .{ .preexec = pid });
        } else if (std.mem.eql(u8, kind, "done")) {
            const pid_s = it.next() orelse return;
            const ec_s = it.next() orelse return;
            const dur_s = it.next() orelse return;
            const cwd = it.rest(); // last field; may contain ';'
            const pid = std.fmt.parseInt(i32, pid_s, 10) catch return;
            const ec = std.fmt.parseInt(i32, ec_s, 10) catch return;
            const dur_i = std.fmt.parseInt(i64, dur_s, 10) catch return;
            // Stash cwd. Capacity was reserved up front so the slice is stable.
            const off = self.cwd_storage.items.len;
            self.cwd_storage.appendSliceAssumeCapacity(cwd);
            try out.append(self.gpa, .{ .done = .{
                .pid = pid,
                .exit_code = ec,
                .cwd = self.cwd_storage.items[off..],
                .dur_ms = @intCast(@max(0, dur_i)),
            } });
        } else if (std.mem.eql(u8, kind, "probe")) {
            try out.append(self.gpa, .{ .probe = parseProbe(it.rest()) });
        }
        // Unknown kinds are ignored.
    }

    /// Remove the first `n` bytes from the accumulator.
    fn consume(self: *Scanner, n: usize) void {
        assert(n <= self.buf.items.len);
        const rem = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[n..]);
        self.buf.shrinkRetainingCapacity(rem);
    }
};

/// `b=5.2.21(1)-release,z=,f=,h=1` → which shell + its major version + hook_v.
fn parseProbe(body: []const u8) ProbeResult {
    var r: ProbeResult = .{ .shell = .unknown, .shell_major = 0, .hook_v = 0 };
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |kv| {
        if (kv.len < 2 or kv[1] != '=') continue;
        const val = kv[2..];
        if (val.len == 0) continue;
        switch (kv[0]) {
            'b' => {
                r.shell = .bash;
                r.shell_major = leadingInt(val);
            },
            'z' => {
                r.shell = .zsh;
                r.shell_major = leadingInt(val);
            },
            'f' => {
                r.shell = .fish;
                r.shell_major = leadingInt(val);
            },
            'h' => r.hook_v = leadingInt(val),
            else => {},
        }
    }
    return r;
}

/// `133;D` body after the `D`: empty, or `;<exit_code>[;aid=...]`.
fn parse133D(rest: []const u8) ?i32 {
    if (rest.len < 2 or rest[0] != ';') return null;
    var it = std.mem.splitScalar(u8, rest[1..], ';');
    return std.fmt.parseInt(i32, it.first(), 10) catch null;
}

fn leadingInt(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
    }
    return n;
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn collectOne(s: *Scanner, data: []const u8) !?Event {
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(s.gpa);
    try s.feed(data, &evs);
    if (evs.items.len == 0) return null;
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    return evs.items[0];
}

test "Shell.parse" {
    try testing.expectEqual(Shell.bash, Shell.parse("bash"));
    try testing.expectEqual(Shell.zsh, Shell.parse("zsh"));
    try testing.expectEqual(Shell.fish, Shell.parse("fish"));
    try testing.expectEqual(Shell.unknown, Shell.parse("powershell"));
}

test "hello BEL-terminated" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;hello;bash;1234\x07")).?;
    try testing.expectEqual(Shell.bash, ev.hello.shell);
    try testing.expectEqual(@as(i32, 1234), ev.hello.pid);
}

test "hello without pid (legacy rc shim)" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;hello;zsh\x07")).?;
    try testing.expectEqual(Shell.zsh, ev.hello.shell);
    try testing.expectEqual(@as(i32, 0), ev.hello.pid);
}

test "done ST-terminated" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;1234;7;123;/tmp\x1b\\")).?;
    try testing.expectEqual(@as(i32, 1234), ev.done.pid);
    try testing.expectEqual(@as(i32, 7), ev.done.exit_code);
    try testing.expectEqualStrings("/tmp", ev.done.cwd);
    try testing.expectEqual(@as(u64, 123), ev.done.dur_ms);
}

test "preexec" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;preexec;5555\x07")).?;
    try testing.expectEqual(@as(i32, 5555), ev.preexec);
}

test "split across every byte boundary" {
    const seq = "\x1b]2718;done;99;42;9876;/home/u\x07";
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        var s = Scanner.init(testing.allocator);
        defer s.deinit();
        var evs: std.ArrayList(Event) = .empty;
        defer evs.deinit(testing.allocator);
        try s.feed(seq[0..i], &evs);
        try s.feed(seq[i..], &evs);
        try testing.expectEqual(@as(usize, 1), evs.items.len);
        try testing.expectEqual(@as(i32, 99), evs.items[0].done.pid);
        try testing.expectEqual(@as(i32, 42), evs.items[0].done.exit_code);
        try testing.expectEqualStrings("/home/u", evs.items[0].done.cwd);
        try testing.expectEqual(@as(u64, 9876), evs.items[0].done.dur_ms);
    }
}

test "split CSI across boundary" {
    const seq = "\x1b[?2004h";
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        var s = Scanner.init(testing.allocator);
        defer s.deinit();
        var evs: std.ArrayList(Event) = .empty;
        defer evs.deinit(testing.allocator);
        try s.feed(seq[0..i], &evs);
        try s.feed(seq[i..], &evs);
        try testing.expectEqual(@as(usize, 1), evs.items.len);
        try testing.expect(evs.items[0] == .prompt);
    }
}

test "50KB junk then OSC, buffer trimmed" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var junk: [1024]u8 = @splat('x');
    var n: usize = 0;
    while (n < 50 * 1024) : (n += junk.len) try s.feed(&junk, &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    try testing.expect(s.buf.items.len <= MAX_TAIL);

    try s.feed("\x1b]2718;hello;zsh;1\x07", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(Shell.zsh, evs.items[0].hello.shell);
    try testing.expect(s.buf.items.len <= MAX_TAIL);
}

test "CSI markers" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    try testing.expect((try collectOne(&s, "\x1b[?2004h")).? == .prompt);
}

test "interleaved events in order" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("garbage\x1b[?2004hmore junk\x1b]2718;done;1;3;5;/x\x07tail", &evs);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);
    try testing.expectEqual(@as(i32, 3), evs.items[1].done.exit_code);
    try testing.expectEqualStrings("/x", evs.items[1].done.cwd);
}

test "two done events in one feed have distinct cwds" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed(
        "\x1b]2718;done;1;1;10;/first/path\x07" ++
            "\x1b]2718;done;1;2;20;/second\x07",
        &evs,
    );
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expectEqualStrings("/first/path", evs.items[0].done.cwd);
    try testing.expectEqualStrings("/second", evs.items[1].done.cwd);
}

test "semicolon in cwd survives" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;1;0;0;/weird;path;dir\x07")).?;
    try testing.expectEqualStrings("/weird;path;dir", ev.done.cwd);
}

test "negative dur clamped to 0" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;1;0;-5;/x\x07")).?;
    try testing.expectEqual(@as(u64, 0), ev.done.dur_ms);
}

test "unterminated OSC bounded" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]2718;", &evs);
    var junk: [1024]u8 = @splat('x');
    var n: usize = 0;
    while (n < 8 * 1024) : (n += junk.len) try s.feed(&junk, &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    try testing.expect(s.buf.items.len <= MAX_OSC_PAYLOAD + MAX_TAIL);
}

test "probe: bash" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;probe;b=5.2.21(1)-release,z=,f=,h=\x07")).?;
    try testing.expectEqual(Shell.bash, ev.probe.shell);
    try testing.expectEqual(@as(u32, 5), ev.probe.shell_major);
    try testing.expectEqual(@as(u32, 0), ev.probe.hook_v);
}

test "probe: zsh, already hooked" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;probe;b=,z=5.9,f=,h=1\x07")).?;
    try testing.expectEqual(Shell.zsh, ev.probe.shell);
    try testing.expectEqual(@as(u32, 5), ev.probe.shell_major);
    try testing.expectEqual(@as(u32, 1), ev.probe.hook_v);
}

test "probe: fish" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;probe;b=,z=,f=3.7.0,h=\x07")).?;
    try testing.expectEqual(Shell.fish, ev.probe.shell);
    try testing.expectEqual(@as(u32, 3), ev.probe.shell_major);
}

test "B1: unterminated OSC immediately followed by OSC 2718 — inner not lost" {
    // Real VT parsers abort an OSC on bare ESC (not just ESC[). We currently
    // only abort on `\e[`, so `\e] junk \e]2718;...` treats the whole thing as
    // one OSC body that doesn't start with `2718;` → event lost.
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]garbage\x1b]2718;preexec;42\x07")) orelse
        return error.InnerOscLost;
    try testing.expectEqual(@as(i32, 42), ev.preexec);
}

test "B2: CSI inside a *terminated* OSC payload not mistaken for abort" {
    // OSC 0 title containing literal `\e[?2004h` text — the OSC is properly
    // BEL-terminated, so the CSI-abort heuristic must not fire and emit a
    // spurious .prompt.
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]0;title-with-\x1b[?2004h-in-it\x07", &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
}

test "OSC 7 (pwd) parsed" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]7;file://host/home/u/proj\x07")) orelse
        return error.EventNotEmitted;
    try testing.expectEqualStrings("/home/u/proj", ev.pwd);
}

test "OSC 7: hostless and percent-encoded" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    // file:///path (no host) — common from `printf '\e]7;file://%s\a' "$PWD"`
    const e1 = (try collectOne(&s, "\x1b]7;file:///root\x07")) orelse
        return error.EventNotEmitted;
    try testing.expectEqualStrings("/root", e1.pwd);
    // Percent-encoding is passed through verbatim (consumer decodes if needed).
    const e2 = (try collectOne(&s, "\x1b]7;file://h/a%20b\x07")) orelse
        return error.EventNotEmitted;
    try testing.expectEqualStrings("/a%20b", e2.pwd);
}

test "OSC 133;D (command end) exit code parsed" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]133;D;42\x07")) orelse
        return error.EventNotEmitted;
    try testing.expectEqual(@as(?i32, 42), ev.osc133_end);
    // No exit-code argument → null.
    const e2 = (try collectOne(&s, "\x1b]133;D\x07")) orelse
        return error.EventNotEmitted;
    try testing.expectEqual(@as(?i32, null), e2.osc133_end);
    // 133;A/B/C are tracked by ghostty's Terminal.semanticPrompt; we only
    // surface D (the one carrying data ghostty doesn't store).
    try testing.expectEqual(@as(?Event, null), try collectOne(&s, "\x1b]133;A\x07"));
}

test "probe: unknown (sh/dash — all version fields empty)" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;probe;b=,z=,f=,h=\x07")).?;
    try testing.expectEqual(Shell.unknown, ev.probe.shell);
    try testing.expectEqual(@as(u32, 0), ev.probe.hook_v);
}

test "5000-byte cwd in single feed" {
    // The whole OSC (including a cwd far larger than max_path_bytes) arrives
    // in one feed(): the terminator is found in the same buffer, so
    // MAX_OSC_PAYLOAD never triggers and the full cwd is returned verbatim.
    // Truncation to max_path_bytes is the *consumer's* job (Session.last_cwd).
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b]2718;done;1;0;0;");
    try seq.appendNTimes(testing.allocator, 'p', 5000);
    try seq.append(testing.allocator, 0x07);

    try s.feed(seq.items, &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(@as(usize, 5000), evs.items[0].done.cwd.len);
    for (evs.items[0].done.cwd) |c| try testing.expectEqual(@as(u8, 'p'), c);
}

test "5000-byte cwd split before BEL is dropped (MAX_OSC_PAYLOAD)" {
    // Trade-off: an unterminated OSC is abandoned once its payload exceeds
    // MAX_OSC_PAYLOAD, to keep the accumulator bounded against a hook that
    // forgot the terminator. The cost is that a *legitimate* done OSC whose
    // cwd alone exceeds 4 KiB will be lost if the terminator arrives in a
    // later read(). PATH_MAX is 4096 on Linux, so this is at the edge of
    // plausible — accepted as the lesser evil vs. unbounded buffering.
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(testing.allocator);
    try head.appendSlice(testing.allocator, "\x1b]2718;done;1;0;0;");
    try head.appendNTimes(testing.allocator, 'p', 5000);

    try s.feed(head.items, &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    // Payload cap fired; OSC start was discarded and only a tail kept.
    try testing.expect(s.buf.items.len <= MAX_TAIL);

    try s.feed("\x07", &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
}

test "unterminated OSC followed by CSI: OSC aborted, .prompt emitted" {
    // Regression: previously the ?2004h was trapped inside the pending OSC
    // (no BEL/ST ever arrived) and .prompt was suppressed. The Scanner now
    // treats ESC[ as an implicit OSC abort, matching real-terminal behaviour.
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    try s.feed("\x1b]2718;done;1;0;0;/tmp\x1b[?2004h", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);

    // Malformed OSC payload was discarded, not parsed.
    try testing.expect(s.buf.items.len <= MAX_TAIL);
}

test "unterminated OSC then CSI, split across feeds" {
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    try s.feed("\x1b]2718;done;1;0;0;/tmp", &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    try s.feed("\x1b[?2004h", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);
}

test "CSI-abort does not shadow a real terminator" {
    // ESC[ appearing *after* the BEL must not steal the parse.
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]2718;done;1;5;1;/x\x07\x1b[?2004h", &evs);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expectEqual(@as(i32, 5), evs.items[0].done.exit_code);
    try testing.expectEqualStrings("/x", evs.items[0].done.cwd);
    try testing.expect(evs.items[1] == .prompt);
}

test "BEL in cwd binds as terminator (cwd truncated)" {
    // BEL is the OSC terminator; a cwd containing a literal 0x07 cannot be
    // round-tripped — the first BEL ends the sequence and the remainder is
    // discarded as ground-state noise. Hook scripts are expected to never
    // emit such a cwd (shells refuse to cd into BEL-containing paths anyway).
    var s = Scanner.init(testing.allocator);
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]2718;done;1;0;0;/tmp/a\x07b\x07", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqualStrings("/tmp/a", evs.items[0].done.cwd);
}
