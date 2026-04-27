//! Shell process spawn: build the inherited environment (with ZMX vars and
//! symlink-indirected refresh keys), drop the per-shell rc shim that emits
//! the OSC 2718 `hello`, and `forkExec` into the PTY slave.
//!
//! Also owns the env-refresh symlink dance used on each attach.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const pty = @import("pty.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.spawn);

const refresh_env_keys = @import("shell.zig").refresh_env_keys;

pub const Spawned = struct {
    pid: posix.pid_t,
    /// What we detected from `$SHELL` (or `.unknown` for `initial_cmd`).
    /// `.unknown` means no announce shim was written, so the session will
    /// never hook and `run` cannot work — the daemon uses this to refuse
    /// `.run` requests up front instead of letting them hang.
    shell: protocol.Shell,
};

/// Spawn the session shell into PTY `p`. If `initial_cmd` is given, exec it
/// directly (degraded mode: no rc shim, no hooks). Otherwise detect the shell
/// from `$SHELL`, write an rc shim under `rc_dir` that sources the user's rc
/// then announces via OSC 2718, and exec the shell interactively.
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

    // Base env: inherit parent + ZMYTH_SESSION + TERM (if unset) + indirected
    // refresh keys pointing at <env_dir>/<KEY>.
    var env: std.ArrayList([*:0]const u8) = .empty;
    {
        var ptr = std.c.environ;
        while (ptr[0]) |e| : (ptr += 1) {
            const s = std.mem.span(e);
            // Skip keys we are about to override.
            if (envKeyIs(s, "ZMYTH_SESSION") or
                envKeyIs(s, "_ZMYTH_ORIG_ZDOTDIR") or
                envKeyIs(s, "ZDOTDIR")) continue;
            var skip = false;
            for (refresh_env_keys) |k| if (envKeyIs(s, k)) {
                skip = true;
            };
            if (skip) continue;
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

    // Explicit initial command: degraded mode, no rc shim, no hooks.
    if (initial_cmd) |cmd| {
        return .{ .pid = try pty.forkExec(p, cmd, env.items), .shell = .unknown };
    }

    // Detect shell from $SHELL basename. Fall back to /bin/sh (not /bin/bash):
    // alpine/busybox/distroless lack bash but always have sh.
    const shell_path = posix.getenv("SHELL") orelse "/bin/sh";
    const base = std.fs.path.basename(shell_path);
    const shell = protocol.Shell.parse(base);

    std.fs.makeDirAbsolute(rc_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const announce = "printf '\\033]2718;hello;{s};%s\\007' \"$$\"\n";

    var argv: std.ArrayList([]const u8) = .empty;
    switch (shell) {
        .bash => {
            const rc = try std.fmt.allocPrint(arena, "{s}/bashrc", .{rc_dir});
            // bash <4 (notably macOS /bin/bash = 3.2) lacks bracketed-paste:
            // the verbatim-paste inject becomes literal `200~...201~` and
            // `run`'s typed commands are mangled the same way. Announce as
            // an unrecognised shell so the daemon refuses `run` cleanly
            // instead of producing `200~true201~: command not found`.
            const body = try std.fmt.allocPrint(
                arena,
                "[ -f ~/.bashrc ] && . ~/.bashrc\n" ++
                    "if [ \"${{BASH_VERSINFO[0]:-0}}\" -ge 4 ]; then\n  " ++ announce ++
                    "else\n  printf '\\033]2718;hello;bash-pre4;%s\\007' \"$$\"\nfi\n",
                .{"bash"},
            );
            try writeFile(rc, body);
            try argv.appendSlice(arena, &.{ shell_path, "--rcfile", rc, "-i" });
        },
        .zsh => {
            // We hijack ZDOTDIR to point at our shim. The shim must (a) let
            // the user's .zshenv run with the *original* ZDOTDIR visible,
            // (b) capture whatever ZDOTDIR the user's .zshenv left behind,
            // (c) re-hijack so zsh reads OUR .zshrc next, then (d) restore
            // the captured value before sourcing the user's .zshrc.
            const orig_zdot = posix.getenv("ZDOTDIR") orelse "";
            const zenv = try std.fmt.allocPrint(arena, "{s}/.zshenv", .{rc_dir});
            // rc_dir derives from user-supplied $ZMYTH_DIR; quote it so a
            // `'` in the path can't break out of the assignment.
            const rc_dir_q = try @import("shell.zig").posixQuote(arena, rc_dir);
            const zenv_body = try std.fmt.allocPrint(
                arena,
                "if [ -n \"$_ZMYTH_ORIG_ZDOTDIR\" ]; then export ZDOTDIR=\"$_ZMYTH_ORIG_ZDOTDIR\"; else unset ZDOTDIR; fi\n" ++
                    "[ -f \"${{ZDOTDIR:-$HOME}}/.zshenv\" ] && . \"${{ZDOTDIR:-$HOME}}/.zshenv\"\n" ++
                    "export _ZMYTH_USER_ZDOTDIR=\"${{ZDOTDIR-__unset__}}\"\n" ++
                    "export ZDOTDIR={s}\n",
                .{rc_dir_q},
            );
            try writeFile(zenv, zenv_body);
            const rc = try std.fmt.allocPrint(arena, "{s}/.zshrc", .{rc_dir});
            const body = try std.fmt.allocPrint(
                arena,
                "if [ \"$_ZMYTH_USER_ZDOTDIR\" = __unset__ ]; then unset ZDOTDIR; " ++
                    "else export ZDOTDIR=\"$_ZMYTH_USER_ZDOTDIR\"; fi\n" ++
                    "unset _ZMYTH_USER_ZDOTDIR _ZMYTH_ORIG_ZDOTDIR\n" ++
                    "[ -f \"${{ZDOTDIR:-$HOME}}/.zshrc\" ] && . \"${{ZDOTDIR:-$HOME}}/.zshrc\"\n" ++
                    announce,
                .{"zsh"},
            );
            try writeFile(rc, body);
            try env.append(arena, try std.fmt.allocPrintSentinel(arena, "_ZMYTH_ORIG_ZDOTDIR={s}", .{orig_zdot}, 0));
            try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}", .{rc_dir}, 0));
            try argv.appendSlice(arena, &.{ shell_path, "-i" });
        },
        .fish => {
            // Pass the announce directly via -C rather than `source`-ing a
            // file: rc_dir derives from user-supplied ZMYTH_DIR and may
            // contain spaces/quotes, and fish word-splits -C's argument.
            try argv.appendSlice(arena, &.{
                shell_path, "-i", "-C",
                "printf '\\033]2718;hello;fish;%s\\007' $fish_pid",
            });
        },
        .unknown => {
            log.warn("unknown shell '{s}'; spawning without announce hook", .{base});
            try argv.appendSlice(arena, &.{ shell_path, "-i" });
        },
    }

    return .{ .pid = try pty.forkExec(p, argv.items, env.items), .shell = shell };
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

fn writeFile(path: []const u8, contents: []const u8) !void {
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
        .flags = .{ .mode = 0o600 },
    });
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

test "envKeyIs" {
    try testing.expect(envKeyIs("FOO=bar", "FOO"));
    try testing.expect(!envKeyIs("FOOBAR=x", "FOO"));
    try testing.expect(!envKeyIs("FOO", "FOO"));
}

test {
    std.testing.refAllDecls(@This());
}
