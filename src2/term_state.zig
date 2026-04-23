//! Terminal state serialization using ghostty-vt.
//!
//! Three operations on a `vt.Terminal`:
//!   - serializeForAttach: full state replay (scrollback + screen + modes/cursor)
//!     so a freshly attached client sees exactly what the daemon's vt sees.
//!   - dumpScrollback: history (`zmx read`) — primary screen scrollback as text.
//!   - dumpScreen: snapshot the visible grid (`zmx read -s`) — works on alt-screen.
//!
//! Ported from src/util.zig:serializeTerminalState + serializeTerminal.

const std = @import("std");
const vt = @import("ghostty-vt");

pub const DumpFormat = enum { plain, vt, html };

/// Serialize full terminal state (scrollback + visible screen + modes/cursor)
/// as VT bytes that, when written to a fresh terminal of the same size,
/// reproduce the state. Used when a client attaches.
///
/// Writer must be a `*std.Io.Writer` (Zig 0.15 unified writer interface);
/// ghostty's formatter requires this concrete type.
pub fn serializeForAttach(term: *vt.Terminal, writer: *std.Io.Writer) !void {
    // Synchronized output (DECSET 2026) is a transient rendering handshake
    // between a program and its current terminal client. Replaying it to a
    // newly attached client can leave that client deferring renders until its
    // local timeout fires, so temporarily exclude it from restored state and
    // restore the original mode before returning.
    const had_sync = term.modes.get(.synchronized_output);
    if (had_sync) term.modes.set(.synchronized_output, false);
    defer if (had_sync) term.modes.set(.synchronized_output, true);

    const pages = &term.screens.active.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    const has_scrollback = !screen_top.eql(active_top);

    // Two-phase serialization to preserve scrollback without corrupting
    // cursor positions. This matters for nested zmx sessions (zmx→SSH→zmx)
    // where the outer daemon's ghostty-vt accumulates inner session scrollback.
    //
    // Phase 1: Emit scrollback content (plain text with styles, no terminal extras).
    // These lines scroll past the visible area into the terminal's scrollback buffer.
    // Phase 2: Clear visible screen, then emit visible content with full extras.
    // The clear ensures visible content starts from a clean slate regardless of
    // how much scrollback preceded it. CUP cursor positioning is then correct.
    //
    // See: https://github.com/neurosnap/zmx/issues/31

    // Phase 1: scrollback only (if any exists)
    if (has_scrollback) {
        if (active_top.up(1)) |sb_bottom_row| {
            var sb_bottom = sb_bottom_row;
            sb_bottom.x = @intCast(pages.cols - 1);

            var scroll_fmt = vt.formatter.TerminalFormatter.init(term, .vt);
            scroll_fmt.content = .{
                .selection = vt.Selection.init(screen_top, sb_bottom, false),
            };
            scroll_fmt.extra = .none; // no modes, cursor, keyboard — just content
            try scroll_fmt.format(writer);
        }

        // Clear visible screen after scrollback. \x1b[2J clears only the visible
        // rows (not the scrollback buffer). \x1b[H homes the cursor. \x1b[0m resets
        // SGR style so phase 1 styles don't bleed into phase 2.
        try writer.writeAll("\x1b[2J\x1b[H\x1b[0m");
    }

    // Phase 2: visible screen with full extras (modes, cursor, keyboard, etc.)
    var vis_fmt = vt.formatter.TerminalFormatter.init(term, .vt);

    // Restrict content to the active viewport only
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });

    vis_fmt.content = .{
        .selection = vt.Selection.init(active_tl.?, active_br.?, false),
    };

    vis_fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false, // tabstop restoration moves cursor after CUP, corrupting position
        .pwd = true,
        .keyboard = true,
        .screen = .all,
    };

    try vis_fmt.format(writer);
}

/// Dump scrollback + primary screen in the given format. If `tail_n != null`,
/// only the last N lines. Used by `zmx read`.
///
/// Always reads the primary screen (where scrollback lives), even if the
/// terminal is currently on the alt-screen.
pub fn dumpScrollback(
    allocator: std.mem.Allocator,
    term: *vt.Terminal,
    fmt: DumpFormat,
    tail_n: ?usize,
    writer: *std.Io.Writer,
) !void {
    const opts: vt.formatter.Options = switch (fmt) {
        .plain => .plain,
        .vt => .vt,
        .html => .html,
    };

    // Use ScreenFormatter on the primary screen directly so this works even
    // when the alt-screen is active (TerminalFormatter only sees active).
    const primary = term.screens.get(.primary).?;
    var sf = vt.formatter.ScreenFormatter.init(primary, opts);
    sf.content = .{ .selection = null };
    sf.extra = .none;

    if (tail_n == null) {
        try sf.format(writer);
        return;
    }

    // TODO: tail without buffering. The clean approach is to compute a start
    // pin N non-blank rows above the last written row and set the selection
    // there, but ghostty's formatter trims trailing blank rows so "last N
    // lines of output" ≠ "last N grid rows". For now buffer then slice.
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try sf.format(&buf.writer);

    const all = buf.writer.buffered();
    const n = tail_n.?;
    if (n == 0) return;

    // Find the start of the Nth-from-last line. Ignore a single trailing
    // newline so it doesn't count as an empty final line.
    var end = all.len;
    if (end > 0 and all[end - 1] == '\n') end -= 1;
    var start: usize = end;
    var lines: usize = 0;
    while (start > 0) {
        start -= 1;
        if (all[start] == '\n') {
            lines += 1;
            if (lines == n) {
                start += 1; // exclude the newline itself
                break;
            }
        }
    }
    try writer.writeAll(all[start..]);
}

/// Dump just the visible screen grid (whichever screen is active — including
/// alt-screen) as plain text. Used by `zmx read -s` to inspect TUIs.
pub fn dumpScreen(term: *vt.Terminal, writer: *std.Io.Writer) !void {
    const screen = term.screens.active;
    const pages = &screen.pages;
    try screen.dumpString(writer, .{
        .tl = pages.getTopLeft(.active),
        .br = pages.getBottomRight(.active) orelse pages.getBottomRight(.screen),
        .unwrap = false,
    });
}

// ───────────────────────────── Tests ─────────────────────────────

const testing = std.testing;

fn testCreateTerminal(
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    vt_data: []const u8,
) !vt.Terminal {
    var term = try vt.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = 10_000_000,
    });
    if (vt_data.len > 0) {
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(vt_data);
    }
    return term;
}

fn serializeToString(alloc: std.mem.Allocator, term: *vt.Terminal) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeForAttach(term, &buf.writer);
    return try alloc.dupe(u8, buf.writer.buffered());
}

fn serializeRoundtrip(alloc: std.mem.Allocator, source: *vt.Terminal) !vt.Terminal {
    const serialized = try serializeToString(alloc, source);
    defer alloc.free(serialized);

    var dest = try vt.Terminal.init(alloc, .{
        .cols = source.screens.active.pages.cols,
        .rows = source.screens.active.pages.rows,
        .max_scrollback = 10_000_000,
    });
    var stream = dest.vtStream();
    defer stream.deinit();
    stream.nextSlice(serialized);
    return dest;
}

fn expectScreensMatch(
    alloc: std.mem.Allocator,
    expected: *vt.Terminal,
    actual: *vt.Terminal,
) !void {
    const exp_str = try expected.plainString(alloc);
    defer alloc.free(exp_str);
    const act_str = try actual.plainString(alloc);
    defer alloc.free(act_str);
    try testing.expectEqualStrings(exp_str, act_str);
}

fn expectCursorAt(term: *vt.Terminal, row: usize, col: usize) !void {
    const cursor = &term.screens.active.cursor;
    try testing.expectEqual(col, cursor.x);
    try testing.expectEqual(row, cursor.y);
}

fn expectMarkerAtRow(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    marker: []const u8,
    expected_row: usize,
) !void {
    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    var row: usize = 0;
    var iter = std.mem.splitScalar(u8, plain, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) {
            try testing.expectEqual(expected_row, row);
            return;
        }
        row += 1;
    }
    std.debug.print("marker '{s}' not found in terminal output\n", .{marker});
    return error.TestExpectedEqual;
}

test "serializeForAttach excludes synchronized output replay" {
    const alloc = testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?2004h"); // Bracketed paste
    stream.nextSlice("\x1b[?2026h"); // Synchronized output
    stream.nextSlice("hello");

    try testing.expect(term.modes.get(.bracketed_paste));
    try testing.expect(term.modes.get(.synchronized_output));

    const output = try serializeToString(alloc, &term);
    defer alloc.free(output);

    // The serialized output should contain bracketed paste (DECSET 2004)
    // but NOT synchronized output (DECSET 2026)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026h") == null);

    // And the original terminal's mode must be restored after serialization.
    try testing.expect(term.modes.get(.synchronized_output));
}

test "serializeForAttach roundtrip preserves cursor position" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[2J" ++ // clear
        "\x1b[10;20H" // cursor at row 10, col 20 (1-indexed)
    );
    defer term.deinit(alloc);

    try expectCursorAt(&term, 9, 19); // 0-indexed

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectCursorAt(&client, 9, 19);
}

test "serializeForAttach roundtrip preserves CUP-positioned markers" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[14;50HMARK_D" ++
        "\x1b[16;20H");
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectMarkerAtRow(alloc, &client, "MARK_D", 13);
    try expectCursorAt(&client, 15, 19);
}

test "serializeForAttach with scrollback preserves visible content" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "");
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    // Generate 80 lines of scrollback (more than 24 visible rows)
    var fbuf: [32]u8 = undefined;
    for (0..80) |i| {
        const line = std.fmt.bufPrint(&fbuf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(line);
    }

    // Clear screen and place markers at specific positions
    stream.nextSlice("\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[16;20H");

    // Verify source terminal has scrollback
    const pages = &term.screens.active.pages;
    const has_scrollback = !pages.getTopLeft(.screen).eql(pages.getTopLeft(.active));
    try testing.expect(has_scrollback);

    // Roundtrip: serialize → feed into fresh terminal
    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    // Visible content must match (this is the core cursor corruption test)
    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectCursorAt(&client, 15, 19);
}

test "serializeForAttach nested roundtrip preserves content" {
    // Simulates: inner zmx → serialized state → outer ghostty-vt → serialized again → client
    // This is the exact nested session scenario (zmx → SSH → zmx).
    const alloc = testing.allocator;

    // "Inner" terminal with scrollback + markers
    var inner = try testCreateTerminal(alloc, 80, 24, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var fbuf: [32]u8 = undefined;
        for (0..60) |i| {
            const line = std.fmt.bufPrint(&fbuf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HINNER_A" ++
            "\x1b[12;25HINNER_B" ++
            "\x1b[20;5H");
    }

    // Record inner's ground truth
    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Serialize inner (simulates inner daemon re-attach to inner client)
    const inner_serialized = try serializeToString(alloc, &inner);
    defer alloc.free(inner_serialized);

    // "Outer" terminal processes inner's serialized output
    var outer = try testCreateTerminal(alloc, 80, 24, "");
    defer outer.deinit(alloc);

    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_serialized);
    }

    // Serialize outer (simulates outer daemon re-attach after detach)
    var client = try serializeRoundtrip(alloc, &outer);
    defer client.deinit(alloc);

    // Client must see the same content as inner's visible screen
    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
    try expectMarkerAtRow(alloc, &client, "INNER_A", 2);
    try expectMarkerAtRow(alloc, &client, "INNER_B", 11);
}

test "serializeForAttach alternate screen not leaked" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[?1049h" ++ // enter alt screen
        "\x1b[2J\x1b[3;10HALT_MARK" ++ // write on alt screen
        "\x1b[?1049l" ++ // exit alt screen
        "\x1b[2J\x1b[2;5HMAIN_MARK\x1b[8;20H" // write on main screen
    );
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);

    const plain = try client.plainString(alloc);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "ALT_MARK") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "MAIN_MARK") != null);
}

test "serializeForAttach size mismatch roundtrip" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 30, "\x1b[2J" ++
        "\x1b[3;10HSIZE_A" ++
        "\x1b[12;20HSIZE_B" ++
        "\x1b[20;40HSIZE_C" ++
        "\x1b[15;15H");
    defer term.deinit(alloc);

    // Resize to 24 rows (simulates outer terminal being smaller)
    try term.resize(alloc, 80, 24);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectCursorAt(&client, term.screens.active.cursor.y, term.screens.active.cursor.x);
}

test "serializeForAttach scrollback + size mismatch nested roundtrip" {
    const alloc = testing.allocator;

    var inner = try testCreateTerminal(alloc, 80, 30, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var fbuf: [32]u8 = undefined;
        for (0..80) |i| {
            const line = std.fmt.bufPrint(&fbuf, "LINE_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HSTRESS_A" ++
            "\x1b[12;25HSTRESS_B" ++
            "\x1b[16;20H");
    }

    // Resize inner to 24 rows (outer terminal is smaller)
    try inner.resize(alloc, 80, 24);

    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Inner serialize → outer processes → outer serialize → client
    const inner_ser = try serializeToString(alloc, &inner);
    defer alloc.free(inner_ser);

    var outer = try testCreateTerminal(alloc, 80, 24, "");
    defer outer.deinit(alloc);
    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_ser);
    }

    var client = try serializeRoundtrip(alloc, &outer);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
}

test "dumpScreen on alt-screen returns alt-screen content" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 40, 10, "PRIMARY_LINE\r\n" ++
        "\x1b[?1049h" ++ // enter alt screen
        "ALT_LINE_1\r\nALT_LINE_2");
    defer term.deinit(alloc);

    try testing.expectEqual(vt.ScreenSet.Key.alternate, term.screens.active_key);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try dumpScreen(&term, &buf.writer);
    const out = buf.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "ALT_LINE_1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ALT_LINE_2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PRIMARY_LINE") == null);
}

test "dumpScrollback tail_n=2 returns last 2 lines" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(
        alloc,
        40,
        10,
        "line1\r\nline2\r\nline3\r\nline4\r\nline5",
    );
    defer term.deinit(alloc);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try dumpScrollback(alloc, &term, .plain, 2, &buf.writer);
    const out = buf.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "line4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line3") == null);
    try testing.expect(std.mem.indexOf(u8, out, "line1") == null);
}

test "dumpScrollback tail_n larger than content returns all" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 40, 10, "a\r\nb\r\nc");
    defer term.deinit(alloc);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try dumpScrollback(alloc, &term, .plain, 100, &buf.writer);
    const out = buf.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b") != null);
    try testing.expect(std.mem.indexOf(u8, out, "c") != null);
}

test "dumpScrollback null tail dumps everything" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 40, 3, "");
    defer term.deinit(alloc);
    {
        var stream = term.vtStream();
        defer stream.deinit();
        var fbuf: [32]u8 = undefined;
        // 8 lines into a 3-row terminal -> 5 in scrollback
        for (0..8) |i| {
            const line = std.fmt.bufPrint(&fbuf, "L{d}\r\n", .{i}) catch unreachable;
            stream.nextSlice(line);
        }
    }

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try dumpScrollback(alloc, &term, .plain, null, &buf.writer);
    const out = buf.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "L0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "L7") != null);
}

test "dumpScrollback reads primary while on alt-screen" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 40, 10, "prim-line\r\n" ++
        "\x1b[?1049h" ++ // enter alt screen
        "alt-line\r\n");
    defer term.deinit(alloc);

    try testing.expectEqual(vt.ScreenSet.Key.alternate, term.screens.active_key);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try dumpScrollback(alloc, &term, .plain, null, &buf.writer);
    const out = buf.writer.buffered();

    // Scrollback lives on the primary screen; alt-screen content must not leak.
    try testing.expect(std.mem.indexOf(u8, out, "prim-line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "alt-line") == null);
}
