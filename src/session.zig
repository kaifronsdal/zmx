//! Shell-session state machine: owns the ghostty Terminal, the protocol
//! Scanner, and the run/hook/layer-stack logic.
//!
//! Pure logic — no fds, no I/O, no wall-clock reads. The embedder's event loop
//! drives it with seven calls:
//!
//!     feedPty(bytes, now)      → process PTY output
//!     pendingInput()/consumeInput(n, now)  → drain bytes to write to PTY
//!     run(cookie, cmd, opts, now) / send(bytes) / installHook(cookie, now)
//!     tick(now)                → fire time-based checks
//!     drainEvents()            → collect .run_done/.hook_done/.warn
//!     nextDeadline()           → compute poll timeout
//!     state()                  → read-only snapshot
//!
//! ## Structure
//!
//! Three concerns share one state machine because the OSC-2718 events
//! (`preexec`/`done`/`prompt`) drive all three at once:
//!
//!   - **Layer stack** (`layers`): nested shells (local → ssh → docker …),
//!     keyed by pid. `done` from a new pid pushes; `done` from below the
//!     top pops. `pushLayer`/`popLayersAbove`/`findLayer`/`top*`.
//!
//!   - **Run queue** (`run_queue`, `out_events`): `run()` requests. Types
//!     when `canType()`; `onPreexec` marks accepted; `onDone` completes;
//!     `tickAcceptance`/`tickPromptWait` fail stuck ones. The six `Via`
//!     outcomes are decided here.
//!
//!   - **Hook install**: `installHook()` probe→install→done. Probe and
//!     install are RunRequests with `.kind = .hook_*`, so preexec/done
//!     matching reuses the run-queue path. `onProbe`/`finishProbe`/
//!     `completeHook`/`tickDeadlines`.
//!
//! `feedPty()` is the integration point: it dispatches each event to
//! `onPreexec`/`onDone`/`onPrompt`, which in turn touch all three. A
//! `done` from a new pid, for instance, pushes a layer AND may complete a
//! `run -i` request AND may complete a hook install — that's why these
//! aren't three modules.
//!
//! Tests (~1000 lines, colocated) follow the implementation.

const std = @import("std");
const assert = std.debug.assert;
const vt = @import("ghostty-vt");
const protocol = @import("protocol.zig");
const shell = @import("shell.zig");
const term_state = @import("term_state.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Public error set. `feedPty`/`run`/`send`/`installHook`/`drainEvents` only
/// fail on these; everything else is infallible or `!void` from ghostty.
pub const Error = error{
    OutOfMemory,
    /// `send()` would push the outbound queue past `pty_input_cap`. The
    /// shell isn't draining; accepting more would only OOM.
    PtyInputCapExceeded,
};

/// How a `run` request reached completion. Values are stable (also used as
/// the IPC wire encoding).
pub const Via = enum(u8) {
    /// Hook's `done` OSC reported the exit code.
    osc_done = 0,
    /// Unhooked layer: `?2004h` (and OSC 133;D, if present) signalled
    /// "back at prompt". exit_code is from 133;D or null.
    prompt_fallback = 1,
    /// PTY master hit EOF (shell exited).
    pty_eof = 2,
    /// No acceptance signal arrived within the window after typing; the
    /// shell was at a continuation prompt and ^C was sent. exit_code = null.
    line_rejected = 3,
    /// `run -i`: a nested prompt appeared. exit_code = 0.
    at_prompt = 4,
    /// The layer this run was typed into exited (e.g. ssh dropped) before
    /// the run's own `done`. exit_code is the parent's `done` ec.
    layer_exited = 5,
    _,
};

pub const HookResult = union(enum) {
    /// Hook was already active in the target shell at this version.
    already_hooked: u32,
    /// Install completed; this is the shell that was hooked.
    installed: protocol.Shell,
    /// Static error string for the client.
    err: []const u8,
};

/// Result of `drainEvents()`. Each event carries the `cookie` passed to the
/// originating `run`/`installHook`.
pub const SessionEvent = union(enum) {
    run_done: RunDone,
    hook_done: HookDone,
    /// Diagnostic for a request that's stuck (still queued behind a slow
    /// shell startup, etc). `msg` is a static string.
    warn: Warn,

    pub const RunDone = struct {
        cookie: u32,
        exit_code: ?i32,
        via: Via,
        dur_ms: u64,
    };
    pub const HookDone = struct { cookie: u32, result: HookResult };
    pub const Warn = struct { cookie: u32, msg: []const u8 };

    pub fn cookie(self: SessionEvent) u32 {
        return switch (self) {
            inline else => |p| p.cookie,
        };
    }
};

/// Read-only snapshot of session state. `cwd`/`title` borrow Session storage
/// and are valid until the next mutating call.
pub const State = struct {
    /// No layer is running a command and no run is in flight.
    idle: bool,
    alt_screen: bool,
    mouse_tracking: bool,
    /// OSC 133 (shell-integration) prompt markers have been seen.
    osc133_seen: bool,
    /// Top layer's hook is installed and emitting OSCs.
    hooked: bool,
    has_gunzip: bool,
    cmd_running: bool,
    shell: protocol.Shell,
    /// Nesting depth (1 = local shell only).
    depth: u8,
    last_exit: ?i32,
    cwd: []const u8,
    title: ?[]const u8,
    /// Monotonic preexec counter; embedder can compare snapshots to detect
    /// "a command was accepted since I last looked" even if `done` arrived
    /// in the same chunk.
    preexec_gen: u64,
    /// Requests in `run_queue` (sent + queued).
    queued_runs: usize,
};

/// `Session.dump` mode.
pub const DumpMode = union(enum) {
    /// Full state for replay into a fresh terminal (attach).
    attach,
    /// Current screen contents as plain text.
    screen,
    /// Scrollback + primary screen, optionally last-N-lines.
    scrollback: ?usize,
};

/// `Session.init` options. Defaults match the daemon's tuning.
pub const Options = struct {
    rows: u16,
    cols: u16,
    /// ghostty scrollback cap in bytes.
    max_scrollback: usize = 10 * 1024 * 1024,
    /// Floor for the line-acceptance window: ns to wait after typing a
    /// `run` for any acceptance signal (preexec/done/prompt). Past this,
    /// the shell is assumed to be at a continuation prompt → ^C.
    /// Actual window is `max(floor, 3 * observed_preexec_latency)`.
    accept_timeout_ns: i128 = 1 * std.time.ns_per_s,
    /// Higher floor for the first command at a layer (no RTT observation).
    accept_timeout_first_ns: i128 = 5 * std.time.ns_per_s,
    /// Emit a `.warn` for an unsent request after this wait.
    prompt_warn_ns: i128 = 5 * std.time.ns_per_s,
    /// Fail an unsent request (with `.prompt_fallback`/null) if no layer
    /// has appeared after this wait.
    prompt_timeout_ns: i128 = 30 * std.time.ns_per_s,
    /// Hook probe deadline.
    hook_probe_timeout_ns: i128 = 5 * std.time.ns_per_s,
    /// Hook install deadline.
    hook_install_timeout_ns: i128 = 10 * std.time.ns_per_s,
};

/// `ReadonlyStream` is not re-exported from lib_vt; derive it.
const VtStream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());
const VtHandler = VtStream.Handler;
/// Return type of `Effects.<field>`'s callback (the types aren't re-exported
/// from lib_vt, so derive them from `?*const fn(*Handler) T`).
fn EffectRet(comptime field: []const u8) type {
    return @typeInfo(@typeInfo(
        @typeInfo(@FieldType(VtHandler.Effects, field)).optional.child,
    ).pointer.child).@"fn".return_type.?;
}

/// Recover `*Session` inside an `Effects` callback. ghostty's Handler has
/// no userdata field, but `h.terminal` is the pointer *we* set (to
/// `&self.term`), so one hop through our own struct layout suffices —
/// independent of how ghostty arranges Stream/Handler internally.
inline fn sessionOf(h: *VtHandler) *Session {
    return @alignCast(@fieldParentPtr("term", h.terminal));
}

/// `Effects.write_pty`: ghostty has computed a response to a terminal query
/// (DSR `\e[6n`, DECRQM, DA, …) the inner app emitted. Exactly one party
/// must answer: when there's a leader, the leader's real terminal does
/// (via passthrough; non-leader replies are dropped in `handleInput`);
/// when there's no leader (headless or all stalled), ghostty answers here
/// so the app doesn't hang on its query timeout.
fn vtWritePty(h: *VtHandler, data: [:0]const u8) void {
    const sess = sessionOf(h);
    if (sess.has_leader) return;
    // OOM: drop the reply; the app will time out as it would have anyway.
    sess.pty_in.put(data) catch return;
}

/// `Effects.device_attributes`: what to report for DA1/2/3. Default = VT220
/// with ANSI colour — conservative enough that apps won't try features the
/// eventual real terminal might lack.
fn vtDeviceAttrs(_: *VtHandler) EffectRet("device_attributes") {
    return .{};
}

/// `Effects.size` (XTWINOPS 14/16/18 t): cell + pixel geometry. Rows/cols
/// from the shadow terminal; cell pixel size is faked (8×16) since there's
/// no real font headlessly. Prevents image tools (chafa, timg) from sitting
/// on a query timeout.
fn vtSize(h: *VtHandler) EffectRet("size") {
    const sess = sessionOf(h);
    if (sess.has_leader) return null;
    return .{
        .rows = @intCast(sess.term.screens.active.pages.rows),
        .columns = @intCast(sess.term.screens.active.pages.cols),
        .cell_width = 8,
        .cell_height = 16,
    };
}

/// `Effects.color_scheme` (DSR ?996 n): light/dark. Report dark — the
/// overwhelmingly common terminal default. nvim 0.10+ probes this for
/// `&background` autodetect.
fn vtColorScheme(h: *VtHandler) EffectRet("color_scheme") {
    if (sessionOf(h).has_leader) return null;
    return .dark;
}

/// `Effects.xtversion`: don't leak "libghostty".
fn vtVersion(_: *VtHandler) EffectRet("xtversion") {
    return "zmyth";
}

/// One pending `run` request.
const RunRequest = struct {
    /// Owned by Session.
    cmd: []u8,
    /// Opaque; caller picks the meaning (daemon maps it to a socket).
    cookie: u32,
    kind: Kind = .user,
    /// nanoTimestamp of the most recent state transition: when queued, then
    /// re-stamped when typed. checkPromptWait reads it as queued-time for
    /// unsent requests; dur_ms reads it as started-time for sent ones.
    ts_ns: i128,
    /// preexec OSC seen?
    accepted: bool = false,
    /// `layers.len - 1` at type time: which layer this was typed into.
    layer_depth: u8 = 0,
    /// Captured at type time: was that layer hooked? (i.e., is a preexec
    /// expected, so absence-of-preexec means continuation prompt → ^C.)
    expect_preexec: bool = false,
    /// `pty_in.mark()` at type-time, or 0 = not yet typed. The request is
    /// *sent* once nonzero, *flushed* once `pty_in.flushed >= flush_mark`.
    flush_mark: u64 = 0,
    /// `now_ns` when `flush_mark` was first reached. Only meaningful when
    /// `Session.flushed(r)`; do NOT test against 0 (virtual clocks may pass
    /// now=0). The acceptance timeout is measured from here.
    flushed_ns: i128 = 0,
    /// Hard deadline (hook requests only). 0 = none.
    deadline_ns: i128 = 0,

    const Kind = enum {
        user,
        /// `run -i`: complete on the first nested-prompt signal (new-pid
        /// `done` or post-preexec `?2004h`) instead of this layer's `done`.
        user_i,
        /// `zmyth hook` probe / install. `cmd` for `.hook_install` is
        /// pre-wrapped (already includes paste markers + body).
        hook_probe,
        hook_install,
    };

    inline fn sent(r: RunRequest) bool {
        return r.flush_mark != 0;
    }
    inline fn interactive(r: RunRequest) bool {
        return r.kind == .user_i;
    }
};

/// One nested shell. `layers[0]` is the locally-spawned shell; deeper indices
/// are nested (ssh, docker exec, su, plain `bash`). Only the top layer can be
/// at a prompt — every layer below is, by construction, running whatever
/// spawned the next layer up.
const Layer = struct {
    /// 0 = unknown (degraded layer pushed by `run -i` on bare ?2004h).
    pid: i32,
    shell: protocol.Shell = .unknown,
    /// This layer's hook is installed and emitting `done` OSCs.
    hooked: bool = false,
    /// preexec seen, done not yet. Meaningful only for the top layer.
    cmd_running: bool = false,
    /// Hook's load-time `command -v gunzip` probe; `write` uses gzip when set.
    has_gunzip: bool = false,
};

/// Nesting deeper than this is treated as a single layer (top is replaced
/// rather than pushed). 8 is already absurd for interactive use.
const max_layers = 8;

/// Fixed-capacity stack (std.BoundedArray was removed in Zig 0.15).
const Layers = struct {
    buffer: [max_layers]Layer = undefined,
    len: u8 = 0,
    fn push(self: *Layers, l: Layer) *Layer {
        if (self.len == max_layers) self.len -= 1; // overflow: replace top
        self.buffer[self.len] = l;
        self.len += 1;
        return &self.buffer[self.len - 1];
    }
};

/// Outbound queue to the PTY master. A read-cursor avoids memmove on every
/// partial write; a monotonic flushed-bytes counter lets a typed `run`
/// record a `mark()` and later test `flushed >= mark` to know its own bytes
/// have reached the PTY regardless of what's queued behind them.
const PtyBuffer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    flushed: u64 = 0,

    /// `append` past this returns error.PtyInputCapExceeded. The kernel PTY
    /// buffer is a few KB; if megabytes are queued the shell is wedged and
    /// accepting more would only OOM the daemon.
    pub const cap = 1024 * 1024;

    fn deinit(p: *PtyBuffer) void {
        p.buf.deinit(p.gpa);
    }

    /// Capped append for client-supplied bytes (`.send`, `.write_data`).
    fn append(p: *PtyBuffer, bytes: []const u8) !void {
        if (p.buf.items.len + bytes.len > cap) return error.PtyInputCapExceeded;
        try p.buf.appendSlice(p.gpa, bytes);
    }

    /// Uncapped append for daemon-generated bytes (typed commands, hook
    /// probe/install, query replies) — those are bounded by construction
    /// and must not be truncated mid-paste.
    fn put(p: *PtyBuffer, bytes: []const u8) !void {
        try p.buf.appendSlice(p.gpa, bytes);
    }

    fn pending(p: *const PtyBuffer) []const u8 {
        return p.buf.items[p.pos..];
    }

    /// Absolute end-of-queue position. A request typed now records this;
    /// once `flushed >= mark`, its bytes have hit the PTY.
    fn mark(p: *const PtyBuffer) u64 {
        return p.flushed + (p.buf.items.len - p.pos);
    }

    fn consume(p: *PtyBuffer, n: usize) void {
        p.pos += n;
        p.flushed += n;
        assert(p.pos <= p.buf.items.len);
        const rem = p.buf.items.len - p.pos;
        if (rem == 0) {
            p.buf.clearRetainingCapacity();
            p.pos = 0;
        } else if (p.pos > 64 * 1024) {
            std.mem.copyForwards(u8, p.buf.items[0..rem], p.buf.items[p.pos..]);
            p.buf.shrinkRetainingCapacity(rem);
            p.pos = 0;
        }
    }
};

pub const Session = struct {
    gpa: Allocator,
    opts: Options,
    /// Set by every public entry point that takes `now_ns`. Internal fns
    /// read this instead of calling the wall clock — Session is clock-pure.
    now: i128 = 0,
    term: vt.Terminal,
    /// Self-referential: `stream.handler.terminal` must point at `self.term`.
    /// Since Session is returned by value from init(), the pointer is fixed up
    /// at the top of every method that touches the stream.
    stream: VtStream,
    scanner: protocol.Scanner,

    /// Nested-shell stack. Empty until the first `done`/`?2004h`.
    layers: Layers = .{},

    /// Observed flush→preexec latency for the most recent accepted request.
    /// Scales the acceptance-timeout window so a nested hook over a slow SSH
    /// link isn't ^C'd just because the OSC took a network RTT to arrive.
    last_preexec_latency_ns: i128 = 0,
    last_exit: ?i32 = null,
    last_cwd: [std.fs.max_path_bytes]u8 = undefined,
    last_cwd_len: usize = 0,
    /// Most recent OSC 133;D exit code, consumed by the next prompt-fallback
    /// completion. Cleared by `done` (which is authoritative when present).
    osc133_exit: ?i32 = null,

    /// Set by the daemon while a healthy attached leader exists. Gates
    /// `vtWritePty`: ghostty answers terminal queries only when no real
    /// terminal can.
    has_leader: bool = false,

    /// Monotonic count of `preexec` events. Lets the daemon detect "preexec
    /// arrived since I last looked" even when preexec+done land in the same
    /// `feedPtyOutput` (so `cmd_running` is already false by the time it
    /// checks).
    preexec_count: u64 = 0,

    /// 5s prompt-wait warning already sent for the current front-unsent
    /// request. Cleared whenever a request is typed (front advances).
    warned_front: bool = false,

    /// `zmyth hook` probe response, stashed by `onProbe` for the probe
    /// request's `done` (or read immediately when the target is unhooked
    /// and no `done` will arrive).
    probe_result: ?protocol.ProbeResult = null,

    // I/O queues — caller drains/fills these.
    pty_in: PtyBuffer,
    run_queue: ArrayList(RunRequest),
    /// Emitted events; `drainEvents()` swaps these into `drained`.
    out_events: ArrayList(SessionEvent),
    drained: ArrayList(SessionEvent),
    /// Scratch reused across feedPty calls.
    scan_buf: ArrayList(protocol.Event),

    pub fn init(gpa: Allocator, opts: Options) !Session {
        var term = try vt.Terminal.init(gpa, .{
            .cols = @max(1, opts.cols),
            .rows = @max(1, opts.rows),
            .max_scrollback = opts.max_scrollback,
        });
        errdefer term.deinit(gpa);

        return .{
            .gpa = gpa,
            .opts = opts,
            .term = term,
            // Handler pointer is patched at the top of feedPty().
            .stream = VtStream.initAlloc(gpa, .{ .terminal = undefined }),
            .scanner = protocol.Scanner.init(gpa),
            .pty_in = .{ .gpa = gpa },
            .run_queue = .empty,
            .out_events = .empty,
            .drained = .empty,
            .scan_buf = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.stream.deinit();
        self.term.deinit(self.gpa);
        self.scanner.deinit();
        self.pty_in.deinit();
        for (self.run_queue.items) |*r| self.gpa.free(r.cmd);
        self.run_queue.deinit(self.gpa);
        self.out_events.deinit(self.gpa);
        self.drained.deinit(self.gpa);
        self.scan_buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// Feed bytes read from the PTY master. Updates the Terminal, runs the
    /// Scanner, and processes events: preexec → mark accepted, done →
    /// complete front request (or push a layer), prompt → fallback-complete
    /// when unhooked. May queue bytes into `pendingInput` and emit events.
    pub fn feedPty(self: *Session, bytes: []const u8, now_ns: i128) Error!void {
        self.now = now_ns;
        // `.terminal` must be patched here (self-referential; Session is
        // returned by value from init). The effects pointers are not
        // self-referential and could go in init(), but Effects has no
        // per-field defaults so naming every callback there is noisier than
        // two stores here.
        self.stream.handler.terminal = &self.term;
        self.stream.handler.effects = .{
            .write_pty = &vtWritePty,
            .device_attributes = &vtDeviceAttrs,
            .size = &vtSize,
            .color_scheme = &vtColorScheme,
            .xtversion = &vtVersion,
            .bell = null,
            .enquiry = null,
            .title_changed = null,
        };
        self.stream.nextSlice(bytes);

        self.scan_buf.clearRetainingCapacity();
        try self.scanner.feed(bytes, &self.scan_buf);

        for (self.scan_buf.items) |ev| switch (ev) {
            .probe => |p| try self.onProbe(p),
            .pwd => |p| self.setLastCwd(p),
            .osc133_end => |ec| {
                self.osc133_exit = ec;
                if (ec) |e| self.last_exit = e;
            },
            .preexec => |pid| self.onPreexec(pid),
            .done => |d| try self.onDone(d),
            .prompt => try self.onPrompt(),
        };
        // setLastCwd/onDone copied any cwd slices; release scanner storage.
        self.scanner.recycleSlices();

        // Type the next queued request only after all events from this chunk
        // are processed, so a trailing event in the same chunk can't be
        // misattributed to a request we haven't actually written yet.
        try self.tryTypeNext();
    }

    pub const RunOptions = struct {
        /// Complete on the first nested-prompt signal (new-pid `done` or
        /// post-preexec `?2004h`) instead of this layer's `done`. For
        /// `ssh remote`, `docker exec -it`, etc.
        interactive: bool = false,
    };

    /// Queue a shell command. If the top layer is idle, types it immediately;
    /// otherwise it waits for the next done/prompt. `cookie` is opaque and
    /// returned with the resulting `.run_done` event.
    pub fn run(self: *Session, cookie: u32, cmd: []const u8, ro: RunOptions, now_ns: i128) Error!void {
        self.now = now_ns;
        const owned = try self.gpa.dupe(u8, cmd);
        errdefer self.gpa.free(owned);
        try self.run_queue.append(self.gpa, .{
            .cmd = owned,
            .cookie = cookie,
            .kind = if (ro.interactive) .user_i else .user,
            .ts_ns = now_ns,
        });
        try self.tryTypeNext();
    }

    // ───────────────────── layer stack + event handlers ─────────────────────

    /// Active (top) layer, or null before any signal has arrived.
    fn top(self: *Session) ?*Layer {
        const n = self.layers.len;
        return if (n == 0) null else &self.layers.buffer[n - 1];
    }

    fn topDepth(self: *const Session) u8 {
        return if (self.layers.len == 0) 0 else self.layers.len - 1;
    }

    /// Index of `pid` in the stack, or null. pid==0 (degraded) only matches
    /// the top — we can't tell degraded layers apart.
    fn findLayer(self: *const Session, pid: i32) ?u8 {
        if (pid == 0) {
            return if (self.layers.len > 0 and self.layers.buffer[self.layers.len - 1].pid == 0)
                self.layers.len - 1
            else
                null;
        }
        var i: u8 = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.buffer[i].pid == pid) return i;
        }
        return null;
    }

    fn pushLayer(self: *Session, l: Layer) *Layer {
        // Degraded-top promotion: if the current top is a pid==0 placeholder
        // (pushed by `run -i` on bare ?2004h) and a real pid now announces,
        // adopt it instead of stacking on top of a ghost.
        if (self.top()) |t| if (t.pid == 0 and l.pid != 0) {
            t.* = l;
            return t;
        };
        return self.layers.push(l);
    }

    /// Pop layers above `depth`, completing any sent run at a popped depth as
    /// `.layer_exited` (its shell vanished before emitting `done`).
    fn popLayersAbove(self: *Session, depth: u8, ec: i32) !void {
        while (self.layers.len > depth + 1) {
            const gone: u8 = @intCast(self.layers.len - 1);
            self.layers.len -= 1;
            var i: usize = 0;
            while (i < self.run_queue.items.len) {
                const r = &self.run_queue.items[i];
                if (r.sent() and r.layer_depth == gone) {
                    const req = self.run_queue.orderedRemove(i);
                    switch (req.kind) {
                        .hook_probe, .hook_install => try self.completeHook(
                            req,
                            .{ .err = "hook: target shell exited mid-install" },
                        ),
                        else => try self.complete(req, ec, .layer_exited, self.dur(req)),
                    }
                } else i += 1;
            }
        }
    }

    fn onPreexec(self: *Session, pid: i32) void {
        self.preexec_count += 1;
        const depth: u8 = self.findLayer(pid) orelse blk: {
            _ = self.pushLayer(.{ .pid = pid, .hooked = true });
            break :blk self.topDepth();
        };
        self.layers.buffer[depth].cmd_running = true;
        if (self.sentAt(depth)) |r| {
            if (self.flushed(r)) {
                self.last_preexec_latency_ns = self.now - r.flushed_ns;
            }
            r.accepted = true;
        }
    }

    fn onDone(self: *Session, d: protocol.Done) !void {
        self.last_exit = d.exit_code;
        self.osc133_exit = null; // `done` is authoritative
        self.setLastCwd(d.cwd);

        // Route by pid: known layer below top → that layer's child chain has
        // exited; pop down. Unknown pid → a freshly-hooked nested shell (file-
        // installed hook reaching its first prompt); push it.
        const found = self.findLayer(d.pid);
        const is_new = found == null;
        const depth: u8 = if (found) |i| blk: {
            try self.popLayersAbove(i, d.exit_code);
            break :blk i;
        } else blk: {
            _ = self.pushLayer(.{ .pid = d.pid, .hooked = true });
            break :blk self.topDepth();
        };

        const layer = &self.layers.buffer[depth];
        layer.hooked = true;
        layer.cmd_running = false;
        layer.shell = d.shell;
        layer.has_gunzip = d.has_gunzip;

        // A NEW layer's first `done` is its first-prompt precmd, not a
        // command completion. It may complete a `run -i` or a hook-install
        // one level down (the install spawned/hooked this layer).
        if (is_new) {
            if (self.sentAt(depth)) |r| {
                // Install typed into the degraded placeholder this `done`
                // just adopted: this is its completion.
                if (r.kind == .hook_install)
                    return self.completeHook(self.removeReq(r), .{ .installed = layer.shell });
                // User run typed while degraded (expect_preexec=false). This
                // `done` is precmd — fires before the prompt reads input —
                // so the typed line is still queued and the now-live hook
                // will bracket it.
                if (!r.accepted) r.expect_preexec = true;
            }
            if (depth > 0) if (self.sentAt(depth - 1)) |r| switch (r.kind) {
                .user_i => if (r.accepted)
                    try self.complete(self.removeReq(r), 0, .at_prompt, d.dur_ms),
                .hook_install => try self.completeHook(self.removeReq(r), .{ .installed = layer.shell }),
                else => {},
            };
            return;
        }
        if (self.sentAt(depth)) |r| {
            // A `done` that arrives before our bytes have reached the PTY
            // is from something else (^C at the prompt, write-abort cleanup).
            if (!self.flushed(r)) return;
            switch (r.kind) {
                .hook_probe => return self.finishProbe(self.removeReq(r)),
                .hook_install => return self.completeHook(
                    self.removeReq(r),
                    .{ .installed = layer.shell },
                ),
                else => {},
            }
            try self.complete(self.removeReq(r), d.exit_code, .osc_done, d.dur_ms);
        }
    }

    fn onPrompt(self: *Session) !void {
        // First prompt-ready signal ever: establish a degraded base layer.
        if (self.layers.len == 0) {
            _ = self.pushLayer(.{ .pid = 0 });
        }
        const t = self.top().?;
        const depth = self.topDepth();
        if (self.sentAt(depth)) |r| {
            // `run -i`: a prompt appeared after preexec → nested line editor.
            // Push a degraded placeholder for it and complete the request.
            if (r.interactive() and r.accepted) {
                const req = self.removeReq(r);
                _ = self.pushLayer(.{ .pid = 0 });
                try self.complete(req, 0, .at_prompt, self.dur(req));
                return;
            }
            // Unhooked top: ?2004h is the only "back at prompt" signal. If the
            // shell emitted OSC 133;D (starship/omp do) we have a real exit
            // code; otherwise null. Hook requests have their own deadline;
            // a stray ?2004h between probe and install must not complete them.
            if (!t.hooked and r.deadline_ns == 0) {
                const ec = self.osc133_exit;
                self.osc133_exit = null;
                const req = self.removeReq(r);
                try self.complete(req, ec, .prompt_fallback, self.dur(req));
            }
        }
    }

    /// First sent-but-not-completed request typed at `depth`.
    fn sentAt(self: *Session, depth: u8) ?*RunRequest {
        for (self.run_queue.items) |*r| {
            if (r.sent() and r.layer_depth == depth) return r;
        }
        return null;
    }

    fn removeReq(self: *Session, r: *RunRequest) RunRequest {
        const idx = (@intFromPtr(r) - @intFromPtr(self.run_queue.items.ptr)) / @sizeOf(RunRequest);
        return self.run_queue.orderedRemove(idx);
    }

    // ───────────────────────── public API ─────────────────────────

    pub const pty_input_cap = PtyBuffer.cap;

    /// Queue raw bytes to the PTY. No waiting, no wrapping.
    pub fn send(self: *Session, bytes: []const u8) Error!void {
        try self.pty_in.append(bytes);
    }

    /// Bytes the caller should write to the PTY master.
    pub fn pendingInput(self: *const Session) []const u8 {
        return self.pty_in.pending();
    }

    /// Discard the first `n` bytes of pending PTY input (after a successful
    /// write to the master). Stamps `flushed_ns` on any sent request whose
    /// flush_mark has now been crossed.
    pub fn consumeInput(self: *Session, n: usize, now_ns: i128) void {
        self.now = now_ns;
        const before = self.pty_in.flushed;
        self.pty_in.consume(n);
        for (self.run_queue.items) |*r| {
            if (r.sent() and before < r.flush_mark and self.pty_in.flushed >= r.flush_mark)
                r.flushed_ns = now_ns;
        }
    }

    /// `r`'s bytes have reached the PTY (its flush_mark has been crossed).
    inline fn flushed(self: *const Session, r: *const RunRequest) bool {
        return r.sent() and self.pty_in.flushed >= r.flush_mark;
    }

    /// Drop every request with `cookie`: not-yet-typed user runs are removed
    /// silently; an in-flight hook is removed (its already-typed bytes can't
    /// be recalled, but a new `installHook` can proceed without waiting out
    /// the timeout). Typed user runs stay — they can't be recalled and will
    /// complete; the caller drops the resulting event at routing time.
    pub fn cancel(self: *Session, cookie: u32) void {
        var i: usize = 0;
        while (i < self.run_queue.items.len) {
            const r = &self.run_queue.items[i];
            if (r.cookie == cookie and (!r.sent() or r.deadline_ns != 0)) {
                self.gpa.free(r.cmd);
                _ = self.run_queue.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Advance time. Fires acceptance-timeout / hook-deadline / prompt-wait
    /// checks and emits events for whatever fired. Call once per event-loop
    /// tick (after `feedPty`/`consumeInput`).
    pub fn tick(self: *Session, now_ns: i128) void {
        self.now = now_ns;
        self.tickAcceptance();
        self.tickDeadlines();
        self.tickPromptWait();
    }

    /// Earliest absolute ns at which `tick()` may fire something, or null
    /// (poll can block). Compute the poll timeout as `deadline - now`.
    pub fn nextDeadline(self: *const Session) ?i128 {
        var earliest: ?i128 = null;
        const min = struct {
            fn f(e: *?i128, v: i128) void {
                if (e.* == null or v < e.*.?) e.* = v;
            }
        }.f;
        for (self.run_queue.items) |r| {
            if (r.deadline_ns != 0) min(&earliest, r.deadline_ns);
            if (!r.sent()) {
                min(&earliest, r.ts_ns + self.opts.prompt_warn_ns);
                if (self.layers.len == 0)
                    min(&earliest, r.ts_ns + self.opts.prompt_timeout_ns);
            } else if (!r.accepted and r.expect_preexec and r.deadline_ns == 0) {
                // Acceptance window. If not yet flushed, we don't know when
                // it will be, so wake soon.
                const base = if (self.flushed(&r)) r.flushed_ns else self.now;
                min(&earliest, base + self.acceptanceWindow());
            }
        }
        return earliest;
    }

    /// Events emitted since the last `drainEvents()`. The returned slice
    /// borrows Session storage and is valid until the next `drainEvents()`
    /// or `deinit()`.
    pub fn drainEvents(self: *Session) []const SessionEvent {
        std.mem.swap(ArrayList(SessionEvent), &self.drained, &self.out_events);
        self.out_events.clearRetainingCapacity();
        return self.drained.items;
    }

    /// Read-only snapshot. `cwd`/`title` borrow Session storage.
    pub fn state(self: *const Session) State {
        const t = if (self.layers.len == 0) Layer{ .pid = 0 } else self.layers.buffer[self.layers.len - 1];
        const m = &self.term.modes;
        return .{
            .idle = !t.cmd_running and self.run_queue.items.len == 0,
            .alt_screen = self.term.screens.active_key == .alternate,
            .mouse_tracking = m.get(.mouse_event_x10) or m.get(.mouse_event_normal) or
                m.get(.mouse_event_button) or m.get(.mouse_event_any),
            .osc133_seen = if (self.term.screens.get(.primary)) |s| s.semantic_prompt.seen else false,
            .hooked = t.hooked,
            .has_gunzip = t.has_gunzip,
            .cmd_running = t.cmd_running,
            .shell = self.topShell(),
            .depth = self.layers.len,
            .last_exit = self.last_exit,
            .cwd = self.last_cwd[0..self.last_cwd_len],
            .title = self.term.getTitle(),
            .preexec_gen = self.preexec_count,
            .queued_runs = self.run_queue.items.len,
        };
    }

    /// Gate headless terminal-query replies: when a real terminal is attached,
    /// it answers DSR/DA/etc; when not, ghostty answers from session state so
    /// apps don't hang on their query timeout.
    pub fn setLeaderAttached(self: *Session, attached: bool) void {
        self.has_leader = attached;
    }

    /// Render terminal state to `w`. `attach` emits a control-sequence stream
    /// for replay into a fresh terminal; `screen`/`scrollback` emit plain text.
    pub fn dump(self: *Session, w: *std.Io.Writer, mode: DumpMode) !void {
        switch (mode) {
            .attach => try term_state.serializeForAttach(&self.term, w),
            .screen => try term_state.dumpScreen(&self.term, w),
            .scrollback => |tail| try term_state.dumpScrollback(self.gpa, &self.term, tail, w),
        }
    }

    pub fn resize(self: *Session, rows: u16, cols: u16) !void {
        // ghostty-vt panics on 0 and OOMs on absurd sizes; clamp both ends.
        try self.term.resize(
            self.gpa,
            std.math.clamp(cols, 1, 1000),
            std.math.clamp(rows, 1, 500),
        );
    }

    /// PTY master hit EOF. Complete every queued request with `.pty_eof`
    /// and the waitpid-derived exit code.
    pub fn onPtyEof(self: *Session, wait_status: u32, now_ns: i128) void {
        self.now = now_ns;
        const W = std.posix.W;
        const ec: i32 = if (W.IFEXITED(wait_status))
            @intCast(W.EXITSTATUS(wait_status))
        else if (W.IFSIGNALED(wait_status))
            128 + @as(i32, @intCast(W.TERMSIG(wait_status)))
        else
            -1;
        while (self.run_queue.items.len > 0) {
            const req = self.run_queue.orderedRemove(0);
            switch (req.kind) {
                .hook_probe, .hook_install => self.completeHook(
                    req,
                    .{ .err = "hook: shell exited" },
                ) catch {},
                else => self.complete(
                    req,
                    if (req.sent()) ec else null,
                    .pty_eof,
                    if (req.sent()) self.dur(req) else 0,
                ) catch {},
            }
        }
    }

    // ───────────────────────── tick sub-checks ─────────────────────────

    fn acceptanceWindow(self: *const Session) i128 {
        const floor = if (self.last_preexec_latency_ns == 0)
            self.opts.accept_timeout_first_ns
        else
            self.opts.accept_timeout_ns;
        return @max(floor, 3 * self.last_preexec_latency_ns);
    }

    /// Front request was typed but no acceptance signal (preexec/done/prompt)
    /// arrived within the window: shell is at a continuation prompt → ^C and
    /// `.line_rejected`.
    fn tickAcceptance(self: *Session) void {
        const r = self.sentAt(self.topDepth()) orelse return;
        if (r.accepted) return;
        // Hook requests have their own deadline.
        if (r.deadline_ns != 0) return;
        // No preexec signal exists when typed into a degraded layer; can't
        // distinguish "running" from "continuation" so don't ^C real commands.
        if (!r.expect_preexec) return;
        if (!self.flushed(r)) return;
        const waited = self.now - r.flushed_ns;
        if (waited < self.acceptanceWindow()) return;

        // Widen the latency estimate from how long we waited so the *next*
        // attempt's window grows — otherwise a slow link whose first preexec
        // never arrives would reject every command at the 1s floor forever.
        self.last_preexec_latency_ns = @max(self.last_preexec_latency_ns, waited);
        self.pty_in.put("\x03") catch {};
        const req = self.removeReq(r);
        self.complete(req, null, .line_rejected, self.dur(req)) catch {};
    }

    /// Times out any sent request past its `deadline_ns` (hook probe/install).
    fn tickDeadlines(self: *Session) void {
        var i: usize = 0;
        while (i < self.run_queue.items.len) {
            const r = &self.run_queue.items[i];
            if (r.deadline_ns != 0 and self.now >= r.deadline_ns) {
                const req = self.run_queue.orderedRemove(i);
                self.completeHook(req, .{ .err = switch (req.kind) {
                    .hook_probe => "hook: no response to probe — not at a bash/zsh/fish prompt?",
                    .hook_install => "hook: install did not complete (no prompt after sourcing hook)",
                    else => "deadline exceeded",
                } }) catch {};
            } else i += 1;
        }
    }

    /// Soft-warn / hard-fail for a queued request that can't be typed yet.
    /// Warns at `prompt_warn_ns`; hard-fails at `prompt_timeout_ns` only if
    /// no layer has appeared yet (after that, an unsent request is queued
    /// behind a real running command which may legitimately take hours).
    fn tickPromptWait(self: *Session) void {
        const r = self.firstUnsent() orelse return;
        const waited = self.now - r.ts_ns;

        if (self.layers.len == 0 and waited >= self.opts.prompt_timeout_ns) {
            const req = self.removeReq(r);
            self.emit(.{ .warn = .{
                .cookie = req.cookie,
                .msg = "shell never reached a prompt; integration unavailable for this session",
            } }) catch {};
            self.complete(req, null, .prompt_fallback, self.dur(req)) catch {};
            return;
        }
        if (waited >= self.opts.prompt_warn_ns and !self.warned_front) {
            self.warned_front = true;
            self.emit(.{ .warn = .{
                .cookie = r.cookie,
                .msg = "still waiting (shell starting, or a previous command is still running)…",
            } }) catch {};
        }
    }

    // ───────────────────────── private accessors ─────────────────────────

    fn isAltScreen(self: *const Session) bool {
        return self.term.screens.active_key == .alternate;
    }

    fn topShell(self: *const Session) protocol.Shell {
        // Prefer the deepest layer that knows its shell (a degraded top hides
        // the hooked layer beneath it otherwise).
        var i: usize = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.buffer[i].shell != .unknown) return self.layers.buffer[i].shell;
        }
        return .unknown;
    }

    fn setLastCwd(self: *Session, cwd: []const u8) void {
        const n = @min(cwd.len, self.last_cwd.len);
        @memcpy(self.last_cwd[0..n], cwd[0..n]);
        self.last_cwd_len = n;
    }

    // ───────────────────────── hook install ─────────────────────────
    //
    // Probe and install are RunRequests with `.kind = .hook_*`, so the
    // existing preexec/done matching tracks them — no separate state
    // machine, no echo_swallow. Two cases:
    //
    //   Target hooked (e.g. `zmyth hook` at the local prompt): the probe is
    //   bracketed by preexec/done like any user run. `onProbe` stashes the
    //   result; `onDone` for `.hook_probe` calls `finishProbe`.
    //
    //   Target unhooked (nested ssh/docker): no preexec/done from the inner
    //   shell. `onProbe` sees `!r.accepted` and calls `finishProbe` itself.
    //   The install's completion signal is the freshly-hooked layer's first
    //   `done` (new pid, depth+1), handled in `onDone`'s `is_new` branch.
    //
    // Timeout is per-request `deadline_ns` checked in `tickDeadlines`.

    /// Begin a hook install: queue + type the probe. Returns a static error
    /// string if the session can't accept a hook right now; null on success
    /// (a `.hook_done` event will follow).
    pub fn installHook(self: *Session, cookie: u32, now_ns: i128) Error!?[]const u8 {
        self.now = now_ns;
        if (self.hookRequest() != null)
            return "hook: another install already in progress";
        if (self.isAltScreen())
            return "hook: session is in a full-screen app, not a shell prompt";
        if (self.sentAt(self.topDepth()) != null)
            return "hook: a `run` is in flight; retry when it completes";

        try self.run_queue.append(self.gpa, .{
            .cmd = try self.gpa.dupe(u8, shell.probe_line),
            .cookie = cookie,
            .kind = .hook_probe,
            .ts_ns = now_ns,
            .deadline_ns = now_ns + @max(self.opts.hook_probe_timeout_ns, 3 * self.last_preexec_latency_ns),
        });
        // Type immediately, bypassing canType: the target may be a nested
        // unhooked shell (top.cmd_running=true from the outer's `ssh`).
        try self.typeCommand(&self.run_queue.items[self.run_queue.items.len - 1]);
        return null;
    }

    fn onProbe(self: *Session, p: protocol.ProbeResult) !void {
        self.probe_result = p;
        // Unhooked target: no `done` is coming, so finish now. Hooked: the
        // probe's `done` will call finishProbe via onDone.
        const r = self.hookRequest() orelse return;
        if (r.kind == .hook_probe and !r.accepted) {
            try self.finishProbe(self.removeReq(r));
        }
    }

    /// The probe request has finished (via its `done`, or directly from
    /// `onProbe` for an unhooked target). Decide: already-hooked / refuse /
    /// enqueue install.
    fn finishProbe(self: *Session, req: RunRequest) !void {
        const p = self.probe_result orelse
            return self.completeHook(req, .{ .err = "hook: no response to probe — not at a bash/zsh/fish prompt?" });
        self.probe_result = null;

        if (p.hook_v >= shell.hook_version)
            return self.completeHook(req, .{ .already_hooked = p.hook_v });
        if (p.shell == .unknown)
            return self.completeHook(req, .{ .err = "hook: not bash, zsh, or fish" });
        if (p.shell == .bash and p.shell_major < 4)
            return self.completeHook(req, .{ .err = "hook: bash < 4 lacks bracketed-paste; cannot hook" });

        try self.run_queue.append(self.gpa, .{
            .cmd = try shell.buildInstall(self.gpa, p.shell),
            .cookie = req.cookie,
            .kind = .hook_install,
            .ts_ns = self.now,
            .deadline_ns = self.now + @max(self.opts.hook_install_timeout_ns, 6 * self.last_preexec_latency_ns),
        });
        self.gpa.free(req.cmd);
        try self.typeCommand(&self.run_queue.items[self.run_queue.items.len - 1]);
    }

    /// In-flight `.hook_*` request, if any.
    fn hookRequest(self: *Session) ?*RunRequest {
        for (self.run_queue.items) |*r| switch (r.kind) {
            .hook_probe, .hook_install => return r,
            else => {},
        };
        return null;
    }

    // ───────────────────────── internals ─────────────────────────

    fn firstUnsent(self: *Session) ?*RunRequest {
        for (self.run_queue.items) |*r| if (!r.sent()) return r;
        return null;
    }

    fn emit(self: *Session, ev: SessionEvent) !void {
        try self.out_events.append(self.gpa, ev);
    }

    fn complete(self: *Session, req: RunRequest, ec: ?i32, via: Via, dur_ms: u64) !void {
        self.gpa.free(req.cmd);
        try self.emit(.{ .run_done = .{
            .cookie = req.cookie,
            .exit_code = ec,
            .via = via,
            .dur_ms = dur_ms,
        } });
    }

    fn completeHook(self: *Session, req: RunRequest, result: HookResult) !void {
        self.gpa.free(req.cmd);
        try self.emit(.{ .hook_done = .{ .cookie = req.cookie, .result = result } });
    }

    inline fn dur(self: *const Session, req: RunRequest) u64 {
        const d = self.now - req.ts_ns;
        if (d <= 0) return 0;
        return @intCast(@divTrunc(d, std.time.ns_per_ms));
    }

    /// Can a queued command be typed into the top layer right now?
    fn canType(self: *Session) bool {
        if (self.isAltScreen()) return false;
        const t = self.top() orelse return false;
        if (t.cmd_running) return false;
        // Don't type over an already-in-flight request at this depth (this
        // also covers an in-flight hook probe/install — they're requests).
        if (self.sentAt(self.topDepth()) != null) return false;
        return true;
    }

    fn tryTypeNext(self: *Session) !void {
        if (self.canType()) if (self.firstUnsent()) |r| try self.typeCommand(r);
    }

    /// Ctrl-U, bracketed-paste, cmd, end-paste, CR. Hook-install requests
    /// are pre-wrapped (buildInstall includes paste markers + body).
    fn typeCommand(self: *Session, req: *RunRequest) !void {
        if (req.kind == .hook_install) {
            try self.pty_in.put(req.cmd);
        } else {
            try self.pty_in.put("\x15\x1b[200~");
            try self.pty_in.put(req.cmd);
            try self.pty_in.put("\x1b[201~\r");
        }
        req.ts_ns = self.now;
        req.flush_mark = self.pty_in.mark();
        req.layer_depth = self.topDepth();
        req.expect_preexec = if (self.top()) |t| t.hooked else false;
        self.warned_front = false;
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

const TPID: i32 = 100;

fn tInit() !Session {
    return Session.init(testing.allocator, .{ .rows = 24, .cols = 80 });
}

/// Drain and assert exactly one `.run_done`; return it.
fn expectRunDone(s: *Session) !SessionEvent.RunDone {
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expect(evs[0] == .run_done);
    return evs[0].run_done;
}

/// Drain and assert exactly one `.hook_done`; return it.
fn expectHookDone(s: *Session) !SessionEvent.HookDone {
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expect(evs[0] == .hook_done);
    return evs[0].hook_done;
}

fn expectNoEvents(s: *Session) !void {
    try testing.expectEqual(@as(usize, 0), s.drainEvents().len);
}

fn doneOsc(buf: []u8, pid: i32, ec: i32, cwd: []const u8, dur: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "\x1b]2718;done;{d};{d};{d};b;{s}\x07",
        .{ pid, ec, dur, cwd },
    ) catch unreachable;
}

fn preexecOsc(buf: []u8, pid: i32) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b]2718;preexec;{d}\x07", .{pid}) catch unreachable;
}

/// Bring a fresh session to the hooked+idle state: layer 0 announces via its
/// first `done` (the rc-shim-loaded hook's first precmd).
fn hookAndIdle(s: *Session) !void {
    var b: [128]u8 = undefined;
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
}

test "first done establishes layer 0: hooked + last_exit + cwd" {
    var s = try tInit();
    defer s.deinit();

    var b: [128]u8 = undefined;
    try s.feedPty(doneOsc(&b, TPID, 42, "/tmp", 7), 0);

    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expect(s.state().hooked);
    try testing.expect(!s.state().cmd_running);
    try testing.expectEqual(@as(?i32, 42), s.last_exit);
    try testing.expectEqualStrings("/tmp", s.state().cwd);
    try expectNoEvents(&s);
}

test "queueRun while idle: type, preexec, done -> completion" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "echo hi", .{}, 0);
    const want = "\x15\x1b[200~echo hi\x1b[201~\r";
    try testing.expect(std.mem.endsWith(u8, s.pendingInput(), want));
    try testing.expect(s.run_queue.items[0].sent());
    s.consumeInput(s.pendingInput().len, 0);

    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try testing.expect(s.state().cmd_running);
    try testing.expect(s.run_queue.items[0].accepted);

    try s.feedPty(doneOsc(&b, TPID, 0, "/tmp", 5), 0);
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u32, 1), evs[0].run_done.cookie);
    try testing.expectEqual(@as(?i32, 0), evs[0].run_done.exit_code);
    try testing.expectEqual(.osc_done, evs[0].run_done.via);
    try testing.expectEqual(@as(u64, 5), evs[0].run_done.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "queueRun while busy waits for done" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    try s.run(1, "first", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try testing.expect(s.state().cmd_running);

    // Second request arrives mid-command.
    try s.run(2, "second", .{}, 0);
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expect(!s.run_queue.items[1].sent());

    // First done -> complete #1 and type #2.
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 1), 0);
    try testing.expectEqual(@as(u32, 1), (try expectRunDone(&s)).cookie);
    try testing.expect(std.mem.endsWith(u8, s.pendingInput(), "second\x1b[201~\r"));
    try testing.expect(s.run_queue.items[0].sent());
}

test "prompt-fallback when not hooked" {
    var s = try tInit();
    defer s.deinit();

    // No hook. First ?2004h pushes a degraded layer (prompt-ready).
    try s.feedPty("\x1b[?2004h", 0);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expect(!s.state().hooked);

    try s.run(7, "echo hi", .{}, 0);
    try testing.expect(std.mem.endsWith(u8, s.pendingInput(), "echo hi\x1b[201~\r"));

    // Shell echoes the command, returns to prompt -> ?2004h again.
    try s.feedPty("\x1b[?2004h", 0);
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u32, 7), evs[0].run_done.cookie);
    try testing.expectEqual(@as(?i32, null), evs[0].run_done.exit_code);
    try testing.expectEqual(.prompt_fallback, evs[0].run_done.via);
}

test "prompt ignored when hooked" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "x", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);
    // Hooked: ?2004h is not authoritative, done is.
    try s.feedPty("\x1b[?2004h", 0);
    try expectNoEvents(&s);
    try s.feedPty(doneOsc(&b, TPID, 3, "/", 1), 0);
    try testing.expectEqual(@as(?i32, 3), (try expectRunDone(&s)).exit_code);
}

test "alt-screen gates typing" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.feedPty("\x1b[?1049h", 0);
    try testing.expect(s.state().alt_screen);

    try s.run(1, "echo hi", .{}, 0);
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);
    try testing.expect(!s.run_queue.items[0].sent());

    var b: [128]u8 = undefined;
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b[?1049l");
    try seq.appendSlice(testing.allocator, doneOsc(&b, TPID, 0, "/", 1));
    try s.feedPty(seq.items, 0);

    try testing.expect(!s.state().alt_screen);
    try testing.expect(std.mem.endsWith(u8, s.pendingInput(), "echo hi\x1b[201~\r"));
    // The done belonged to the TUI's wrapping shell, not our command.
    try expectNoEvents(&s);
}

test "tick: acceptance timeout sends ^C and rejects" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    // Seed an observed RTT so the 1s floor applies (first-command floor is 5s).
    s.last_preexec_latency_ns = 50 * std.time.ns_per_ms;

    try s.run(9, "echo \"unclosed", .{}, 0);
    try testing.expect(s.run_queue.items[0].sent());

    // Window doesn't open until bytes hit the PTY.
    s.tick(std.math.maxInt(i64));
    try expectNoEvents(&s);

    const tf: i128 = 1000;
    s.consumeInput(s.pendingInput().len, tf);
    try testing.expectEqual(tf, s.run_queue.items[0].flushed_ns);

    // Not yet.
    s.tick(tf + @divTrunc(s.opts.accept_timeout_ns, 2));
    try expectNoEvents(&s);

    // Past the threshold.
    s.tick(tf + s.opts.accept_timeout_ns + 100 * std.time.ns_per_ms);
    try testing.expect(std.mem.endsWith(u8, s.pendingInput(), "\x03"));
    const rd = try expectRunDone(&s);
    try testing.expectEqual(.line_rejected, rd.via);
    try testing.expectEqual(@as(?i32, null), rd.exit_code);
    try testing.expectEqual(@as(u32, 9), rd.cookie);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "tick: acceptance timeout disabled when not hooked" {
    var s = try tInit();
    defer s.deinit();
    try s.feedPty("\x1b[?2004h", 0);
    try s.run(1, "sleep 5", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    s.tick(s.opts.prompt_timeout_ns - 1);
    try expectNoEvents(&s);
}

test "two dones in one chunk don't misattribute" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "a", .{}, 0);
    try s.run(2, "b", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);

    // One chunk: done(a, ec=7) immediately followed by a stray done(ec=99).
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(testing.allocator);
    try chunk.appendSlice(testing.allocator, doneOsc(&b, TPID, 7, "/", 1));
    try chunk.appendSlice(testing.allocator, doneOsc(&b, TPID, 99, "/", 1));
    try s.feedPty(chunk.items, 0);

    // Only req#1 completed; req#2 was typed at end-of-chunk, NOT completed.
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u32, 1), evs[0].run_done.cookie);
    try testing.expectEqual(@as(?i32, 7), evs[0].run_done.exit_code);
    try testing.expect(s.run_queue.items.len == 1 and s.run_queue.items[0].sent());
}

test "checkAcceptanceTimeout ignored once accepted" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "sleep 10", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    const tf = s.run_queue.items[0].flushed_ns;
    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);

    s.tick(tf + 10 * std.time.ns_per_s);
    try expectNoEvents(&s);
}

test "onPtyEof completes all queued" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "exec true", .{}, 0);
    try s.run(2, "never runs", .{}, 0);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);

    // Exit code 5 in the high byte of wait status.
    s.onPtyEof(5 << 8, 0);
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(@as(u32, 1), evs[0].run_done.cookie);
    try testing.expectEqual(.pty_eof, evs[0].run_done.via);
    try testing.expectEqual(@as(?i32, 5), evs[0].run_done.exit_code);
    // Never-sent request: no exit code, zero duration.
    try testing.expectEqual(@as(u32, 2), evs[1].run_done.cookie);
    try testing.expectEqual(@as(?i32, null), evs[1].run_done.exit_code);
    try testing.expectEqual(@as(u64, 0), evs[1].run_done.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "resize clamps zero" {
    var s = try tInit();
    defer s.deinit();
    try s.resize(0, 0);
    try testing.expect(s.term.screens.active.pages.rows >= 1);
    try testing.expect(s.term.screens.active.pages.cols >= 1);
}

test "queueSend is raw passthrough" {
    var s = try tInit();
    defer s.deinit();
    try s.send("jk\x1b");
    try testing.expectEqualStrings("jk\x1b", s.pendingInput());
    s.consumeInput(2, 0);
    try testing.expectEqualStrings("\x1b", s.pendingInput());
}

test "resize clamps absurd dimensions" {
    var s = try tInit();
    defer s.deinit();
    try s.resize(65535, 65535);
    try testing.expect(s.term.screens.active.pages.rows <= 500);
    try testing.expect(s.term.screens.active.pages.cols <= 1000);
    try testing.expect(s.term.screens.active.pages.rows >= 1);
}

test "queueRun with 2MB command is buffered without leak" {
    // typeCommand() does NOT enforce pty_input_cap (only queueSend() does), so
    // an oversized run command is simply buffered. This test pins that there
    // is no panic and no leak: the duped cmd is owned by run_queue and freed
    // on deinit (testing.allocator asserts). The daemon is expected to reject
    // pathological run payloads at the IPC layer before they reach here.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    const big = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try s.run(1, big, .{}, 0);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expect(s.pendingInput().len > Session.pty_input_cap);
    // cmd slice is the duped copy, distinct from `big`.
    try testing.expect(s.run_queue.items[0].cmd.ptr != big.ptr);
}

test "cancelClientRuns drops only unsent for that client" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "a", .{}, 0); // typed immediately (idle, hooked)
    try s.run(2, "b", .{}, 0); // queued, unsent
    try s.run(1, "c", .{}, 0); // queued, unsent
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expect(!s.run_queue.items[1].sent());
    try testing.expect(!s.run_queue.items[2].sent());

    s.cancel(1);

    // "a" is already in the PTY and can't be recalled; "c" is dropped; "b"
    // (different client) survives.
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expectEqualStrings("a", s.run_queue.items[0].cmd);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expectEqualStrings("b", s.run_queue.items[1].cmd);
    try testing.expectEqual(@as(u32, 2), s.run_queue.items[1].cookie);
}

test "done without preexec is not credited to a typed-but-unaccepted request" {
    // ^C at the prompt, an empty line, or a write-abort cleanup all produce
    // a `done` (precmd fires) with no matching preexec. If a run was queued
    // into pty_input but its bytes haven't reached the shell yet, that done
    // must not complete it.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    // Stray ^C is queued first; the run is typed after it. Neither flushed.
    try s.send("\x03");
    try s.run(7, "echo hi", .{}, 0);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expect(!s.flushed(&s.run_queue.items[0]));

    // ^C → precmd → done;130. Our bytes not flushed ⇒ NOT our completion.
    var b: [128]u8 = undefined;
    try s.feedPty(doneOsc(&b, TPID, 130, "/", 0), 0);
    try expectNoEvents(&s);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);

    // The real bracket then arrives.
    s.consumeInput(s.pendingInput().len, 1);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 1), 0);
    try testing.expectEqual(@as(?i32, 0), (try expectRunDone(&s)).exit_code);
}

test "R-flush: per-request flush_mark — trailing send doesn't hide flush" {
    // A `.send` queued behind a typed command leaves pty_input non-empty
    // after the command's bytes have drained. flushed_ns is keyed on the
    // request's own flush_mark, so it's stamped at the partial drain.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.run(1, "true", .{}, 0);
    const cmd_len = s.pendingInput().len;
    try s.send("# tail the kernel PTY buffer didn't accept yet\n");
    s.consumeInput(cmd_len, 0); // command flushed; send still pending
    try testing.expect(s.pendingInput().len > 0);
    try testing.expect(s.flushed(&s.run_queue.items[0]));

    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 1), 0);
    try testing.expectEqual(@as(?i32, 0), (try expectRunDone(&s)).exit_code);
}

test "?2004h-then-done split across reads: request typed in gap is upgraded" {
    // fish emits ?2004h and the hook's first `done` as separate writes; if a
    // queued run is typed after onPrompt but before onDone, it captured
    // expect_preexec=false. Adoption must retroactively arm the acceptance
    // timeout so a continuation-prompt hang is detected.
    var s = try tInit();
    defer s.deinit();

    try s.run(3, "printf %s foo\\", .{}, 0);
    try testing.expect(!s.run_queue.items[0].sent());

    // First read: ?2004h alone → degraded layer, request typed.
    try s.feedPty("\x1b[?2004h", 0);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expect(!s.run_queue.items[0].expect_preexec);
    s.consumeInput(s.pendingInput().len, 0);
    try testing.expect(s.flushed(&s.run_queue.items[0]));

    // Second read: hook's first done → adopts the placeholder.
    var b: [128]u8 = undefined;
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expect(s.state().hooked);
    // Upgraded: the typed line is still in the PTY buffer when precmd runs.
    try testing.expect(s.run_queue.items[0].expect_preexec);

    // No preexec arrives (continuation prompt) → acceptance timeout ^C's it.
    s.tick(std.math.maxInt(i64));
    try testing.expectEqual(.line_rejected, (try expectRunDone(&s)).via);
}

test "tick: first command at a layer uses the higher floor; rejection still widens" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    // First command (no observed RTT): the 1s floor must NOT reject; the
    // 5s first-command floor does.
    try s.run(1, "a", .{}, 0);
    s.consumeInput(s.pendingInput().len, 100);
    s.tick(100 + s.opts.accept_timeout_ns + 50 * std.time.ns_per_ms);
    try expectNoEvents(&s);
    s.tick(100 + s.opts.accept_timeout_first_ns + 50 * std.time.ns_per_ms);
    try testing.expectEqual(.line_rejected, (try expectRunDone(&s)).via);
    s.consumeInput(s.pendingInput().len, 0); // ^C

    // Rejection widened the estimate from the 5s wait → next window is ~15s.
    try testing.expect(s.last_preexec_latency_ns >= s.opts.accept_timeout_first_ns);
    var b: [128]u8 = undefined;
    try s.feedPty(doneOsc(&b, TPID, 130, "/", 0), 0); // ^C's precmd
    try s.run(2, "b", .{}, 0);
    s.consumeInput(s.pendingInput().len, 200);
    s.tick(200 + s.opts.accept_timeout_first_ns + 50 * std.time.ns_per_ms);
    try expectNoEvents(&s);
}

test "tick: acceptance window adapts to observed preexec latency" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First command: flush at t=0, preexec at t=800ms → 800ms RTT recorded.
    try s.run(1, "a", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 800 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, 800 * std.time.ns_per_ms), s.last_preexec_latency_ns);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 1), 0);
    _ = s.drainEvents();

    // Second command: window is now max(1s, 3 × 800ms) = 2.4s.
    try s.run(2, "b", .{}, 0);
    s.consumeInput(s.pendingInput().len, 1000);
    const window = s.acceptanceWindow();
    try testing.expect(window > s.opts.accept_timeout_ns);
    // Past the 1s floor but inside the adaptive window: must NOT reject.
    s.tick(1000 + s.opts.accept_timeout_ns + 200 * std.time.ns_per_ms);
    try expectNoEvents(&s);
    // Past the adaptive window: rejects.
    s.tick(1000 + window + 100 * std.time.ns_per_ms);
    try testing.expectEqual(.line_rejected, (try expectRunDone(&s)).via);
}

test "tick: warn for request queued behind a running command; never hard-fail" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First request: typed and accepted; runs indefinitely (e.g. ssh with no
    // remote announce → cmd_running stays true, no `done` ever arrives).
    try s.run(1, "ssh remote", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try testing.expect(s.state().cmd_running);

    // Second request: blocked on cmd_running.
    try s.run(2, "ls", .{}, 0);
    try testing.expect(!s.run_queue.items[1].sent());
    const t0 = s.run_queue.items[1].ts_ns;

    // Before 5s: silent.
    s.tick(t0 + 2 * std.time.ns_per_s);
    try expectNoEvents(&s);
    // At 5s: warn fires for cookie 2 (not 1 — front is sent).
    s.tick(t0 + 6 * std.time.ns_per_s);
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(@as(u32, 2), evs[0].warn.cookie);
    // One-shot.
    s.tick(t0 + 7 * std.time.ns_per_s);
    try expectNoEvents(&s);
    // No hard timeout even past 60s — previous command may run for hours.
    s.tick(t0 + 90 * std.time.ns_per_s);
    try expectNoEvents(&s);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
}

// ───────── hook install state machine ─────────

test "startHook queues probe and arms" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try testing.expectEqual(@as(?[]const u8, null), try s.installHook(7, 0));
    try testing.expectEqual(.hook_probe, s.hookRequest().?.kind);
    try testing.expect(std.mem.indexOf(u8, s.pendingInput(), "$__ZMYTH_HOOK_V") != null);
    try expectNoEvents(&s);
}

test "startHook refused: alt-screen / run in flight / concurrent" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    try s.feedPty("\x1b[?1049h", 0);
    try testing.expect((try s.installHook(1, 0)) != null);
    try s.feedPty("\x1b[?1049l", 0);

    try s.run(1, "x", .{}, 0);
    try testing.expect((try s.installHook(1, 0)) != null);
    s.cancel(1);
    s.consumeInput(s.pendingInput().len, 0);
    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
    _ = s.drainEvents();

    try testing.expectEqual(@as(?[]const u8, null), try s.installHook(1, 0));
    try testing.expect((try s.installHook(2, 0)) != null);
}

test "hook: probe reports already hooked → no install typed" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.installHook(7, 0);
    s.consumeInput(s.pendingInput().len, 0);
    var b: [128]u8 = undefined;
    // Local hooked layer brackets the probe with preexec/done; the probe OSC
    // arrives between them. The probe request is `accepted`, so finishProbe
    // is deferred until the bracketing `done`.
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(std.fmt.bufPrint(
        &b,
        "\x1b]2718;probe;b=5.2,z=,f=,h={d}\x07",
        .{shell.hook_version},
    ) catch unreachable, 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);

    const hd = try expectHookDone(&s);
    try testing.expectEqual(@as(u32, 7), hd.cookie);
    try testing.expectEqual(shell.hook_version, hd.result.already_hooked);
    try testing.expect(s.hookRequest() == null);
    // No install was typed.
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);
    try testing.expectEqual(@as(?i32, 0), s.last_exit);
}

test "hook: probe → install → done completes" {
    var s = try tInit();
    defer s.deinit();
    // Nested-shell scenario: outer layer is *not* the one being hooked, so
    // simulate by going straight to a degraded prompt (no local hook).
    try s.feedPty("\x1b[?2004h", 0);

    _ = try s.installHook(9, 0);
    s.consumeInput(s.pendingInput().len, 0);
    // Remote (unhooked) shell emits probe OSC, no preexec/done bracket.
    try s.feedPty("\x1b]2718;probe;b=,z=5.9,f=,h=\x07", 0);
    try testing.expectEqual(.hook_install, s.hookRequest().?.kind);
    // Install was queued: paste + body in one go.
    const inp = s.pendingInput();
    try testing.expect(std.mem.indexOf(u8, inp, "head -c ") != null);
    try testing.expect(std.mem.indexOf(u8, inp, "${ZDOTDIR:-$HOME}/.zshrc") != null);
    try testing.expect(std.mem.endsWith(u8, inp, shell.hookBody(.zsh)));
    s.consumeInput(inp.len, 0);

    // Newly-hooked layer reaches its first prompt → first done (tagged zsh).
    try s.feedPty("\x1b]2718;done;555;0;0;z;/home/u\x07", 0);
    const hd = try expectHookDone(&s);
    try testing.expectEqual(@as(u32, 9), hd.cookie);
    try testing.expectEqual(protocol.Shell.zsh, hd.result.installed);
    try testing.expect(s.hookRequest() == null);
    try testing.expect(s.state().hooked);
    try testing.expectEqualStrings("/home/u", s.state().cwd);
    // drainEvents is one-shot.
    try expectNoEvents(&s);
}

test "hook: probe says unknown shell → err, no install" {
    var s = try tInit();
    defer s.deinit();
    try s.feedPty("\x1b[?2004h", 0);
    _ = try s.installHook(1, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty("\x1b]2718;probe;b=,z=,f=,h=\x07", 0);
    try testing.expect((try expectHookDone(&s)).result == .err);
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);
}

test "hook: bash <4 → err" {
    var s = try tInit();
    defer s.deinit();
    try s.feedPty("\x1b[?2004h", 0);
    _ = try s.installHook(1, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty("\x1b]2718;probe;b=3.2.57(1)-release,z=,f=,h=\x07", 0);
    try testing.expect((try expectHookDone(&s)).result == .err);
}

test "hook: probe in stale-hooked layer (exec'd to non-shell) → deadline, not ^C" {
    // Layer believes it's hooked, but the shell exec'd into something else.
    // Probe gets no preexec. tickAcceptance must NOT fire (would mis-route to
    // .run_done); tickDeadlines handles it.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    s.last_preexec_latency_ns = 1; // tiny → acceptance window = opts.accept_timeout_ns

    _ = try s.installHook(7, 0);
    s.consumeInput(s.pendingInput().len, 1);
    try testing.expect(s.hookRequest().?.expect_preexec); // typed into "hooked" layer

    s.tick(60 * std.time.ns_per_s);
    // hook_done(.err), NOT run_done(.line_rejected).
    try testing.expect((try expectHookDone(&s)).result == .err);
}

test "hook: probe timeout" {
    var s = try tInit();
    defer s.deinit();
    try s.feedPty("\x1b[?2004h", 0);
    _ = try s.installHook(1, 0);
    s.tick(std.time.ns_per_s); // before deadline
    try testing.expect(s.hookRequest() != null);
    s.tick(10 * std.time.ns_per_s);
    try testing.expect((try expectHookDone(&s)).result == .err);
    try testing.expect(s.hookRequest() == null);
}

test "hook: install bracketed by outer's preexec/done completes" {
    // Hooking the current (already-hooked) shell — e.g. upgrading from hook
    // v1 to v2. The install is a normal command from the outer's POV.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    _ = try s.installHook(3, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty("\x1b]2718;probe;b=5.2,z=,f=,h=1\x07", 0); // stale v1
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
    try testing.expectEqual(.hook_install, s.hookRequest().?.kind);
    s.consumeInput(s.pendingInput().len, 0);

    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
    try testing.expectEqual(protocol.Shell.bash, (try expectHookDone(&s)).result.installed);
    try testing.expect(s.hookRequest() == null);
}

test "queueRun while hook in flight defers typing" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.installHook(1, 0);
    s.consumeInput(s.pendingInput().len, 0);
    // run arrives mid-probe: must NOT be typed (probe occupies the slot).
    try s.run(2, "ls", .{}, 0);
    try testing.expect(!s.run_queue.items[1].sent());
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);

    // Probe says already-hooked → hook completes.
    var b: [128]u8 = undefined;
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(std.fmt.bufPrint(
        &b,
        "\x1b]2718;probe;b=5.2,z=,f=,h={d}\x07",
        .{shell.hook_version},
    ) catch unreachable, 0);
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 0), 0);
    try testing.expect((try expectHookDone(&s)).result == .already_hooked);
    // Now the queued run is typed.
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expectEqual(.user, s.run_queue.items[0].kind);
}

// ───────── PID-stack + run -i ─────────

test "run -i: ?2004h after preexec → at_prompt + degraded layer pushed" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.run(1, "ssh remote", .{ .interactive = true }, 0);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expectEqual(@as(u8, 0), s.run_queue.items[0].layer_depth);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try testing.expect(s.run_queue.items[0].accepted);

    // Remote (unhooked) prompt appears.
    try s.feedPty("\x1b[?2004h", 0);
    const rd = try expectRunDone(&s);
    try testing.expectEqual(.at_prompt, rd.via);
    try testing.expectEqual(@as(?i32, 0), rd.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    // Degraded nested layer pushed.
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 0), s.top().?.pid);
    try testing.expect(!s.state().hooked);

    // A subsequent run types into the new top (depth 1), not the busy outer.
    try s.run(2, "ls", .{}, 0);
    try testing.expect(s.run_queue.items[0].sent());
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[0].layer_depth);
    try testing.expect(!s.run_queue.items[0].expect_preexec);
    // Unhooked top: ?2004h is the completion signal.
    try s.feedPty("\x1b[?2004h", 0);
    try testing.expectEqual(.prompt_fallback, (try expectRunDone(&s)).via);
}

test "run -i: done from new pid → at_prompt + hooked layer pushed" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.run(1, "ssh remote", .{ .interactive = true }, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);

    // Remote has a file-installed hook → first prompt emits done from new pid.
    try s.feedPty(doneOsc(&b, 555, 0, "/home/r", 0), 0);
    try testing.expectEqual(.at_prompt, (try expectRunDone(&s)).via);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 555), s.top().?.pid);
    try testing.expect(s.state().hooked);
    try testing.expectEqualStrings("/home/r", s.state().cwd);

    // Nested run types at depth 1; remote done completes it.
    try s.run(2, "ls", .{}, 0);
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[0].layer_depth);
    try testing.expect(s.run_queue.items[0].expect_preexec);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, 555), 0);
    try s.feedPty(doneOsc(&b, 555, 7, "/home/r", 3), 0);
    const rd2 = try expectRunDone(&s);
    try testing.expectEqual(@as(?i32, 7), rd2.exit_code);
    try testing.expectEqual(.osc_done, rd2.via);
}

test "run -i: command exits without nested prompt → osc_done (not at_prompt)" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    // run -i on a command that just exits (no nested shell).
    try s.run(1, "false", .{ .interactive = true }, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, TPID, 1, "/", 5), 0);
    const rd = try expectRunDone(&s);
    try testing.expectEqual(@as(?i32, 1), rd.exit_code);
    try testing.expectEqual(.osc_done, rd.via);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
}

test "layer pop: done from below-top pid pops + completes dangling run" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.run(1, "ssh remote", .{ .interactive = true }, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty(doneOsc(&b, 555, 0, "/", 0), 0);
    _ = s.drainEvents();
    try testing.expectEqual(@as(u8, 2), s.layers.len);

    // Type into layer 1, accept, but don't complete.
    try s.run(2, "sleep 60", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, 555), 0);
    try testing.expect(s.run_queue.items[0].accepted);

    // ssh exits → layer 0's done. Layer 1 popped; depth-1 run → layer_exited.
    try s.feedPty(doneOsc(&b, TPID, 0, "/", 100), 0);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expectEqual(@as(i32, TPID), s.top().?.pid);
    const rd = try expectRunDone(&s);
    try testing.expectEqual(@as(u32, 2), rd.cookie);
    try testing.expectEqual(.layer_exited, rd.via);
    try testing.expectEqual(@as(?i32, 0), rd.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    try testing.expect(!s.state().cmd_running);
}

test "non-interactive run -- ssh: outer run survives nested layer push/pop" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    // Plain run (NOT -i): blocks until ssh exits.
    try s.run(1, "ssh remote", .{}, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    // Remote hooked → done;555. NOT interactive → does NOT complete the run.
    try s.feedPty(doneOsc(&b, 555, 0, "/", 0), 0);
    try expectNoEvents(&s);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);

    // Another client's run goes into layer 1 (top), even with the depth-0
    // run still pending.
    try s.run(2, "ls", .{}, 0);
    try testing.expect(s.run_queue.items[1].sent());
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[1].layer_depth);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, 555), 0);
    try s.feedPty(doneOsc(&b, 555, 0, "/", 1), 0);
    // Only client 2's run completed; client 1's ssh still running.
    try testing.expectEqual(@as(u32, 2), (try expectRunDone(&s)).cookie);

    // ssh exits → done;100 → pop layer 1, complete client 1's run.
    try s.feedPty(doneOsc(&b, TPID, 5, "/", 999), 0);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    const rd = try expectRunDone(&s);
    try testing.expectEqual(@as(u32, 1), rd.cookie);
    try testing.expectEqual(@as(?i32, 5), rd.exit_code);
    try testing.expectEqual(.osc_done, rd.via);
}

test "degraded-top adoption: run -i ?2004h then hook installs → same layer" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.run(1, "ssh remote", .{ .interactive = true }, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty(preexecOsc(&b, TPID), 0);
    try s.feedPty("\x1b[?2004h", 0); // run -i completes, push degraded
    _ = s.drainEvents();
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 0), s.top().?.pid);

    // Now `zmyth hook` installs into the degraded top.
    _ = try s.installHook(2, 0);
    s.consumeInput(s.pendingInput().len, 0);
    try s.feedPty("\x1b]2718;probe;b=5.2,z=,f=,h=\x07", 0);
    s.consumeInput(s.pendingInput().len, 0);
    // Newly-hooked layer's first done: pid 555. Adopted into the placeholder,
    // NOT stacked on top of it.
    try s.feedPty(doneOsc(&b, 555, 0, "/", 0), 0);
    try testing.expectEqual(protocol.Shell.bash, (try expectHookDone(&s)).result.installed);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 555), s.top().?.pid);
    try testing.expect(s.state().hooked);
}

test "headless: terminal query gets a response" {
    // An app inside the session sends DSR (cursor position). With no attach
    // client, ghostty's shadow terminal is the only thing that can answer —
    // and it knows the cursor position. The response should land in pty_input
    // so the app reads it from stdin.
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    // Put the cursor somewhere known, then query it.
    try s.feedPty("\x1b[5;7H", 0); // CUP to row 5, col 7
    try s.feedPty("\x1b[6n", 0); // DSR: report cursor position
    try testing.expectEqualStrings("\x1b[5;7R", s.pendingInput());
    s.consumeInput(s.pendingInput().len, 0);

    // DA1 (primary device attributes) — apps like nvim send this at startup.
    try s.feedPty("\x1b[c", 0);
    try testing.expect(std.mem.startsWith(u8, s.pendingInput(), "\x1b[?"));
    s.consumeInput(s.pendingInput().len, 0);

    // DECRQM (request mode state) for bracketed-paste.
    try s.feedPty("\x1b[?2004$p", 0);
    // Response: CSI ? 2004 ; <0|1|2> $ y
    try testing.expect(std.mem.startsWith(u8, s.pendingInput(), "\x1b[?2004;"));
}

test "ghostty answers queries only when there's no leader" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    s.has_leader = true;
    try s.feedPty("\x1b[6n", 0);
    try testing.expectEqual(@as(usize, 0), s.pendingInput().len);

    s.has_leader = false;
    try s.feedPty("\x1b[6n", 0);
    try testing.expect(s.pendingInput().len > 0);
}

test "headless: XTWINOPS, color-scheme, XTVERSION are answered" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    // CSI 18 t → CSI 8;rows;cols t
    try s.feedPty("\x1b[18t", 0);
    try testing.expect(std.mem.indexOf(u8, s.pendingInput(), "\x1b[8;24;80t") != null);
    s.consumeInput(s.pendingInput().len, 0);

    // DSR ?996 n (color scheme) → CSI ? 997 ; 1|2 n
    try s.feedPty("\x1b[?996n", 0);
    try testing.expect(std.mem.indexOf(u8, s.pendingInput(), "\x1b[?997;") != null);
    s.consumeInput(s.pendingInput().len, 0);

    // XTVERSION → DCS > | zmyth ST
    try s.feedPty("\x1b[>0q", 0);
    try testing.expect(std.mem.indexOf(u8, s.pendingInput(), "zmyth") != null);
}

test "OSC 7 updates lastCwd in unhooked session" {
    var s = try tInit();
    defer s.deinit();
    // Degraded (unhooked) session: our `done` OSC never arrives, but the
    // shell's own OSC 7 does.
    try s.feedPty("\x1b[?2004h", 0);
    try testing.expectEqualStrings("", s.state().cwd);
    try s.feedPty("\x1b]7;file://host/home/u\x07", 0);
    try testing.expectEqualStrings("/home/u", s.state().cwd);
}

test "OSC 133;D updates last_exit and completes degraded run" {
    var s = try tInit();
    defer s.deinit();
    try s.feedPty("\x1b[?2004h", 0);
    try s.run(1, "false", .{}, 0);
    try testing.expect(s.run_queue.items[0].sent());
    // Shell with starship/omp emits 133;D;<ec> then ?2004h. Degraded `run`
    // currently completes via .prompt_fallback with ec=null; with 133;D it
    // should report the real exit code.
    try s.feedPty("\x1b]133;D;1\x07\x1b[?2004h", 0);
    try testing.expectEqual(@as(?i32, 1), (try expectRunDone(&s)).exit_code);
    try testing.expectEqual(@as(?i32, 1), s.state().last_exit);
}

test "ghostty-tracked state: title, mouse, osc133" {
    var s = try tInit();
    defer s.deinit();

    try testing.expect(s.state().title == null);
    try testing.expect(!s.state().mouse_tracking);
    try testing.expect(!s.state().osc133_seen);

    try s.feedPty("\x1b]2;running vim\x07", 0); // OSC 2 set title
    try testing.expectEqualStrings("running vim", s.state().title.?);

    try s.feedPty("\x1b[?1002h", 0); // mouse button-event tracking
    try testing.expect(s.state().mouse_tracking);
    try s.feedPty("\x1b[?1002l", 0);
    try testing.expect(!s.state().mouse_tracking);

    try s.feedPty("\x1b]133;A\x07", 0); // OSC 133 prompt-start
    try testing.expect(s.state().osc133_seen);
}

test "max_layers overflow: top replaced, no panic" {
    var s = try tInit();
    defer s.deinit();
    var b: [128]u8 = undefined;
    var pid: i32 = 100;
    while (pid < 100 + max_layers + 3) : (pid += 1) {
        try s.feedPty(doneOsc(&b, pid, 0, "/", 0), 0);
    }
    try testing.expectEqual(@as(u8, max_layers), s.layers.len);
}

test "cancelClientHook clears pending for that client only" {
    var s = try tInit();
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.installHook(7, 0);
    try testing.expect(s.hookRequest() != null);
    s.cancel(99); // wrong client
    try testing.expect(s.hookRequest() != null);
    s.cancel(7);
    try testing.expect(s.hookRequest() == null);
    // New hook can start immediately.
    s.consumeInput(s.pendingInput().len, 0);
    try testing.expectEqual(@as(?[]const u8, null), try s.installHook(8, 0));
}

test "tick: prompt-wait warn at 5s, timeout at 30s; none once a layer exists" {
    var s = try tInit();
    defer s.deinit();
    // No done/?2004h yet — shell is "starting".
    try s.run(7, "echo hi", .{}, 0);
    const t0 = s.run_queue.items[0].ts_ns;
    try testing.expect(!s.run_queue.items[0].sent());

    s.tick(t0 + 1 * std.time.ns_per_s);
    try expectNoEvents(&s);
    s.tick(t0 + 6 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 7), s.drainEvents()[0].warn.cookie);
    // Warn fires once.
    s.tick(t0 + 7 * std.time.ns_per_s);
    try expectNoEvents(&s);
    // Hard timeout: warn(reason) + run_done(prompt_fallback).
    s.tick(t0 + 31 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    const evs = s.drainEvents();
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expect(evs[0] == .warn);
    try testing.expectEqual(.prompt_fallback, evs[1].run_done.via);

    // Once the prompt-ready signal arrives, no more warns/timeouts.
    try s.feedPty("\x1b[?2004h", 0);
    try s.run(8, "echo hi", .{}, 0);
    s.tick(s.opts.prompt_timeout_ns - 1);
    try expectNoEvents(&s);
}
