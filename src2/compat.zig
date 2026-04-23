//! Platform shims for the daemon/client poll loops.
//!
//! Linux has `ppoll(2)`, which atomically swaps the signal mask for the
//! duration of the wait — the textbook fix for the check-flag/poll race.
//! Darwin does not. There we fall back to the self-pipe trick: handlers
//! write a byte to a nonblocking pipe whose read end is added to the poll
//! set, so a signal landing between the flag check and `poll()` still wakes
//! the loop. Signals are left *unblocked* on Darwin for this to work.
//!
//! Single-threaded callers only; `poll_scratch` is file-level static.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const use_ppoll = builtin.os.tag == .linux;

var sig_pipe_r: posix.fd_t = -1;
var sig_pipe_w: posix.fd_t = -1;

/// Must be called once before any `pollWithMask`/`notifySignal`. No-op on
/// platforms with native `ppoll`.
pub fn initSignalPipe() !void {
    if (use_ppoll) return;
    const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    sig_pipe_r = fds[0];
    sig_pipe_w = fds[1];
}

/// Async-signal-safe; call from signal handlers after setting their flag so
/// a blocked `pollWithMask` wakes up. No-op on platforms with native `ppoll`.
pub fn notifySignal() void {
    if (use_ppoll) return;
    const w = sig_pipe_w;
    if (w < 0) return;
    _ = posix.system.write(w, "x", 1);
}

/// On Linux, block `to_block` and return the previous mask (to be passed as
/// `pollWithMask`'s `mask`). On platforms using the self-pipe, signals must
/// stay deliverable so handlers can write to the pipe; returns an empty set
/// that `pollWithMask` will ignore.
pub fn blockSignalsForPoll(to_block: *const posix.sigset_t) posix.sigset_t {
    if (comptime use_ppoll) {
        var orig: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, to_block, &orig);
        return orig;
    }
    // Self-pipe path: leave signals deliverable so handlers can write to the
    // pipe. (`to_block` is referenced above; AstGen's unused-param check is
    // syntactic, so no discard needed.)
    return posix.sigemptyset();
}

/// Daemon polls listen + pty + up to 64 clients; client polls 2. One extra
/// slot for the self-pipe.
var poll_scratch: [128]posix.pollfd = undefined;

/// Portable `ppoll`. On Linux: the real thing. Elsewhere: copies `fds` into a
/// scratch buffer, appends the self-pipe read end, and calls plain `poll()`.
/// Returns `error.SignalInterrupt` if the pipe was readable, after draining
/// it, so callers can re-check their signal flags exactly as they would on
/// EINTR from `ppoll`.
pub fn pollWithMask(
    fds: []posix.pollfd,
    timeout: ?*const posix.timespec,
    mask: ?*const posix.sigset_t,
) !usize {
    if (comptime use_ppoll) return posix.ppoll(fds, timeout, mask);
    // `mask` is referenced above; AstGen's unused-param check is syntactic.
    return pollSelfPipe(fds, timeout);
}

fn pollSelfPipe(fds: []posix.pollfd, timeout: ?*const posix.timespec) !usize {
    std.debug.assert(fds.len + 1 <= poll_scratch.len);
    const buf = poll_scratch[0 .. fds.len + 1];
    @memcpy(buf[0..fds.len], fds);
    buf[fds.len] = .{ .fd = sig_pipe_r, .events = posix.POLL.IN, .revents = 0 };

    const timeout_ms: i32 = if (timeout) |t| ms: {
        const sec: i64 = @intCast(t.sec);
        const nsec: i64 = @intCast(t.nsec);
        break :ms @intCast(sec * 1000 + @divTrunc(nsec, std.time.ns_per_ms));
    } else -1;

    // std.posix.poll retries EINTR internally; that's fine here because the
    // handler has already written to the pipe, so the retried poll returns
    // immediately with buf[fds.len] readable.
    const n = try posix.poll(buf, timeout_ms);
    for (fds, buf[0..fds.len]) |*dst, src| dst.revents = src.revents;

    if (buf[fds.len].revents & posix.POLL.IN != 0) {
        var drain: [256]u8 = undefined;
        while (true) {
            const r = posix.read(sig_pipe_r, &drain) catch break;
            if (r < drain.len) break;
        }
        return error.SignalInterrupt;
    }
    return n;
}
