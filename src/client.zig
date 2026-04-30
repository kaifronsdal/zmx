//! Client half of zmyth: one `pub fn` per CLI verb. Each parses its own
//! flags, connects to (or creates) a session daemon over its Unix socket,
//! speaks the ipc.zig framing protocol, and returns a process exit code.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const ipc = @import("ipc.zig");
const paths = @import("posix/paths.zig");
const pty = @import("posix/pty.zig");
const compat = @import("posix/compat.zig");
const daemon = @import("daemon.zig");
const spawn = @import("spawn.zig");
const lib = @import("zmyth");

const writeAllFd = compat.writeAllFd;
const eq = std.mem.eql;
const env_forward = spawn.env_forward;

// Loopback RTT is <1ms; a healthy daemon answers `.info` instantly. These
// bound how long `ls` stalls on a hung/unresponsive daemon, so keep them tight.
const probe_connect_ms = 100;
const probe_recv_timeout_us = 100_000;

/// Streaming (non-positional) formatted write to stdout.
pub fn outf(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&buf, fmt, args));
}

/// Best-effort: errors writing to stderr are swallowed. On format overflow,
/// emit a marker rather than truncated noise (bufPrint fills the buffer
/// before erroring, so the partial content has no trailing newline).
pub fn errf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "zmyth: <error message overflow>\n";
    std.fs.File.stderr().writeAll(s) catch {};
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

const connectOrCreate = daemon.ensure;

// ---- glob resolution -----------------------------------------------------

fn hasGlobChars(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

/// Expand `patterns` against live sessions. Unmatched literals pass through
/// (so `wait foo` errors at connect time with a useful message); unmatched
/// globs are dropped. Callers treat an empty result as an error.
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
            for (out.items) |o| if (eq(u8, o, s)) {
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
        compat.setNonBlock(fd, false) catch continue;
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

/// Set by `attach()` once raw mode / alt-screen are active, so a TERM/HUP
/// arriving mid-attach can restore the outer terminal before dying. Defers
/// don't run on signal death, and leaving the user's tty raw + alt-screen
/// is the worst failure mode an attach can have.
var attach_tty: struct {
    raw: ?pty.RawMode = null,
    alt_screen_fd: ?posix.fd_t = null,
} = .{};

fn handleFatal(sig: c_int) callconv(.c) void {
    if (attach_tty.alt_screen_fd) |fd| _ = posix.write(fd, "\x1b[?1049l") catch {};
    if (attach_tty.raw) |*r| r.leave();
    // Re-raise with default disposition so the parent sees the right status.
    posix.sigaction(@intCast(sig), &.{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.raise(@intCast(sig)) catch posix.exit(128 + @as(u8, @intCast(sig)));
}

/// Install handlers and block SIGWINCH; returns the pre-block mask for ppoll
/// so the signal is delivered atomically inside the wait — closing the
/// check-flag/ppoll race on an idle attach. On platforms without ppoll the
/// self-pipe in `compat` plays that role and the returned mask is unused.
fn installSignals() !posix.sigset_t {
    try compat.initSignalPipe();

    inline for (.{
        .{ posix.SIG.WINCH, handleSigwinch },
        .{ posix.SIG.PIPE, posix.SIG.IGN },
        .{ posix.SIG.TERM, handleFatal },
        .{ posix.SIG.HUP, handleFatal },
        .{ posix.SIG.INT, handleFatal },
    }) |s| posix.sigaction(s[0], &.{
        .handler = .{ .handler = s[1] },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

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
        if (!eq(u8, args[1], "--")) {
            errf("zmyth: attach: expected '--' before command\n", .{});
            return 2;
        }
        // `attach name --` with nothing after is just `attach name`.
        if (args.len > 2) initial_cmd = @ptrCast(args[2..]);
    }

    // Refuse to nest regardless of which session we're inside: attaching to
    // ourselves recurses, and attaching to another session leaves the outer
    // attach's raw-mode/alt-screen wrapping in a confused state. Set-but-
    // empty (`ZMYTH_SESSION=`) is the explicit override.
    if (posix.getenv("ZMYTH_SESSION")) |cur| if (cur.len > 0) {
        errf("zmyth: already inside session '{s}'; detach first or use `send`\n", .{cur});
        return 1;
    };

    const sock = connectOrCreate(allocator, name, initial_cmd) catch |err| {
        errf("zmyth: attach: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer posix.close(sock);

    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const stdout_tty = posix.isatty(stdout_fd);
    const stdin_tty = posix.isatty(stdin_fd);

    const ppoll_mask = try installSignals();

    if (stdin_tty) attach_tty.raw = try pty.RawMode.enter(stdin_fd);
    defer if (attach_tty.raw) |*r| {
        r.leave();
        attach_tty.raw = null;
    };

    if (stdout_tty) {
        try writeAllFd(stdout_fd, "\x1b[?1049h\x1b[2J\x1b[H");
        attach_tty.alt_screen_fd = stdout_fd;
    }
    defer if (attach_tty.alt_screen_fd) |fd| {
        writeAllFd(fd, "\x1b[?1049l") catch {};
        attach_tty.alt_screen_fd = null;
    };

    // Make socket nonblocking for the Framer-driven pump.
    try compat.setNonBlock(sock, true);

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
    var interactive = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-' and !eq(u8, args[i], "--")) : (i += 1) {
        if (eq(u8, args[i], "-d")) detach_mode = true //
        else if (eq(u8, args[i], "-j")) json_out = true //
        else if (eq(u8, args[i], "-i")) interactive = true //
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
    if (i >= args.len or !eq(u8, args[i], "--")) {
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

    // Wire payload: 1-byte interactive flag + cmd.
    const payload = try allocator.alloc(u8, cmd.len + 1);
    defer allocator.free(payload);
    payload[0] = if (interactive) 1 else 0;
    @memcpy(payload[1..], cmd);
    try ipc.sendBlocking(sock, .run, payload);
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
                // line_rejected/prompt_fallback have no exit code; without -j
                // the only signal is the 125 return — say why.
                if (ec == null and !json_out) switch (rd.via) {
                    .line_rejected => errf(
                        "zmyth: run: shell did not accept the line " ++
                            "(unclosed quote? or a slow link — retry)\n",
                        .{},
                    ),
                    .prompt_fallback => errf(
                        "zmyth: run: completed via prompt fallback; exit code unknown\n",
                        .{},
                    ),
                    else => {},
                };
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

/// Install the shell-integration hook into the (possibly nested) shell that
/// `name` is currently sitting at. With no `<name>`, prints the per-shell rc
/// snippet for manual install instead.
pub fn hook(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try writeAllFd(
            posix.STDOUT_FILENO,
            "# zmyth hook — add ONE of these to the target shell's rc:\n\n" ++
                "# bash (~/.bashrc):\n" ++ lib.hook.rcSourceLine(.bash) ++ "\n\n" ++
                "# zsh (~/.zshrc):\n" ++ lib.hook.rcSourceLine(.zsh) ++ "\n\n" ++
                "# fish (~/.config/fish/conf.d/zmyth.fish):\n" ++ lib.hook.rcSourceLine(.fish) ++ "\n\n" ++
                "# Or, with the session at the target shell's prompt:\n" ++
                "#   zmyth hook <session>\n" ++
                "# which writes " ++ lib.hook.dir ++ "/hook.<shell> and appends the line above.\n",
        );
        return 0;
    }
    const name = args[0];
    if (validateNameOrFail(name, "hook")) |rc| return rc;

    const sock = connectOrFail(allocator, name, "hook") orelse return 1;
    defer posix.close(sock);
    try ipc.sendBlocking(sock, .hook, "");

    while (true) {
        const msg = ipc.recvBlocking(allocator, sock) catch |err| switch (err) {
            error.UnexpectedEof => {
                errf("zmyth: hook: daemon closed connection\n", .{});
                return 1;
            },
            else => return err,
        };
        defer allocator.free(msg.payload);
        switch (msg.tag) {
            .ack => {
                try outf("zmyth: {s}\n", .{msg.payload});
                return 0;
            },
            .err => {
                errf("zmyth: {s}\n", .{msg.payload});
                return 1;
            },
            .eof => return 1,
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

    if (args.len == 2 and eq(u8, args[1], "-")) {
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
    var tail_n: u32 = 0;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(u8, a, "-f")) follow = true //
        else if (eq(u8, a, "-s")) screen = true //
        else if (eq(u8, a, "-n")) {
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

    var payload: [5]u8 = undefined;
    payload[0] = if (follow) 2 else if (screen) 1 else 0;
    std.mem.writeInt(u32, payload[1..5], tail_n, .little);
    try ipc.sendBlocking(sock, .read, &payload);

    while (true) {
        const msg = ipc.recvBlocking(allocator, sock) catch |err| switch (err) {
            // A clean end arrives as an `.eof` frame; raw socket EOF without
            // one means the daemon died (or, in non-follow mode, the dump
            // completed and the daemon hung up — also fine).
            error.UnexpectedEof => return if (follow) 1 else 0,
            else => return err,
        };
        defer allocator.free(msg.payload);
        switch (msg.tag) {
            .data, .output => try writeAllFd(posix.STDOUT_FILENO, msg.payload),
            .eof => return 0,
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
        if (eq(u8, a, "-j")) json_out = true //
        else if (eq(u8, a, "-q")) quiet = true //
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

    // Format into memory then writeAllFd: see io.zig for why
    // File.stdout().writer() is unsafe with `>>` redirects.
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
        if (eq(u8, a, "-j")) json_out = true //
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
    if (names.len == 0) {
        errf("zmyth: wait: no sessions match\n", .{});
        return 1;
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

const write_buffer_cap = 64 * 1024 * 1024;

/// gzip-compress `raw` into an owned buffer, or null if `gzip` isn't on PATH.
/// Zig 0.15.2's `std.compress.flate` compressor is unfinished (doesn't
/// compile — mid-rewrite for the new Writer API), so shell out. A thread
/// feeds stdin so a full stdout pipe can't deadlock us. Caller frees.
fn gzipCompress(allocator: Allocator, raw: []const u8) !?[]u8 {
    var child = std.process.Child.init(&.{ "gzip", "-c", "-1" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const Feeder = struct {
        fn run(f: std.fs.File, data: []const u8) void {
            f.writeAll(data) catch {};
            f.close();
        }
    };
    const t = try std.Thread.spawn(.{}, Feeder.run, .{ child.stdin.?, raw });
    child.stdin = null; // thread owns it

    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len / 4 + 64);
    errdefer out.deinit(allocator);
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&tmp) catch break;
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }
    t.join();
    _ = child.wait() catch {};
    return try out.toOwnedSlice(allocator);
}

pub fn write(allocator: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len < 2) {
        errf("zmyth: write: expected <name> <path>\n", .{});
        return 2;
    }
    const name = args[0];
    const path = args[1];
    if (validateNameOrFail(name, "write")) |rc| return rc;

    // Buffer all of stdin: we must know both plain and gzip encoded lengths
    // up front so the daemon can pick the opener. Nested-SSH writes are
    // scripts/configs (KB–MB); cap at 64MB. Local-FS handles larger files
    // at depth 0 (use scp for nested >64MB).
    var raw: std.ArrayList(u8) = try .initCapacity(allocator, 64 * 1024);
    defer raw.deinit(allocator);
    {
        var tmp: [64 * 1024]u8 = undefined;
        while (true) {
            const r = try posix.read(posix.STDIN_FILENO, &tmp);
            if (r == 0) break;
            if (raw.items.len + r > write_buffer_cap) {
                errf("zmyth: write: stdin exceeds {d}MB\n", .{write_buffer_cap >> 20});
                return 1;
            }
            try raw.appendSlice(allocator, tmp[0..r]);
        }
    }

    const sock = connectOrFail(allocator, name, "write") orelse return 1;
    defer posix.close(sock);

    try ipc.sendBlocking(sock, .write_hdr, path);

    // Daemon replies with the mode it can support: 'L' (local-FS direct),
    // 'z' (PTY, gunzip available), 'p' (PTY, plain only). Compression
    // happens AFTER this so local-FS pays no gzip cost.
    const offered: u8 = blk: {
        const reply = try ipc.recvBlocking(allocator, sock);
        defer allocator.free(reply.payload);
        if (reply.tag == .err) {
            errf("zmyth: write: {s}\n", .{reply.payload});
            return 1;
        }
        if (reply.tag != .ack or reply.payload.len == 0) return 1;
        break :blk reply.payload[0];
    };

    var gz_buf: []const u8 = "";
    defer allocator.free(gz_buf);
    const body: []const u8, const b64: bool = switch (offered) {
        'L' => .{ raw.items, false },
        'z', 'p' => blk: {
            // Try gzip when offered; downgrade to plain if it didn't shrink
            // or gzip is missing client-side.
            if (offered == 'z') if (try gzipCompress(allocator, raw.items)) |g| {
                gz_buf = g;
            };
            const use_gz = gz_buf.len > 0 and gz_buf.len < raw.items.len;
            const src = if (use_gz) gz_buf else raw.items;
            var begin: [9]u8 = undefined;
            begin[0] = if (use_gz) 'z' else 'p';
            std.mem.writeInt(u64, begin[1..9], lib.hook.writeEncLen(src.len), .little);
            try ipc.sendBlocking(sock, .write_begin, &begin);
            const ack = try ipc.recvBlocking(allocator, sock);
            defer allocator.free(ack.payload);
            if (ack.tag != .ack) {
                if (ack.tag == .err) errf("zmyth: write: {s}\n", .{ack.payload});
                return 1;
            }
            break :blk .{ src, true };
        },
        else => return 1,
    };
    try writeStream(allocator, sock, body, b64);

    try ipc.sendBlocking(sock, .write_data, "");
    const reply = try ipc.recvBlocking(allocator, sock);
    defer allocator.free(reply.payload);
    if (reply.tag == .err) {
        errf("zmyth: write: {s}\n", .{reply.payload});
        return 1;
    }
    return if (reply.tag == .ack) 0 else 1;
}

/// Send `body` as `.write_data` chunks (raw or base64-encoded), waiting for
/// `.ack` after each. 48 raw → 64 enc + '\n' per line; mid-stream chunks are
/// 48-aligned so `=` padding appears only at EOF.
fn writeStream(allocator: Allocator, sock: posix.fd_t, body: []const u8, b64: bool) !void {
    var enc: [65 * 1024]u8 = undefined;
    var pos: usize = 0;
    while (pos < body.len) {
        const take = @min(48 * 1024, body.len - pos);
        const chunk = body[pos..][0..take];
        pos += take;
        const wire: []const u8 = if (!b64) chunk else blk: {
            var w: usize = 0;
            var off: usize = 0;
            while (off < take) : (off += 48) {
                const e = std.base64.standard.Encoder.encode(enc[w..], chunk[off..@min(off + 48, take)]);
                w += e.len;
                enc[w] = '\n';
                w += 1;
            }
            break :blk enc[0..w];
        };
        try ipc.sendBlocking(sock, .write_data, wire);
        const ack = try ipc.recvBlocking(allocator, sock);
        defer allocator.free(ack.payload);
        if (ack.tag != .ack) {
            if (ack.tag == .err) errf("zmyth: write: {s}\n", .{ack.payload});
            return error.WriteFailed;
        }
    }
}

pub fn kill(allocator: Allocator, args: []const [:0]const u8) !u8 {
    var sig: u8 = @intCast(posix.SIG.TERM);
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(allocator);
    for (args) |a| {
        if (eq(u8, a, "-9")) sig = @intCast(posix.SIG.KILL) //
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
    if (names.len == 0) {
        errf("zmyth: kill: no sessions match\n", .{});
        return 1;
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

const setenv = paths.setenv;
const unsetenv = paths.unsetenv;

test "resolveGlobs dedupe + literal passthrough" {
    const tmp = "/tmp/zmyth-client-test-globs";
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
