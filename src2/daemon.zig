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
const spawn = @import("spawn.zig");
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

// ───────────────────────────── public API ─────────────────────────────

pub const EnsureResult = struct {
    /// Caller owns; allocated with the passed allocator.
    sock_path: []u8,
    /// An already-connected blocking fd to the daemon (caller owns).
    fd: posix.fd_t,
};

/// Ensure a session daemon exists for `name`. If the socket already responds,
/// returns the connected fd. Otherwise: fork; child becomes the daemon (setsid,
/// redirect stdio to log, spawn shell, listen, run loop, never returns); parent
/// waits briefly for the socket to appear and returns.
pub fn ensure(
    allocator: Allocator,
    name: []const u8,
    initial_cmd: ?[]const []const u8,
) !EnsureResult {
    try paths.validateName(name);

    const sock_path = try paths.socketPath(allocator, name);
    errdefer allocator.free(sock_path);

    // Probe: does a live daemon already own this socket?
    if (probe(sock_path)) |fd| {
        return .{ .sock_path = sock_path, .fd = fd };
    }

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
        if (probe(sock_path)) |fd| {
            return .{ .sock_path = sock_path, .fd = fd };
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    // Daemon never came up — surface a distinct error so the caller can say
    // "daemon failed to start" rather than the misleading NoSuchSession that
    // a follow-up connect() would produce. (errdefer above frees sock_path.)
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

    // Ignore SIGPIPE: client sockets going away must not kill the daemon.
    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);

    const exit_act: posix.Sigaction = .{
        .handler = .{ .handler = sigExit },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &exit_act, null);
    posix.sigaction(posix.SIG.INT, &exit_act, null);

    const chld_act: posix.Sigaction = .{
        .handler = .{ .handler = sigChld },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.CHLD, &chld_act, null);

    var to_block = posix.sigemptyset();
    posix.sigaddset(&to_block, posix.SIG.TERM);
    posix.sigaddset(&to_block, posix.SIG.INT);
    posix.sigaddset(&to_block, posix.SIG.CHLD);
    return compat.blockSignalsForPoll(&to_block);
}

// ───────────────────────────── client ─────────────────────────────

const WriteState = struct {
    client_id: u32,
    /// "__ZMX_EOF_" + 8 lowercase hex + "__"
    delim: [20]u8,
};

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
    /// What spawn.zig detected from `$SHELL`. `.unknown` means the shell will
    /// never announce, so `.run` requests cannot work — refuse them up front.
    spawned_shell: protocol.Shell,
    /// Set by the SIGCHLD reaper if it wins the race against handlePtyEof.
    shell_status: ?u32 = null,
    listen_fd: posix.fd_t,

    clients: std.ArrayList(Client) = .empty,
    next_client_id: u32 = 1,
    leader_id: ?u32 = null,

    /// Client ids blocked in `.wait`; each gets a `.run_done` once the
    /// session is idle (no run in flight, queue empty).
    waiters: std.ArrayList(u32) = .empty,
    /// In-flight `write` heredoc; only one at a time.
    write_state: ?WriteState = null,

    created_ts: i64,
    pollfds: std.ArrayList(posix.pollfd) = .empty,

    fn deinit(self: *Daemon) void {
        for (self.clients.items) |*c| {
            c.framer.deinit();
            posix.close(c.fd);
        }
        self.clients.deinit(self.gpa);
        self.waiters.deinit(self.gpa);
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
        self.session.resize(c.rows, c.cols) catch {};
        pty.setWinsize(self.pty_fd, .{ .rows = c.rows, .cols = c.cols }) catch {};
    }

    fn removeWaiter(self: *Daemon, id: u32) void {
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            if (self.waiters.items[i] == id) _ = self.waiters.swapRemove(i) //
            else i += 1;
        }
    }
};

// ───────────────────────────── daemon entry ─────────────────────────────

/// Runs in the forked child. Never returns to caller's stack frame in any
/// useful sense — caller `posix.exit()`s after this returns.
fn daemonMain(name: []const u8, initial_cmd: ?[]const []const u8) !void {
    const gpa = std.heap.c_allocator;

    // 1. Daemonize ─────────────────────────────────────────────────────
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

    // 2. Spawn shell into a PTY ───────────────────────────────────────
    const session = try Session.init(gpa, 24, 80);

    var p = try pty.Pty.open();
    try pty.setWinsize(p.master, .{ .rows = 24, .cols = 80 });
    // Non-blocking master so the poll loop never wedges on read/write.
    try pty.setNonBlock(p.master, true);

    const spawned = try spawn.spawnShell(gpa, &p, name, sp.rc_dir, sp.env_dir, initial_cmd);

    // 3. Listen (lock held; safe to clear any stale socket file) ──────
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

    // 5. Poll loop ────────────────────────────────────────────────────
    runLoop(&d) catch |err| {
        log.err("loop error: {s}", .{@errorName(err)});
    };

    // 6. Cleanup ──────────────────────────────────────────────────────
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

    var read_buf: [4096]u8 = undefined;

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
        const pty_re = d.pollfds.items[idx_pty].revents;
        if (pty_re & posix.POLL.OUT != 0) {
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
        }
        if (pty_re & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            const n = posix.read(d.pty_fd, &read_buf) catch |err| switch (err) {
                error.WouldBlock => @as(usize, std.math.maxInt(usize)), // sentinel: no data
                // EIO on Linux when the slave end is closed.
                error.InputOutput => 0,
                else => 0,
            };
            if (n == 0) {
                handlePtyEof(d);
                break;
            } else if (n != std.math.maxInt(usize)) {
                const data = read_buf[0..n];
                // Recount before each feed: a client whose backlog has crossed
                // the demote threshold (catatonic terminal) won't relay query
                // replies, so it doesn't count as "someone who'll answer."
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
            }
        }

        // ── client fds ───────────────────────────────────────────────
        // Only iterate clients that existed when pollfds was built.
        const polled = d.pollfds.items.len - fixed_fds;
        var i: usize = 0;
        while (i < polled) : (i += 1) {
            const c = &d.clients.items[i];
            const re = d.pollfds.items[fixed_fds + i].revents;
            if (c.closed) continue;

            if (re & posix.POLL.OUT != 0) {
                flushClient(c);
            }
            if (re & posix.POLL.IN != 0) {
                const rn = posix.read(c.fd, &read_buf) catch |err| switch (err) {
                    error.WouldBlock => @as(usize, std.math.maxInt(usize)),
                    else => 0,
                };
                if (rn == 0) {
                    c.closed = true;
                } else if (rn != std.math.maxInt(usize)) {
                    c.framer.pushRead(read_buf[0..rn]) catch {
                        c.closed = true;
                        continue;
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
            if (re & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                c.closed = true;
            }
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
        // This client just got its answer; if it had also issued `.wait` on
        // the same connection, drop it from waiters so drainWaiters below
        // doesn't send a second `.run_done`.
        d.removeWaiter(c.id);
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
    if (d.waiters.items.len == 0) return;
    const wire = waitReplyWire(d);
    for (d.waiters.items) |id| {
        const c = d.findClient(id) orelse continue;
        if (c.closed) continue;
        queueOrClose(c, .run_done, std.mem.asBytes(&wire));
    }
    d.waiters.clearRetainingCapacity();
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
        d.removeWaiter(c.id);
        // If this client owned an in-flight write, close the heredoc so the
        // shell returns to the prompt (body may be incomplete; base64 -d will
        // fail, but the session isn't wedged).
        if (d.write_state) |ws| if (ws.client_id == c.id) {
            var buf: [32]u8 = undefined;
            const closer = std.fmt.bufPrint(&buf, "\n{s}\x1b[201~\r", .{&ws.delim}) catch unreachable;
            d.session.queueSend(closer) catch {};
            d.write_state = null;
        };
        c.framer.deinit();
        posix.close(c.fd);
        _ = d.clients.swapRemove(i);
    }
    // Promote a new leader if the old one was reaped or demoted. Prefer a
    // client that's actually draining; a backlog-demoted client must not be
    // immediately re-elected.
    if (d.leader_id == null) {
        var fallback: ?*Client = null;
        for (d.clients.items) |*nc| if (nc.attached and !nc.closed) {
            if (nc.framer.pendingWrite().len <= leader_demote_backlog) {
                fallback = nc;
                break;
            }
            if (fallback == null) fallback = nc;
        };
        if (fallback) |nc| d.promoteLeader(nc);
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
    errdefer posix.close(fd);

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
            if (d.write_state != null) {
                return queueErr(c, "run: write in progress", .{});
            }
            // The locally-spawned shell is one we don't know how to hook
            // (e.g. dash, or bash <4 which announces as `bash-pre4`), and no
            // nested shell has announced either. `run` would hang forever
            // waiting for a prompt-ready signal that never comes.
            if ((d.spawned_shell == .unknown or d.session.unhookable) and
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
                try d.waiters.append(d.gpa, c.id);
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
        .rename => try handleRename(d, c, msg.payload),
        .hook => {
            if (try d.session.startHook(c.id, std.time.nanoTimestamp())) |refusal| {
                try c.framer.queue(.err, refusal);
            }
            // else: probe queued; completion routed via routeHookCompletion.
        },
        .detach => {
            try c.framer.queue(.ack, "");
            // Empty payload: detach all attached clients (leader + followers).
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
    spawn.refreshEnvLinks(d.sp.env_dir, payload[4..]) catch |err| {
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
    if (payload.len < 6) return queueErr(c, "read: short payload", .{});
    const mode = payload[0];
    const fmt: term_state.DumpFormat = switch (payload[1]) {
        0 => .plain,
        1 => .vt,
        2 => .html,
        else => .plain,
    };
    const tail_n = std.mem.readInt(u32, payload[2..6], .little);
    const tail: ?usize = if (tail_n == 0) null else tail_n;

    var buf: std.Io.Writer.Allocating = .init(d.gpa);
    defer buf.deinit();

    switch (mode) {
        1 => { // screen
            try term_state.dumpScreen(&d.session.term, &buf.writer);
            try queueChunked(c, .data, buf.writer.buffered(), data_chunk);
            try c.framer.queue(.eof, "");
        },
        2 => { // follow: scrollback then live .output
            try term_state.dumpScrollback(d.gpa, &d.session.term, fmt, tail, &buf.writer);
            try queueChunked(c, .data, buf.writer.buffered(), data_chunk);
            c.wants_output = true; // receive .output going forward; no .eof
        },
        else => { // 0: scrollback
            try term_state.dumpScrollback(d.gpa, &d.session.term, fmt, tail, &buf.writer);
            try queueChunked(c, .data, buf.writer.buffered(), data_chunk);
            try c.framer.queue(.eof, "");
        },
    }
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

fn handleWriteHdr(d: *Daemon, c: *Client, path: []const u8) !void {
    if (path.len == 0 or path.len >= 4096)
        return queueErr(c, "write: invalid path length", .{});
    if (std.mem.indexOfAny(u8, path, "\n\x00") != null)
        return queueErr(c, "write: path contains newline/NUL", .{});
    if (d.write_state != null)
        return queueErr(c, "write: another write in progress", .{});
    if (d.session.topCmdRunning() or d.session.run_queue.items.len > 0)
        return queueErr(c, "write: session busy", .{});
    if (d.session.isAltScreen())
        return queueErr(c, "write: session in alt-screen", .{});
    if (d.session.layers.len == 0)
        return queueErr(c, "write: session not ready", .{});
    // Heredoc syntax is bash/zsh only.
    const sh = d.session.topShell();
    if (sh == .fish or sh == .unknown)
        return queueErr(c, "write: unsupported shell '{s}'", .{@tagName(sh)});

    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    var ws: WriteState = .{ .client_id = c.id, .delim = undefined };
    @memcpy(ws.delim[0..10], "__ZMX_EOF_");
    ws.delim[10..18].* = std.fmt.bytesToHex(rnd, .lower);
    @memcpy(ws.delim[18..20], "__");

    const quoted = try shell.posixQuote(d.gpa, path);
    defer d.gpa.free(quoted);

    // One bracketed-paste enclosing the full heredoc (opener here, body via
    // .write_data, delimiter + paste-end on the empty .write_data).
    const opener = try std.fmt.allocPrint(
        d.gpa,
        "\x15\x1b[200~base64 -d > {s} << '{s}'\n",
        .{ quoted, &ws.delim },
    );
    defer d.gpa.free(opener);
    try d.session.queueSend(opener);

    d.write_state = ws;
    try c.framer.queue(.ack, "");
}

fn handleWriteData(d: *Daemon, c: *Client, payload: []const u8) !void {
    const ws = d.write_state orelse return queueErr(c, "write: no write in progress", .{});
    if (ws.client_id != c.id) return queueErr(c, "write: not the writing client", .{});
    if (payload.len > 0) {
        try d.session.queueSend(payload);
        return;
    }
    // Empty payload = EOF: close heredoc, end paste, submit.
    var buf: [32]u8 = undefined;
    const closer = std.fmt.bufPrint(&buf, "{s}\x1b[201~\r", .{&ws.delim}) catch unreachable;
    try d.session.queueSend(closer);
    d.write_state = null;
    try c.framer.queue(.ack, "");
}

fn handleRename(d: *Daemon, c: *Client, new_name: []const u8) !void {
    paths.validateName(new_name) catch {
        return queueErr(c, "rename: invalid name", .{});
    };
    // Allocate everything up front; `committed` flips once the on-disk socket
    // rename succeeds. Covers both error returns and the queueErr path without
    // double-free or leaving Daemon pointers stale.
    var committed = false;
    const nn = try d.gpa.dupe(u8, new_name);
    defer if (!committed) d.gpa.free(nn);
    const new_sp = try paths.SessionPaths.init(d.gpa, new_name);
    defer if (!committed) new_sp.deinit(d.gpa);

    // Refuse to clobber another session: posix.rename() silently overwrites,
    // which would orphan the other daemon (still running, socket gone). The
    // access() probe alone is racy — between it and rename() another daemon
    // could bind — so also take the new name's lock (same nonblocking flock
    // ensure() uses) and hold it across the rename.
    if (posix.access(new_sp.sock, posix.F_OK)) |_| {
        return queueErr(c, "rename: '{s}' already exists", .{new_name});
    } else |_| {}
    const new_lock_fd = acquireLock(new_sp.lock) catch |err| switch (err) {
        error.WouldBlock => return queueErr(c, "rename: '{s}' already exists", .{new_name}),
        else => return queueErr(c, "rename: lock '{s}': {s}", .{ new_name, @errorName(err) }),
    };

    // Socket is the only rename whose failure aborts the operation: it is what
    // clients discover the session by.
    posix.rename(d.sp.sock, new_sp.sock) catch |err| {
        posix.close(new_lock_fd);
        posix.unlink(new_sp.lock) catch {};
        return queueErr(c, "rename: {s}", .{@errorName(err)});
    };
    committed = true;
    // New lock file is already in place and held; drop the old one.
    posix.unlink(d.sp.lock) catch {};
    posix.close(d.lock_fd);
    d.lock_fd = new_lock_fd;
    posix.rename(d.sp.rc_dir, new_sp.rc_dir) catch {};
    posix.rename(d.sp.env_dir, new_sp.env_dir) catch {};
    posix.rename(d.sp.log, new_sp.log) catch {};

    d.gpa.free(d.name);
    d.sp.deinit(d.gpa);
    d.name = nn;
    d.sp = new_sp;

    try c.framer.queue(.ack, "");
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
