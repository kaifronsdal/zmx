//! Pure shell-side half of OSC-2718: hook scripts, the install/probe
//! one-liners, the `write` opener, and shell-string quoting. No fds, no
//! syscalls — everything here returns bytes for the caller to type.
//!
//! Contrast `protocol.zig` (parses what comes *out* of the PTY) and
//! `../spawn.zig` (the fd-using spawn/rc-shim half).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Shell = @import("protocol.zig").Shell;

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
///
/// The local hook is *not* delivered this way: the rc-shim sources
/// `hookBody` directly during shell startup, so BP being enabled is not a
/// precondition for hooking. BP *is* required for `run`/`write`/`hook`
/// (which type into a live prompt), and the hook itself forces it on
/// (`bind 'set enable-bracketed-paste on'` / `zle_bracketed_paste`) as its
/// last act, so a user rc that disabled it is overridden. If the user
/// disables it again *after* the hook loads, `run` fails visibly (ec=127,
/// `[200~cmd[201~: command not found`) — not silently.
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

// ───────────────────── spawn recipe ─────────────────────
//
// `spawnSpec()` is the pure half of spawning a hooked shell: it returns
// *what to write and exec*, not the syscalls. The caller writes `files`
// under `rc_dir`, merges `env_set` over their inherited env (after
// stripping `env_strip`), and execs `argv`. Works with fork/posix_spawn/
// remote-exec equally — and `lib/` stays fd-free.

pub const SpawnSpec = struct {
    /// argv[0] is `opts.shell_path`. All slices borrow from `arena` or
    /// `opts`; keep both alive until after exec.
    argv: []const []const u8,
    /// Env vars to set/override after stripping `env_strip`.
    env_set: []const KV,
    /// Keys to remove from the inherited env before applying `env_set`
    /// (zsh: ZDOTDIR + the ZDOTDIR-restore helpers, so a nested zsh
    /// inside the session reads the user's dotdir, not our shim).
    env_strip: []const []const u8,
    /// Files to write under `rc_dir` (paths relative to it) before exec.
    files: []const File,

    pub const KV = struct { key: []const u8, val: []const u8 };
    pub const File = struct { name: []const u8, content: []const u8 };
};

pub const SpawnOpts = struct {
    /// Absolute path to the shell binary.
    shell_path: []const u8,
    /// Directory the caller will write `files` into. Appears in argv
    /// (bash `--rcfile`) and env (zsh `ZDOTDIR=`), so the caller must
    /// create it and pass the real path.
    rc_dir: []const u8,
    /// Appended after the user's rc is sourced. Pass `hookBody(shell)`
    /// for OSC-2718, or your own integration snippet.
    body: []const u8,
    /// Current value of `$ZDOTDIR` (zsh only). null = unset.
    orig_zdotdir: ?[]const u8 = null,
};

/// Per-shell recipe for launching an interactive shell with `opts.body`
/// loaded *after* the user's rc, without breaking the user's config.
///
/// bash: `--rcfile` to a shim that sources `~/.bashrc` then `body`.
///
/// zsh: no `--rcfile` exists. Hijack `ZDOTDIR` to point at `rc_dir`; but
/// the user's `.zshenv` runs first and may itself set `ZDOTDIR`, so the
/// `.zshenv` shim restores the original, sources the user's, captures
/// whatever ZDOTDIR that left, and re-hijacks; the `.zshrc` shim then
/// restores the captured value before sourcing the user's `.zshrc`.
///
/// fish: `-C <body>` runs before `config.fish`; since the body only
/// registers event handlers, order doesn't matter and no file is needed.
///
/// `.unknown`: plain `-i`, no body — degraded mode.
///
/// All allocations go into `arena`; caller frees the arena.
pub fn spawnSpec(arena: Allocator, shell: Shell, opts: SpawnOpts) !SpawnSpec {
    const dupe = std.mem.concat;
    return switch (shell) {
        .bash => .{
            .argv = try dupe(arena, []const u8, &.{&.{
                opts.shell_path,
                "--rcfile",
                try std.fs.path.join(arena, &.{ opts.rc_dir, "bashrc" }),
                "-i",
            }}),
            .env_set = &.{},
            .env_strip = &.{},
            .files = try dupe(arena, SpawnSpec.File, &.{&.{.{
                .name = "bashrc",
                .content = try dupe(arena, u8, &.{
                    "[ -f ~/.bashrc ] && . ~/.bashrc\n",
                    opts.body,
                }),
            }}}),
        },
        .zsh => blk: {
            // rc_dir is user-influenced; quote it so a `'` in the path
            // can't break out of the assignment.
            const rc_q = try posixQuote(arena, opts.rc_dir);
            break :blk .{
                .argv = try dupe(arena, []const u8, &.{&.{ opts.shell_path, "-i" }}),
                .env_set = try dupe(arena, SpawnSpec.KV, &.{&.{
                    .{ .key = "_ZMYTH_ORIG_ZDOTDIR", .val = opts.orig_zdotdir orelse "" },
                    .{ .key = "ZDOTDIR", .val = opts.rc_dir },
                }}),
                .env_strip = &.{ "ZDOTDIR", "_ZMYTH_ORIG_ZDOTDIR" },
                .files = try dupe(arena, SpawnSpec.File, &.{&.{
                    .{
                        .name = ".zshenv",
                        .content = try std.fmt.allocPrint(
                            arena,
                            "if [ -n \"$_ZMYTH_ORIG_ZDOTDIR\" ]; then export ZDOTDIR=\"$_ZMYTH_ORIG_ZDOTDIR\"; else unset ZDOTDIR; fi\n" ++
                                "[ -f \"${{ZDOTDIR:-$HOME}}/.zshenv\" ] && . \"${{ZDOTDIR:-$HOME}}/.zshenv\"\n" ++
                                "export _ZMYTH_USER_ZDOTDIR=\"${{ZDOTDIR-__unset__}}\"\n" ++
                                "export ZDOTDIR={s}\n",
                            .{rc_q},
                        ),
                    },
                    .{
                        .name = ".zshrc",
                        .content = try dupe(arena, u8, &.{
                            "if [ \"$_ZMYTH_USER_ZDOTDIR\" = __unset__ ]; then unset ZDOTDIR; " ++
                                "else export ZDOTDIR=\"$_ZMYTH_USER_ZDOTDIR\"; fi\n" ++
                                "unset _ZMYTH_USER_ZDOTDIR _ZMYTH_ORIG_ZDOTDIR\n" ++
                                "[ -f \"${ZDOTDIR:-$HOME}/.zshrc\" ] && . \"${ZDOTDIR:-$HOME}/.zshrc\"\n",
                            opts.body,
                        }),
                    },
                }}),
            };
        },
        .fish => .{
            .argv = try dupe(arena, []const u8, &.{&.{ opts.shell_path, "-i", "-C", opts.body }}),
            .env_set = &.{},
            .env_strip = &.{},
            .files = &.{},
        },
        .unknown => .{
            .argv = try dupe(arena, []const u8, &.{&.{ opts.shell_path, "-i" }}),
            .env_set = &.{},
            .env_strip = &.{},
            .files = &.{},
        },
    };
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

test "spawnSpec: bash → --rcfile shim sourcing ~/.bashrc then body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try spawnSpec(arena.allocator(), .bash, .{
        .shell_path = "/bin/bash",
        .rc_dir = "/tmp/rc",
        .body = "BODY\n",
    });
    try testing.expectEqual(@as(usize, 4), spec.argv.len);
    try testing.expectEqualStrings("/bin/bash", spec.argv[0]);
    try testing.expectEqualStrings("--rcfile", spec.argv[1]);
    try testing.expectEqualStrings("/tmp/rc/bashrc", spec.argv[2]);
    try testing.expectEqualStrings("-i", spec.argv[3]);
    try testing.expectEqual(@as(usize, 0), spec.env_set.len);
    try testing.expectEqual(@as(usize, 0), spec.env_strip.len);
    try testing.expectEqual(@as(usize, 1), spec.files.len);
    try testing.expectEqualStrings("bashrc", spec.files[0].name);
    try testing.expect(std.mem.startsWith(u8, spec.files[0].content, "[ -f ~/.bashrc ] && . ~/.bashrc\n"));
    try testing.expect(std.mem.endsWith(u8, spec.files[0].content, "BODY\n"));
}

test "spawnSpec: zsh → ZDOTDIR hijack with two-file restore dance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try spawnSpec(arena.allocator(), .zsh, .{
        .shell_path = "/usr/bin/zsh",
        .rc_dir = "/run/x",
        .body = "BODY\n",
        .orig_zdotdir = "/home/u/.zsh",
    });
    try testing.expectEqualStrings("-i", spec.argv[1]);
    // env: ZDOTDIR points at rc_dir; the original is stashed.
    try testing.expectEqual(@as(usize, 2), spec.env_set.len);
    try testing.expectEqualStrings("_ZMYTH_ORIG_ZDOTDIR", spec.env_set[0].key);
    try testing.expectEqualStrings("/home/u/.zsh", spec.env_set[0].val);
    try testing.expectEqualStrings("ZDOTDIR", spec.env_set[1].key);
    try testing.expectEqualStrings("/run/x", spec.env_set[1].val);
    // env_strip: both keys, so a nested zsh inside the session inherits
    // neither our hijack nor the helper.
    try testing.expectEqual(@as(usize, 2), spec.env_strip.len);
    // Two shim files; .zshenv re-hijacks, .zshrc restores then loads body.
    try testing.expectEqual(@as(usize, 2), spec.files.len);
    try testing.expectEqualStrings(".zshenv", spec.files[0].name);
    try testing.expect(std.mem.indexOf(u8, spec.files[0].content, "export ZDOTDIR='/run/x'\n") != null);
    try testing.expectEqualStrings(".zshrc", spec.files[1].name);
    try testing.expect(std.mem.indexOf(u8, spec.files[1].content, "${ZDOTDIR:-$HOME}/.zshrc") != null);
    try testing.expect(std.mem.endsWith(u8, spec.files[1].content, "BODY\n"));
}

test "spawnSpec: zsh quotes rc_dir containing single-quote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try spawnSpec(arena.allocator(), .zsh, .{
        .shell_path = "zsh",
        .rc_dir = "/tmp/a'b",
        .body = "",
    });
    // The .zshenv shim assigns ZDOTDIR=<rc_dir>; an unquoted `'` would
    // break the assignment.
    try testing.expect(std.mem.indexOf(u8, spec.files[0].content, "'/tmp/a'\\''b'") != null);
}

test "spawnSpec: fish → -C body, no files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try spawnSpec(arena.allocator(), .fish, .{
        .shell_path = "/usr/bin/fish",
        .rc_dir = "/unused",
        .body = "function __x; end\n",
    });
    try testing.expectEqual(@as(usize, 4), spec.argv.len);
    try testing.expectEqualStrings("-C", spec.argv[2]);
    try testing.expectEqualStrings("function __x; end\n", spec.argv[3]);
    try testing.expectEqual(@as(usize, 0), spec.files.len);
    try testing.expectEqual(@as(usize, 0), spec.env_set.len);
}

test "spawnSpec: unknown → plain -i, degraded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try spawnSpec(arena.allocator(), .unknown, .{
        .shell_path = "/bin/sh",
        .rc_dir = "/unused",
        .body = "ignored",
    });
    try testing.expectEqual(@as(usize, 2), spec.argv.len);
    try testing.expectEqualStrings("-i", spec.argv[1]);
    try testing.expectEqual(@as(usize, 0), spec.files.len);
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

