//! Daemon-side session: owns the ghostty Terminal, the protocol Scanner, and
//! the shell-integration state machine.
//!
//! Pure logic — no fds, no socket I/O. The daemon poll loop reads from the PTY
//! master and calls `feedPtyOutput()`; it drains `pendingPtyInput()` to write
//! back to the PTY master; it reads `completions()` to reply to clients.

const std = @import("std");
const assert = std.debug.assert;
const vt = @import("ghostty-vt");
const protocol = @import("protocol.zig");
const shell = @import("shell.zig");

/// Floor for the line-acceptance window: nanoseconds the daemon waits, after
/// typing a `run` command, for any acceptance signal (preexec/done/prompt).
/// Past this, the shell is assumed to be at a continuation prompt and the line
/// is rejected with ^C. See repros/poc-hooks/RESULTS.md "incomplete input".
///
/// The actual window is `max(this, 3 * last_preexec_latency_ns)`: a nested
/// hooked shell over SSH can need a full network RTT for the preexec OSC, so
/// the floor alone would spuriously ^C every command on a slow link. 1s is
/// generous for the local continuation-prompt case this was built for while
/// giving margin to sluggish PTYs.
const ACCEPT_TIMEOUT_NS: i128 = 1000 * std.time.ns_per_ms;

/// `ReadonlyStream` is not re-exported from lib_vt; derive it.
const VtStream = @TypeOf(@as(*vt.Terminal, undefined).vtStream());
const VtHandler = VtStream.Handler;
// `device_attributes.Attributes` isn't re-exported from lib_vt; derive it from
// the callback's return type (`?*const fn(*Handler) Attributes`).
const VtAttrs = @typeInfo(@typeInfo(
    @typeInfo(@FieldType(VtHandler.Effects, "device_attributes")).optional.child,
).pointer.child).@"fn".return_type.?;

// The handler→stream→session `@fieldParentPtr` chain below is sound only
// while ghostty's `Stream` holds its handler by value. Guard at comptime so
// a future ghostty change to `*Handler` fails loudly here, not as UB.
comptime {
    assert(@FieldType(VtStream, "handler") == VtHandler);
}

/// `Effects.write_pty`: ghostty has computed a response to a terminal query
/// (DSR `\e[6n`, DECRQM, DA, …) the inner app emitted. With no attach client
/// the app would otherwise wait on its query timeout, since nothing else can
/// answer; queue ghostty's response to its stdin. With a client attached, the
/// real terminal answers via passthrough — stay silent so the app doesn't see
/// two replies.
fn vtWritePty(h: *VtHandler, data: [:0]const u8) void {
    const stream: *VtStream = @alignCast(@fieldParentPtr("handler", h));
    const sess: *Session = @alignCast(@fieldParentPtr("stream", stream));
    if (sess.attached_clients > 0) return;
    // OOM: drop the reply; the app will time out as it would have anyway.
    sess.pty_input.appendSlice(sess.gpa, data) catch return;
}

/// `Effects.device_attributes`: what to report for DA1/2/3. Default = VT220
/// with ANSI colour — conservative enough that apps won't try features the
/// eventual real terminal might lack.
fn vtDeviceAttrs(_: *VtHandler) VtAttrs {
    return .{};
}

const RunCompletion = struct {
    /// null when no exit code is knowable (prompt-fallback / line-rejected).
    exit_code: ?i32,
    via: @import("ipc.zig").RunDoneWire.Via,
    dur_ms: u64,
};

const Completion = struct {
    client_id: u32,
    result: RunCompletion,
};

/// One pending `zmx run` request.
const RunRequest = struct {
    /// Owned by Session.
    cmd: []u8,
    /// Opaque; daemon maps it back to a socket.
    client_id: u32,
    /// `run -i`: complete on the first nested-prompt signal (new-pid `done`
    /// or post-preexec `?2004h`) instead of waiting for this layer's `done`.
    interactive: bool,
    /// nanoTimestamp when queued (for the prompt-wait timeout).
    queued_ns: i128,
    /// Bytes queued into pty_input?
    sent: bool = false,
    /// preexec OSC seen?
    accepted: bool = false,
    /// 5s prompt-wait warning already sent to this client?
    warned: bool = false,
    /// `layers.len - 1` at type time: which layer this was typed into.
    layer_depth: u8 = 0,
    /// Captured at type time: was that layer hooked? (i.e., is a preexec
    /// expected, so absence-of-preexec means continuation prompt → ^C.)
    expect_preexec: bool = false,
    /// nanoTimestamp when typed.
    started_ns: i128 = 0,
    /// nanoTimestamp when pty_input drained to empty after typing (i.e. the
    /// bytes have actually hit the PTY). 0 = not yet. Acceptance timeout is
    /// measured from here, not started_ns.
    flushed_ns: i128 = 0,
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

pub const PromptWait = union(enum) {
    none,
    /// Front request has waited >5s for the first prompt-ready signal.
    warn: u32, // client_id
    /// Front request has waited >30s; daemon should send an explanatory
    /// `.err` to this client (the request has already been completed with
    /// `.prompt_fallback`/null and removed from the queue).
    timeout: u32, // client_id
};

/// In-flight `zmyth hook` install.
const HookPending = struct {
    client_id: u32,
    phase: enum { probing, installing },
    deadline_ns: i128,
    /// Count of preexec/done events to swallow before the install's own
    /// `done` is the one we're waiting for. When the probe runs in an
    /// already-hooked outer shell, that shell's preexec/done bracket it;
    /// when not hooked (the nested case), nothing brackets it.
    echo_swallow: u8 = 0,
};

pub const HookResult = union(enum) {
    /// Hook was already active in the target shell at this version.
    already_hooked: u32,
    /// Install completed; this is the shell that was hooked.
    installed: protocol.Shell,
    /// Static error string for the client.
    err: []const u8,
};

pub const HookCompletion = struct {
    client_id: u32,
    result: HookResult,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    /// Self-referential: `stream.handler.terminal` must point at `self.term`.
    /// Since Session is returned by value from init(), the pointer is fixed up
    /// at the top of every method that touches the stream.
    stream: VtStream,
    scanner: protocol.Scanner,

    /// Nested-shell stack. Empty until the first `done`/`?2004h`.
    layers: Layers = .{},

    /// At least one `?2004h` seen → degraded "back at prompt" detection works.
    seen_prompt: bool = false,
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

    /// Number of `.attach`ed clients whose write backlog is under the demote
    /// threshold — i.e., clients whose real terminal can plausibly answer a
    /// DSR/DA query via passthrough. Recomputed by the daemon before each
    /// `feedPtyOutput`. When zero, ghostty's shadow terminal answers on the
    /// app's behalf (`vtWritePty`); when nonzero, ghostty stays silent so the
    /// app doesn't see two replies. A stalled attach (half-open SSH) doesn't
    /// count, since it can't relay the query.
    attached_clients: u32 = 0,

    /// In-flight `zmyth hook` install (probe → install → wait for done).
    hook_pending: ?HookPending = null,
    hook_completed: ?HookCompletion = null,

    // I/O queues — daemon drains/fills these.
    /// Bytes to write to PTY master.
    pty_input: std.ArrayList(u8),
    run_queue: std.ArrayList(RunRequest),
    completed: std.ArrayList(Completion),
    /// Scratch reused across feedPtyOutput calls.
    events: std.ArrayList(protocol.Event),

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Session {
        var term = try vt.Terminal.init(allocator, .{
            .cols = @max(1, cols),
            .rows = @max(1, rows),
        });
        errdefer term.deinit(allocator);

        return .{
            .gpa = allocator,
            .term = term,
            // Handler pointer is patched at the top of feedPtyOutput().
            .stream = VtStream.initAlloc(allocator, .{ .terminal = undefined }),
            .scanner = protocol.Scanner.init(allocator),
            .pty_input = .empty,
            .run_queue = .empty,
            .completed = .empty,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.stream.deinit();
        self.term.deinit(self.gpa);
        self.scanner.deinit();
        self.pty_input.deinit(self.gpa);
        for (self.run_queue.items) |*r| self.gpa.free(r.cmd);
        self.run_queue.deinit(self.gpa);
        self.completed.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.* = undefined;
    }

    /// Feed bytes read from PTY master. Updates the Terminal, runs the
    /// Scanner, and processes events: preexec → mark accepted, done → complete
    /// front run request (or push a new layer), prompt → fallback-complete when
    /// not hooked. May queue bytes into pty_input (next queued command) and
    /// append to completions.
    pub fn feedPtyOutput(self: *Session, bytes: []const u8) !void {
        // `.terminal` must be patched here (self-referential; Session is
        // returned by value from init). The effects pointers are not
        // self-referential and could go in init(), but Effects has no
        // per-field defaults so naming every callback there is noisier than
        // two stores here.
        self.stream.handler.terminal = &self.term;
        self.stream.handler.effects.write_pty = &vtWritePty;
        self.stream.handler.effects.device_attributes = &vtDeviceAttrs;
        self.stream.nextSlice(bytes);

        self.events.clearRetainingCapacity();
        try self.scanner.feed(bytes, &self.events);

        for (self.events.items) |ev| switch (ev) {
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

        // Type the next queued request only after all events from this chunk
        // are processed, so a trailing event in the same chunk can't be
        // misattributed to a request we haven't actually written yet.
        try self.tryTypeNext();
    }

    /// Queue a `zmx run` request. If the top layer is idle, types it
    /// immediately; otherwise it waits for the next done/prompt.
    pub fn queueRun(self: *Session, client_id: u32, cmd: []const u8, interactive: bool) !void {
        const owned = try self.gpa.dupe(u8, cmd);
        errdefer self.gpa.free(owned);
        try self.run_queue.append(self.gpa, .{
            .cmd = owned,
            .client_id = client_id,
            .interactive = interactive,
            .queued_ns = std.time.nanoTimestamp(),
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
                if (r.sent and r.layer_depth == gone) {
                    const req = self.run_queue.orderedRemove(i);
                    try self.complete(req, .{
                        .exit_code = ec,
                        .via = .layer_exited,
                        .dur_ms = msSince(req.started_ns, std.time.nanoTimestamp()),
                    });
                } else i += 1;
            }
        }
    }

    fn onPreexec(self: *Session, pid: i32) void {
        const depth: u8 = self.findLayer(pid) orelse blk: {
            _ = self.pushLayer(.{ .pid = pid, .hooked = true });
            break :blk self.topDepth();
        };
        const layer = &self.layers.buffer[depth];
        layer.cmd_running = true;
        if (self.hook_pending) |*hp| {
            hp.echo_swallow +|= 1;
            return;
        }
        if (self.sentAt(depth)) |r| {
            if (r.flushed_ns != 0) {
                self.last_preexec_latency_ns = std.time.nanoTimestamp() - r.flushed_ns;
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

        if (self.hook_pending) |*hp| {
            if (hp.echo_swallow > 0) {
                hp.echo_swallow -= 1;
                return;
            }
            // The freshly-hooked layer's first `done` has no paired preexec
            // (the hook arms preexec only after the first prompt), so it
            // arrives here with echo_swallow==0. This holds whether the
            // layer is a new pid (ssh, subshell) or the same pid (`exec
            // bash`). The one false positive — an outer layer's `done`
            // landing in the <1s install window (e.g. ssh dropping mid-
            // install) — is rare and benign: the file was written, only the
            // "installed" message is optimistic.
            if (hp.phase == .installing) {
                self.completeHook(.{ .installed = layer.shell });
                return;
            }
            // .probing: let normal routing handle it.
        }
        // A NEW layer's first `done` is its first-prompt precmd, not a command
        // completion. It may complete a pending `run -i` one level down.
        if (is_new) {
            // A request typed into this layer while it was still a degraded
            // placeholder had expect_preexec=false. This `done` is precmd —
            // it runs *before* the prompt reads input — so the typed line is
            // still in the PTY buffer and the now-live hook will bracket it.
            if (self.sentAt(depth)) |r| if (!r.accepted) {
                r.expect_preexec = true;
            };
            if (depth > 0) if (self.sentAt(depth - 1)) |r| if (r.interactive and r.accepted) {
                const req = self.removeReq(r);
                try self.complete(req, .{ .exit_code = 0, .via = .at_prompt, .dur_ms = d.dur_ms });
            };
            return;
        }
        if (self.sentAt(depth)) |r| {
            const req = self.removeReq(r);
            try self.complete(req, .{ .exit_code = d.exit_code, .via = .osc_done, .dur_ms = d.dur_ms });
        }
    }

    fn onPrompt(self: *Session) !void {
        self.seen_prompt = true;
        // First prompt-ready signal ever: establish a degraded base layer.
        if (self.layers.len == 0) {
            _ = self.pushLayer(.{ .pid = 0 });
        }
        const t = self.top().?;
        const depth = self.topDepth();
        if (self.sentAt(depth)) |r| {
            // `run -i`: a prompt appeared after preexec → nested line editor.
            // Push a degraded placeholder for it and complete the request.
            if (r.interactive and r.accepted) {
                const req = self.removeReq(r);
                _ = self.pushLayer(.{ .pid = 0 });
                try self.complete(req, .{
                    .exit_code = 0,
                    .via = .at_prompt,
                    .dur_ms = msSince(req.started_ns, std.time.nanoTimestamp()),
                });
                return;
            }
            // Unhooked top: ?2004h is the only "back at prompt" signal. If the
            // shell emitted OSC 133;D (starship/omp do) we have a real exit
            // code; otherwise null.
            if (!t.hooked) {
                const req = self.removeReq(r);
                const ec = self.osc133_exit;
                self.osc133_exit = null;
                try self.complete(req, .{
                    .exit_code = ec,
                    .via = .prompt_fallback,
                    .dur_ms = msSince(req.started_ns, std.time.nanoTimestamp()),
                });
            }
        }
    }

    /// First sent-but-not-completed request typed at `depth`.
    fn sentAt(self: *Session, depth: u8) ?*RunRequest {
        for (self.run_queue.items) |*r| {
            if (r.sent and r.layer_depth == depth) return r;
        }
        return null;
    }

    fn removeReq(self: *Session, r: *RunRequest) RunRequest {
        const idx = (@intFromPtr(r) - @intFromPtr(self.run_queue.items.ptr)) / @sizeOf(RunRequest);
        return self.run_queue.orderedRemove(idx);
    }

    // ───────────────────── top-layer accessors (for daemon.zig) ─────────────

    pub fn topShell(self: *Session) protocol.Shell {
        // Prefer the deepest layer that knows its shell (a degraded top hides
        // the hooked layer beneath it otherwise).
        var i: usize = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.buffer[i].shell != .unknown) return self.layers.buffer[i].shell;
        }
        return .unknown;
    }
    pub fn topHooked(self: *Session) bool {
        return if (self.top()) |t| t.hooked else false;
    }
    pub fn topCmdRunning(self: *Session) bool {
        return if (self.top()) |t| t.cmd_running else false;
    }

    /// Drop the in-flight hook install if `client_id` owns it. The probe (and
    /// possibly install) bytes already typed can't be recalled, but clearing
    /// the pending state lets a new `.hook` proceed without waiting out the
    /// timeout, and stops the orphaned completion from being routed nowhere.
    pub fn cancelClientHook(self: *Session, client_id: u32) void {
        if (self.hook_pending) |hp| if (hp.client_id == client_id) {
            self.hook_pending = null;
        };
        if (self.hook_completed) |hc| if (hc.client_id == client_id) {
            self.hook_completed = null;
        };
    }

    /// Drop any not-yet-typed run requests from `client_id`. Requests already
    /// typed into the PTY can't be recalled and will complete (and be dropped
    /// at routing time when the client is gone).
    pub fn cancelClientRuns(self: *Session, client_id: u32) void {
        var i: usize = 0;
        while (i < self.run_queue.items.len) {
            const r = &self.run_queue.items[i];
            if (r.client_id == client_id and !r.sent) {
                self.gpa.free(r.cmd);
                _ = self.run_queue.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Max bytes buffered for the PTY master before further input is dropped.
    /// The PTY's kernel buffer is a few KB; if we've queued megabytes the
    /// shell is wedged and accepting more would only OOM the daemon.
    pub const pty_input_cap = 1 * 1024 * 1024;

    /// Queue raw bytes to PTY (zmx send). No waiting, no wrapping.
    pub fn queueSend(self: *Session, bytes: []const u8) !void {
        if (self.pty_input.items.len + bytes.len > pty_input_cap)
            return error.PtyInputOverflow;
        try self.pty_input.appendSlice(self.gpa, bytes);
    }

    /// Bytes the daemon should write to the PTY master.
    pub fn pendingPtyInput(self: *Session) []const u8 {
        return self.pty_input.items;
    }

    /// Discard the first `n` bytes of pending PTY input (after a successful
    /// write to the master).
    pub fn consumePtyInput(self: *Session, n: usize) void {
        assert(n <= self.pty_input.items.len);
        const rem = self.pty_input.items.len - n;
        std.mem.copyForwards(u8, self.pty_input.items[0..rem], self.pty_input.items[n..]);
        self.pty_input.shrinkRetainingCapacity(rem);
        // The acceptance-timeout window opens once the typed bytes have
        // actually reached the PTY. Any sent-but-unflushed request qualifies
        // (with layers there can be at most one — only top accepts typing).
        if (rem == 0) {
            const now = std.time.nanoTimestamp();
            for (self.run_queue.items) |*r| if (r.sent and r.flushed_ns == 0) {
                r.flushed_ns = now;
            };
        }
    }

    /// Completed run requests since the last clearCompletions().
    pub fn completions(self: *Session) []const Completion {
        return self.completed.items;
    }

    pub fn clearCompletions(self: *Session) void {
        self.completed.clearRetainingCapacity();
    }

    /// PTY master hit EOF. Complete every queued request with `.pty_eof`
    /// and the waitpid-derived exit code.
    pub fn onPtyEof(self: *Session, wait_status: u32) void {
        const W = std.posix.W;
        const ec: i32 = if (W.IFEXITED(wait_status))
            @intCast(W.EXITSTATUS(wait_status))
        else if (W.IFSIGNALED(wait_status))
            128 + @as(i32, @intCast(W.TERMSIG(wait_status)))
        else
            -1;
        const now = std.time.nanoTimestamp();
        while (self.run_queue.items.len > 0) {
            const req = self.run_queue.orderedRemove(0);
            self.complete(req, .{
                .exit_code = if (req.sent) ec else null,
                .via = .pty_eof,
                .dur_ms = if (req.sent) msSince(req.started_ns, now) else 0,
            }) catch {};
        }
    }

    /// Called periodically by the daemon (e.g. after poll timeout). If the
    /// front request was typed >ACCEPT_TIMEOUT ago and no acceptance signal
    /// arrived, send ^C and complete with `.line_rejected`. Returns true if
    /// action was taken.
    pub fn checkAcceptanceTimeout(self: *Session, now_ns: i128) bool {
        // Only the top-layer request can be awaiting acceptance.
        const r = self.sentAt(self.topDepth()) orelse return false;
        if (r.accepted) return false;
        // No preexec signal exists when typed into a degraded layer; can't
        // distinguish "running" from "continuation" so don't ^C real commands.
        if (!r.expect_preexec) return false;
        if (r.flushed_ns == 0) return false;
        // Adaptive window: 3x the last observed flush→preexec round-trip,
        // floored at ACCEPT_TIMEOUT_NS. First command after hooking uses the
        // floor (latency is 0); subsequent ones scale to the link.
        const window = @max(ACCEPT_TIMEOUT_NS, 3 * self.last_preexec_latency_ns);
        if (now_ns - r.flushed_ns < window) return false;

        // Shell is at a continuation prompt (unclosed quote, etc.). Abort.
        self.pty_input.append(self.gpa, 0x03) catch {};
        const req = self.removeReq(r);
        self.complete(req, .{
            .exit_code = null,
            .via = .line_rejected,
            .dur_ms = msSince(req.started_ns, now_ns),
        }) catch {};
        return true;
    }

    /// Soft-warn / hard-fail for a queued request that can't be typed. Two
    /// causes: (a) the shell hasn't reached its first prompt yet (slow rc,
    /// nested unrecognized shell) — warns at 5s, hard-fails at 30s; (b) the
    /// request is queued behind a still-running previous command (e.g. front
    /// request is `ssh remote`) — warns at 5s, never hard-fails. Caller should
    /// send an `.err` to the returned client_id. On `.timeout` the request has
    /// already been completed with `.prompt_fallback`/null.
    pub fn checkPromptWait(self: *Session, now_ns: i128) PromptWait {
        const r = self.firstUnsent() orelse return .none;
        const waited = now_ns - r.queued_ns;

        // Hard timeout only applies before the top layer has signalled
        // readiness (hooked or ?2004h). Once ready, an unsent request is
        // queued behind a running command which may legitimately take hours —
        // never fail it, just warn.
        const ready = if (self.top()) |t| (t.hooked or self.seen_prompt) else false;
        if (!ready and waited >= 30 * std.time.ns_per_s) {
            const req = self.removeReq(r);
            const cid = req.client_id;
            self.complete(req, .{
                .exit_code = null,
                .via = .prompt_fallback,
                .dur_ms = msSince(req.queued_ns, now_ns),
            }) catch {};
            return .{ .timeout = cid };
        }
        if (waited >= 5 * std.time.ns_per_s and !r.warned) {
            r.warned = true;
            return .{ .warn = r.client_id };
        }
        return .none;
    }

    pub fn isAltScreen(self: *Session) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// Any mouse-tracking mode is active. A weaker "TUI running" signal than
    /// alt-screen (some prompt frameworks enable click-to-position at the
    /// prompt), so exposed in `ls -j` for visibility but not used as a gate.
    pub fn mouseTracking(self: *Session) bool {
        const m = &self.term.modes;
        return m.get(.mouse_event_x10) or m.get(.mouse_event_normal) or
            m.get(.mouse_event_button) or m.get(.mouse_event_any);
    }

    /// OSC 0/2 window title — already populated by `vtStream()`. Most shells
    /// set this from `$PROMPT_COMMAND`/`precmd`; TUIs set it explicitly.
    pub fn title(self: *const Session) ?[]const u8 {
        return self.term.getTitle();
    }

    /// At least one OSC 133 (FinalTerm/iTerm2 shell-integration) sequence has
    /// been seen. starship/oh-my-posh emit these; useful as a passive
    /// "shell has *some* integration" flag in unhooked sessions.
    //
    pub fn osc133Seen(self: *const Session) bool {
        // Primary screen, not active: OSC 133 is a shell-prompt thing and
        // the shell lives on the primary screen.
        return if (self.term.screens.get(.primary)) |s| s.semantic_prompt.seen else false;
    }

    /// Some typed run is awaiting its acceptance signal (preexec).
    fn pendingAcceptance(self: *Session) bool {
        for (self.run_queue.items) |*r| if (r.sent and !r.accepted) return true;
        return false;
    }

    /// No command running on the top layer and nothing queued — a `wait` can
    /// be answered now.
    pub fn isIdle(self: *Session) bool {
        return !self.topCmdRunning() and self.run_queue.items.len == 0;
    }

    /// Poll loop should use a short timeout instead of blocking: a typed run
    /// is awaiting `preexec` (acceptance window), an untyped one is waiting
    /// for the first prompt (5s/30s warn/fail), or a hook install is pending.
    pub fn needsTimeoutWake(self: *Session) bool {
        if (self.hook_pending != null) return true;
        for (self.run_queue.items) |r| if (!r.sent or !r.accepted) return true;
        return false;
    }

    pub fn resize(self: *Session, rows: u16, cols: u16) !void {
        // ghostty-vt panics on 0 and OOMs on absurd sizes; clamp both ends.
        try self.term.resize(
            self.gpa,
            std.math.clamp(cols, 1, 1000),
            std.math.clamp(rows, 1, 500),
        );
    }

    pub fn lastCwd(self: *const Session) []const u8 {
        return self.last_cwd[0..self.last_cwd_len];
    }

    fn setLastCwd(self: *Session, cwd: []const u8) void {
        const n = @min(cwd.len, self.last_cwd.len);
        @memcpy(self.last_cwd[0..n], cwd[0..n]);
        self.last_cwd_len = n;
    }

    // ───────────────────────── hook install ─────────────────────────

    /// Begin a `zmyth hook` install: queue the probe line and arm the state
    /// machine. Returns a static error string if the session can't accept a
    /// hook install right now (caller sends it as `.err`); null on success.
    pub fn startHook(self: *Session, client_id: u32, now_ns: i128) !?[]const u8 {
        if (self.hook_pending != null)
            return "hook: another install already in progress";
        if (self.isAltScreen())
            return "hook: session is in a full-screen app, not a shell prompt";
        // A just-typed run that hasn't been accepted yet would have its
        // preexec eaten by echo_swallow. The window is milliseconds; refusing
        // is simpler than trying to interleave.
        if (self.pendingAcceptance())
            return "hook: a `run` request is mid-acceptance; retry in a moment";

        const probe = try shell.wrapPaste(self.gpa, shell.probe_line);
        defer self.gpa.free(probe);
        try self.pty_input.appendSlice(self.gpa, probe);

        const window = @max(2 * std.time.ns_per_s, 3 * self.last_preexec_latency_ns);
        self.hook_pending = .{
            .client_id = client_id,
            .phase = .probing,
            .deadline_ns = now_ns + window,
        };
        return null;
    }

    /// Daemon polls this each tick. Non-null exactly once per install.
    pub fn takeHookCompletion(self: *Session) ?HookCompletion {
        defer self.hook_completed = null;
        return self.hook_completed;
    }

    /// Called periodically by the daemon. Times out a stuck probe/install.
    pub fn checkHookTimeout(self: *Session, now_ns: i128) void {
        const hp = self.hook_pending orelse return;
        if (now_ns < hp.deadline_ns) return;
        self.completeHook(.{ .err = switch (hp.phase) {
            .probing => "hook: no response to probe — not at a bash/zsh/fish prompt?",
            .installing => "hook: install did not complete (no prompt after sourcing hook)",
        } });
    }

    fn onProbe(self: *Session, p: protocol.ProbeResult) !void {
        const hp = &(self.hook_pending orelse return);
        if (hp.phase != .probing) return;

        if (p.hook_v >= shell.hook_version)
            return self.completeHook(.{ .already_hooked = p.hook_v });
        if (p.shell == .unknown)
            return self.completeHook(.{ .err = "hook: not bash, zsh, or fish" });
        if (p.shell == .bash and p.shell_major < 4)
            return self.completeHook(.{
                .err = "hook: bash < 4 lacks bracketed-paste; cannot hook",
            });

        const inst = try shell.buildInstall(self.gpa, p.shell);
        defer self.gpa.free(inst);
        try self.pty_input.appendSlice(self.gpa, inst);

        const window = @max(5 * std.time.ns_per_s, 6 * self.last_preexec_latency_ns);
        hp.phase = .installing;
        hp.deadline_ns = std.time.nanoTimestamp() + window;
    }

    fn completeHook(self: *Session, r: HookResult) void {
        const hp = self.hook_pending.?;
        self.hook_completed = .{ .client_id = hp.client_id, .result = r };
        self.hook_pending = null;
        // A run queued during the install can now be typed.
        self.tryTypeNext() catch {};
    }

    // ───────────────────────── internals ─────────────────────────

    fn firstUnsent(self: *Session) ?*RunRequest {
        for (self.run_queue.items) |*r| if (!r.sent) return r;
        return null;
    }

    fn complete(self: *Session, req: RunRequest, result: RunCompletion) !void {
        self.gpa.free(req.cmd);
        try self.completed.append(self.gpa, .{
            .client_id = req.client_id,
            .result = result,
        });
    }

    /// Can a queued command be typed into the top layer right now?
    fn canType(self: *Session) bool {
        if (self.isAltScreen()) return false;
        // Hook install owns the prompt; a `run` typed alongside would have
        // its preexec/done eaten by echo_swallow and then be ^C'd.
        if (self.hook_pending != null) return false;
        // Need at least one layer (done/?2004h has arrived).
        const t = self.top() orelse return false;
        if (t.cmd_running) return false;
        // Degraded layer: need at least one ?2004h.
        if (!t.hooked and !self.seen_prompt) return false;
        // Don't type over an already-in-flight request at this depth.
        if (self.sentAt(self.topDepth()) != null) return false;
        return true;
    }

    fn tryTypeNext(self: *Session) !void {
        const r = self.firstUnsent() orelse return;
        if (!self.canType()) return;
        try self.typeCommand(r);
    }

    /// Ctrl-U, bracketed-paste, cmd, end-paste, CR.
    fn typeCommand(self: *Session, req: *RunRequest) !void {
        try self.pty_input.appendSlice(self.gpa, "\x15\x1b[200~");
        try self.pty_input.appendSlice(self.gpa, req.cmd);
        try self.pty_input.appendSlice(self.gpa, "\x1b[201~\r");
        req.sent = true;
        req.started_ns = std.time.nanoTimestamp();
        req.layer_depth = self.topDepth();
        req.expect_preexec = self.top().?.hooked;
    }

    fn msSince(start_ns: i128, now_ns: i128) u64 {
        const d = now_ns - start_ns;
        if (d <= 0) return 0;
        return @intCast(@divTrunc(d, std.time.ns_per_ms));
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

const TPID: i32 = 100;

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
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));
}

test "first done establishes layer 0: hooked + last_exit + cwd" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    var b: [128]u8 = undefined;
    try s.feedPtyOutput(doneOsc(&b, TPID, 42, "/tmp", 7));

    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expect(s.topHooked());
    try testing.expect(!s.topCmdRunning());
    try testing.expectEqual(@as(?i32, 42), s.last_exit);
    try testing.expectEqualStrings("/tmp", s.lastCwd());
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "queueRun while idle: type, preexec, done -> completion" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "echo hi", false);
    const want = "\x15\x1b[200~echo hi\x1b[201~\r";
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), want));
    try testing.expect(s.run_queue.items[0].sent);

    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try testing.expect(s.topCmdRunning());
    try testing.expect(s.run_queue.items[0].accepted);

    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/tmp", 5));
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expectEqual(@as(?i32, 0), comps[0].result.exit_code);
    try testing.expectEqual(.osc_done, comps[0].result.via);
    try testing.expectEqual(@as(u64, 5), comps[0].result.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "queueRun while busy waits for done" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    try s.queueRun(1, "first", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try testing.expect(s.topCmdRunning());

    // Second request arrives mid-command.
    try s.queueRun(2, "second", false);
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expect(!s.run_queue.items[1].sent);

    // First done -> complete #1 and type #2.
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 1));
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(u32, 1), s.completions()[0].client_id);
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "second\x1b[201~\r"));
    try testing.expect(s.run_queue.items[0].sent);
}

test "prompt-fallback when not hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    // No hook. First ?2004h marks the prompt as ready (degraded path).
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expect(s.seen_prompt);
    try testing.expect(!s.topHooked());

    try s.queueRun(7, "echo hi", false);
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "echo hi\x1b[201~\r"));

    // Shell echoes the command, returns to prompt -> ?2004h again.
    try s.feedPtyOutput("\x1b[?2004h");
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 7), comps[0].client_id);
    try testing.expectEqual(@as(?i32, null), comps[0].result.exit_code);
    try testing.expectEqual(.prompt_fallback, comps[0].result.via);
}

test "prompt ignored when hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "x", false);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    // Hooked: ?2004h is not authoritative, done is.
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    try s.feedPtyOutput(doneOsc(&b, TPID, 3, "/", 1));
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(?i32, 3), s.completions()[0].result.exit_code);
}

test "alt-screen gates typing" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.feedPtyOutput("\x1b[?1049h");
    try testing.expect(s.isAltScreen());

    try s.queueRun(1, "echo hi", false);
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    try testing.expect(!s.run_queue.items[0].sent);

    var b: [128]u8 = undefined;
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b[?1049l");
    try seq.appendSlice(testing.allocator, doneOsc(&b, TPID, 0, "/", 1));
    try s.feedPtyOutput(seq.items);

    try testing.expect(!s.isAltScreen());
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "echo hi\x1b[201~\r"));
    // The done belonged to the TUI's wrapping shell, not our command.
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "checkAcceptanceTimeout sends ^C and rejects" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(9, "echo \"unclosed", false);
    try testing.expect(s.run_queue.items[0].sent);

    // Window doesn't open until bytes hit the PTY.
    try testing.expect(!s.checkAcceptanceTimeout(std.math.maxInt(i64)));

    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    try testing.expect(tf != 0);

    // Not yet.
    try testing.expect(!s.checkAcceptanceTimeout(tf + @divTrunc(ACCEPT_TIMEOUT_NS, 2)));
    try testing.expectEqual(@as(usize, 0), s.completions().len);

    // Past the threshold.
    try testing.expect(s.checkAcceptanceTimeout(tf + ACCEPT_TIMEOUT_NS + 100 * std.time.ns_per_ms));
    try testing.expect(std.mem.endsWith(u8, s.pendingPtyInput(), "\x03"));
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(.line_rejected, comps[0].result.via);
    try testing.expectEqual(@as(?i32, null), comps[0].result.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "checkAcceptanceTimeout disabled when not hooked" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(1, "sleep 5", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expect(!s.checkAcceptanceTimeout(std.math.maxInt(i64)));
}

test "two dones in one chunk don't misattribute" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "a", false);
    try s.queueRun(2, "b", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));

    // One chunk: done(a, ec=7) immediately followed by a stray done(ec=99).
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(testing.allocator);
    try chunk.appendSlice(testing.allocator, doneOsc(&b, TPID, 7, "/", 1));
    try chunk.appendSlice(testing.allocator, doneOsc(&b, TPID, 99, "/", 1));
    try s.feedPtyOutput(chunk.items);

    // Only req#1 completed; req#2 was typed at end-of-chunk, NOT completed.
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expectEqual(@as(?i32, 7), comps[0].result.exit_code);
    try testing.expect(s.run_queue.items.len == 1 and s.run_queue.items[0].sent);
}

test "checkAcceptanceTimeout ignored once accepted" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "sleep 10", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));

    try testing.expect(!s.checkAcceptanceTimeout(tf + 10 * std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

test "onPtyEof completes all queued" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "exec true", false);
    try s.queueRun(2, "never runs", false);
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);

    // Exit code 5 in the high byte of wait status.
    s.onPtyEof(5 << 8);
    const comps = s.completions();
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqual(@as(u32, 1), comps[0].client_id);
    try testing.expectEqual(.pty_eof, comps[0].result.via);
    try testing.expectEqual(@as(?i32, 5), comps[0].result.exit_code);
    // Never-sent request: no exit code, zero duration.
    try testing.expectEqual(@as(u32, 2), comps[1].client_id);
    try testing.expectEqual(@as(?i32, null), comps[1].result.exit_code);
    try testing.expectEqual(@as(u64, 0), comps[1].result.dur_ms);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
}

test "resize clamps zero" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.resize(0, 0);
    try testing.expect(s.term.screens.active.pages.rows >= 1);
    try testing.expect(s.term.screens.active.pages.cols >= 1);
}

test "queueSend is raw passthrough" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.queueSend("jk\x1b");
    try testing.expectEqualStrings("jk\x1b", s.pendingPtyInput());
    s.consumePtyInput(2);
    try testing.expectEqualStrings("\x1b", s.pendingPtyInput());
}

test "resize clamps absurd dimensions" {
    var s = try Session.init(testing.allocator, 24, 80);
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
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    const big = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try s.queueRun(1, big, false);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expect(s.pendingPtyInput().len > Session.pty_input_cap);
    // cmd slice is the duped copy, distinct from `big`.
    try testing.expect(s.run_queue.items[0].cmd.ptr != big.ptr);
}

test "cancelClientRuns drops only unsent for that client" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.queueRun(1, "a", false); // typed immediately (idle, hooked)
    try s.queueRun(2, "b", false); // queued, unsent
    try s.queueRun(1, "c", false); // queued, unsent
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expect(!s.run_queue.items[1].sent);
    try testing.expect(!s.run_queue.items[2].sent);

    s.cancelClientRuns(1);

    // "a" is already in the PTY and can't be recalled; "c" is dropped; "b"
    // (different client) survives.
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expectEqualStrings("a", s.run_queue.items[0].cmd);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expectEqualStrings("b", s.run_queue.items[1].cmd);
    try testing.expectEqual(@as(u32, 2), s.run_queue.items[1].client_id);
}

test "?2004h-then-done split across reads: request typed in gap is upgraded" {
    // fish emits ?2004h and the hook's first `done` as separate writes; if a
    // queued run is typed after onPrompt but before onDone, it captured
    // expect_preexec=false. Adoption must retroactively arm the acceptance
    // timeout so a continuation-prompt hang is detected.
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    try s.queueRun(3, "printf %s foo\\", false);
    try testing.expect(!s.run_queue.items[0].sent);

    // First read: ?2004h alone → degraded layer, request typed.
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expect(!s.run_queue.items[0].expect_preexec);
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expect(s.run_queue.items[0].flushed_ns != 0);

    // Second read: hook's first done → adopts the placeholder.
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expect(s.topHooked());
    // Upgraded: the typed line is still in the PTY buffer when precmd runs.
    try testing.expect(s.run_queue.items[0].expect_preexec);

    // No preexec arrives (continuation prompt) → acceptance timeout ^C's it.
    try testing.expect(s.checkAcceptanceTimeout(std.math.maxInt(i64)));
    try testing.expectEqual(.line_rejected, s.completions()[0].result.via);
}

test "acceptance timeout adapts to observed preexec latency" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First command: backdate flushed_ns so the preexec that follows records
    // a ~800ms round-trip (simulating a hooked shell behind a slow SSH link).
    try s.queueRun(1, "a", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    s.run_queue.items[0].flushed_ns = std.time.nanoTimestamp() - 800 * std.time.ns_per_ms;
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try testing.expect(s.last_preexec_latency_ns >= 800 * std.time.ns_per_ms);
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 1));
    s.clearCompletions();

    // Second command: window is now max(1s, 3 * ~800ms) ≈ 2.4s.
    try s.queueRun(2, "b", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    const tf = s.run_queue.items[0].flushed_ns;
    const window = @max(ACCEPT_TIMEOUT_NS, 3 * s.last_preexec_latency_ns);
    try testing.expect(window > ACCEPT_TIMEOUT_NS);
    // Past the 1s floor but inside the adaptive window: must NOT reject.
    try testing.expect(!s.checkAcceptanceTimeout(tf + ACCEPT_TIMEOUT_NS + 200 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    // Past the adaptive window: rejects.
    try testing.expect(s.checkAcceptanceTimeout(tf + window + 100 * std.time.ns_per_ms));
    try testing.expectEqual(.line_rejected, s.completions()[0].result.via);
}

test "checkPromptWait warns for request queued behind a running command" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    var b: [128]u8 = undefined;
    // First request: typed and accepted; runs indefinitely (e.g. ssh with no
    // remote announce → cmd_running stays true, no `done` ever arrives).
    try s.queueRun(1, "ssh remote", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try testing.expect(s.topCmdRunning());

    // Second request: blocked on cmd_running.
    try s.queueRun(2, "ls", false);
    try testing.expect(!s.run_queue.items[1].sent);
    const t0 = s.run_queue.items[1].queued_ns;

    // Before 5s: silent.
    try testing.expectEqual(PromptWait.none, s.checkPromptWait(t0 + 2 * std.time.ns_per_s));
    // At 5s: warn fires for client 2 (not client 1 — front is sent).
    try testing.expectEqual(@as(u32, 2), s.checkPromptWait(t0 + 6 * std.time.ns_per_s).warn);
    // One-shot.
    try testing.expectEqual(PromptWait.none, s.checkPromptWait(t0 + 7 * std.time.ns_per_s));
    // No hard timeout even past 60s — previous command may run for hours.
    try testing.expectEqual(PromptWait.none, s.checkPromptWait(t0 + 90 * std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 2), s.run_queue.items.len);
    try testing.expectEqual(@as(usize, 0), s.completions().len);
}

// ───────── hook install state machine ─────────

test "startHook queues probe and arms" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try testing.expectEqual(@as(?[]const u8, null), try s.startHook(7, 0));
    try testing.expectEqual(.probing, s.hook_pending.?.phase);
    try testing.expect(std.mem.indexOf(u8, s.pendingPtyInput(), "$__ZMYTH_HOOK_V") != null);
    try testing.expect(s.takeHookCompletion() == null);
}

test "startHook refused: alt-screen / run in flight / concurrent" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    try s.feedPtyOutput("\x1b[?1049h");
    try testing.expect((try s.startHook(1, 0)) != null);
    try s.feedPtyOutput("\x1b[?1049l");

    try s.queueRun(1, "x", false);
    try testing.expect((try s.startHook(1, 0)) != null);
    s.cancelClientRuns(1);
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));
    s.clearCompletions();

    try testing.expectEqual(@as(?[]const u8, null), try s.startHook(1, 0));
    try testing.expect((try s.startHook(2, 0)) != null);
}

test "hook: probe reports already hooked → no install typed" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.startHook(7, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    // Local hooked layer brackets the probe with preexec/done; the probe OSC
    // arrives between them. echo_swallow ensures the done isn't taken as the
    // install completion.
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput("\x1b]2718;probe;b=5.2,z=,f=,h=1\x07");
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));

    const c = s.takeHookCompletion().?;
    try testing.expectEqual(@as(u32, 7), c.client_id);
    try testing.expectEqual(@as(u32, 1), c.result.already_hooked);
    try testing.expect(s.hook_pending == null);
    // No install was typed.
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
    // The bracketing done was swallowed (no run-queue effect, last_exit ok).
    try testing.expectEqual(@as(?i32, 0), s.last_exit);
}

test "hook: probe → install → done completes" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    // Nested-shell scenario: outer layer is *not* the one being hooked, so
    // simulate by going straight to a degraded prompt (no local hook).
    try s.feedPtyOutput("\x1b[?2004h");

    _ = try s.startHook(9, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    // Remote (unhooked) shell emits probe OSC, no preexec/done bracket.
    try s.feedPtyOutput("\x1b]2718;probe;b=,z=5.9,f=,h=\x07");
    try testing.expectEqual(.installing, s.hook_pending.?.phase);
    // Install was queued: paste + body in one go.
    const inp = s.pendingPtyInput();
    try testing.expect(std.mem.indexOf(u8, inp, "head -c ") != null);
    try testing.expect(std.mem.indexOf(u8, inp, "${ZDOTDIR:-$HOME}/.zshrc") != null);
    try testing.expect(std.mem.endsWith(u8, inp, shell.hookBody(.zsh)));
    s.consumePtyInput(inp.len);

    // Newly-hooked layer reaches its first prompt → first done (tagged zsh).
    try s.feedPtyOutput("\x1b]2718;done;555;0;0;z;/home/u\x07");
    const c = s.takeHookCompletion().?;
    try testing.expectEqual(@as(u32, 9), c.client_id);
    try testing.expectEqual(protocol.Shell.zsh, c.result.installed);
    try testing.expect(s.hook_pending == null);
    try testing.expect(s.topHooked());
    try testing.expectEqualStrings("/home/u", s.lastCwd());
    // takeHookCompletion is one-shot.
    try testing.expect(s.takeHookCompletion() == null);
}

test "hook: probe says unknown shell → err, no install" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    _ = try s.startHook(1, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput("\x1b]2718;probe;b=,z=,f=,h=\x07");
    try testing.expect(s.takeHookCompletion().?.result == .err);
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);
}

test "hook: bash <4 → err" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    _ = try s.startHook(1, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput("\x1b]2718;probe;b=3.2.57(1)-release,z=,f=,h=\x07");
    try testing.expect(s.takeHookCompletion().?.result == .err);
}

test "hook: probe timeout" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    _ = try s.startHook(1, 0);
    s.checkHookTimeout(std.time.ns_per_s); // before deadline
    try testing.expect(s.hook_pending != null);
    s.checkHookTimeout(10 * std.time.ns_per_s);
    try testing.expect(s.takeHookCompletion().?.result == .err);
    try testing.expect(s.hook_pending == null);
}

test "hook: install in already-hooked outer; outer's preexec/done swallowed" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.startHook(3, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    var b: [128]u8 = undefined;
    // Outer brackets probe; probe says NOT hooked (h=) — contrived (outer is
    // hooked, but inner var unset because inner shell hasn't sourced hook):
    // models `attach`→`ssh`→hook where outer is hooked, inner isn't, and the
    // outer preexec/done leak through ssh… actually outer is running ssh so
    // it doesn't bracket. The realistic case for echo_swallow during install
    // is when probe ran in outer (h=1, already_hooked) — covered above. This
    // test pins that a stray preexec during .installing doesn't misfire.
    try s.feedPtyOutput("\x1b]2718;probe;b=5.2,z=,f=,h=\x07");
    try testing.expectEqual(.installing, s.hook_pending.?.phase);
    s.consumePtyInput(s.pendingPtyInput().len);
    // Stray preexec (outer somehow): swallowed, paired done swallowed.
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));
    try testing.expect(s.hook_pending != null);
    try testing.expect(s.takeHookCompletion() == null);
    // The freshly-hooked inner's first done (no preexec preceded it).
    try s.feedPtyOutput(doneOsc(&b, 999, 0, "/", 0));
    try testing.expectEqual(protocol.Shell.bash, s.takeHookCompletion().?.result.installed);
}

test "queueRun while hook_pending defers typing" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.startHook(1, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    // run arrives mid-probe: must NOT be typed.
    try s.queueRun(2, "ls", false);
    try testing.expect(!s.run_queue.items[0].sent);
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);

    // Probe says already-hooked → hook completes.
    var b: [128]u8 = undefined;
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput("\x1b]2718;probe;b=5.2,z=,f=,h=1\x07");
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 0));
    try testing.expect(s.takeHookCompletion() != null);
    // Now the queued run is typed.
    try testing.expect(s.run_queue.items[0].sent);
}

// ───────── PID-stack + run -i ─────────

test "run -i: ?2004h after preexec → at_prompt + degraded layer pushed" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.queueRun(1, "ssh remote", true);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expectEqual(@as(u8, 0), s.run_queue.items[0].layer_depth);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try testing.expect(s.run_queue.items[0].accepted);

    // Remote (unhooked) prompt appears.
    try s.feedPtyOutput("\x1b[?2004h");
    const c = s.completions();
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(.at_prompt, c[0].result.via);
    try testing.expectEqual(@as(?i32, 0), c[0].result.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    // Degraded nested layer pushed.
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 0), s.top().?.pid);
    try testing.expect(!s.topHooked());
    s.clearCompletions();

    // A subsequent run types into the new top (depth 1), not the busy outer.
    try s.queueRun(2, "ls", false);
    try testing.expect(s.run_queue.items[0].sent);
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[0].layer_depth);
    try testing.expect(!s.run_queue.items[0].expect_preexec);
    // Unhooked top: ?2004h is the completion signal.
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expectEqual(.prompt_fallback, s.completions()[0].result.via);
}

test "run -i: done from new pid → at_prompt + hooked layer pushed" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.queueRun(1, "ssh remote", true);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));

    // Remote has a file-installed hook → first prompt emits done from new pid.
    try s.feedPtyOutput(doneOsc(&b, 555, 0, "/home/r", 0));
    try testing.expectEqual(.at_prompt, s.completions()[0].result.via);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 555), s.top().?.pid);
    try testing.expect(s.topHooked());
    try testing.expectEqualStrings("/home/r", s.lastCwd());
    s.clearCompletions();

    // Nested run types at depth 1; remote done completes it.
    try s.queueRun(2, "ls", false);
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[0].layer_depth);
    try testing.expect(s.run_queue.items[0].expect_preexec);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, 555));
    try s.feedPtyOutput(doneOsc(&b, 555, 7, "/home/r", 3));
    try testing.expectEqual(@as(?i32, 7), s.completions()[0].result.exit_code);
    try testing.expectEqual(.osc_done, s.completions()[0].result.via);
}

test "run -i: command exits without nested prompt → osc_done (not at_prompt)" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    // run -i on a command that just exits (no nested shell).
    try s.queueRun(1, "false", true);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput(doneOsc(&b, TPID, 1, "/", 5));
    try testing.expectEqual(@as(?i32, 1), s.completions()[0].result.exit_code);
    try testing.expectEqual(.osc_done, s.completions()[0].result.via);
    try testing.expectEqual(@as(u8, 1), s.layers.len);
}

test "layer pop: done from below-top pid pops + completes dangling run" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.queueRun(1, "ssh remote", true);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput(doneOsc(&b, 555, 0, "/", 0));
    s.clearCompletions();
    try testing.expectEqual(@as(u8, 2), s.layers.len);

    // Type into layer 1, accept, but don't complete.
    try s.queueRun(2, "sleep 60", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, 555));
    try testing.expect(s.run_queue.items[0].accepted);

    // ssh exits → layer 0's done. Layer 1 popped; depth-1 run → layer_exited.
    try s.feedPtyOutput(doneOsc(&b, TPID, 0, "/", 100));
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expectEqual(@as(i32, TPID), s.top().?.pid);
    const c = s.completions();
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(u32, 2), c[0].client_id);
    try testing.expectEqual(.layer_exited, c[0].result.via);
    try testing.expectEqual(@as(?i32, 0), c[0].result.exit_code);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    try testing.expect(!s.topCmdRunning());
}

test "non-interactive run -- ssh: outer run survives nested layer push/pop" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    // Plain run (NOT -i): blocks until ssh exits.
    try s.queueRun(1, "ssh remote", false);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    // Remote hooked → done;555. NOT interactive → does NOT complete the run.
    try s.feedPtyOutput(doneOsc(&b, 555, 0, "/", 0));
    try testing.expectEqual(@as(usize, 0), s.completions().len);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(usize, 1), s.run_queue.items.len);

    // Another client's run goes into layer 1 (top), even with the depth-0
    // run still pending.
    try s.queueRun(2, "ls", false);
    try testing.expect(s.run_queue.items[1].sent);
    try testing.expectEqual(@as(u8, 1), s.run_queue.items[1].layer_depth);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, 555));
    try s.feedPtyOutput(doneOsc(&b, 555, 0, "/", 1));
    // Only client 2's run completed; client 1's ssh still running.
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(u32, 2), s.completions()[0].client_id);
    s.clearCompletions();

    // ssh exits → done;100 → pop layer 1, complete client 1's run.
    try s.feedPtyOutput(doneOsc(&b, TPID, 5, "/", 999));
    try testing.expectEqual(@as(u8, 1), s.layers.len);
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(@as(u32, 1), s.completions()[0].client_id);
    try testing.expectEqual(@as(?i32, 5), s.completions()[0].result.exit_code);
    try testing.expectEqual(.osc_done, s.completions()[0].result.via);
}

test "degraded-top adoption: run -i ?2004h then hook installs → same layer" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);
    var b: [128]u8 = undefined;

    try s.queueRun(1, "ssh remote", true);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput(preexecOsc(&b, TPID));
    try s.feedPtyOutput("\x1b[?2004h"); // run -i completes, push degraded
    s.clearCompletions();
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 0), s.top().?.pid);

    // Now `zmyth hook` installs into the degraded top.
    _ = try s.startHook(2, 0);
    s.consumePtyInput(s.pendingPtyInput().len);
    try s.feedPtyOutput("\x1b]2718;probe;b=5.2,z=,f=,h=\x07");
    s.consumePtyInput(s.pendingPtyInput().len);
    // Newly-hooked layer's first done: pid 555. Adopted into the placeholder,
    // NOT stacked on top of it.
    try s.feedPtyOutput(doneOsc(&b, 555, 0, "/", 0));
    try testing.expectEqual(protocol.Shell.bash, s.takeHookCompletion().?.result.installed);
    try testing.expectEqual(@as(u8, 2), s.layers.len);
    try testing.expectEqual(@as(i32, 555), s.top().?.pid);
    try testing.expect(s.topHooked());
}

test "headless: terminal query gets a response" {
    // An app inside the session sends DSR (cursor position). With no attach
    // client, ghostty's shadow terminal is the only thing that can answer —
    // and it knows the cursor position. The response should land in pty_input
    // so the app reads it from stdin.
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    // Put the cursor somewhere known, then query it.
    try s.feedPtyOutput("\x1b[5;7H"); // CUP to row 5, col 7
    try s.feedPtyOutput("\x1b[6n"); // DSR: report cursor position
    try testing.expectEqualStrings("\x1b[5;7R", s.pendingPtyInput());
    s.consumePtyInput(s.pendingPtyInput().len);

    // DA1 (primary device attributes) — apps like nvim send this at startup.
    try s.feedPtyOutput("\x1b[c");
    try testing.expect(std.mem.startsWith(u8, s.pendingPtyInput(), "\x1b[?"));
    s.consumePtyInput(s.pendingPtyInput().len);

    // DECRQM (request mode state) for bracketed-paste.
    try s.feedPtyOutput("\x1b[?2004$p");
    // Response: CSI ? 2004 ; <0|1|2> $ y
    try testing.expect(std.mem.startsWith(u8, s.pendingPtyInput(), "\x1b[?2004;"));
}

test "headless: query NOT answered when an attach client is present" {
    // When a real terminal is attached, IT will answer (via passthrough), so
    // ghostty must stay silent — otherwise the app gets two replies.
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    s.attached_clients = 1;
    try s.feedPtyOutput("\x1b[6n");
    try testing.expectEqual(@as(usize, 0), s.pendingPtyInput().len);

    s.attached_clients = 0;
    try s.feedPtyOutput("\x1b[6n");
    try testing.expect(s.pendingPtyInput().len > 0);
}

test "OSC 7 updates lastCwd in unhooked session" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    // Degraded (unhooked) session: our `done` OSC never arrives, but the
    // shell's own OSC 7 does.
    try s.feedPtyOutput("\x1b[?2004h");
    try testing.expectEqualStrings("", s.lastCwd());
    try s.feedPtyOutput("\x1b]7;file://host/home/u\x07");
    try testing.expectEqualStrings("/home/u", s.lastCwd());
}

test "OSC 133;D updates last_exit and completes degraded run" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(1, "false", false);
    try testing.expect(s.run_queue.items[0].sent);
    // Shell with starship/omp emits 133;D;<ec> then ?2004h. Degraded `run`
    // currently completes via .prompt_fallback with ec=null; with 133;D it
    // should report the real exit code.
    try s.feedPtyOutput("\x1b]133;D;1\x07\x1b[?2004h");
    const c = s.completions();
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(?i32, 1), c[0].result.exit_code);
    try testing.expectEqual(@as(?i32, 1), s.last_exit);
}

test "ghostty-tracked state: title, mouse, osc133" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();

    try testing.expect(s.title() == null);
    try testing.expect(!s.mouseTracking());
    try testing.expect(!s.osc133Seen());

    try s.feedPtyOutput("\x1b]2;running vim\x07"); // OSC 2 set title
    try testing.expectEqualStrings("running vim", s.title().?);

    try s.feedPtyOutput("\x1b[?1002h"); // mouse button-event tracking
    try testing.expect(s.mouseTracking());
    try s.feedPtyOutput("\x1b[?1002l");
    try testing.expect(!s.mouseTracking());

    try s.feedPtyOutput("\x1b]133;A\x07"); // OSC 133 prompt-start
    try testing.expect(s.osc133Seen());
}

test "max_layers overflow: top replaced, no panic" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    var b: [128]u8 = undefined;
    var pid: i32 = 100;
    while (pid < 100 + max_layers + 3) : (pid += 1) {
        try s.feedPtyOutput(doneOsc(&b, pid, 0, "/", 0));
    }
    try testing.expectEqual(@as(u8, max_layers), s.layers.len);
}

test "cancelClientHook clears pending for that client only" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    try hookAndIdle(&s);

    _ = try s.startHook(7, 0);
    try testing.expect(s.hook_pending != null);
    s.cancelClientHook(99); // wrong client
    try testing.expect(s.hook_pending != null);
    s.cancelClientHook(7);
    try testing.expect(s.hook_pending == null);
    // New hook can start immediately.
    s.consumePtyInput(s.pendingPtyInput().len);
    try testing.expectEqual(@as(?[]const u8, null), try s.startHook(8, 0));
}

test "checkPromptWait: warn at 5s, timeout at 30s, none once ready" {
    var s = try Session.init(testing.allocator, 24, 80);
    defer s.deinit();
    // No done/?2004h yet — shell is "starting".
    try s.queueRun(7, "echo hi", false);
    const t0 = s.run_queue.items[0].queued_ns;
    try testing.expect(!s.run_queue.items[0].sent);

    try testing.expectEqual(PromptWait.none, s.checkPromptWait(t0 + 1 * std.time.ns_per_s));
    try testing.expectEqual(@as(u32, 7), s.checkPromptWait(t0 + 6 * std.time.ns_per_s).warn);
    // Warn fires once.
    try testing.expectEqual(PromptWait.none, s.checkPromptWait(t0 + 7 * std.time.ns_per_s));
    // Hard timeout completes the request.
    try testing.expectEqual(@as(u32, 7), s.checkPromptWait(t0 + 31 * std.time.ns_per_s).timeout);
    try testing.expectEqual(@as(usize, 0), s.run_queue.items.len);
    try testing.expectEqual(@as(usize, 1), s.completions().len);
    try testing.expectEqual(.prompt_fallback, s.completions()[0].result.via);
    s.clearCompletions();

    // Once the prompt-ready signal arrives, no more warns/timeouts.
    try s.feedPtyOutput("\x1b[?2004h");
    try s.queueRun(8, "echo hi", false);
    try testing.expectEqual(PromptWait.none, s.checkPromptWait(std.time.nanoTimestamp() + 60 * std.time.ns_per_s));
}
