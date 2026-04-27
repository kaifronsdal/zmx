//! One-daemon-per-session process: owns a `Session`, a PTY master, a listening
//! Unix socket, and N connected clients. Single-threaded poll loop; no
//! allocation in the hot path beyond what Framer/Session already do.
//!
//! The only public entry point is `ensure()`, called from main.zig. Everything
//! else is private to this file.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const ipc = @import("ipc.zig");
const pty = @import("pty.zig");
const compat = @import("compat.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");
const protocol = @import("protocol.zig");
const input = @import("input.zig");
const term_state = @import("term_state.zig");
const Session = @import("session.zig").Session;

const log = std.log.scoped(.daemon);

/// Drop a client whose outbound framer backlog exceeds this.
const client_backpressure_limit = 4 * 1024 * 1024;
/// A leader whose backlog crosses this is demoted (kept connected). A client
/// that isn't draining is one whose terminal is catatonic (half-open SSH,
/// stuck pty master) — it must not keep driving the PTY's winsize.
const leader_demote_backlog = 256 * 1024;
/// Refuse new connections beyond this; protects against fd exhaustion from
/// idle/leaked clients (each connection is same-uid, so this is anti-foot-gun
/// not a security boundary).
const max_clients = 64;
/// Max payload per `.state` frame sent on attach.
const state_chunk = 256 * 1024;
/// Max payload per `.data` frame sent for `read`.
const data_chunk = 64 * 1024;
/// `.write_data` ack is deferred while pty_input is above this, so the client
/// can't push faster than the PTY drains.
const write_backpressure = 256 * 1024;

// ───────────────────────────── public API ─────────────────────────────

/// Ensure a session daemon exists for `name` and return a connected blocking
/// fd. If the socket already responds, that's it. Otherwise: fork; child
/// becomes the daemon (setsid, redirect stdio to log, spawn shell, listen,
/// run loop, never returns); parent waits briefly for the socket to appear.
pub fn ensure(
    allocator: Allocator,
    name: []const u8,
    initial_cmd: ?[]const []const u8,
) !posix.fd_t {
    try paths.validateName(name);

    const sock_path = try paths.socketPath(allocator, name);
    defer allocator.free(sock_path);

    // Probe: does a live daemon already own this socket?
    if (probe(sock_path)) |fd| return fd;

    // Stale socket cleanup is deferred to the child (under flock) to avoid
    // racing parents unlinking a freshly-bound socket from a competing child.
    const pid = try posix.fork();
    if (pid == 0) {
        // ── child ────────────────────────────────────────────────────
        // From here on we never return to the caller; on any error we
        // log (best-effort) and _exit so the parent isn't duplicated.
        daemonMain(name, initial_cmd) catch |err| {
            log.err("daemon for '{s}' died: {s}", .{ name, @errorName(err) });
        };
        posix.exit(0);
    }

    // Reap the intermediate child (it exits immediately after the second fork).
    var st: c_int = undefined;
    _ = std.c.waitpid(pid, &st, 0);

    // ── parent: wait for the socket to come up ───────────────────────
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (probe(sock_path)) |fd| return fd;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    // Daemon never came up — surface a distinct error so the caller can say
    // "daemon failed to start" rather than the misleading NoSuchSession that
    // a follow-up connect() would produce.
    return error.DaemonStartTimeout;
}

// ───────────────────────────── signals ─────────────────────────────

var should_exit: std.atomic.Value(bool) = .init(false);
var should_reap: std.atomic.Value(bool) = .init(false);

fn sigExit(_: c_int) callconv(.c) void {
    should_exit.store(true, .release);
    compat.notifySignal();
}
fn sigChld(_: c_int) callconv(.c) void {
    should_reap.store(true, .release);
    compat.notifySignal();
}

/// Install handlers and block TERM/INT/CHLD in the normal mask. Returns the
/// pre-block mask, which the loop passes to `ppoll` so those signals are
/// delivered atomically inside the wait — closing the check-flag/ppoll race.
/// On platforms without `ppoll` the self-pipe in `compat` plays that role
/// instead and the returned mask is unused.
fn setupSignals() !posix.sigset_t {
    try compat.initSignalPipe();

    // SIGPIPE: client sockets going away must not kill the daemon.
    install(posix.SIG.PIPE, posix.SIG.IGN);
    install(posix.SIG.TERM, sigExit);
    install(posix.SIG.INT, sigExit);
    install(posix.SIG.CHLD, sigChld);

    var to_block = posix.sigemptyset();
    posix.sigaddset(&to_block, posix.SIG.TERM);
    posix.sigaddset(&to_block, posix.SIG.INT);
    posix.sigaddset(&to_block, posix.SIG.CHLD);
    return compat.blockSignalsForPoll(&to_block);
}

fn install(sig: u6, handler: ?posix.Sigaction.handler_fn) void {
    posix.sigaction(sig, &.{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
}

// ───────────────────────────── client ─────────────────────────────

const Client = struct {
    fd: posix.fd_t,
    /// Monotonic; Session uses this to route run completions.
    id: u32,
    framer: ipc.Framer,
    input_cls: input.Classifier,
    /// Sent `.attach` (vs. one-shot `.run`/`.read`).
    attached: bool = false,
    /// Wants live `.output` frames (set on `.attach` and `.run`).
    wants_output: bool = false,
    /// Blocked in `.wait`; receives `.run_done` once the session is idle.
    waiting: bool = false,
    /// `.write_data` chunk received while pty_input was over the backpressure
    /// threshold; `.ack` is deferred until servicePty drains it.
    write_ack_pending: bool = false,
    /// Mode byte sent in the deferred `.write_hdr` ack: 'z' (gzip) or 'p'.
    /// The local-FS path acks immediately so doesn't use this.
    write_mode: u8 = 'p',
    closed: bool = false,
    /// Last reported terminal size from this client (for leader promotion).
    rows: u16 = 24,
    cols: u16 = 80,
};

// ───────────────────────────── daemon state ─────────────────────────────

const Daemon = struct {
    gpa: Allocator,
    name: []u8, // owned
    sp: paths.SessionPaths, // owned

    session: Session,
    ppoll_mask: posix.sigset_t,
    pty_fd: posix.fd_t,
    lock_fd: posix.fd_t,
    shell_pid: posix.pid_t,
    /// What `spawnShell` detected from `$SHELL`. `.unknown` means the shell will
    /// never announce, so `.run` requests cannot work — refuse them up front.
    spawned_shell: protocol.Shell,
    /// Set by the SIGCHLD reaper if it wins the race against handlePtyEof.
    shell_status: ?u32 = null,
    listen_fd: posix.fd_t,

    clients: std.ArrayList(Client) = .empty,
    next_client_id: u32 = 1,
    leader_id: ?u32 = null,

    /// Client id of the in-flight `write` (only one at a time).
    write_client: ?u32 = null,
    /// Local-FS shortcut: depth-0 absolute-path writes go straight to this fd
    /// instead of through the PTY. null when the PTY path is in use.
    write_local_fd: ?posix.fd_t = null,

    created_ts: i64,
    pollfds: std.ArrayList(posix.pollfd) = .empty,

    fn deinit(self: *Daemon) void {
        for (self.clients.items) |*c| {
            c.framer.deinit();
            posix.close(c.fd);
        }
        self.clients.deinit(self.gpa);
        self.pollfds.deinit(self.gpa);
        self.session.deinit();
        self.gpa.free(self.name);
        self.sp.deinit(self.gpa);
    }

    fn findClient(self: *Daemon, id: u32) ?*Client {
        for (self.clients.items) |*c| if (c.id == id) return c;
        return null;
    }

    /// Make `c` the size-driving client and resize the PTY to match.
    fn promoteLeader(self: *Daemon, c: *Client) void {
        self.leader_id = c.id;
        // best-effort: ghostty resize can OOM and the PTY ioctl almost never
        // fails — neither should cost the client its leader status.
        self.session.resize(c.rows, c.cols) catch {};
        pty.setWinsize(self.pty_fd, .{ .rows = c.rows, .cols = c.cols }) catch {};
    }
};

// ───────────────────────────── daemon entry ─────────────────────────────

/// Runs in the forked child. Never returns to caller's stack frame in any
/// useful sense — caller `posix.exit()`s after this returns.
fn daemonMain(name: []const u8, initial_cmd: ?[]const []const u8) !void {
    const gpa = std.heap.c_allocator;

    // ── daemonize ─────────────────────────────────────────────────────
    // First fork already happened in ensure(). Become session leader,
    // then fork again so we are not a session leader (and can't acquire
    // a controlling TTY by accident).
    _ = posix.setsid() catch {};
    const pid2 = try posix.fork();
    if (pid2 != 0) posix.exit(0);

    posix.chdir("/") catch {};

    var sp = try paths.SessionPaths.init(gpa, name);

    // Redirect stderr to the session log, close stdin/stdout.
    {
        const log_fd = try posix.open(
            sp.log,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o600,
        );
        try posix.dup2(log_fd, posix.STDERR_FILENO);
        if (log_fd != posix.STDERR_FILENO) posix.close(log_fd);

        const devnull = try posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        try posix.dup2(devnull, posix.STDIN_FILENO);
        try posix.dup2(devnull, posix.STDOUT_FILENO);
        if (devnull > posix.STDERR_FILENO) posix.close(devnull);
    }

    log.info("starting session={s} pid={d}", .{ name, std.c.getpid() });

    const ppoll_mask = try setupSignals();

    // Exclusive lock — resolves the ensure() race where two clients fork
    // daemons concurrently. Loser exits before touching anything; both
    // parents' probe loops will find the winner's socket.
    const lock_fd = acquireLock(sp.lock) catch |err| switch (err) {
        error.WouldBlock => {
            log.info("lost daemon race for '{s}'; exiting", .{name});
            sp.deinit(gpa);
            return;
        },
        else => return err,
    };
    log.info("lock acquired", .{});

    std.fs.makeDirAbsolute(sp.env_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // ── spawn shell into a PTY ───────────────────────────────────────
    const session = try Session.init(gpa, 24, 80);

    var p = try pty.Pty.open();
    try pty.setWinsize(p.master, .{ .rows = 24, .cols = 80 });
    // Non-blocking master so the poll loop never wedges on read/write.
    try pty.setNonBlock(p.master, true);

    const spawned = try shell.spawnShell(gpa, &p, name, sp.rc_dir, sp.env_dir, initial_cmd);

    // ── listen (lock held; safe to clear any stale socket file) ──────
    posix.unlink(sp.sock) catch {};
    const listen_fd = try listenUnix(sp.sock);

    var d = Daemon{
        .gpa = gpa,
        .name = try gpa.dupe(u8, name),
        .sp = sp,
        .session = session,
        .ppoll_mask = ppoll_mask,
        .pty_fd = p.master,
        .lock_fd = lock_fd,
        .shell_pid = spawned.pid,
        .spawned_shell = spawned.shell,
        .listen_fd = listen_fd,
        .created_ts = std.time.timestamp(),
    };
    defer d.deinit();

    // ── poll loop ────────────────────────────────────────────────────
    runLoop(&d) catch |err| {
        log.err("loop error: {s}", .{@errorName(err)});
    };

    // ── cleanup ──────────────────────────────────────────────────────
    log.info("shutting down session={s}", .{d.name});
    posix.close(d.listen_fd);
    posix.unlink(d.sp.sock) catch {};
    posix.unlink(d.sp.lock) catch {};
    posix.close(d.lock_fd);
    std.fs.deleteTreeAbsolute(d.sp.rc_dir) catch {};
    std.fs.deleteTreeAbsolute(d.sp.env_dir) catch {};

    // Terminate the shell: SIGTERM, brief grace, SIGKILL.
    if (d.shell_status == null) {
        posix.kill(d.shell_pid, posix.SIG.TERM) catch {};
        std.Thread.sleep(200 * std.time.ns_per_ms);
        posix.kill(d.shell_pid, posix.SIG.KILL) catch {};
        var st: c_int = undefined;
        _ = std.c.waitpid(d.shell_pid, &st, 0);
    }
    posix.close(d.pty_fd);
}

// ───────────────────────────── poll loop ─────────────────────────────

fn runLoop(d: *Daemon) !void {
    // pollfds layout: [idx_listen] listen_fd, [idx_pty] pty_fd, then one
    // entry per client in d.clients order.
    const idx_listen = 0;
    const idx_pty = 1;
    const fixed_fds = 2;

    // 64KB matches the Linux PTY kernel buffer, so one read drains it instead
    // of looping 16× through poll/broadcast/timeout-check for the same burst.
    var read_buf: [64 * 1024]u8 = undefined;

    while (true) {
        if (should_exit.load(.acquire)) break;

        d.pollfds.clearRetainingCapacity();
        try d.pollfds.append(d.gpa, .{
            .fd = d.listen_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });
        var pty_ev: i16 = posix.POLL.IN;
        if (d.session.pendingPtyInput().len > 0) pty_ev |= posix.POLL.OUT;
        try d.pollfds.append(d.gpa, .{ .fd = d.pty_fd, .events = pty_ev, .revents = 0 });
        for (d.clients.items) |*c| {
            var ev: i16 = posix.POLL.IN;
            if (c.framer.hasPendingWrite()) ev |= posix.POLL.OUT;
            try d.pollfds.append(d.gpa, .{ .fd = c.fd, .events = ev, .revents = 0 });
        }

        // 300ms timeout if a typed run is awaiting acceptance, else block.
        const timeout: ?posix.timespec = if (d.session.needsTimeoutWake())
            .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms }
        else
            null;
        // ppoll (not poll): std.posix.poll retries EINTR internally, which
        // would prevent the SIGTERM flag from being observed promptly. The
        // mask atomically unblocks TERM/INT/CHLD only for the duration of
        // the wait, so a signal arriving between the flag check above and
        // here is held pending and then delivered inside ppoll → EINTR. On
        // platforms without ppoll, compat uses a self-pipe to the same end.
        _ = compat.pollWithMask(
            d.pollfds.items,
            if (timeout) |*t| t else null,
            &d.ppoll_mask,
        ) catch |err| switch (err) {
            error.SignalInterrupt => {
                if (should_exit.load(.acquire)) break;
                // SIGCHLD landing here would otherwise be deferred a full
                // loop iteration; reap now so handlePtyEof sees the status.
                reapChildren(d);
                continue;
            },
            else => return err,
        };

        if (should_exit.load(.acquire)) break;

        // ── listen_fd ────────────────────────────────────────────────
        if (d.pollfds.items[idx_listen].revents & posix.POLL.IN != 0) {
            acceptClient(d) catch |err| log.warn("accept: {s}", .{@errorName(err)});
        }

        // ── pty_fd ───────────────────────────────────────────────────
        if (try servicePty(d, d.pollfds.items[idx_pty].revents, &read_buf)) break;

        // ── client fds ───────────────────────────────────────────────
        // Only iterate clients that existed when pollfds was built.
        const polled = d.pollfds.items.len - fixed_fds;
        var i: usize = 0;
        while (i < polled) : (i += 1) {
            const c = &d.clients.items[i];
            if (c.closed) continue;
            serviceClient(d, c, d.pollfds.items[fixed_fds + i].revents, &read_buf);
        }

        const now = std.time.nanoTimestamp();
        // Acceptance-timeout check (front run typed but no preexec yet).
        if (d.session.checkAcceptanceTimeout(now)) {
            routeCompletions(d);
        }
        // Hook-install timeout + completion routing.
        d.session.checkHookTimeout(now);
        routeHookCompletion(d);
        // Prompt-wait check (front run never typed because shell hasn't
        // reached its first prompt). Soft warn at 5s, hard fail at 30s.
        switch (d.session.checkPromptWait(now)) {
            .none => {},
            .warn => |cid| if (d.findClient(cid)) |wc| {
                queueErr(
                    wc,
                    "still waiting (shell starting, or a previous command is still running)…",
                    .{},
                ) catch {};
            },
            .timeout => |cid| {
                if (d.findClient(cid)) |wc| {
                    queueErr(
                        wc,
                        "shell never reached a prompt after 30s; " ++
                            "integration unavailable for this session",
                        .{},
                    ) catch {};
                }
                routeCompletions(d);
            },
        }

        reapChildren(d);
        reapClosedClients(d);
    }
}

/// Non-blocking read: `null` on EAGAIN, `0` on EOF or error, else byte count.
/// Folding errors into EOF lets the caller's close path handle both.
fn readNb(fd: posix.fd_t, buf: []u8) ?usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => null,
        // EIO on Linux when a PTY slave end is closed → treat as EOF.
        error.InputOutput => 0,
        else => 0,
    };
}

/// Drain queued PTY input (POLLOUT), then read PTY output (POLLIN/HUP) and
/// broadcast it. Returns true on PTY EOF — caller breaks the poll loop.
fn servicePty(d: *Daemon, re: i16, read_buf: []u8) !bool {
    if (re & posix.POLL.OUT != 0) {
        const pending = d.session.pendingPtyInput();
        if (pending.len > 0) {
            const n = posix.write(d.pty_fd, pending) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => blk: {
                    log.warn("pty write: {s}", .{@errorName(err)});
                    break :blk 0;
                },
            };
            d.session.consumePtyInput(n);
        }
        releaseWriteAck(d);
    }
    if (re & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) return false;

    const n = readNb(d.pty_fd, read_buf) orelse return false;
    if (n == 0) {
        handlePtyEof(d);
        return true;
    }
    const data = read_buf[0..n];
    // Recount before each feed: a client whose backlog has crossed the demote
    // threshold (catatonic terminal) won't relay query replies, so it doesn't
    // count as "someone who'll answer."
    d.session.attached_clients = blk: {
        var k: u32 = 0;
        for (d.clients.items) |*c| if (c.attached and !c.closed and
            c.framer.pendingWrite().len <= leader_demote_backlog)
        {
            k += 1;
        };
        break :blk k;
    };
    try d.session.feedPtyOutput(data);
    releaseWriteAck(d);
    // Broadcast to clients that want live output.
    for (d.clients.items) |*c| {
        if (c.wants_output and !c.closed) {
            const backlog = c.framer.pendingWrite().len;
            if (backlog > client_backpressure_limit) {
                log.warn("client {d} write backlog >4MiB; dropping", .{c.id});
                c.closed = true;
                continue;
            }
            if (d.leader_id == c.id and backlog > leader_demote_backlog) {
                log.warn(
                    "client {d} backlog >{d}KiB; demoting leader",
                    .{ c.id, leader_demote_backlog / 1024 },
                );
                d.leader_id = null; // reapClosedClients re-elects
            }
            queueOrClose(c, .output, data);
        }
    }
    routeCompletions(d);
    return false;
}

/// POLLOUT flush, POLLIN read+dispatch, HUP/ERR close.
fn serviceClient(d: *Daemon, c: *Client, re: i16, read_buf: []u8) void {
    if (re & posix.POLL.OUT != 0) {
        flushClient(c);
    }
    if (re & posix.POLL.IN != 0) {
        if (readNb(c.fd, read_buf)) |n| {
            if (n == 0) {
                c.closed = true;
            } else {
                c.framer.pushRead(read_buf[0..n]) catch {
                    c.closed = true;
                    return;
                };
                while (c.framer.next() catch blk: {
                    c.closed = true;
                    break :blk null;
                }) |msg| {
                    dispatch(d, c, msg) catch |err| {
                        log.warn("dispatch tag={d} client={d}: {s}", .{
                            @intFromEnum(msg.tag), c.id, @errorName(err),
                        });
                        // Client is blocked expecting a reply; surface the
                        // failure and hang up so it doesn't wait forever.
                        queueErr(c, "internal: {s}", .{@errorName(err)}) catch {};
                        c.closed = true;
                    };
                    if (c.closed) break;
                }
            }
        }
    }
    if (re & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
        c.closed = true;
    }
}

/// SIGCHLD: reap without blocking; stash the shell's status so handlePtyEof
/// can report it even if we got here first.
fn reapChildren(d: *Daemon) void {
    if (!should_reap.swap(false, .acq_rel)) return;
    var st: c_int = undefined;
    while (true) {
        const pid = std.c.waitpid(-1, &st, posix.W.NOHANG);
        if (pid <= 0) break;
        if (pid == d.shell_pid) d.shell_status = @bitCast(st);
    }
}

fn flushClient(c: *Client) void {
    const pending = c.framer.pendingWrite();
    if (pending.len == 0) return;
    const n = posix.write(c.fd, pending) catch |err| switch (err) {
        error.WouldBlock => return,
        else => {
            c.closed = true;
            return;
        },
    };
    c.framer.consumeWrite(n);
}

fn handlePtyEof(d: *Daemon) void {
    log.info("pty EOF; shell exited", .{});
    // The shell has closed the slave end so it is (almost certainly) exiting.
    // We can't block in waitpid(0) here — TERM/INT are masked outside ppoll,
    // so a shell that closed the PTY without exiting would wedge the daemon
    // unkillably. Bounded WNOHANG poll instead; fall back to whatever the
    // SIGCHLD reaper already stashed. (posix.waitpid panics on ECHILD; use libc.)
    const status: u32 = blk: {
        var st: c_int = 0;
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            const r = std.c.waitpid(d.shell_pid, &st, posix.W.NOHANG);
            if (r == d.shell_pid) break :blk @bitCast(st);
            if (r < 0) break; // ECHILD: already reaped
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (d.shell_status == null)
            log.warn("shell pid={d} not reaped after PTY EOF", .{d.shell_pid});
        break :blk d.shell_status orelse 0;
    };
    d.shell_status = status;
    d.session.onPtyEof(status);
    routeCompletions(d);
    drainWaiters(d);
    for (d.clients.items) |*c| {
        if (!c.closed) {
            c.framer.queue(.eof, "") catch {};
            flushClient(c);
        }
    }
}

fn routeCompletions(d: *Daemon) void {
    const comps = d.session.completions();
    for (comps) |comp| {
        const c = d.findClient(comp.client_id) orelse continue;
        if (c.closed) continue;
        const wire: ipc.RunDoneWire = .{
            .exit_code = comp.result.exit_code orelse ipc.RunDoneWire.null_exit,
            .via = comp.result.via,
            .dur_ms = comp.result.dur_ms,
        };
        queueOrClose(c, .run_done, std.mem.asBytes(&wire));
        c.wants_output = false;
        c.waiting = false;
    }
    if (comps.len > 0) d.session.clearCompletions();
    // Any transition to idle (run completion, or interactive command's `done`)
    // releases blocked waiters.
    if (d.session.isIdle()) drainWaiters(d);
}

fn routeHookCompletion(d: *Daemon) void {
    const hc = d.session.takeHookCompletion() orelse return;
    const c = d.findClient(hc.client_id) orelse return;
    if (c.closed) return;
    var b: [128]u8 = undefined;
    switch (hc.result) {
        .already_hooked => |v| queueOrClose(c, .ack, std.fmt.bufPrint(
            &b,
            "already hooked (v{d})",
            .{v},
        ) catch "already hooked"),
        .installed => |sh| queueOrClose(c, .ack, std.fmt.bufPrint(
            &b,
            "installed → {s}/hook.{s}",
            .{ shell.hook_dir, @tagName(sh) },
        ) catch "installed"),
        .err => |e| queueOrClose(c, .err, e),
    }
}

fn waitReplyWire(d: *Daemon) ipc.RunDoneWire {
    return .{
        .exit_code = d.session.last_exit orelse ipc.RunDoneWire.null_exit,
        .via = .osc_done,
        .dur_ms = 0,
    };
}

fn drainWaiters(d: *Daemon) void {
    const wire = waitReplyWire(d);
    for (d.clients.items) |*c| if (c.waiting and !c.closed) {
        queueOrClose(c, .run_done, std.mem.asBytes(&wire));
        c.waiting = false;
    };
}

fn reapClosedClients(d: *Daemon) void {
    var i: usize = 0;
    while (i < d.clients.items.len) {
        const c = &d.clients.items[i];
        if (!c.closed) {
            i += 1;
            continue;
        }
        // Best-effort flush of any final ack/err before close.
        flushClient(c);
        log.info("client {d} disconnected", .{c.id});
        if (d.leader_id == c.id) d.leader_id = null;
        // Don't execute commands queued by a now-dead client.
        d.session.cancelClientRuns(c.id);
        d.session.cancelClientHook(c.id);
        // If this client owned an in-flight write, ^C so the shell returns
        // to the prompt (head -c N would otherwise wait for the missing
        // bytes; base64 -d will leave a partial file but the session isn't
        // wedged). For the local-FS path, just close the fd.
        if (d.write_client == c.id) {
            if (d.write_local_fd) |fd| {
                posix.close(fd);
                d.write_local_fd = null;
            } else {
                d.session.queueSend("\x03") catch {};
            }
            d.write_client = null;
        }
        c.framer.deinit();
        posix.close(c.fd);
        _ = d.clients.swapRemove(i);
    }
    // Promote a new leader if the old one was reaped or demoted. Only a
    // client that's actually draining is eligible — re-electing a backlog-
    // demoted client would demote→re-elect→resize+SIGWINCH every poll tick.
    // With no eligible client, leave leader_id null: the PTY stays at its
    // last size until a healthy client appears or types (handleInput).
    if (d.leader_id == null) {
        for (d.clients.items) |*nc| if (nc.attached and !nc.closed and
            nc.framer.pendingWrite().len <= leader_demote_backlog)
        {
            d.promoteLeader(nc);
            break;
        };
    }
}

fn acceptClient(d: *Daemon) !void {
    const fd = posix.accept(
        d.listen_fd,
        null,
        null,
        posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
    ) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };

    if (!checkPeerUid(fd)) {
        log.warn("rejecting client: peer uid mismatch", .{});
        posix.close(fd);
        return;
    }
    if (d.clients.items.len >= max_clients) {
        log.warn("rejecting client: max_clients={d} reached", .{max_clients});
        posix.close(fd);
        return;
    }
    errdefer posix.close(fd);

    const id = d.next_client_id;
    d.next_client_id += 1;
    try d.clients.append(d.gpa, .{
        .fd = fd,
        .id = id,
        .framer = ipc.Framer.init(d.gpa),
        .input_cls = input.Classifier.init(),
    });
    log.info("client {d} connected (total={d})", .{ id, d.clients.items.len });
}

// ───────────────────────────── dispatch ─────────────────────────────

fn dispatch(d: *Daemon, c: *Client, msg: ipc.Message) !void {
    switch (msg.tag) {
        .attach => try handleAttach(d, c, msg.payload),
        .input => try handleInput(d, c, msg.payload),
        .resize => try handleResize(d, c, msg.payload),
        .run => {
            if (d.write_client != null) {
                return queueErr(c, "run: write in progress", .{});
            }
            // The locally-spawned shell is one we don't know how to hook
            // (e.g. dash, or bash <4 which announces as `bash-pre4`), and no
            // nested shell has announced either. `run` would hang forever
            // waiting for a prompt-ready signal that never comes.
            if (d.spawned_shell == .unknown and
                d.session.layers.len == 0 and !d.session.seen_prompt)
            {
                try queueErr(
                    c,
                    "shell integration unavailable for this session " ++
                        "(unsupported $SHELL); use `attach` or `send`",
                    .{},
                );
                const w: ipc.RunDoneWire = .{
                    .exit_code = ipc.RunDoneWire.null_exit,
                    .via = .prompt_fallback,
                    .dur_ms = 0,
                };
                try c.framer.queue(.run_done, std.mem.asBytes(&w));
                return;
            }
            // First payload byte: 0 = normal, 1 = `-i`.
            const interactive = msg.payload.len > 0 and msg.payload[0] == 1;
            const cmd = if (msg.payload.len > 0) msg.payload[1..] else msg.payload;
            c.wants_output = true;
            try d.session.queueRun(c.id, cmd, interactive);
        },
        .send => {
            try d.session.queueSend(msg.payload);
            try c.framer.queue(.ack, "");
        },
        .read => try handleRead(d, c, msg.payload),
        .info => try handleInfo(d, c),
        .wait => {
            if (d.session.isIdle()) {
                const wire = waitReplyWire(d);
                try c.framer.queue(.run_done, std.mem.asBytes(&wire));
            } else {
                c.waiting = true;
            }
        },
        .write_hdr => try handleWriteHdr(d, c, msg.payload),
        .write_data => try handleWriteData(d, c, msg.payload),
        .kill => {
            const sig: u8 = if (msg.payload.len >= 1) msg.payload[0] else @intCast(posix.SIG.TERM);
            try c.framer.queue(.ack, "");
            if (sig == posix.SIG.KILL) {
                posix.kill(d.shell_pid, posix.SIG.KILL) catch {};
            }
            // Interactive shells ignore SIGTERM; let the shutdown path do
            // SIGTERM→SIGKILL on the shell.
            should_exit.store(true, .release);
        },
        .hook => {
            if (try d.session.startHook(c.id, std.time.nanoTimestamp())) |refusal| {
                try c.framer.queue(.err, refusal);
            }
            // else: probe queued; completion routed via routeHookCompletion.
        },
        .detach => {
            try c.framer.queue(.ack, "");
            // detach all attached clients (leader + followers); payload unused.
            for (d.clients.items) |*oc| if (oc.attached) {
                oc.closed = true;
            };
            c.closed = true;
        },
        else => try queueErr(c, "unknown tag {d}", .{@intFromEnum(msg.tag)}),
    }
}

fn handleAttach(d: *Daemon, c: *Client, payload: []const u8) !void {
    if (payload.len < 4) return queueErr(c, "attach: short payload", .{});
    c.cols = std.mem.readInt(u16, payload[0..2], .little);
    c.rows = std.mem.readInt(u16, payload[2..4], .little);
    c.attached = true;
    c.wants_output = true;
    // The freshest attach is overwhelmingly the terminal a human is looking
    // at; an existing leader may be a stale orphan (half-open SSH) holding
    // the wrong winsize. Always promote — if the old leader is alive they
    // re-promote on their next keystroke (handleInput).
    d.promoteLeader(c);

    // Env refresh (#104): KEY=VAL\0KEY=VAL\0...
    shell.refreshEnvLinks(d.sp.env_dir, payload[4..]) catch |err| {
        log.warn("env refresh: {s}", .{@errorName(err)});
    };

    // Serialize terminal state into chunked .state frames (≤256 KiB each).
    var buf: std.Io.Writer.Allocating = .init(d.gpa);
    defer buf.deinit();
    try term_state.serializeForAttach(&d.session.term, &buf.writer);
    try queueChunked(c, .state, buf.writer.buffered(), state_chunk);
}

fn handleInput(d: *Daemon, c: *Client, payload: []const u8) !void {
    const r = c.input_cls.feed(payload);
    if (r.detach) {
        try c.framer.queue(.ack, "");
        c.closed = true;
        return;
    }
    // Leader promotion on real user keystrokes (#135 fix: never drop, just
    // don't promote on terminal-generated reports).
    if (r.user_input and d.leader_id != c.id) d.promoteLeader(c);
    try d.session.queueSend(payload);
}

fn handleResize(d: *Daemon, c: *Client, payload: []const u8) !void {
    if (payload.len < 4) return queueErr(c, "resize: short payload", .{});
    c.cols = std.mem.readInt(u16, payload[0..2], .little);
    c.rows = std.mem.readInt(u16, payload[2..4], .little);
    // Same best-effort swallow as promoteLeader: a ghostty resize OOM
    // shouldn't drop the client (the PTY ioctl almost never fails).
    if (d.leader_id == c.id) d.promoteLeader(c);
}

fn handleRead(d: *Daemon, c: *Client, payload: []const u8) !void {
    if (payload.len < 5) return queueErr(c, "read: short payload", .{});
    const mode = payload[0];
    const tail_n = std.mem.readInt(u32, payload[1..5], .little);
    const tail: ?usize = if (tail_n == 0) null else tail_n;

    var buf: std.Io.Writer.Allocating = .init(d.gpa);
    defer buf.deinit();

    if (mode == 1)
        try term_state.dumpScreen(&d.session.term, &buf.writer)
    else
        try term_state.dumpScrollback(d.gpa, &d.session.term, tail, &buf.writer);
    try queueChunked(c, .data, buf.writer.buffered(), data_chunk);
    // follow: receive live .output going forward instead of an .eof.
    if (mode == 2) c.wants_output = true else try c.framer.queue(.eof, "");
}

fn handleInfo(d: *Daemon, c: *Client) !void {
    var n_clients: u32 = 0;
    for (d.clients.items) |*cl| if (cl.attached and !cl.closed) {
        n_clients += 1;
    };

    var buf: std.Io.Writer.Allocating = .init(d.gpa);
    defer buf.deinit();
    try std.json.Stringify.value(.{
        .name = d.name,
        .pid = @as(i32, @intCast(std.c.getpid())),
        .shell_pid = d.shell_pid,
        .shell = @tagName(d.session.topShell()),
        .hooked = d.session.topHooked(),
        .has_gunzip = d.session.topHasGunzip(),
        .cmd_running = d.session.topCmdRunning(),
        .depth = d.session.layers.len,
        .alt_screen = d.session.isAltScreen(),
        .mouse_tracking = d.session.mouseTracking(),
        .osc133 = d.session.osc133Seen(),
        .title = d.session.title(),
        .last_exit = d.session.last_exit,
        .cwd = d.session.lastCwd(),
        .clients = n_clients,
        .created = d.created_ts,
    }, .{}, &buf.writer);

    try c.framer.queue(.info_reply, buf.writer.buffered());
}

fn handleWriteHdr(d: *Daemon, c: *Client, payload: []const u8) !void {
    if (payload.len < 16) return queueErr(c, "write: short header", .{});
    const plain_len = std.mem.readInt(u64, payload[0..8], .little);
    const gz_len = std.mem.readInt(u64, payload[8..16], .little);
    const path = payload[16..];
    if (path.len == 0 or path.len >= 4096)
        return queueErr(c, "write: invalid path length", .{});
    // ESC would let the path terminate the bracketed-paste wrapper early.
    if (std.mem.indexOfAny(u8, path, "\n\x00\x1b") != null)
        return queueErr(c, "write: path contains control character", .{});
    if (d.write_client != null)
        return queueErr(c, "write: another write in progress", .{});

    // Local-FS shortcut: at depth 0 the daemon and shell share a filesystem
    // namespace, so an absolute path (or `~/…`) means the same thing to both
    // — open and write it directly, no PTY round-trip. Relative paths fall
    // through (only the shell knows its cwd reliably).
    if (d.session.layers.len == 1) if (writeLocalPath(d.gpa, path)) |abs| {
        defer d.gpa.free(abs);
        const fd = posix.open(abs, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644) catch |e| {
            return queueErr(c, "write: open {s}: {s}", .{ abs, @errorName(e) });
        };
        d.write_client = c.id;
        d.write_local_fd = fd;
        try c.framer.queue(.ack, "L");
        return;
    };

    if (d.session.run_queue.items.len > 0)
        return queueErr(c, "write: session busy", .{});
    if (!d.session.canType())
        return queueErr(c, "write: session not ready", .{});
    // Body is delivered to head's stdin, not the line editor — that
    // handoff is signalled by `preexec`, which only a hooked layer emits.
    if (!d.session.topHooked())
        return queueErr(c, "write: requires shell integration", .{});

    // gzip if the layer reports gunzip AND the client says it shrank
    // (gz_len > 0 and < plain_len). Incompressible data sends plain.
    const gzip = d.session.topHasGunzip() and gz_len > 0 and gz_len < plain_len;
    const opener = try shell.writeOpener(d.gpa, path, if (gzip) gz_len else plain_len, gzip);
    defer d.gpa.free(opener);
    try d.session.queueSend(opener);

    d.write_client = c.id;
    // Defer the hdr ack until `preexec` arrives. The line editor over-reads
    // whatever is in the kernel PTY buffer when it accepts the command, so
    // body bytes written before that are eaten or mistranslated. preexec is
    // the positive signal that the editor has handed the tty to head.
    c.write_ack_pending = true;
    c.write_mode = if (gzip) 'z' else 'p';
}

/// Resolve `path` to an absolute path the daemon can open directly, or null
/// if it's relative (only the shell can resolve those). Caller frees.
fn writeLocalPath(gpa: Allocator, path: []const u8) ?[]u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return gpa.dupe(u8, path) catch null;
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = posix.getenv("HOME") orelse return null;
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, path[2..] }) catch null;
    }
    return null;
}

fn handleWriteData(d: *Daemon, c: *Client, payload: []const u8) !void {
    if (d.write_client != c.id) return queueErr(c, "write: no write in progress", .{});
    if (d.write_local_fd) |fd| {
        if (payload.len == 0) {
            posix.close(fd);
            d.write_local_fd = null;
            d.write_client = null;
            try c.framer.queue(.ack, "");
            return;
        }
        @import("io.zig").writeAllFd(fd, payload) catch |e| {
            posix.close(fd);
            d.write_local_fd = null;
            d.write_client = null;
            return queueErr(c, "write: {s}", .{@errorName(e)});
        };
        try c.framer.queue(.ack, "");
        return;
    }
    if (payload.len == 0) {
        d.write_client = null;
        try c.framer.queue(.ack, "");
        return;
    }
    try d.session.queueSend(payload);
    // Per-chunk ack is the backpressure signal: deferred while pty_input is
    // backed up so the client (which blocks on recv) can't outrun the PTY.
    if (d.session.pendingPtyInput().len < write_backpressure)
        try c.framer.queue(.ack, "")
    else
        c.write_ack_pending = true;
}

/// Send a deferred `.write_hdr`/`.write_data` ack once it's safe: the opener
/// has been accepted (`cmd_running` — base64 owns the tty) and pty_input has
/// room. Called after both PTY drain (room may have opened) and PTY read
/// (preexec may have arrived).
fn releaseWriteAck(d: *Daemon) void {
    const id = d.write_client orelse return;
    if (d.write_local_fd != null) return;
    if (!d.session.topCmdRunning()) return;
    if (d.session.pendingPtyInput().len >= write_backpressure) return;
    if (d.findClient(id)) |wc| if (wc.write_ack_pending) {
        wc.write_ack_pending = false;
        // The hdr ack carries the mode; chunk acks reuse it (client ignores
        // the payload after the first).
        queueOrClose(wc, .ack, &.{wc.write_mode});
    };
}

// ───────────────────────────── helpers ─────────────────────────────

/// Queue a frame, marking the client closed on failure (the only realistic
/// failure is OOM, at which point dropping the client is the best option).
fn queueOrClose(c: *Client, tag: ipc.Tag, payload: []const u8) void {
    c.framer.queue(tag, payload) catch {
        c.closed = true;
    };
}

fn queueErr(c: *Client, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    try c.framer.queue(.err, msg);
}

/// Queue `data` as one or more `tag` frames, each ≤ `chunk` bytes.
fn queueChunked(c: *Client, tag: ipc.Tag, data: []const u8, chunk: usize) !void {
    var off: usize = 0;
    while (off < data.len) {
        const end = @min(off + chunk, data.len);
        try c.framer.queue(tag, data[off..end]);
        off = end;
    }
    if (data.len == 0) try c.framer.queue(tag, "");
}

/// Connect to `path` as a probe. Returns the connected fd if a daemon answers.
fn probe(path: []const u8) ?posix.fd_t {
    const stream = std.net.connectUnixSocket(path) catch return null;
    return stream.handle;
}

fn acquireLock(path: []const u8) !posix.fd_t {
    const fd = try posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    errdefer posix.close(fd);
    try posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB);
    return fd;
}

fn listenUnix(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(fd);
    var addr = try std.net.Address.initUnix(path);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    // bind() honours umask; tighten explicitly so a permissive umask doesn't
    // leave a world-writable socket if the user pointed ZMYTH_DIR somewhere
    // outside the 0700 runtime dir.
    posix.fchmodat(posix.AT.FDCWD, path, 0o600, 0) catch {};
    try posix.listen(fd, 64);
    return fd;
}

/// Peer-uid check on the accepted Unix socket. Linux: SO_PEERCRED.
/// Darwin: LOCAL_PEERCRED (struct xucred). Elsewhere: allow (the 0700
/// runtime dir is the remaining guard).
fn checkPeerUid(fd: posix.fd_t) bool {
    switch (builtin.os.tag) {
        .linux => {
            const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
            var cred: Ucred = undefined;
            posix.getsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.PEERCRED,
                std.mem.asBytes(&cred),
            ) catch return false;
            return cred.uid == posix.getuid();
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // <sys/ucred.h>: XUCRED_VERSION 0, NGROUPS 16.
            // <sys/un.h>:    SOL_LOCAL 0, LOCAL_PEERCRED 1.
            const Xucred = extern struct {
                cr_version: u32,
                cr_uid: posix.uid_t,
                cr_ngroups: c_short,
                cr_groups: [16]posix.gid_t,
            };
            const SOL_LOCAL: i32 = 0;
            const LOCAL_PEERCRED: u32 = 1;
            var cred: Xucred = undefined;
            posix.getsockopt(
                fd,
                SOL_LOCAL,
                LOCAL_PEERCRED,
                std.mem.asBytes(&cred),
            ) catch return false;
            return cred.cr_uid == posix.getuid();
        },
        else => return true,
    }
}

// Force analysis of the I/O glue so it at least type-checks.
test {
    std.testing.refAllDecls(@This());
}
