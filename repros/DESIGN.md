# zmx redesign notes

Synthesized from: code review (`FINDINGS.md`), PoC (`poc-hooks/RESULTS.md`),
Warp's approach, and open GitHub issues.

## What Warp does that zmx should borrow

| Technique | Why | Effort |
|---|---|---|
| **Announce-DCS → inject precmd/preexec hooks** | Exit code + cwd + duration via OSC, no scrollback pollution, no `$?`/`$status` guessing, boundary-safe. PoC: 133/133 across bash/zsh/fish × starship/omp/p10k × ssh/nested. | M — hook scripts + OSC dispatch in ghostty callback |
| **Send command as one atomic write wrapped in bracketed-paste** (`\e[200~<cmd>\e[201~\r`) | Multi-line commands, `!`/`^`/tab/ctrl chars become literal; readline doesn't try to history-expand or complete mid-type. | S |
| **Prepend `Ctrl-U`** before each typed command | Clears any stuck readline buffer (fish syntax-error case, leftover from interrupted attach). | XS |
| **JSON-in-DCS** instead of positional OSC params | Extensible: `{"ec":0,"cwd":"/x","dur_ms":120,"pipestatus":[0,1,0]}` without protocol churn. | S |
| **Alt-screen sentinel** (`?1049h`/`l`) to bracket TUI regions | `zmx history` can mark `[interactive app]` instead of dumping garbage; `zmx run` can detect "inside a TUI, no prompt coming" and switch to send-only mode. | S |
| **Idle-gate**: only inject auxiliary commands when precmd has fired and preexec hasn't | Safe to run probes (`stty size`, `pwd`) without colliding with a running user command. | S |

**Skip:** tmux control mode (heavy, needs remote tmux, has CPR bugs); Warp's own line editor (out of scope).

## How GitHub issues map to the redesign

| Issue | What it asks | Addressed by |
|---|---|---|
| **#138** `zmx send` for TUI apps | Raw PTY input without the `; echo MARKER` trailer | New `run` has no trailer. Add `zmx run --no-wait` (or `zmx send`) that types and returns immediately; daemon detects TUI via `?1049h` and auto-selects this. |
| **#135** input dropped after re-attach to TUI | `isUserInput` per-chunk parser misclassifies CSI-u → non-leader payload silently dropped (main.zig:776) | **Already in FINDINGS** (read-boundary class). Fix: long-lived parser per client; never drop on `false`, just don't promote leader. |
| **#124** Ctrl+\ not detected under modifyOtherKeys | `isCtrlBackslash` doesn't match `\e[27;5;92~` | Add the xterm encoding to the matcher; longer-term, a single keypress decoder covering legacy/kitty/modifyOtherKeys. |
| **#123** `zmx run --help` creates session "--help" | Hand-rolled arg parsing | **Already in FINDINGS** (#09). Real arg parser. |
| **#132** `zmx list` O(n) on stale sessions | Sequential `connect()` with 1s timeout each | Probe all sockets concurrently (one `poll()` over N nonblocking connects); also auto-clean stale sockets so they don't accumulate. |
| **#106** session content leaks into scrollback | Restore sequence on detach doesn't properly leave alt-screen / clear | Wrap the whole attach in `?1049h` … `?1049l` so the host terminal's main screen is untouched; only do this if `isatty(stdout)`. |
| **#104** SSH agent forwarding stale | Daemon's `SSH_AUTH_SOCK` env captured at creation; new SSH connection has a new socket path | On each attach, client sends its `SSH_AUTH_SOCK`/`DISPLAY`/etc; daemon updates a symlink (`$ZMX_DIR/<sess>.ssh-auth → $SSH_AUTH_SOCK`) and the spawned shell's env points at the symlink. (Standard tmux `update-environment` pattern.) |
| **#28** logs in socket dir | `XDG_RUNTIME_DIR` is tmpfs, cleared on logout → logs lost; also it's small | Logs → `$XDG_STATE_HOME/zmx/` (or `~/.local/state/zmx/`). |
| **#81** "last active" in `list` | — | precmd hook already gives this for free (timestamp of last `done` OSC). |
| **#76** persist across reboot | — | Out of scope (needs serializing scrollback to disk + relaunching shell). Defer. |
| **#46** rename sessions | — | `zmx rename <old> <new>`: rename socket file + IPC msg so daemon updates `ZMX_SESSION` for next-spawned children. Low effort. |

## Remaining design changes vs current zmx (beyond what's in FINDINGS.md §Architecture)

1. **`run` becomes trailer-free.** Type `^U \e[200~<cmd>\e[201~ \r`, then wait for `preexec` OSC (line accepted) → `done` OSC (exit code). No `; echo …`. Fixes #04/#10/#15/#17/#138 and the shell-compat table in one move.

2. **Three input modes, auto-selected:**
   - `run <sess> <cmd>` — wait for `done` OSC (the normal case)
   - `run --no-wait <sess> <text>` / `send` — fire-and-forget (TUI apps, #138)
   - daemon auto-switches to no-wait when alt-screen is active

3. **Per-client persistent state** instead of ad-hoc per-chunk scanning: one ghostty input-parser per client (fixes #135), client identity = `*Client` not fd (fixes #08).

4. **Env refresh on attach** (`SSH_AUTH_SOCK`, `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`) via symlink indirection — fixes #104, the most-common "works in tmux, broken in zmx" complaint after the marker.

5. **Concurrent session probing** in `list`/`kill`/`wait`/`tail` via one nonblocking `poll()` — fixes #132.

6. **`--json` on `list`** and **`exit_code` always present** (null if unknown) — every issue filed by an AI agent (#138, #123, several closed) wants machine-readable status.

## Proposed CLI

```
attach <name> [cmd...]             interactive (auto-create)
run    <name> [-d] [-j] -- <cmd>   run cmd, propagate exit code (auto-create)
send   <name> [- | <bytes>]        raw PTY input, no waiting (#138)
read   <name> [-f] [-s] [-n N]     scrollback / -s screen / -f follow / -n tail
                [--vt|--html]      (replaces history + tail; -s shows alt-screen TUI)
write  <name> <path>               stdin -> file via PTY
wait   <name|glob>... [-j]
ls     [glob] [-j|-q]
kill   <name|glob>... [-9]
mv     <old> <new>                 (#46)
detach [<name>]
completions <shell> | version | help
```

Conventions: globs work on every selector; `-j` = JSON on every structured
output; `--` mandatory before user commands; auto-create only on
`attach`/`run`.

## Other approach changes vs current zmx

### Integration testing (#96)
Formalize the `repros/*.sh` pattern into `zig build test-integration`: each test
spawns sessions under `ZMX_DIR=$TMPDIR/zmx-test-<nonce>`, drives them via the
PoC harness pattern (PTY + stateful OSC scanner + assert on events), cleans up.
Every bug in FINDINGS.md is catchable this way.

### Scrollback bounds
Explicit `max_scrollback_lines` on the ghostty-vt Terminal (tmux default: 2000).
`read -n N` served from a ring buffer, not serialize-everything-then-truncate.
Prevents long-running noisy sessions from OOMing the daemon.

### Peer-credential check on accept()
`getsockopt(SO_PEERCRED)` (Linux) / `LOCAL_PEERCRED` (macOS) after `accept()`;
refuse if UID ≠ daemon's UID unless `ZMX_ALLOW_GROUP=1`. Closes the
crafted-IPC DoS surface (#14, #16) and makes group-sharing explicit opt-in
instead of a `ZMX_DIR_MODE` side-effect.

### Explicit `switch` instead of magic `attach`
main.zig:1658: `attach` inside a session silently becomes "switch the leader's
view." Surprising; broke isolated testing when `ZMX_SESSION` leaked. Make it
`zmx switch <name>` (or `attach --switch`) and have plain `attach` error with
"already inside session X; use `switch`".

### State-restore golden tests
The serialize/restore path owns most open correctness issues (#86 cursor style,
#106 scrollback leak, #135 input drop, #14 kitty graphics, README nested-SSH
cursor). Add fixtures: feed known VT bytes → serialize → replay into fresh
Terminal → `expectScreensMatch` cell-by-cell. Cover: alt-screen active, kitty
kbd mode, scrolling region set, OSC 8 hyperlinks, wide chars at wrap, SGR
stacks. util.zig:1203 already has the primitive; needs the fixture corpus.

### Surface daemon knowledge in `ls -j`
The precmd-OSC hook gives cwd, last-exit, duration, pipestatus, alt-screen
state, shell type for free. Expose them so `ls -j | jq` replaces ad-hoc probing
and the fzf picker (#132) shows live state without N round-trips:
```json
{"name":"dev","pid":123,"cwd":"/src","alt_screen":true,"last_exit":0,
 "last_active":1776...,"integration":"hooked","shell":"fish"}
```

## What stays the same

One daemon per session, unix socket per session, ghostty-vt for state restore,
no config file, no window management. The "smol contract" holds — these changes
are about making the in-band PTY channel reliable, not adding features.
