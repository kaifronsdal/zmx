//! Persistent classifier for client→daemon input bytes.
//!
//! Answers, per chunk: (a) did the user press the detach key (Ctrl-\)? and
//! (b) does this chunk contain real user keystrokes (vs. only terminal-
//! generated reports like DA/CPR/focus/mouse)?
//!
//! Unlike the v1 implementation, parser state persists across feed() calls so
//! escape sequences split across read() boundaries are handled correctly
//! (GitHub #135, #124).

const std = @import("std");
const vt = @import("ghostty-vt");

const Result = struct {
    /// Ctrl-\ was seen anywhere in this chunk (any encoding).
    detach: bool,
    /// At least one byte/sequence was a real keypress (not a terminal report).
    user_input: bool,
};

pub const Classifier = struct {
    parser: vt.Parser,
    /// Bytes to swallow following a legacy mouse report (CSI M + 3 bytes).
    skip_bytes: u8,
    /// Inside a bracketed-paste (`\e[200~`…`\e[201~`). The detach key is
    /// suppressed here so a clipboard containing 0x1c (binary garbage,
    /// terminal recordings) doesn't detach the session. The outer terminal
    /// only emits these when it has paste enabled, so we can trust them.
    in_paste: bool,

    pub fn init() Classifier {
        return .{ .parser = .init(), .skip_bytes = 0, .in_paste = false };
    }

    pub fn feed(self: *Classifier, bytes: []const u8) Result {
        var r: Result = .{ .detach = false, .user_input = false };
        for (bytes) |c| {
            if (self.skip_bytes > 0) {
                self.skip_bytes -= 1;
                continue;
            }
            // High bytes are UTF-8 (lead/continuation). Terminals only emit
            // 7-bit ESC-prefixed reports in the input direction, so any byte
            // ≥0x80 is user text. Don't feed it to the VT parser, which would
            // misread 0x80–0x9F as 8-bit C1 controls (e.g. 0x9B = CSI) and
            // wedge the state machine on CJK input.
            if (c >= 0x80) {
                r.user_input = true;
                continue;
            }
            for (self.parser.next(c)) |action_opt| {
                const action = action_opt orelse continue;
                switch (action) {
                    .print => r.user_input = true,
                    .execute => |code| {
                        r.user_input = true;
                        if (code == 0x1c and !self.in_paste) r.detach = true;
                    },
                    .csi_dispatch => |csi| self.classifyCsi(csi, &r),
                    // Alt+key, vi-mode ESC-then-key, SS3 fn keys all surface
                    // here. Terminals never auto-generate bare ESC sequences
                    // in the input direction (only CSI/DCS reports).
                    .esc_dispatch => r.user_input = true,
                    else => {}, // osc, dcs, apc: not user input
                }
            }
        }
        return r;
    }

    fn classifyCsi(self: *Classifier, csi: vt.Parser.Action.CSI, r: *Result) void {
        const has = struct {
            fn f(s: []const u8, ch: u8) bool {
                return std.mem.indexOfScalar(u8, s, ch) != null;
            }
        }.f;

        // Terminal-generated reports: do not count as user input.
        // Private-prefixed (?, >, <) sequences in the input direction are
        // always reports: DA replies, DECRPM, kitty kbd query, SGR mouse.
        if (has(csi.intermediates, '?') or
            has(csi.intermediates, '>') or
            has(csi.intermediates, '<')) return;
        switch (csi.final) {
            // DA, CPR/DSR, focus, XTWINOPS reply.
            'c', 'R', 'n', 'I', 'O', 't' => return,
            // Mouse final 'M'. Two encodings reach here without a private
            // prefix: legacy X10 (`CSI M` + 3 raw bytes, no params) and
            // urxvt 1015 (`CSI Cb;Cx;Cy M`, params carry the coords). Only
            // the legacy form has trailing bytes to swallow.
            'M' => {
                if (csi.params.len == 0) self.skip_bytes = 3;
                return;
            },
            // SGR mouse release without '<' shouldn't occur, but be safe.
            'm' => return,
            // DECRPM reply: CSI [?] Ps ; Pm $ y. The private-mode form is
            // caught by the '?' check above; the ANSI-mode form lands here.
            'y' => if (has(csi.intermediates, '$')) return,
            // Bracketed-paste markers themselves are not input; the wrapped
            // content arrives as ordinary .print/.execute and is counted
            // (but not as detach — see `in_paste`).
            '~' => if (csi.params.len >= 1) switch (csi.params[0]) {
                200 => {
                    self.in_paste = true;
                    return;
                },
                201 => {
                    self.in_paste = false;
                    return;
                },
                else => {},
            },
            else => {},
        }

        // Everything else is an encoded keypress.
        r.user_input = true;

        // Detach-key check. Modifier param encodes (1 + bitfield); Ctrl is bit 2.
        switch (csi.final) {
            // kitty: CSI key ; mod u
            'u' => if (csi.params.len >= 2 and csi.params[0] == '\\' and
                ctrlHeld(csi.params[1])) {
                r.detach = true;
            },
            // xterm modifyOtherKeys: CSI 27 ; mod ; key ~
            '~' => if (csi.params.len >= 3 and csi.params[0] == 27 and
                csi.params[2] == '\\' and ctrlHeld(csi.params[1]))
            {
                r.detach = true;
            },
            else => {},
        }
    }

    fn ctrlHeld(mod_param: u16) bool {
        return mod_param >= 1 and ((mod_param - 1) & 4) != 0;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFeed(c: *Classifier, bytes: []const u8, detach: bool, user: bool) !void {
    const r = c.feed(bytes);
    try testing.expectEqual(detach, r.detach);
    try testing.expectEqual(user, r.user_input);
}

fn expectOne(bytes: []const u8, detach: bool, user: bool) !void {
    var c = Classifier.init();
    try expectFeed(&c, bytes, detach, user);
}

test "legacy Ctrl-\\" {
    try expectOne(&.{0x1c}, true, true);
}

test "printable text" {
    try expectOne("hello", false, true);
}

test "xterm modifyOtherKeys Ctrl-\\" {
    try expectOne("\x1b[27;5;92~", true, true);
}

test "kitty Ctrl-\\" {
    try expectOne("\x1b[92;5u", true, true);
}

test "kitty Alt-\\ (no Ctrl) does not detach" {
    try expectOne("\x1b[92;3u", false, true);
}

test "kitty Ctrl+Shift-\\ detaches" {
    try expectOne("\x1b[92;6u", true, true);
}

test "DA reply is not user input" {
    try expectOne("\x1b[?1;2c", false, false);
}

test "secondary DA reply is not user input" {
    try expectOne("\x1b[>0;276;0c", false, false);
}

test "CPR is not user input" {
    try expectOne("\x1b[24;80R", false, false);
}

test "SGR mouse is not user input" {
    try expectOne("\x1b[<35;10;20M", false, false);
    try expectOne("\x1b[<35;10;20m", false, false);
}

test "legacy mouse swallows 3 trailing bytes" {
    try expectOne("\x1b[M !!", false, false);
    // 'x' is the 4th byte after M and should count.
    try expectOne("\x1b[M !!x", false, true);
}

test "focus events are not user input" {
    try expectOne("\x1b[I", false, false);
    try expectOne("\x1b[O", false, false);
}

test "kitty kbd query reply is not user input" {
    try expectOne("\x1b[?1u", false, false);
}

test "bracketed paste markers are not user input but content is" {
    try expectOne("\x1b[200~", false, false);
    try expectOne("\x1b[201~", false, false);
    try expectOne("\x1b[200~hi\x1b[201~", false, true);
}

test "T4: 0x1c inside bracketed paste does NOT detach" {
    try expectOne("\x1b[200~before\x1cafter\x1b[201~", false, true);
    // Split across feeds: paste-open in one, 0x1c in the next.
    var c = Classifier.init();
    try expectFeed(&c, "\x1b[200~", false, false);
    try expectFeed(&c, "\x1c", false, true);
    try expectFeed(&c, "\x1b[201~", false, false);
    // After paste closes, 0x1c detaches again.
    try expectFeed(&c, "\x1c", true, true);
}

test "arrow key is user input" {
    try expectOne("\x1b[A", false, true);
}

test "SS3 function key is user input" {
    try expectOne("\x1bOP", false, true);
}

test "vi-mode ESC then key is user input" {
    var c = Classifier.init();
    // Lone ESC: parser enters escape state, no action yet — that's fine,
    // the very next byte will produce esc_dispatch which counts.
    try expectFeed(&c, "\x1b", false, false);
    try expectFeed(&c, "k", false, true);
}

test "Alt-x (ESC x in same chunk) is user input" {
    try expectOne("\x1bx", false, true);
}

test "UTF-8 with all bytes >=0xA0 is user input" {
    // ghostty's VT parser has no ground-state rule for 0xA0-0xFF (null
    // action) and treats 0x80-0x9F as C1 controls. Without the >=0x80
    // short-circuit, a paste of 'é' (C3 A9) yields user_input=false.
    try expectOne("\xc3\xa9", false, true); // é
    try expectOne("\xc2\xa0", false, true); // U+00A0 nbsp
}

test "UTF-8 byte 0x9D doesn't wedge parser for following ASCII" {
    var c = Classifier.init();
    // Without the fix, 0x9D → osc_string state; the following 'x' becomes
    // .osc_put → user_input=false until an ESC arrives.
    try expectFeed(&c, "\x9d", false, true);
    try expectFeed(&c, "x", false, true);
}

test "boundary split: kitty Ctrl-\\ across two feeds" {
    var c = Classifier.init();
    try expectFeed(&c, "\x1b[92;", false, false);
    try expectFeed(&c, "5u", true, true);
}

test "boundary split: DA reply at every offset never user input" {
    const seq = "\x1b[?1;2c";
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        var c = Classifier.init();
        try expectFeed(&c, seq[0..i], false, false);
        try expectFeed(&c, seq[i..], false, false);
    }
}

test "boundary split: legacy mouse trailing bytes across feeds" {
    var c = Classifier.init();
    try expectFeed(&c, "\x1b[M ", false, false);
    try expectFeed(&c, "ab", false, false);
}

test "mixed: keypress + focus + Ctrl-\\" {
    try expectOne("x\x1b[I\x1c", true, true);
}

test "report followed by keypress" {
    try expectOne("\x1b[?1;2c\x1b[A", false, true);
}

test "urxvt mouse (mode 1015) is not user input" {
    try expectOne("\x1b[32;10;20M", false, false);
}

test "urxvt mouse does not swallow following bytes" {
    // Regression: previously every final-'M' set skip_bytes=3, so the three
    // bytes after a urxvt mouse report were silently eaten. urxvt encodes
    // coords as CSI params and has no trailing bytes; only legacy X10 does.
    var c = Classifier.init();
    try expectFeed(&c, "\x1b[32;10;20M", false, false);
    try expectFeed(&c, "x", false, true);
}

test "legacy mouse (no params) still swallows 3 bytes after fix" {
    var c = Classifier.init();
    try expectFeed(&c, "\x1b[M", false, false);
    try expectFeed(&c, "abc", false, false);
    try expectFeed(&c, "d", false, true);
}

test "DECRPM reply (ANSI mode, no '?') is not user input" {
    // CSI Ps ; Pm $ y — e.g. sync-output query reply. Previously fell through
    // to the user_input=true path because it has no private prefix.
    try expectOne("\x1b[2026;1$y", false, false);
}

test "DECRPM reply (DEC private mode) is not user input" {
    try expectOne("\x1b[?2026;1$y", false, false);
}

test "plain 'y'-final CSI without '$' is still user input" {
    // Guard against the DECRPM fix being over-broad.
    try expectOne("\x1b[1;5y", false, true);
}
