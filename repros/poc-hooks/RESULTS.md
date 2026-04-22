# PoC: announce → inject → precmd-OSC approach

**55/55 tests pass.** Harness: `harness.py`, matrix: `test_matrix.py`.
Requires `/tmp/zmx-poc-sshd` (run `sshd -f /tmp/zmx-poc-sshd/sshd_config` first) for SSH cases.

## Protocol tested

1. Shell rc emits `\e]2718;hello;<shell>\a` at startup (one line per shell).
2. Daemon-side parser sees it, types `eval "$(echo <b64> | base64 -d)"` (or `| source` for fish) to install a precmd hook.
3. Hook emits `\e]2718;done;<exit>;<pwd>\a` before every prompt.
4. `run` types the bare command (no trailer); reads exit code from the OSC.
5. Fallbacks: `\e[?2004h` (back-at-prompt, code unknown) → PTY EOF (`waitpid` code) → timeout.

## Prompt-engine compatibility (84/84 pass)

| | bash | zsh | fish |
|---|---|---|---|
| plain | ✅ | ✅ | ✅ |
| **starship** 1.25.0 | ✅ | ✅ | ✅ |
| **oh-my-posh** 29.10.0 | ✅ | ✅ | ✅ |
| **powerlevel10k** | — | ✅ | — |

All return correct exit codes (0/1/17) via OSC. Coexistence works because:
- bash hook **prepends** to `PROMPT_COMMAND` → captures `$?` before starship/omp run
- zsh: `precmd_functions` entries each see the original `$?` (zsh preserves it)
- fish: `--on-event fish_prompt` handlers each see original `$status`

## Coverage

| Scenario | Result |
|---|---|
| bash / zsh / fish — basic exit codes (0, 1, 42, 2, 143) | ✅ |
| Coexists with existing `PROMPT_COMMAND` / `precmd()` / `precmd_functions` / custom `fish_prompt` | ✅ |
| `exec foo` / `exit N` | ✅ via `pty-eof` (waitpid gives the real code) |
| Backgrounded `cmd &` | ✅ precmd fires immediately (ec=0 — same as `$?`) |
| Syntax error | ✅ bash (ec=2), ⚠️ zsh (precmd fires but `$?` stale), ⚠️ fish ([#8832](https://github.com/fish-shell/fish-shell/issues/8832): `fish_prompt` event skipped → needs timeout) |
| 50KB output before OSC (boundary split) | ✅ stateful scanner |
| No rc snippet present | ✅ degrades to `?2004h` prompt-fallback (completion only, no code) |
| Nested `bash → bash` | ✅ re-announce → re-inject; outer hook survives inner exit |
| `ssh localhost → bash` | ✅ remote announce traverses SSH PTY; injection typed through |
| `ssh → bash → fish` (cross-shell, cross-host nesting) | ✅ each layer announces; correct shell-specific hook injected each time |
| User forges the OSC | ⚠️ observed — production needs per-session nonce (`2718;done;<nonce>;<ec>`) |

## vs current zmx `; echo ZMX_TASK_COMPLETED:$?`

| Property | Current | This approach |
|---|---|---|
| Scrollback pollution | marker visible in `history` | none (terminal swallows OSC) |
| False-positive on user output | yes (#04) | needs nonce, then no |
| Read-boundary split | yes (#10) | no (stateful parser) |
| `$?` vs `$status` vs … | `--fish` flag, wrong if mismatched | shell self-identifies in announce |
| `exit`/`exec` → wrong code 0 | yes (#15) | no (`pty-eof` + `waitpid`) |
| fish trailing-`\` quote hang | yes (#17) | no (no trailer to mis-quote) |
| Works over SSH/docker/sudo | yes | yes |
| Requires remote rc edit | no | yes — one `printf` line (or daemon injects for the shell it spawns) |

## "Weird construct" coverage (133/133 pass)

All via OSC across bash/zsh/fish: pipes (`a|b`), `&&`/`||`, subshells `(...)`,
process substitution `<(...)`, command substitution `$(...)`, `a; b; c`,
redirects, 5KB single command line, background `cmd &` (returns ec=0
immediately — correct shell semantics; `wait` afterwards → ec=0), heredocs
(multi-line `\r`-separated), **Ctrl-C mid-command → ec=130 + clean recovery**.

## The one remaining hard case: incomplete input (unclosed quote/block)

| Shell | `echo "foo<CR>` | Why |
|---|---|---|
| bash | `prompt-fallback` (ec=unknown, **no hang**) | readline emits `?2004h` at PS2 too |
| zsh | `prompt-fallback` (ec=unknown, **no hang**) | zle emits `?2004h` at `dquote>` |
| fish | no signal | fish continuation emits nothing — no preexec, no prompt, no posterror |

**Fix without `--timeout`:** add a `preexec` OSC to all three hooks. After sending
`<cmd>\r`, the daemon waits a short bounded interval (~300ms) for **line
acceptance** — i.e., any of `preexec` / `done` / `posterror` / `?2004h`. If none
arrives, the line is in continuation → send `^C`, report ec=125. This is not a
command-duration timeout: a 30-minute `sleep 1800` fires `preexec` within
milliseconds, so the daemon knows to keep waiting. Verified: fish fires
`fish_preexec` for valid commands (instantly) and nothing for incomplete input.

## Residual limitations

- **fish syntax error** keeps the bad input in the line buffer and skips `fish_prompt` event ([#8832](https://github.com/fish-shell/fish-shell/issues/8832)). Mitigation: `--timeout` + send `^C` on timeout.
- **zsh syntax error** fires precmd but `$?` is from the *previous* command. Better than current (which would skip the trailer entirely), but the code is wrong.
- **dash/busybox sh** — no `PROMPT_COMMAND`, no precmd, no `?2004h`. Only timeout works. (Same as current.)
- **The injection itself appears in scrollback once** (the `eval $(echo … | base64 -d)` line). Could be hidden with `\e[2K\r` after, or by using bracketed-paste so it executes as one unit.
- The remote rc-file line is a setup step. For local sessions zmx can inject it via env/`--rcfile` at spawn; for SSH the user adds it once (same model as Warp).
