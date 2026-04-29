//! Per-shell knowledge: everything zmyth puts *into* a shell.
//!
//! - Hook scripts (assets/hook.*) and the bracketed-paste wrapper that
//!   delivers them
//! - The `zmyth hook` install sequence (`buildInstall`) and probe one-liner
//! - Shell-string quoting
//! - Per-attach env-var lists and the symlink-indirection refresh dance
//! - The shell-process spawn itself (rc-shim that sources `hookBody`)
//!
//! Contrast with `protocol.zig`, which parses what comes *out* of the PTY.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const pty = @import("pty.zig");
const Shell = @import("protocol.zig").Shell;

const log = std.log.scoped(.shell);

// Hook scripts are bracketed-pasted verbatim into the interactive shell, so
// they contain NO `#` comments: interactive zsh lacks INTERACTIVE_COMMENTS by
// default and would parse each comment line as a command. Design notes:
//
//   bash — DEBUG trap (chained over any prior trap) emits `preexec` once per
//     accepted line, gated by __ZMX_AT_PROMPT/__ZMX_IN_PC so PROMPT_COMMAND
//     entries don't fire it. PROMPT_COMMAND is wrapped (array or string) so
//     $? is captured first and __zmx_precmd runs last to re-arm the guard.
//     `bind` calls force bracketed-paste on and bind it in vi-command keymap
//     so `run`'s ^U + paste wrapper survives `set -o vi` / disabled paste.
//
//   zsh — preexec/precmd via add-zsh-hook; __ZMX_RAN distinguishes "ran,
//     $?=N" from "zle rejected line, $? stale" (→ ec=125). zle_bracketed_paste
//     and vicmd bindings are forced for the same reason as bash.
//
//   fish — fish_preexec/fish_prompt events; fish_posterror covers the syntax-
//     error case where fish_prompt does NOT fire (fish #8832). Duration via
//     $CMD_DURATION (built-in, ms).
//
// Each hook sets `__ZMYTH_HOOK_V=1` on load. The probe one-liner reports this
// so `zmyth hook` can detect already-installed without writing anything.
const hook_bash = @embedFile("assets/hook.bash");
const hook_zsh = @embedFile("assets/hook.zsh");
const hook_fish = @embedFile("assets/hook.fish");

/// Bumped whenever a hook asset changes in a way that requires reinstall.
pub const hook_version: u32 = 2;

/// Where `zmyth hook` writes the per-shell hook file. Referenced by
/// `buildInstall`, the `hook` verb's no-arg help text, and the daemon's
/// "installed → …" message — single source of truth so they can't drift.
pub const hook_dir = "~/.config/zmyth";

/// The line `buildInstall` appends to the user's rc, and what `zmyth hook`
/// (no-arg) tells the user to add manually. One definition so they agree.
/// `inline` so a comptime-known `sh` yields a comptime string literal usable
/// with `++`.
pub inline fn rcSourceLine(sh: Shell) []const u8 {
    return switch (sh) {
        .bash => "[ -f " ++ hook_dir ++ "/hook.bash ] && . " ++ hook_dir ++ "/hook.bash",
        .zsh => "[ -f " ++ hook_dir ++ "/hook.zsh ] && . " ++ hook_dir ++ "/hook.zsh",
        .fish => "test -f " ++ hook_dir ++ "/hook.fish; and source " ++ hook_dir ++ "/hook.fish",
        .unknown => unreachable,
    };
}

const paste_open = "\x15\x1b[200~";
const paste_close = "\x1b[201~\r";

/// Wrap `s` in `^U \e[200~ ... \e[201~ \r` for typing as one accepted line.
/// Bracketed paste delivers it verbatim — no history expansion, no `\` line
/// continuation — and the shell executes on the final CR.
pub fn wrapPaste(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ paste_open, s, paste_close });
}

/// Hook script body for `shell`. Sourced directly by the rc shim at spawn,
/// and what `buildInstall`'s `head -c` writes to the hook file.
pub fn hookBody(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => hook_bash,
        .zsh => hook_zsh,
        .fish => hook_fish,
        .unknown => unreachable,
    };
}

/// One-line shell-detection probe, valid syntax in bash/zsh/fish. Non-shells
/// (python, gdb) syntax-error and emit nothing; sh/dash run it and emit all-
/// empty fields (`shell == .unknown`).
///
/// `set +u` first: bash `set -u` / zsh `setopt nounset` would otherwise abort
/// on the unset version vars. `${VAR-}` is the idiomatic guard but is a syntax
/// error in fish, so disable nounset instead — fish has no nounset and its
/// `set +u` just errors (suppressed). Side effect: leaves nounset off in the
/// target shell for the rest of that session; accepted for a one-time install.
pub const probe_line =
    \\set +u 2>/dev/null; printf '\033]2718;probe;b=%s,z=%s,f=%s,h=%s\007' "$BASH_VERSION" "$ZSH_VERSION" "$FISH_VERSION" "$__ZMYTH_HOOK_V"
;

/// Build the `zmyth hook` install sequence for `shell`: a bracketed-paste
/// wrapping the visible 3-line install script, immediately followed by the
/// hook body (consumed by `head -c N` on line 2, so it never echoes). The
/// length-prefix means no EOF marker is needed and the body can be queued in
/// the same write as the paste — `head` reads exactly N bytes regardless of
/// when they arrive relative to the tty mode switch.
///
/// `tr '\r' '\n'`: the body passes through the line discipline in whatever
/// mode the line editor left it — bash/fish editors are raw (-ICRNL, -INLCR)
/// so NL survives, but zle sets INLCR (NL→CR) so a body that lands while zle
/// is still active arrives with CRs. Normalising on the receiving end is the
/// only fix that doesn't depend on write/read timing. Caller frees.
pub fn buildInstall(allocator: std.mem.Allocator, shell: Shell) ![]u8 {
    const body = hookBody(shell);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll(paste_open);
    // Three-line install:
    //   1. mkdir + read body to a temp file (drain-wrapped so a write
    //      failure doesn't leave the body for readline to execute)
    //   2. atomic mv into place — a half-written hook is never sourced;
    //      then append the rc line ON SUCCESS with a leading \n so a user
    //      rc lacking a trailing newline isn't corrupted
    //   3. source it
    // The rc line itself is `[ -f ] &&`-guarded so `rm -rf ~/.config/zmyth`
    // is a clean uninstall. rc-append is grep-gated rather than file-gated
    // so a failed line-2 retry doesn't accumulate duplicates.
    switch (shell) {
        .bash, .zsh => {
            const rc = if (shell == .bash) "~/.bashrc" else "\"${ZDOTDIR:-$HOME}/.zshrc\"";
            const ext = @tagName(shell);
            try w.print(
                "mkdir -p {0s}; stty -echo; head -c {1d} | {{ tr '\\r' '\\n' >| {0s}/hook.tmp || cat >/dev/null; }}; stty echo\n" ++
                    "mv -f {0s}/hook.tmp {0s}/hook.{2s} && {{ grep -q zmyth/hook {3s} 2>/dev/null || printf '\\n%s\\n' '{4s}' >> {3s}; }}\n" ++
                    ". {0s}/hook.{2s}",
                .{ hook_dir, body.len, ext, rc, rcSourceLine(shell) },
            );
        },
        .fish => try w.print(
            // fish: conf.d/ is ours alone so unconditional rewrite is fine.
            "mkdir -p {0s} ~/.config/fish/conf.d; stty -echo; head -c {1d} | begin; tr '\\r' '\\n' > {0s}/hook.tmp; or cat >/dev/null; end; stty echo\n" ++
                "mv -f {0s}/hook.tmp {0s}/hook.fish; and printf '%s\\n' '{2s}' > ~/.config/fish/conf.d/zmyth.fish\n" ++
                "source {0s}/hook.fish",
            .{ hook_dir, body.len, rcSourceLine(.fish) },
        ),
        .unknown => unreachable,
    }
    try w.writeAll(paste_close);
    try w.writeAll(body);
    return out.toOwnedSlice(allocator);
}

// ───────────────────── `zmyth write` ─────────────────────
//
// A short bracketed-paste runs `head -c N | tr | base64 -d > path`; the
// base64 body is streamed *after* the paste so `head` reads it directly
// from the tty. Compared to a heredoc-inside-paste this is ~60× faster
// (readline only buffers the ~80-byte command, not the whole body) and
// needs no heredoc syntax, so it works in fish too.
//
// `head -c N` (length-prefixed) rather than `^D`-terminated: bytes that
// land in the kernel input queue while the line editor is still in raw
// mode are *not* reprocessed when the tty flips to cooked, so a `^D` sent
// too early is delivered as literal 0x04. `head -c N` reads exactly N
// bytes regardless of mode. `-icanon` lets head read in big chunks instead
// of per-`\n` (≈25% faster, and puts us at the kernel PTY ceiling of
// ~40 MB/s). No `tr` needed: any NL/CR mangling from mode transitions is
// whitespace, which `base64 -d` ignores. The daemon defers the
// `.write_hdr` ack until `preexec` so the body is never written into the
// same kernel-buffer-full as the command itself (line editors over-read
// whatever is available).

/// `^U ⟨paste⟩stty -icanon -echo; head -c N | <drain decode> ; stty icanon
/// echo⟨/paste⟩\r`. `n` is the byte length of the encoded body. Caller then
/// streams exactly `n` bytes. Caller frees.
///
/// The decode stage is wrapped so the pipe is *always* drained: if the
/// redirect fails (typo'd path, EACCES, zsh `~nosuchuser`), `head` would
/// otherwise SIGPIPE early and the unread body would flood readline. The
/// `|| cat >/dev/null` swallows the rest so `head -c N` always completes
/// and `stty icanon echo` always runs.
pub fn writeOpener(allocator: Allocator, sh: Shell, path: []const u8, n: u64, gzip: bool) ![]u8 {
    const q = try quoteRedirectTarget(allocator, path);
    defer allocator.free(q);
    const gz = if (gzip) " | gunzip" else "";
    return switch (sh) {
        .fish => std.fmt.allocPrint(
            allocator,
            paste_open ++
                "stty -icanon -echo; head -c {d} | begin; base64 -d{s} > {s} 2>/dev/null; " ++
                "or cat >/dev/null; end; stty icanon echo" ++
                paste_close,
            .{ n, gz, q },
        ),
        // `setopt nonomatch` (zsh) makes a failed `~user` expansion fall
        // through to a literal (then ENOENT → caught by `||`) instead of
        // aborting the whole list. No-op in bash (`2>/dev/null`).
        else => std.fmt.allocPrint(
            allocator,
            paste_open ++
                "stty -icanon -echo; head -c {d} | {{ setopt nonomatch 2>/dev/null; " ++
                "base64 -d{s} > {s} 2>/dev/null || cat >/dev/null; }}; stty icanon echo" ++
                paste_close,
            .{ n, gz, q },
        ),
    };
}

/// Quote `path` for use as a redirect target. A leading `~`/`~user/` prefix
/// is left unquoted so the shell expands it — tilde expansion needs the `~`
/// and the terminating `/` both unquoted, then `'rest'` is concatenated
/// after quote removal (so `~user/'rest'` → `<user's home>/rest`).
/// Everything else is posixQuote'd.
fn quoteRedirectTarget(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        const cut = if (std.mem.indexOfScalar(u8, path, '/')) |s| s + 1 else path.len;
        const q = try posixQuote(allocator, path[cut..]);
        defer allocator.free(q);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0..cut], q });
    }
    return posixQuote(allocator, path);
}

/// Encoded body length for `raw_len` input bytes, given the client's
/// 48-byte→64-char+`\n` line framing.
pub fn writeEncLen(raw_len: u64) u64 {
    const full = raw_len / 48;
    const rem = raw_len % 48;
    var n = full * 65;
    if (rem > 0) n += ((rem + 2) / 3) * 4 + 1;
    return n;
}

/// Wrap `s` in single quotes, encoding embedded `'` as `'\''`. Safe for
/// bash/zsh word-splitting and expansion. Caller frees.
pub fn posixQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(allocator, "'\\''") //
        else try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

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

// ───────────────────── shell process spawn ─────────────────────

pub const Spawned = struct {
    pid: posix.pid_t,
    /// What we detected from `$SHELL` (or `.unknown` for `initial_cmd`).
    /// `.unknown` means no announce shim was written, so the session will
    /// never hook and `run` cannot work — the daemon uses this to refuse
    /// `.run` requests up front instead of letting them hang.
    shell: Shell,
};

/// Spawn the session shell into PTY `p`. If `initial_cmd` is given, exec it
/// directly (degraded mode: no rc shim, no hooks). Otherwise detect the shell
/// from `$SHELL`, write an rc shim under `rc_dir` that sources the user's rc
/// then `hookBody(shell)`, and exec the shell interactively.
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

    // Detect shell up front so the env-strip loop knows whether to take
    // ZDOTDIR (only the zsh arm overrides it; bash/fish should inherit so
    // a `zsh` launched later inside the session reads the right dotdir).
    const shell_path = posix.getenv("SHELL") orelse "/bin/sh";
    const shell: Shell = if (initial_cmd != null) .unknown else Shell.parse(std.fs.path.basename(shell_path));

    // Base env: inherit parent + ZMYTH_SESSION + TERM (if unset) + indirected
    // refresh keys pointing at <env_dir>/<KEY>.
    var env: std.ArrayList([*:0]const u8) = .empty;
    {
        var ptr = std.c.environ;
        while (ptr[0]) |e| : (ptr += 1) {
            const s = std.mem.span(e);
            if (envKeyIs(s, "ZMYTH_SESSION")) continue;
            if (shell == .zsh and (envKeyIs(s, "_ZMYTH_ORIG_ZDOTDIR") or
                envKeyIs(s, "ZDOTDIR"))) continue;
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

    std.fs.makeDirAbsolute(rc_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // The rc-shim sources the user's rc, then the hook script itself —
    // loaded *during* rc, not typed afterward, so there is no preexec/done
    // for the daemon to swallow. Layer 0 announces via its first `done`
    // (the hook's first precmd) exactly like a file-installed nested layer.
    var argv: std.ArrayList([]const u8) = .empty;
    switch (shell) {
        .bash => {
            // bash <4 lacks bracketed-paste; the hook self-guards on
            // BASH_VERSINFO so it's a no-op there → session is degraded
            // (?2004h-only) and `run` falls back to .prompt_fallback.
            const rc = try std.fmt.allocPrint(arena, "{s}/bashrc", .{rc_dir});
            try writeFile(rc, try std.mem.concat(arena, u8, &.{
                "[ -f ~/.bashrc ] && . ~/.bashrc\n",
                hookBody(.bash),
            }));
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
            const rc_dir_q = try posixQuote(arena, rc_dir);
            try writeFile(zenv, try std.fmt.allocPrint(
                arena,
                "if [ -n \"$_ZMYTH_ORIG_ZDOTDIR\" ]; then export ZDOTDIR=\"$_ZMYTH_ORIG_ZDOTDIR\"; else unset ZDOTDIR; fi\n" ++
                    "[ -f \"${{ZDOTDIR:-$HOME}}/.zshenv\" ] && . \"${{ZDOTDIR:-$HOME}}/.zshenv\"\n" ++
                    "export _ZMYTH_USER_ZDOTDIR=\"${{ZDOTDIR-__unset__}}\"\n" ++
                    "export ZDOTDIR={s}\n",
                .{rc_dir_q},
            ));
            const rc = try std.fmt.allocPrint(arena, "{s}/.zshrc", .{rc_dir});
            try writeFile(rc, try std.mem.concat(arena, u8, &.{
                "if [ \"$_ZMYTH_USER_ZDOTDIR\" = __unset__ ]; then unset ZDOTDIR; " ++
                    "else export ZDOTDIR=\"$_ZMYTH_USER_ZDOTDIR\"; fi\n" ++
                    "unset _ZMYTH_USER_ZDOTDIR _ZMYTH_ORIG_ZDOTDIR\n" ++
                    "[ -f \"${ZDOTDIR:-$HOME}/.zshrc\" ] && . \"${ZDOTDIR:-$HOME}/.zshrc\"\n",
                hookBody(.zsh),
            }));
            try env.append(arena, try std.fmt.allocPrintSentinel(arena, "_ZMYTH_ORIG_ZDOTDIR={s}", .{orig_zdot}, 0));
            try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}", .{rc_dir}, 0));
            try argv.appendSlice(arena, &.{ shell_path, "-i" });
        },
        .fish => {
            // -C runs *before* config.fish, but the hook only registers
            // event handlers (--on-event) — order vs user config doesn't
            // matter. Pass the body as the -C argument directly so rc_dir
            // (which may contain spaces/quotes) never appears in fish source.
            try argv.appendSlice(arena, &.{ shell_path, "-i", "-C", hookBody(.fish) });
        },
        .unknown => {
            log.warn("unknown shell '{s}'; spawning without hook", .{shell_path});
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

test "buildInstall: head -c N matches body length, body follows paste" {
    inline for (.{ Shell.bash, Shell.zsh, Shell.fish }) |sh| {
        const inst = try buildInstall(testing.allocator, sh);
        defer testing.allocator.free(inst);
        const body = hookBody(sh);
        // Ends with the hook body verbatim (streamed after the paste).
        try testing.expect(std.mem.endsWith(u8, inst, body));
        // The pasted script's `head -c N` uses the exact body length.
        var nb: [16]u8 = undefined;
        const ns = try std.fmt.bufPrint(&nb, "head -c {d} ", .{body.len});
        try testing.expect(std.mem.indexOf(u8, inst, ns) != null);
        try testing.expect(std.mem.startsWith(u8, inst, "\x15\x1b[200~mkdir -p"));
        // Paste terminator precedes the body.
        const pt = std.mem.indexOf(u8, inst, "\x1b[201~\r").?;
        try testing.expectEqual(inst.len - body.len, pt + 7);
    }
}

test "embedded hooks: comment-free, no ESC, end with newline" {
    inline for (.{ hook_bash, hook_zsh, hook_fish }) |h| {
        try testing.expect(std.mem.indexOf(u8, h, "__ZMYTH_HOOK_V") != null);
        // Paste-terminator safety: scripts must not contain raw ESC (the
        // `\033` in printf format strings is four literal chars).
        try testing.expect(std.mem.indexOfScalar(u8, h, 0x1b) == null);
        // Streamed via `head -c N` into a tty in canonical mode: a missing
        // trailing LF would leave head blocked waiting for the line.
        try testing.expectEqual(@as(u8, '\n'), h[h.len - 1]);
        // No control chars other than LF (canonical-mode line discipline
        // would treat ^D/^U/^C etc. as edits, corrupting the stream).
        for (h) |c| try testing.expect(c == '\n' or (c >= 0x20 and c < 0x7f));
        // No `#` at start-of-word (zsh INTERACTIVE_COMMENTS): `#` mid-word is
        // a parameter-expansion operator (`${V#p}`) or arithmetic base
        // (`10#$x`), which all three shells parse without the option.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, h, i, '#')) |p| : (i = p + 1) {
            try testing.expect(p > 0 and h[p - 1] != ' ' and h[p - 1] != '\n');
        }
    }
}

test "quoteRedirectTarget: tilde prefix unquoted through the slash" {
    const cases = .{
        .{ "/abs/path", "'/abs/path'" },
        .{ "~/foo", "~/'foo'" },
        .{ "~/foo's bar", "~/'foo'\\''s bar'" },
        .{ "~user/x", "~user/'x'" },
        .{ "~", "~''" },
        .{ "~root", "~root''" },
        .{ "rel", "'rel'" },
    };
    inline for (cases) |c| {
        const q = try quoteRedirectTarget(testing.allocator, c[0]);
        defer testing.allocator.free(q);
        try testing.expectEqualStrings(c[1], q);
    }
}

test "posixQuote" {
    const q1 = try posixQuote(testing.allocator, "/tmp/a b");
    defer testing.allocator.free(q1);
    try testing.expectEqualStrings("'/tmp/a b'", q1);

    const q2 = try posixQuote(testing.allocator, "it's");
    defer testing.allocator.free(q2);
    try testing.expectEqualStrings("'it'\\''s'", q2);

    const q3 = try posixQuote(testing.allocator, "");
    defer testing.allocator.free(q3);
    try testing.expectEqualStrings("''", q3);
}

test "hook_version constant matches __ZMYTH_HOOK_V in every asset" {
    // The probe reports the asset's hardcoded value; if this constant is
    // bumped without editing the assets, every probe says "stale" → install
    // loops forever. This test makes that drift a build failure.
    const px = std.fmt.comptimePrint("__ZMYTH_HOOK_V={d}", .{hook_version});
    const fish = std.fmt.comptimePrint("__ZMYTH_HOOK_V {d}", .{hook_version});
    inline for (.{ hook_bash, hook_zsh, hook_fish }) |h| {
        try testing.expect(std.mem.indexOf(u8, h, px) != null or
            std.mem.indexOf(u8, h, fish) != null);
    }
}

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
