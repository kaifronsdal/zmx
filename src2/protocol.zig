//! OSC-2718 shell-integration protocol.
//!
//! Wire format (terminator is BEL `\x07` or ST `\x1b\\`):
//!   ESC ] 2718;hello;<shell> BEL
//!   ESC ] 2718;preexec;<nonce> BEL
//!   ESC ] 2718;done;<nonce>;<ec>;<dur_ms>;<cwd> BEL   (cwd last: may contain ';')
//!
//! Also detects:
//!   ESC [ ? 2004 h   bracketed-paste on  -> .prompt (fallback "back at prompt")

const std = @import("std");
const assert = std.debug.assert;

// Hook scripts are bracketed-pasted verbatim into the interactive shell, so
// they contain NO `#` comments: interactive zsh lacks INTERACTIVE_COMMENTS by
// default and would parse each comment line as a command. Design notes:
//
//   bash — DEBUG trap (chained over any prior trap) emits `preexec` once per
//     accepted line, gated by __ZMX_AT_PROMPT/__ZMX_IN_PC so PROMPT_COMMAND
//     entries don't fire it. PROMPT_COMMAND is wrapped (array or string) so
//     $? is captured first and __zmx_precmd runs last to re-arm the guard.
//     `bind` calls force bracketed-paste on and bind it in vi-command keymap
//     so `run`'s ^U + paste wrapper survives `set -o vi` / disabled paste.
//
//   zsh — preexec/precmd via add-zsh-hook; __ZMX_RAN distinguishes "ran,
//     $?=N" from "zle rejected line, $? stale" (→ ec=125). zle_bracketed_paste
//     and vicmd bindings are forced for the same reason as bash.
//
//   fish — fish_preexec/fish_prompt events; fish_posterror covers the syntax-
//     error case where fish_prompt does NOT fire (fish #8832). Duration via
//     $CMD_DURATION (built-in, ms).
const hook_bash = @embedFile("assets/hook.bash");
const hook_zsh = @embedFile("assets/hook.zsh");
const hook_fish = @embedFile("assets/hook.fish");

const OSC_START = "\x1b]2718;";
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

pub const Event = union(enum) {
    hello: Shell,
    /// nonce already validated against Scanner.nonce
    preexec,
    done: struct { exit_code: i32, cwd: []const u8, dur_ms: u64 },
    /// CSI ?2004h (bracketed-paste on) — shell is back at the prompt
    prompt,
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    /// Owned copy of the expected nonce. preexec/done with a different nonce
    /// are silently dropped.
    nonce: []const u8,
    /// Accumulator for boundary-safe scanning.
    buf: std.ArrayList(u8),
    /// Backing storage for `done.cwd` slices emitted during the current feed().
    /// Cleared at the top of each feed(); all cwd slices in one batch point at
    /// disjoint ranges of this buffer.
    cwd_storage: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, nonce: []const u8) !Scanner {
        return .{
            .gpa = allocator,
            .nonce = try allocator.dupe(u8, nonce),
            .buf = .empty,
            .cwd_storage = .empty,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.gpa.free(self.nonce);
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

    fn parsePayload(self: *Scanner, payload: []const u8, out: *std.ArrayList(Event)) !void {
        var it = std.mem.splitScalar(u8, payload, ';');
        const kind = it.next() orelse return;
        if (std.mem.eql(u8, kind, "hello")) {
            const sh = it.next() orelse return;
            try out.append(self.gpa, .{ .hello = Shell.parse(sh) });
        } else if (std.mem.eql(u8, kind, "preexec")) {
            const n = it.next() orelse return;
            if (!std.mem.eql(u8, n, self.nonce)) return;
            try out.append(self.gpa, .preexec);
        } else if (std.mem.eql(u8, kind, "done")) {
            const n = it.next() orelse return;
            if (!std.mem.eql(u8, n, self.nonce)) return;
            const ec_s = it.next() orelse return;
            const dur_s = it.next() orelse return;
            const cwd = it.rest(); // last field; may contain ';'
            const ec = std.fmt.parseInt(i32, ec_s, 10) catch return;
            const dur_i = std.fmt.parseInt(i64, dur_s, 10) catch return;
            // Stash cwd. Capacity was reserved up front so the slice is stable.
            const off = self.cwd_storage.items.len;
            self.cwd_storage.appendSliceAssumeCapacity(cwd);
            try out.append(self.gpa, .{ .done = .{
                .exit_code = ec,
                .cwd = self.cwd_storage.items[off..],
                .dur_ms = @intCast(@max(0, dur_i)),
            } });
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

/// Fill `buf` with 16 random lowercase hex characters and return the slice.
pub fn genNonce(buf: *[16]u8) []const u8 {
    var raw: [8]u8 = undefined;
    std.crypto.random.bytes(&raw);
    buf.* = std.fmt.bytesToHex(raw, .lower);
    return buf;
}

/// Build the keystroke sequence to inject the hook for `shell` into a PTY.
/// Layout: Ctrl-U, bracketed-paste start, the eval/source command, bracketed-
/// paste end, CR. The hook script's `__ZMX_NONCE__` placeholder is replaced
/// with `nonce`. The script is sent verbatim inside the paste — bracketed
/// paste delivers it as one multi-line input which the shell executes on the
/// final CR, so no `base64`/`eval` wrapper (and no dependency on `base64`
/// being in PATH). Hook scripts contain only printable bytes; the paste
/// terminator `\e[201~` cannot occur in them. Caller frees the returned slice.
pub fn buildInject(allocator: std.mem.Allocator, shell: Shell, nonce: []const u8) ![]u8 {
    assert(shell != .unknown);
    const tmpl = switch (shell) {
        .bash => hook_bash,
        .zsh => hook_zsh,
        .fish => hook_fish,
        .unknown => unreachable,
    };
    assert(std.mem.indexOf(u8, tmpl, "__ZMX_NONCE__") != null);

    const script = try std.mem.replaceOwned(u8, allocator, tmpl, "__ZMX_NONCE__", nonce);
    defer allocator.free(script);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x15\x1b[200~");
    try out.appendSlice(allocator, script);
    try out.appendSlice(allocator, "\x1b[201~\r");
    return out.toOwnedSlice(allocator);
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
    var s = try Scanner.init(testing.allocator, "NONCE");
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;hello;bash\x07")).?;
    try testing.expectEqual(Shell.bash, ev.hello);
}

test "done ST-terminated" {
    var s = try Scanner.init(testing.allocator, "NONCE");
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;NONCE;7;123;/tmp\x1b\\")).?;
    try testing.expectEqual(@as(i32, 7), ev.done.exit_code);
    try testing.expectEqualStrings("/tmp", ev.done.cwd);
    try testing.expectEqual(@as(u64, 123), ev.done.dur_ms);
}

test "preexec with correct nonce" {
    var s = try Scanner.init(testing.allocator, "abc123");
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;preexec;abc123\x07")).?;
    try testing.expect(ev == .preexec);
}

test "wrong nonce dropped" {
    var s = try Scanner.init(testing.allocator, "RIGHT");
    defer s.deinit();
    try testing.expectEqual(@as(?Event, null), try collectOne(&s, "\x1b]2718;preexec;WRONG\x07"));
    try testing.expectEqual(@as(?Event, null), try collectOne(&s, "\x1b]2718;done;WRONG;0;0;/\x07"));
}

test "split across every byte boundary" {
    const seq = "\x1b]2718;done;NONCE;42;9876;/home/u\x07";
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        var s = try Scanner.init(testing.allocator, "NONCE");
        defer s.deinit();
        var evs: std.ArrayList(Event) = .empty;
        defer evs.deinit(testing.allocator);
        try s.feed(seq[0..i], &evs);
        try s.feed(seq[i..], &evs);
        try testing.expectEqual(@as(usize, 1), evs.items.len);
        try testing.expectEqual(@as(i32, 42), evs.items[0].done.exit_code);
        try testing.expectEqualStrings("/home/u", evs.items[0].done.cwd);
        try testing.expectEqual(@as(u64, 9876), evs.items[0].done.dur_ms);
    }
}

test "split CSI across boundary" {
    const seq = "\x1b[?2004h";
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        var s = try Scanner.init(testing.allocator, "n");
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
    var s = try Scanner.init(testing.allocator, "NONCE");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var junk: [1024]u8 = @splat('x');
    var n: usize = 0;
    while (n < 50 * 1024) : (n += junk.len) try s.feed(&junk, &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    try testing.expect(s.buf.items.len <= MAX_TAIL);

    try s.feed("\x1b]2718;hello;zsh\x07", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(Shell.zsh, evs.items[0].hello);
    try testing.expect(s.buf.items.len <= MAX_TAIL);
}

test "CSI markers" {
    var s = try Scanner.init(testing.allocator, "n");
    defer s.deinit();
    try testing.expect((try collectOne(&s, "\x1b[?2004h")).? == .prompt);
}

test "interleaved events in order" {
    var s = try Scanner.init(testing.allocator, "NONCE");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("garbage\x1b[?2004hmore junk\x1b]2718;done;NONCE;3;5;/x\x07tail", &evs);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);
    try testing.expectEqual(@as(i32, 3), evs.items[1].done.exit_code);
    try testing.expectEqualStrings("/x", evs.items[1].done.cwd);
}

test "two done events in one feed have distinct cwds" {
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed(
        "\x1b]2718;done;N;1;10;/first/path\x07" ++
            "\x1b]2718;done;N;2;20;/second\x07",
        &evs,
    );
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expectEqualStrings("/first/path", evs.items[0].done.cwd);
    try testing.expectEqualStrings("/second", evs.items[1].done.cwd);
}

test "semicolon in cwd survives" {
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;N;0;0;/weird;path;dir\x07")).?;
    try testing.expectEqualStrings("/weird;path;dir", ev.done.cwd);
}

test "negative dur clamped to 0" {
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    const ev = (try collectOne(&s, "\x1b]2718;done;N;0;-5;/x\x07")).?;
    try testing.expectEqual(@as(u64, 0), ev.done.dur_ms);
}

test "unterminated OSC bounded" {
    var s = try Scanner.init(testing.allocator, "n");
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

test "genNonce" {
    var b: [16]u8 = undefined;
    const n = genNonce(&b);
    try testing.expectEqual(@as(usize, 16), n.len);
    for (n) |c| try testing.expect(std.ascii.isHex(c));
}

test "buildInject wraps script verbatim" {
    inline for (.{ Shell.bash, Shell.zsh, Shell.fish }) |sh| {
        const inj = try buildInject(testing.allocator, sh, "abc123");
        defer testing.allocator.free(inj);
        try testing.expect(std.mem.startsWith(u8, inj, "\x15\x1b[200~"));
        try testing.expect(std.mem.endsWith(u8, inj, "\x1b[201~\r"));
        try testing.expect(std.mem.indexOf(u8, inj, "abc123") != null);
        try testing.expect(std.mem.indexOf(u8, inj, "__ZMX_NONCE__") == null);
        // No external-binary dependency in the inject path.
        try testing.expect(std.mem.indexOf(u8, inj, "base64") == null);
    }
}

test "embedded hooks contain placeholder and no ESC" {
    inline for (.{ hook_bash, hook_zsh, hook_fish }) |h| {
        try testing.expect(std.mem.indexOf(u8, h, "__ZMX_NONCE__") != null);
        // Paste-terminator safety: scripts must not contain raw ESC (the
        // `\033` in printf format strings is four literal chars).
        try testing.expect(std.mem.indexOfScalar(u8, h, 0x1b) == null);
    }
}

test "5000-byte cwd in single feed" {
    // The whole OSC (including a cwd far larger than max_path_bytes) arrives
    // in one feed(): the terminator is found in the same buffer, so
    // MAX_OSC_PAYLOAD never triggers and the full cwd is returned verbatim.
    // Truncation to max_path_bytes is the *consumer's* job (Session.last_cwd).
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b]2718;done;N;0;0;");
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
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(testing.allocator);
    try head.appendSlice(testing.allocator, "\x1b]2718;done;N;0;0;");
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
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    try s.feed("\x1b]2718;done;N;0;0;/tmp\x1b[?2004h", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);

    // Malformed OSC payload was discarded, not parsed.
    try testing.expect(s.buf.items.len <= MAX_TAIL);
}

test "unterminated OSC then CSI, split across feeds" {
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);

    try s.feed("\x1b]2718;done;N;0;0;/tmp", &evs);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
    try s.feed("\x1b[?2004h", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expect(evs.items[0] == .prompt);
}

test "CSI-abort does not shadow a real terminator" {
    // ESC[ appearing *after* the BEL must not steal the parse.
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]2718;done;N;5;1;/x\x07\x1b[?2004h", &evs);
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
    var s = try Scanner.init(testing.allocator, "N");
    defer s.deinit();
    var evs: std.ArrayList(Event) = .empty;
    defer evs.deinit(testing.allocator);
    try s.feed("\x1b]2718;done;N;0;0;/tmp/a\x07b\x07", &evs);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqualStrings("/tmp/a", evs.items[0].done.cwd);
}
