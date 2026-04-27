//! Per-shell knowledge: everything zmyth *types into* a shell.
//!
//! - Hook scripts (assets/hook.*) and the bracketed-paste wrapper that
//!   delivers them
//! - The `zmyth hook` install sequence (`buildInstall`) and probe one-liner
//! - Shell-string quoting
//! - Per-attach env-var lists
//!
//! Contrast with `protocol.zig`, which parses what comes *out* of the PTY,
//! and `spawn.zig`, which forks the shell process.

const std = @import("std");

pub const Shell = @import("protocol.zig").Shell;

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
pub const hook_version: u32 = 1;

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

/// Hook script body for `shell`. This is what `buildInject` pastes verbatim
/// and what `buildInstall`'s `head -c` writes to the hook file.
pub fn hookBody(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => hook_bash,
        .zsh => hook_zsh,
        .fish => hook_fish,
        .unknown => unreachable,
    };
}

/// Build the keystroke sequence to inject the hook for `shell` into a PTY.
/// Hook scripts contain only printable bytes; the paste terminator `\e[201~`
/// cannot occur in them. Caller frees.
pub fn buildInject(allocator: std.mem.Allocator, shell: Shell) ![]u8 {
    return wrapPaste(allocator, hookBody(shell));
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
    switch (shell) {
        .bash, .zsh => {
            // ZDOTDIR: zsh reads $ZDOTDIR/.zshrc, not ~/.zshrc, when set.
            const rc = if (shell == .bash) "~/.bashrc" else "\"${ZDOTDIR:-$HOME}/.zshrc\"";
            const ext = @tagName(shell);
            // rc-append gated on hook-file existence, not grep: a user who
            // moved/commented the line, or sources it from .bash_profile,
            // shouldn't get a duplicate. The appended line is itself
            // `[ -f ] &&`-guarded so a later `rm -rf ~/.config/zmyth`
            // uninstall leaves no broken-source error. `>|` survives
            // `set -o noclobber` on upgrade.
            try w.print(
                "mkdir -p {s}; [ -f {s}/hook.{s} ] || echo '{s}' >> {s}\n" ++
                    "stty -echo; head -c {d} | tr '\\r' '\\n' >| {s}/hook.{s}; stty echo\n" ++
                    ". {s}/hook.{s}",
                .{ hook_dir, hook_dir, ext, rcSourceLine(shell), rc, body.len, hook_dir, ext, hook_dir, ext },
            );
        },
        .fish => try w.print(
            // fish has no noclobber (`>` always overwrites) and conf.d/ is
            // ours alone, so plain `>` and unconditional rewrite are fine.
            "mkdir -p {s} ~/.config/fish/conf.d; echo '{s}' > ~/.config/fish/conf.d/zmyth.fish\n" ++
                "stty -echo; head -c {d} | tr '\\r' '\\n' > {s}/hook.fish; stty echo\n" ++
                "source {s}/hook.fish",
            .{ hook_dir, rcSourceLine(.fish), body.len, hook_dir, hook_dir },
        ),
        .unknown => unreachable,
    }
    try w.writeAll(paste_close);
    try w.writeAll(body);
    return out.toOwnedSlice(allocator);
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

/// Subset of `env_forward` whose values are filesystem paths and so can be
/// refreshed via symlink indirection without restarting the shell. The others
/// (DISPLAY, DBUS_…) need an env-reload mechanism — deferred (DESIGN.md #104).
pub const refresh_env_keys = [_][]const u8{
    "SSH_AUTH_SOCK",
    "WAYLAND_DISPLAY",
};

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

test "buildInject wraps script verbatim" {
    inline for (.{ Shell.bash, Shell.zsh, Shell.fish }) |sh| {
        const inj = try buildInject(testing.allocator, sh);
        defer testing.allocator.free(inj);
        try testing.expect(std.mem.startsWith(u8, inj, "\x15\x1b[200~"));
        try testing.expect(std.mem.endsWith(u8, inj, "\x1b[201~\r"));
        try testing.expect(std.mem.indexOf(u8, inj, "__ZMYTH_HOOK_V") != null);
        // No external-binary dependency in the inject path.
        try testing.expect(std.mem.indexOf(u8, inj, "base64") == null);
    }
}

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
    const posix = std.fmt.comptimePrint("__ZMYTH_HOOK_V={d}", .{hook_version});
    const fish = std.fmt.comptimePrint("__ZMYTH_HOOK_V {d}", .{hook_version});
    inline for (.{ hook_bash, hook_zsh, hook_fish }) |h| {
        try testing.expect(std.mem.indexOf(u8, h, posix) != null or
            std.mem.indexOf(u8, h, fish) != null);
    }
}

test "Shell.parse round-trips every named variant" {
    // `parse` is an if-chain (not a switch), so adding a Shell variant doesn't
    // force updating it. This test does.
    inline for (comptime std.meta.tags(Shell)) |sh| {
        if (comptime sh != .unknown)
            try testing.expectEqual(sh, Shell.parse(@tagName(sh)));
    }
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
