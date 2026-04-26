//! Pseudo-terminal allocation, fork/exec into a PTY, and raw-mode helpers.
//!
//! Thin, portable wrappers over the platform PTY/termios primitives. All
//! functions are blocking and assume libc is linked.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ---- libc externs (no header in std) -------------------------------------

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

// ---- ioctl request numbers -----------------------------------------------

// std.posix.system.T has IOCGWINSZ on every target; the *set* variants are
// missing on macOS as of 0.15.2, so define those ourselves.
const TIOCGWINSZ: c_ulong = std.posix.system.T.IOCGWINSZ;
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => std.os.linux.T.IOCSWINSZ,
    .macos => 0x80087467,
    else => @compileError("unsupported OS"),
};
const TIOCSCTTY: c_ulong = switch (builtin.os.tag) {
    .linux => std.os.linux.T.IOCSCTTY,
    .macos => 0x20007461,
    else => @compileError("unsupported OS"),
};

fn ioctl(fd: posix.fd_t, req: c_ulong, arg: usize) !void {
    while (true) {
        // std.c.ioctl takes the request as c_int; the canonical values are
        // 32-bit on every platform we target even though headers type them
        // as unsigned long.
        const rc = std.c.ioctl(fd, @bitCast(@as(u32, @truncate(req))), arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF => return error.BadFileDescriptor,
            .INVAL => return error.InvalidArgument,
            .NOTTY => return error.NotATerminal,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

// ---- Winsize -------------------------------------------------------------

pub const Winsize = struct {
    rows: u16,
    cols: u16,
};

pub fn setWinsize(fd: posix.fd_t, ws: Winsize) !void {
    var kws = posix.winsize{
        .row = ws.rows,
        .col = ws.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    try ioctl(fd, TIOCSWINSZ, @intFromPtr(&kws));
}

pub fn getWinsize(fd: posix.fd_t) !Winsize {
    var kws: posix.winsize = undefined;
    try ioctl(fd, TIOCGWINSZ, @intFromPtr(&kws));
    return .{ .rows = kws.row, .cols = kws.col };
}

/// Set or clear O_NONBLOCK on `fd`.
pub fn setNonBlock(fd: posix.fd_t, on: bool) !void {
    const flags: usize = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nb: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, if (on) flags | nb else flags & ~nb);
}

// ---- Pty -----------------------------------------------------------------

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    /// Allocate a master/slave PTY pair via posix_openpt + grantpt/unlockpt.
    pub fn open() !Pty {
        const oflag: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true })));

        const master = posix_openpt(oflag);
        if (master < 0) return error.OpenPtFailed;
        errdefer posix.close(master);

        if (grantpt(master) < 0) return error.GrantPtFailed;
        if (unlockpt(master) < 0) return error.UnlockPtFailed;

        const slave_path = ptsname(master) orelse return error.PtsNameFailed;
        const slave = try posix.openZ(slave_path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(slave);

        // CLOEXEC on master so it doesn't leak into the child shell.
        _ = try posix.fcntl(master, posix.F.SETFD, posix.FD_CLOEXEC);

        return .{ .master = master, .slave = slave };
    }

    pub fn close(self: *Pty) void {
        posix.close(self.master);
        if (self.slave >= 0) posix.close(self.slave);
        self.* = .{ .master = -1, .slave = -1 };
    }
};

/// Fork; in the child: setsid, make `pty.slave` the controlling TTY and
/// stdio, then execvpe(argv, env). In the parent: close the slave end and
/// return the child pid.
///
/// On exec failure the child writes a diagnostic to stderr and exits 127.
pub fn forkExec(
    pty: *Pty,
    argv: []const []const u8,
    env: []const [*:0]const u8,
) !posix.pid_t {
    std.debug.assert(argv.len > 0);

    // Build null-terminated argv/envp on the parent heap before forking so
    // the child does no allocation between fork and exec.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try a.dupeZ(u8, arg)).ptr;
    const envp_z = try a.allocSentinel(?[*:0]const u8, env.len, null);
    for (env, 0..) |e, i| envp_z[i] = e;

    const pid = try posix.fork();
    if (pid != 0) {
        // Parent: slave end is no longer needed here.
        posix.close(pty.slave);
        pty.slave = -1;
        return pid;
    }

    // ---- child --------------------------------------------------------
    childSetupAndExec(pty.*, argv_z, envp_z);
}

/// Runs in the forked child. Never returns: either execs or _exit()s.
fn childSetupAndExec(
    p: Pty,
    argv_z: [*:null]const ?[*:0]const u8,
    envp_z: [*:null]const ?[*:0]const u8,
) noreturn {
    // New session; detach from any inherited controlling terminal.
    _ = posix.setsid() catch {};

    // Make the slave our controlling TTY.
    ioctl(p.slave, TIOCSCTTY, 0) catch {};

    // Wire slave to stdio.
    posix.dup2(p.slave, posix.STDIN_FILENO) catch posix.exit(127);
    posix.dup2(p.slave, posix.STDOUT_FILENO) catch posix.exit(127);
    posix.dup2(p.slave, posix.STDERR_FILENO) catch posix.exit(127);
    if (p.slave > posix.STDERR_FILENO) posix.close(p.slave);
    // master has FD_CLOEXEC set; leave it for exec to close.

    // Restore default SIGPIPE and an empty signal mask so the spawned
    // process behaves normally (the parent typically ignores SIGPIPE and
    // may have signals blocked for ppoll).
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &dfl, null);
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    const err = posix.execvpeZ(argv_z[0].?, argv_z, envp_z);
    // exec failed.
    const msg = std.fmt.bufPrint(
        &child_err_buf,
        "zmyth: exec {s}: {s}\r\n",
        .{ argv_z[0].?, @errorName(err) },
    ) catch "zmyth: exec failed\r\n";
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
    posix.exit(127);
}

var child_err_buf: [256]u8 = undefined;

// ---- RawMode -------------------------------------------------------------

/// Put a terminal fd into raw mode (cfmakeraw equivalent), restoring the
/// original attributes on `leave`.
pub const RawMode = struct {
    fd: posix.fd_t,
    orig: posix.termios,

    pub fn enter(fd: posix.fd_t) !RawMode {
        const orig = try posix.tcgetattr(fd);
        var raw = orig;

        // cfmakeraw(3):
        //   iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON)
        //   oflag &= ~OPOST
        //   lflag &= ~(ECHO|ECHONL|ICANON|ISIG|IEXTEN)
        //   cflag &= ~(CSIZE|PARENB); cflag |= CS8
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // Block for at least one byte, no inter-byte timeout.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);
        return .{ .fd = fd, .orig = orig };
    }

    pub fn leave(self: *RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.orig) catch {};
    }
};

// ---- tests ---------------------------------------------------------------

test {
    // Force analysis of every public decl so forkExec/RawMode get
    // type-checked even though we can't unit-test them without a real TTY.
    std.testing.refAllDeclsRecursive(@This());
}

test "Pty.open returns valid fds and winsize round-trips" {
    var pty = try Pty.open();
    defer pty.close();

    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
    try std.testing.expect(pty.master != pty.slave);

    try setWinsize(pty.master, .{ .rows = 37, .cols = 111 });
    const ws = try getWinsize(pty.master);
    try std.testing.expectEqual(@as(u16, 37), ws.rows);
    try std.testing.expectEqual(@as(u16, 111), ws.cols);

    // Slave end should observe the same dimensions.
    const sws = try getWinsize(pty.slave);
    try std.testing.expectEqual(@as(u16, 37), sws.rows);
    try std.testing.expectEqual(@as(u16, 111), sws.cols);
}
