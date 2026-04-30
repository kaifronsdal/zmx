//! Spawn the session shell with the OSC-2718 hook pre-loaded, and refresh
//! the env-symlink indirection on attach.
//!
//! This is the daemon's startup path: detect the user's shell, write an rc
//! shim under `rc_dir` that sources the user's rc then `hook.body(shell)`,
//! and forkExec into the PTY. Contrast `lib/hook.zig`, which is the pure
//! string-building half (assets, install one-liners, quoting) with no fds.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const pty = lib.posix;
const lib = @import("zmyth");
const hook = lib.hook;
const Shell = lib.Shell;

const log = std.log.scoped(.spawn);

// ───────────────────── per-attach env vars ─────────────────────
//
// Two related but distinct lists. Kept together so they can't silently drift.

/// Keys the *client* forwards on attach (`buildAttachPayload`). The daemon
/// receives these and updates whatever it can — currently just the symlink-
/// indirected subset below.
pub const env_forward = [_][:0]const u8{
    "SSH_AUTH_SOCK",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "DBUS_SESSION_BUS_ADDRESS",
};

/// Subset of `env_forward` whose values are *absolute filesystem paths* and
/// so can be refreshed via symlink indirection without restarting the shell.
/// WAYLAND_DISPLAY is conventionally a bare name (`wayland-0`) resolved
/// against $XDG_RUNTIME_DIR — symlinking it would dangle. The others
/// (DISPLAY, DBUS_…) need an env-reload mechanism (DESIGN.md #104).
pub const refresh_env_keys = [_][]const u8{
    "SSH_AUTH_SOCK",
};

pub const Spawned = struct {
    pid: posix.pid_t,
    /// What we detected from `$SHELL` (or `.unknown` for `initial_cmd`).
    /// `.unknown` means no announce shim was written, so the session will
    /// never hook and `run` cannot work — the daemon uses this to refuse
    /// `.run` requests up front instead of letting them hang.
    shell: Shell,
};

/// Spawn the session shell into PTY `p`. If `initial_cmd` is given, exec it
/// directly (degraded mode: no rc shim, no hooks). Otherwise detect the
/// shell from `$SHELL`, materialise `hook.spawnSpec` (write rc shims, merge
/// env), and forkExec.
pub fn spawnShell(
    allocator: Allocator,
    p: *pty.Pty,
    name: []const u8,
    rc_dir: []const u8,
    env_dir: []const u8,
    initial_cmd: ?[]const []const u8,
) !Spawned {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shell_path = posix.getenv("SHELL") orelse "/bin/sh";
    const shell: Shell = if (initial_cmd != null) .unknown else Shell.parse(std.fs.path.basename(shell_path));
    if (shell == .unknown and initial_cmd == null)
        log.warn("unknown shell '{s}'; spawning without hook", .{shell_path});

    const spec = try hook.spawnSpec(arena, shell, .{
        .shell_path = shell_path,
        .rc_dir = rc_dir,
        .body = if (shell == .unknown) "" else hook.body(shell),
        .orig_zdotdir = posix.getenv("ZDOTDIR"),
    });

    // ── env: inherit parent, strip per-spec + zmyth + symlink keys, then
    //    add ZMYTH_SESSION/TERM/symlinks/spec.env_set ──────────────────
    var env: std.ArrayList([*:0]const u8) = .empty;
    {
        var ptr = std.c.environ;
        outer: while (ptr[0]) |e| : (ptr += 1) {
            const s = std.mem.span(e);
            if (envKeyIs(s, "ZMYTH_SESSION")) continue;
            for (spec.env_strip) |k| if (envKeyIs(s, k)) continue :outer;
            for (refresh_env_keys) |k| if (envKeyIs(s, k)) continue :outer;
            try env.append(arena, e);
        }
    }
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ZMYTH_SESSION={s}", .{name}, 0));
    if (posix.getenv("TERM") == null) {
        try env.append(arena, "TERM=xterm-256color");
    }
    // For each refresh key the *parent* actually has, point the child's env
    // var at the indirection symlink and create that symlink now (targeting
    // the parent's current value) so the shell's rc can use it before any
    // client attaches. Keys absent from the parent are left absent in the
    // child rather than pointed at a dangling path.
    for (refresh_env_keys) |k| {
        const val = posix.getenv(k) orelse continue;
        const link = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ env_dir, k }, 0);
        posix.unlink(link) catch {};
        try posix.symlink(val, link);
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ k, link }, 0));
    }
    for (spec.env_set) |kv| {
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ kv.key, kv.val }, 0));
    }

    // Explicit initial command: degraded mode, no rc shim, no hooks.
    if (initial_cmd) |cmd| {
        return .{ .pid = try pty.forkExec(p, cmd, env.items), .shell = .unknown };
    }

    // ── materialise rc shims ────────────────────────────────────────────
    if (spec.files.len > 0) {
        std.fs.makeDirAbsolute(rc_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        for (spec.files) |f| {
            const path = try std.fs.path.join(arena, &.{ rc_dir, f.name });
            try std.fs.cwd().writeFile(.{
                .sub_path = path,
                .data = f.content,
                .flags = .{ .mode = 0o600 },
            });
        }
    }

    return .{ .pid = try pty.forkExec(p, spec.argv, env.items), .shell = shell };
}

/// Parse a `KEY=VAL\0KEY=VAL\0...` blob and, for each key in
/// `refresh_env_keys`, atomically repoint `<env_dir>/<KEY>` at `VAL`.
pub fn refreshEnvLinks(env_dir: []const u8, kv_pairs: []const u8) !void {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;

    var it = std.mem.splitScalar(u8, kv_pairs, 0);
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        for (refresh_env_keys) |k| {
            if (!std.mem.eql(u8, k, key)) continue;
            // Atomic symlink replace: link to <key>.tmp then rename.
            const link = try std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ env_dir, key });
            const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/{s}.tmp", .{ env_dir, key });
            posix.unlink(tmp) catch {};
            try posix.symlink(val, tmp);
            try posix.rename(tmp, link);
        }
    }
}

/// True iff `entry` is `KEY=...` for exactly `key` (not a prefix match).
fn envKeyIs(entry: []const u8, key: []const u8) bool {
    return entry.len > key.len and
        entry[key.len] == '=' and
        std.mem.eql(u8, entry[0..key.len], key);
}

const testing = std.testing;

test "envKeyIs" {
    try testing.expect(envKeyIs("FOO=bar", "FOO"));
    try testing.expect(!envKeyIs("FOOBAR=x", "FOO"));
    try testing.expect(!envKeyIs("FOO", "FOO"));
}

test "refresh_env_keys ⊆ env_forward" {
    for (refresh_env_keys) |k| {
        var found = false;
        for (env_forward) |f| if (std.mem.eql(u8, k, f)) {
            found = true;
        };
        try testing.expect(found);
    }
}
