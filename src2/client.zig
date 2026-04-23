//! Client half of zmyth: one `pub fn` per CLI verb. Each parses its own
//! flags, connects to (or creates) a session daemon over its Unix socket,
//! speaks the ipc.zig framing protocol, and returns a process exit code.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
const pty = @import("pty.zig");
const compat = @import("compat.zig");

const daemon = @import("daemon.zig");

const O_NONBLOCK: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

const probe_connect_ms = 200;
const probe_recv_timeout_us = 500_000;

const env_forward = [_][:0]const u8{
    "SSH_AUTH_SOCK", "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
};

// ---- tiny io helpers -----------------------------------------------------
//
// We deliberately avoid `std.fs.File.writer()` here: in Zig 0.15 it uses
// positional `pwritev` starting at offset 0, which is fine for ttys/pipes but
// overwrites the head of a regular file when stdout is redirected. Mixing
// that with the sequential `posix.write` calls used for `.output` payloads
// scrambles the output ordering. Format into a stack buffer and use the same
// sequential write path for everything.

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

fn errf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    // bufPrint fills buf to capacity before erroring, so `catch buf[0..]`
    // would emit a valid (truncated) message — but with no trailing newline.
    // Prefer an explicit marker so truncation is obvious.
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "zmyth: <error message overflow>\n";
    writeAllFd(posix.STDERR_FILENO, s) catch {};
}

fn outf(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAllFd(posix.STDOUT_FILENO, s);
}

// ---- shared verb prologue ------------------------------------------------

/// Returns 2 (and prints) on invalid name, null on success — so a verb can
/// `if (validateNameOrFail(n, "verb")) |rc| return rc;`.
fn validateNameOrFail(name: []const u8, verb: []const u8) ?u8 {
    paths.validateName(name) catch {
        errf("zmyth: {s}: invalid session name '{s}'\n", .{ verb, name });
        return 2;
    };
    return null;
}

/// Connect to an existing session or print a diagnostic and return null.
/// Callers decide whether null means `return 1` or `continue`.
fn connectOrFail(allocator: Allocator, name: []const u8, verb: []const u8) ?posix.fd_t {
    return connect(allocator, name) catch |err| {
        errf("zmyth: {s}: {s}: {s}\n", .{ verb, name, @errorName(err) });
        return null;
    };
}

// ---- connection helpers --------------------------------------------------

fn connectPath(sock_path: []const u8, nonblock: bool) !posix.fd_t {
    const addr = std.net.Address.initUnix(sock_path) catch |err| switch (err) {
        // sun_path is ~108 bytes; long ZMYTH_DIR + name overflows it. Surface
        // a specific error rather than letting the daemon fork-then-fail and
        // returning the misleading DaemonStartTimeout.
        error.NameTooLong => return error.SocketPathTooLong,
        else => return err,
    };
    var stype: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    if (nonblock) stype |= posix.SOCK.NONBLOCK;
    const fd = try posix.socket(posix.AF.UNIX, stype, 0);
    errdefer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return error.NoSuchSession,
        error.WouldBlock => {}, // nonblocking connect in progress
        else => return err,
    };
    return fd;
}

fn connect(allocator: Allocator, name: []const u8) !posix.fd_t {
    const sp = try paths.socketPath(allocator, name);
    defer allocator.free(sp);
    return connectPath(sp, false);
}

fn connectOrCreate(
    allocator: Allocator,
    name: []const u8,
    initial_cmd: ?[]const []const u8,
) !posix.fd_t {
    const r = try daemon.ensure(allocator, name, initial_cmd);
    allocator.free(r.sock_path);
    return r.fd;
}

// ---- glob resolution -----------------------------------------------------

fn hasGlobChars(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

/// Expand each pattern against listSessions(); literals that match nothing
/// are passed through so the verb can report "no such session".
fn resolveGlobs(allocator: Allocator, patterns: []const []const u8) ![][]const u8 {
    const sessions = try paths.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    for (patterns) |pat| {
        var matched = false;
        for (sessions) |s| {
            if (!paths.globMatch(pat, s)) continue;
            matched = true;
            // dedupe
            var dup = false;
            for (out.items) |o| if (std.mem.eql(u8, o, s)) {
                dup = true;
                break;
            };
            if (!dup) try out.append(allocator, try allocator.dupe(u8, s));
        }
        if (!matched and !hasGlobChars(pat)) {
            try out.append(allocator, try allocator.dupe(u8, pat));
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- concurrent probe ----------------------------------------------------

const Probe = struct {
    name: []const u8,
    info: ?std.json.Parsed(std.json.Value),
};

/// Open all sockets nonblocking, poll once with a short budget, send .info
/// on each connected fd, collect .info_reply. info==null means dead/stale.
fn probeAll(allocator: Allocator, names: []const []const u8) ![]Probe {
    const probes = try allocator.alloc(Probe, names.len);
    const fds = try allocator.alloc(?posix.fd_t, names.len);
    defer allocator.free(fds);
    for (probes, fds, names) |*p, *fd, n| {
        p.* = .{ .name = n, .info = null };
        fd.* = null;
    }

    var pfds: std.ArrayList(posix.pollfd) = .empty;
    defer pfds.deinit(allocator);

    for (fds, names) |*fdp, n| {
        const sp = paths.socketPath(allocator, n) catch continue;
        defer allocator.free(sp);
        const fd = connectPath(sp, true) catch continue;
        fdp.* = fd;
        try pfds.append(allocator, .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 });
    }

    if (pfds.items.len > 0) {
        _ = posix.poll(pfds.items, probe_connect_ms) catch {};
    }

    const recv_to = posix.timeval{ .sec = 0, .usec = probe_recv_timeout_us };
    var pi: usize = 0;
    for (probes, fds) |*p, fdp| {
        const fd = fdp orelse continue;
        defer posix.close(fd);
        // Verify the nonblocking connect actually completed: poll() may have
        // timed out (revents==0) or signalled an error, and even POLLOUT only
        // means "writable" — SO_ERROR must be 0 for the connect to be good.
        const re = pfds.items[pi].revents;
        pi += 1;
        if (re & posix.POLL.OUT == 0) continue;
        if (re & (posix.POLL.ERR | posix.POLL.HUP) != 0) continue;
        posix.getsockoptError(fd) catch continue;
        // Flip back to blocking for the request/reply.
        const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch continue;
        _ = posix.fcntl(fd, posix.F.SETFL, flags & ~O_NONBLOCK) catch continue;
        // Bound the wait so a wedged daemon can't hang `ls`.
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&recv_to)) catch {};

        ipc.sendBlocking(fd, .info, "") catch continue;
        // WouldBlock (RCVTIMEO expiry) or any other error -> no info.
        const msg = ipc.recvBlocking(allocator, fd) catch continue;
        defer allocator.free(msg.payload);
        if (msg.tag == .info_reply) {
            p.info = std.json.parseFromSlice(std.json.Value, allocator, msg.payload, .{}) catch null;
        }
    }
    return probes;
}

fn freeProbes(allocator: Allocator, probes: []Probe) void {
    for (probes) |*p| if (p.info) |*inf| inf.deinit();
    allocator.free(probes);
}

// ---- signals -------------------------------------------------------------

var sigwinch_flag: std.atomic.Value(bool) = .init(false);

fn handleSigwinch(_: c_int) callconv(.c) void {
    sigwinch_flag.store(true, .release);
    compat.notifySignal();
}

/// Install handlers and block SIGWINCH; returns the pre-block mask for ppoll
/// so the signal is delivered atomically inside the wait — closing the
/// check-flag/ppoll race on an idle attach. On platforms without ppoll the
/// self-pipe in `compat` plays that role and the returned mask is unused.
fn installSignals() !posix.sigset_t {
    try compat.initSignalPipe();

    const winch: posix.Sigaction = .{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &winch, null);

    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);

    var to_block = posix.sigemptyset();
    posix.sigaddset(&to_block, posix.SIG.WINCH);
    return compat.blockSignalsForPoll(&to_block);
}

// ---- wire payload encoders ----------------------------------------------

fn encodeWinsize(buf: *[4]u8, ws: pty.Winsize) void {
    std.mem.writeInt(u16, buf[0..2], ws.cols, .little);
    std.mem.writeInt(u16, buf[2..4], ws.rows, .little);
}

fn buildAttachPayload(allocator: Allocator, ws: pty.Winsize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var sz: [4]u8 = undefined;
    encodeWinsize(&sz, ws);
    try buf.appendSlice(allocator, &sz);
    for (env_forward) |key| {
        if (posix.getenv(key)) |val| {
            try buf.appendSlice(allocator, key);
            try buf.append(allocator, '=');
            try buf.appendSlice(allocator, val);
            try buf.append(allocator, 0);
        }
    }
    return buf.toOwnedSlice(allocator);
}

// =========================================================================
// Verbs
// =========================================================================

pub fn attach(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        errf("zmyth: attach: missing <name>\n", .{});
        return 2;
    }
    const name = args[0];
    if (validateNameOrFail(name, "attach")) |rc| return rc;

    var initial_cmd: ?[]const []const u8 = null;
    if (args.len > 1) {
        if (!std.mem.eql(u8, args[1], "--")) {
            errf("zmyth: attach: expected '--' before command\n", .{});
            return 2;
        }
        // `attach name --` with nothing after is just `attach name`.
        if (args.len > 2) initial_cmd = @ptrCast(args[2..]);
    }

    // Refuse to nest regardless of which session we're inside: attaching to
    // ourselves recurses, and attaching to another session leaves the outer
    // attach's raw-mode/alt-screen wrapping in a confused state.
    if (posix.getenv("ZMYTH_SESSION")) |cur| {
        errf("zmyth: already inside session '{s}'; detach first or use `send`\n", .{cur});
        return 1;
    }

    const sock = connectOrCreate(allocator, name, initial_cmd) catch |err| {
        errf("zmyth: attach: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer posix.close(sock);

    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const stdout_tty = posix.isatty(stdout_fd);
    const stdin_tty = posix.isatty(stdin_fd);

    var raw: ?pty.RawMode = if (stdin_tty) try pty.RawMode.enter(stdin_fd) else null;
    defer if (raw) |*r| r.leave();

    if (stdout_tty) try writeAllFd(stdout_fd, "\x1b[?1049h\x1b[2J\x1b[H");
    defer if (stdout_tty) writeAllFd(stdout_fd, "\x1b[?1049l") catch {};

    const ppoll_mask = try installSignals();

    // Make socket nonblocking for the Framer-driven pump.
    const sf = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, sf | O_NONBLOCK);

    var framer = ipc.Framer.init(allocator);
    defer framer.deinit();

    const ws = pty.getWinsize(stdout_fd) catch pty.Winsize{ .rows = 24, .cols = 80 };
    {
        const payload = try buildAttachPayload(allocator, ws);
        defer allocator.free(payload);
        try framer.queue(.attach, payload);
    }

    var pfds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
    };
    var rbuf: [4096]u8 = undefined;

    while (true) {
        if (sigwinch_flag.swap(false, .acq_rel)) {
            const nws = pty.getWinsize(stdout_fd) catch ws;
            var sz: [4]u8 = undefined;
            encodeWinsize(&sz, nws);
            try framer.queue(.resize, &sz);
        }

        pfds[1].events = posix.POLL.IN;
        if (framer.hasPendingWrite()) pfds[1].events |= posix.POLL.OUT;

        // ppoll (not poll): std.posix.poll retries EINTR internally, which
        // would prevent the SIGWINCH flag from being observed on idle attach.
        // On platforms without ppoll, compat uses a self-pipe instead.
        _ = compat.pollWithMask(&pfds, null, &ppoll_mask) catch |err| switch (err) {
            error.SignalInterrupt => continue, // recheck sigwinch_flag
            else => return err,
        };

        // stdin -> .input
        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(stdin_fd, &rbuf) catch 0;
            if (n == 0) {
                try framer.queue(.detach, "");
                pfds[0].fd = -1; // stop polling stdin
            } else {
                try framer.queue(.input, rbuf[0..n]);
            }
        }

        // sock writable -> flush queued frames
        if (pfds[1].revents & posix.POLL.OUT != 0) {
            const pending = framer.pendingWrite();
            const n = posix.write(sock, pending) catch |err| switch (err) {
                error.WouldBlock => 0,
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    errf("\r\n[zmyth: connection to daemon lost]\r\n", .{});
                    return 1;
                },
                else => return err,
            };
            framer.consumeWrite(n);
        }

        // sock readable -> drain frames
        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(sock, &rbuf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                // A clean shell exit arrives as an `.eof` frame (handled
                // below); raw socket EOF without that means the daemon died.
                errf("\r\n[zmyth: connection to daemon lost]\r\n", .{});
                return 1;
            }
            try framer.pushRead(rbuf[0..n]);
            while (try framer.next()) |msg| switch (msg.tag) {
                .output, .state => try writeAllFd(stdout_fd, msg.payload),
                .ack => return 0, // detach acked
                .eof => {
                    errf("\r\n[session exited]\r\n", .{});
                    return 0;
                },
                .err => errf("\r\nzmyth: {s}\r\n", .{msg.payload}),
                else => {},
            };
        }
    }
}

pub fn run(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var detach_mode = false;
    var json_out = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-' and !std.mem.eql(u8, args[i], "--")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) detach_mode = true //
        else if (std.mem.eql(u8, args[i], "-j")) json_out = true //
        else {
            errf("zmyth: run: unknown flag '{s}'\n", .{args[i]});
            return 2;
        }
    }
    if (i >= args.len) {
        errf("zmyth: run: missing <name>\n", .{});
        return 2;
    }
    const name = args[i];
    i += 1;
    if (validateNameOrFail(name, "run")) |rc| return rc;
    if (i >= args.len or !std.mem.eql(u8, args[i], "--")) {
        errf("zmyth: run: expected '--' before command\n", .{});
        return 2;
    }
    i += 1;
    if (i >= args.len) {
        errf("zmyth: run: missing command\n", .{});
        return 2;
    }
    const cmd = try std.mem.join(allocator, " ", @ptrCast(args[i..]));
    defer allocator.free(cmd);

    const sock = connectOrCreate(allocator, name, null) catch |err| {
        errf("zmyth: run: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer posix.close(sock);

    try ipc.sendBlocking(sock, .run, cmd);
    if (detach_mode) return 0;

    var got_err = false;
    while (true) {
        const msg = ipc.recvBlocking(allocator, sock) catch |err| switch (err) {
            error.UnexpectedEof => return 1,
            else => return err,
        };
        defer allocator.free(msg.payload);
        switch (msg.tag) {
            .output => try writeAllFd(posix.STDOUT_FILENO, msg.payload),
            .run_done => {
                const rd = ipc.RunDoneWire.decode(msg.payload) orelse return 1;
                const ec = rd.exitCode();
                if (json_out) {
                    const via_s = std.enums.tagName(ipc.RunDoneWire.Via, rd.via) orelse "unknown";
                    // Leading \n: ensure JSON is on its own line after PTY output.
                    if (ec) |e| try outf(
                        "\n{{\"exit_code\":{d},\"via\":\"{s}\",\"dur_ms\":{d}}}\n",
                        .{ e, via_s, rd.dur_ms },
                    ) else try outf(
                        "\n{{\"exit_code\":null,\"via\":\"{s}\",\"dur_ms\":{d}}}\n",
                        .{ via_s, rd.dur_ms },
                    );
                }
                return if (ec) |e| @intCast(@as(u32, @bitCast(e)) & 0xff) else 125;
            },
            // Diagnostic from the daemon (e.g. "still waiting for shell
            // prompt"). Print it but keep waiting; only `.run_done`/`.eof`
            // are terminal. We do remember that an error was reported so
            // a fatal `.err` followed by socket close still exits non-zero.
            .err => {
                errf("zmyth: run: {s}\n", .{msg.payload});
                got_err = true;
            },
            .eof => return if (got_err) 1 else 0,
            else => {},
        }
    }
}

pub fn send(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        errf("zmyth: send: missing <name>\n", .{});
        return 2;
    }
    const name = args[0];
    if (validateNameOrFail(name, "send")) |rc| return rc;
    var bytes: []const u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);

    if (args.len == 2 and std.mem.eql(u8, args[1], "-")) {
        var buf: std.ArrayList(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = try posix.read(posix.STDIN_FILENO, &tmp);
            if (n == 0) break;
            try buf.appendSlice(allocator, tmp[0..n]);
        }
        owned = try buf.toOwnedSlice(allocator);
        bytes = owned.?;
    } else if (args.len > 1) {
        owned = try std.mem.join(allocator, " ", @ptrCast(args[1..]));
        bytes = owned.?;
    } else {
        errf("zmyth: send: missing input (text or '-')\n", .{});
        return 2;
    }

    const sock = connectOrFail(allocator, name, "send") orelse return 1;
    defer posix.close(sock);
    try ipc.sendBlocking(sock, .send, bytes);
    const ack = try ipc.recvBlocking(allocator, sock);
    allocator.free(ack.payload);
    return if (ack.tag == .ack) 0 else 1;
}

pub fn read(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var follow = false;
    var screen = false;
    var fmt: u8 = 0;
    var tail_n: u32 = 0;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f")) follow = true //
        else if (std.mem.eql(u8, a, "-s")) screen = true //
        else if (std.mem.eql(u8, a, "--vt")) fmt = 1 //
        else if (std.mem.eql(u8, a, "--html")) fmt = 2 //
        else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) {
                errf("zmyth: read: -n requires a number\n", .{});
                return 2;
            }
            tail_n = std.fmt.parseInt(u32, args[i], 10) catch {
                errf("zmyth: read: invalid -n value\n", .{});
                return 2;
            };
        } else if (a.len > 0 and a[0] == '-') {
            errf("zmyth: read: unknown flag '{s}'\n", .{a});
            return 2;
        } else name = a;
    }
    const nm = name orelse {
        errf("zmyth: read: missing <name>\n", .{});
        return 2;
    };
    if (validateNameOrFail(nm, "read")) |rc| return rc;

    const sock = connectOrFail(allocator, nm, "read") orelse return 1;
    defer posix.close(sock);

    var payload: [6]u8 = undefined;
    payload[0] = if (follow) 2 else if (screen) 1 else 0;
    payload[1] = fmt;
    std.mem.writeInt(u32, payload[2..6], tail_n, .little);
    try ipc.sendBlocking(sock, .read, &payload);

    while (true) {
        const msg = ipc.recvBlocking(allocator, sock) catch |err| switch (err) {
            error.UnexpectedEof => return 0,
            else => return err,
        };
        defer allocator.free(msg.payload);
        switch (msg.tag) {
            .data, .output => try writeAllFd(posix.STDOUT_FILENO, msg.payload),
            .eof => if (!follow) return 0,
            .err => {
                errf("zmyth: read: {s}\n", .{msg.payload});
                return 1;
            },
            else => {},
        }
    }
}

fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .integer) f.integer else null;
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn jsonBool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .bool) f.bool else null;
}

pub fn ls(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var json_out = false;
    var quiet = false;
    var glob: []const u8 = "*";
    for (args) |a| {
        if (std.mem.eql(u8, a, "-j")) json_out = true //
        else if (std.mem.eql(u8, a, "-q")) quiet = true //
        else if (a.len > 0 and a[0] == '-') {
            errf("zmyth: ls: unknown flag '{s}'\n", .{a});
            return 2;
        } else glob = a;
    }

    const names = try resolveGlobs(allocator, &.{glob});
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    const probes = try probeAll(allocator, names);
    defer freeProbes(allocator, probes);

    // Format into memory then writeAllFd: see the note above writeAllFd for
    // why File.stdout().writer() is unsafe with `>>` redirects.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (json_out) {
        try w.writeAll("[");
        var first = true;
        for (probes) |p| {
            if (!first) try w.writeAll(",");
            first = false;
            if (p.info) |inf| {
                try std.json.Stringify.value(inf.value, .{}, w);
            } else {
                try w.print("{{\"name\":\"{s}\",\"alive\":false}}", .{p.name});
            }
        }
        try w.writeAll("]\n");
    } else if (quiet) {
        for (probes) |p| try w.print("{s}\n", .{p.name});
    } else {
        for (probes) |p| {
            if (p.info) |inf| {
                const v = inf.value;
                const pid = jsonInt(v, "pid") orelse 0;
                const hooked = if (jsonBool(v, "hooked") orelse false) "hooked" else "-";
                const cwd = jsonStr(v, "cwd") orelse "";
                if (jsonInt(v, "last_exit")) |ec|
                    try w.print("{s}\t{d}\t{s}\t{d}\t{s}\n", .{ p.name, pid, hooked, ec, cwd })
                else
                    try w.print("{s}\t{d}\t{s}\t-\t{s}\n", .{ p.name, pid, hooked, cwd });
            } else {
                try w.print("{s}\t-\tdead\t-\t-\n", .{p.name});
            }
        }
    }
    try writeAllFd(posix.STDOUT_FILENO, aw.written());
    return if (probes.len == 0) 1 else 0;
}

pub fn wait(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var json_out = false;
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(allocator);
    for (args) |a| {
        if (std.mem.eql(u8, a, "-j")) json_out = true //
        else if (a.len > 0 and a[0] == '-') {
            errf("zmyth: wait: unknown flag '{s}'\n", .{a});
            return 2;
        } else try pats.append(allocator, a);
    }
    if (pats.items.len == 0) {
        errf("zmyth: wait: missing <name|glob>\n", .{});
        return 2;
    }
    const names = try resolveGlobs(allocator, pats.items);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var agg: u8 = 0;
    for (names) |name| {
        var ec: ?i32 = null;
        const sock = connectOrFail(allocator, name, "wait") orelse {
            agg = @max(agg, 1);
            if (json_out) try outf("{{\"name\":\"{s}\",\"exit_code\":null}}\n", .{name});
            continue;
        };
        defer posix.close(sock);

        try ipc.sendBlocking(sock, .wait, "");
        while (true) {
            const msg = ipc.recvBlocking(allocator, sock) catch |err| switch (err) {
                // Daemon vanished without sending .run_done/.eof — treat as
                // failure so `zmyth wait foo && deploy` doesn't proceed on a
                // crash.
                error.UnexpectedEof => {
                    errf("zmyth: wait: {s}: daemon connection lost\n", .{name});
                    agg = @max(agg, 1);
                    break;
                },
                else => return err,
            };
            defer allocator.free(msg.payload);
            switch (msg.tag) {
                .run_done => {
                    if (ipc.RunDoneWire.decode(msg.payload)) |rd| ec = rd.exitCode();
                    break;
                },
                .err => {
                    errf("zmyth: wait: {s}: {s}\n", .{ name, msg.payload });
                    agg = @max(agg, 1);
                    break;
                },
                .eof => break,
                else => {},
            }
        }
        if (json_out) {
            if (ec) |e| try outf("{{\"name\":\"{s}\",\"exit_code\":{d}}}\n", .{ name, e }) //
            else try outf("{{\"name\":\"{s}\",\"exit_code\":null}}\n", .{name});
        }
        if (ec) |e| {
            if (e != 0) agg = @max(agg, @as(u8, @intCast(@as(u32, @bitCast(e)) & 0xff)));
        }
    }
    return agg;
}

pub fn write(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        errf("zmyth: write: expected <name> <path>\n", .{});
        return 2;
    }
    const name = args[0];
    const path = args[1];
    if (validateNameOrFail(name, "write")) |rc| return rc;

    const sock = connectOrFail(allocator, name, "write") orelse return 1;
    defer posix.close(sock);

    try ipc.sendBlocking(sock, .write_hdr, path);
    {
        const reply = try ipc.recvBlocking(allocator, sock);
        defer allocator.free(reply.payload);
        if (reply.tag == .err) {
            errf("zmyth: write: {s}\n", .{reply.payload});
            return 1;
        }
        if (reply.tag != .ack) return 1;
    }

    // Stream stdin -> base64 lines -> .write_data. Only complete 48-byte
    // groups are encoded mid-stream so no `=` padding appears before EOF.
    var raw: [48 * 256]u8 = undefined;
    var held: usize = 0;
    var enc: std.ArrayList(u8) = .empty;
    defer enc.deinit(allocator);
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, raw[held..]);
        const total = held + n;
        const eof = n == 0;
        const emit_end: usize = if (eof) total else (total / 48) * 48;

        enc.clearRetainingCapacity();
        var off: usize = 0;
        while (off < emit_end) : (off = @min(off + 48, emit_end)) {
            const end = @min(off + 48, emit_end);
            var line: [68]u8 = undefined;
            const e = std.base64.standard.Encoder.encode(&line, raw[off..end]);
            try enc.appendSlice(allocator, e);
            try enc.append(allocator, '\n');
        }
        if (enc.items.len > 0) try ipc.sendBlocking(sock, .write_data, enc.items);

        if (eof) break;
        held = total - emit_end;
        std.mem.copyForwards(u8, raw[0..held], raw[emit_end..total]);
    }

    try ipc.sendBlocking(sock, .write_data, "");
    const reply = try ipc.recvBlocking(allocator, sock);
    defer allocator.free(reply.payload);
    if (reply.tag == .err) {
        errf("zmyth: write: {s}\n", .{reply.payload});
        return 1;
    }
    return if (reply.tag == .ack) 0 else 1;
}

pub fn kill(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var sig: u8 = @intCast(posix.SIG.TERM);
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(allocator);
    for (args) |a| {
        if (std.mem.eql(u8, a, "-9")) sig = @intCast(posix.SIG.KILL) //
        else if (a.len > 0 and a[0] == '-') {
            errf("zmyth: kill: unknown flag '{s}'\n", .{a});
            return 2;
        } else try pats.append(allocator, a);
    }
    if (pats.items.len == 0) {
        errf("zmyth: kill: missing <name|glob>\n", .{});
        return 2;
    }
    const names = try resolveGlobs(allocator, pats.items);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var rc: u8 = 0;
    for (names) |name| {
        const sp = try paths.socketPath(allocator, name);
        defer allocator.free(sp);
        const sock = connectPath(sp, false) catch |err| switch (err) {
            error.NoSuchSession => {
                // Stale socket: clean it up. Missing entirely: report.
                posix.unlink(sp) catch {
                    errf("zmyth: kill: no such session '{s}'\n", .{name});
                    rc = 1;
                };
                continue;
            },
            else => {
                errf("zmyth: kill: {s}: {s}\n", .{ name, @errorName(err) });
                rc = 1;
                continue;
            },
        };
        defer posix.close(sock);
        // Daemon may already be tearing down (race with another kill / shell
        // exit); treat a broken pipe like the recv side does and move on.
        ipc.sendBlocking(sock, .kill, &.{sig}) catch |err| {
            errf("zmyth: kill: {s}: {s}\n", .{ name, @errorName(err) });
            rc = 1;
            continue;
        };
        const ack = ipc.recvBlocking(allocator, sock) catch continue;
        allocator.free(ack.payload);
    }
    return rc;
}

pub fn mv(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len != 2) {
        errf("zmyth: mv: expected <old> <new>\n", .{});
        return 2;
    }
    if (validateNameOrFail(args[0], "mv")) |rc| return rc;
    if (validateNameOrFail(args[1], "mv")) |rc| return rc;
    const sock = connectOrFail(allocator, args[0], "mv") orelse return 1;
    defer posix.close(sock);
    try ipc.sendBlocking(sock, .rename, args[1]);
    const reply = try ipc.recvBlocking(allocator, sock);
    defer allocator.free(reply.payload);
    if (reply.tag == .err) {
        errf("zmyth: mv: {s}\n", .{reply.payload});
        return 1;
    }
    return 0;
}

pub fn detach(allocator: Allocator, args: []const [:0]const u8) !u8 {
    const name = if (args.len > 0) args[0] else posix.getenv("ZMYTH_SESSION") orelse {
        errf("zmyth: detach: not inside a session and no <name> given\n", .{});
        return 2;
    };
    if (validateNameOrFail(name, "detach")) |rc| return rc;
    const sock = connectOrFail(allocator, name, "detach") orelse return 1;
    defer posix.close(sock);
    try ipc.sendBlocking(sock, .detach, "");
    return 0;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "resolveGlobs dedupe + literal passthrough" {
    const tmp = "/tmp/zmx-client-test-globs";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};
    _ = setenv("ZMYTH_DIR", tmp, 1);
    defer _ = unsetenv("ZMYTH_DIR");

    testing.allocator.free(try paths.runtimeDir(testing.allocator)); // ensure dir
    var d = try std.fs.openDirAbsolute(tmp, .{});
    defer d.close();
    (try d.createFile("dev.sock", .{})).close();
    (try d.createFile("build-1.sock", .{})).close();

    const out = try resolveGlobs(testing.allocator, &.{ "*", "dev", "ghost" });
    defer {
        for (out) |s| testing.allocator.free(s);
        testing.allocator.free(out);
    }
    // "*" -> build-1, dev; "dev" deduped; "ghost" passed through.
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("build-1", out[0]);
    try testing.expectEqualStrings("dev", out[1]);
    try testing.expectEqualStrings("ghost", out[2]);
}

test "hasGlobChars" {
    try testing.expect(hasGlobChars("foo*"));
    try testing.expect(hasGlobChars("a?b"));
    try testing.expect(!hasGlobChars("plain"));
}

test "encodeWinsize little-endian" {
    var b: [4]u8 = undefined;
    encodeWinsize(&b, .{ .cols = 0x1234, .rows = 0x5678 });
    try testing.expectEqual(@as(u8, 0x34), b[0]);
    try testing.expectEqual(@as(u8, 0x12), b[1]);
    try testing.expectEqual(@as(u8, 0x78), b[2]);
    try testing.expectEqual(@as(u8, 0x56), b[3]);
}

test {
    std.testing.refAllDecls(@This());
}
