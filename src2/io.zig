//! Formatted stdout/stderr helpers that use the *streaming* write path.
//!
//! Zig 0.15's `File.writer(buf)` defaults to *positional* mode (`File.Writer
//! .Mode.positional`): it tracks its own `pos` and flushes via `pwritev`.
//! That's correct when one writer owns the file, but `client.zig` interleaves
//! raw PTY passthrough (`File.writeAll`, sequential) with formatted status
//! lines on the same fd — a fresh positional writer there would `pwritev` at
//! offset 0 and clobber the head of a redirected file (`run -j > out.txt`).
//!
//! `File.writeAll` is the streaming primitive; these wrappers add fmt on top.
//! There is no stdlib `File.printAll(fmt, args)` so this stays a small helper.

const std = @import("std");
const posix = std.posix;
const File = std.fs.File;

/// Set or clear O_NONBLOCK on `fd`. Works on any fd (sockets, PTYs, pipes).
pub fn setNonBlock(fd: posix.fd_t, on: bool) !void {
    const flags: usize = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nb: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, if (on) flags | nb else flags & ~nb);
}

pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    return (File{ .handle = fd }).writeAll(bytes);
}

pub fn outf(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    try File.stdout().writeAll(try std.fmt.bufPrint(&buf, fmt, args));
}

/// Best-effort: errors writing to stderr are swallowed. On format overflow,
/// emit a marker rather than truncated noise (bufPrint fills the buffer before
/// erroring, so the partial content has no trailing newline).
pub fn errf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "zmyth: <error message overflow>\n";
    File.stderr().writeAll(s) catch {};
}
