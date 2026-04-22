# zmx v0.5.0 Code Review Findings

Reviewed at commit `81243b9` (upstream/main, v0.5.0). Built with Zig 0.15.2.
All repros use `ZMX_DIR=/tmp/zmx-test-*` for isolation; run from repo root.

## Summary

| # | Bug | Severity | Repro | Status |
|---|-----|----------|-------|--------|
| 01 | `run` flag `-d`/`--fish` swallows command args | **High** | ✅ deterministic | confirmed |
| 02 | `kill nonexistent` silently exits 0 | Medium (UX) | ✅ deterministic | confirmed |
| 03 | `write` >190KB silently truncates | **High** | ✅ deterministic | confirmed |
| 04 | ZMX_TASK_COMPLETED false-positive on user output | **High** | ✅ deterministic | confirmed |
| 05 | `tail` connects to same session twice | Medium | ✅ deterministic | confirmed |
| 06 | `write` path single-quote → shell injection | **High (security)** | ✅ deterministic | confirmed |
| 07 | Shared log lacks O_APPEND → lost writes | Medium | ✅ deterministic | confirmed |
| 08 | `closeClient` doesn't clear `leader_client_fd` | Medium | ✅ deterministic | confirmed |
| 09 | `zmx run -d <sess> <cmd>` (README example) broken | Medium (UX) | ✅ deterministic | confirmed |
| 10 | Sentinel split across 4096-byte read boundary | Medium | ⚠️ probabilistic | source-confirmed |
| 11 | `ipc.appendMessage` logs at info → log flood | Low | ✅ deterministic | confirmed |
| 12 | `tail` shares one `SocketBuffer` across sockets | **High** | ⚠️ probabilistic | source-confirmed |
| 14 | `handleWrite` u32 overflow → daemon panic | **High (DoS)** | ✅ deterministic | confirmed |
| 15 | `exit`/`exec` → marker never fires → rc=0 | Medium | ✅ deterministic | confirmed |
| 16 | `handleResize{0,0}` → daemon panic | **High (DoS)** | ✅ deterministic | confirmed |
| 17 | fish + arg ending in `\` → unterminated quote → hang | **High** | ✅ deterministic | confirmed |

Run all: `for f in repros/*.sh; do bash "$f"; done`
Convention: scripts **exit 1** when the bug reproduces, **exit 0** when not.

---

## Confirmed bugs with deterministic repros

### 01 — `run` flag parsing swallows command arguments
**`src/main.zig:159-171`** — Uses `std.mem.startsWith` for `-d`/`--fish` and scans *all* args, not just leading ones.
```sh
zmx run sess ls -d /        # runs `ls /` detached (lists root contents)
zmx run sess find . -depth  # -depth eaten
zmx run sess rm -drf x      # -drf eaten -> runs `rm x` detached
```
**Fix:** `std.mem.eql` instead of `startsWith`; stop parsing flags at first non-flag arg or `--`.

### 02 — `kill nonexistent` is silent
**`src/main.zig:231-246`** — Iterates existing sessions; unmatched names fall through with exit 0, no message. Compare `history nonexistent` which errors.
**Fix:** Track `matched` per matcher; error on unmatched.

### 03 — `write` silently corrupts files >~190KB
**`src/main.zig:1068-1090` + `742-757`** — `handleWrite` queues all base64 chunks synchronously; `queuePtyInput` drops once `pty_write_buf` exceeds 256KB. Client still gets `.Ack`.
Observed: 500000B in → 192000B out, 7 "pty input dropped" warnings, "file created" reported.
**Fix:** Either backpressure (`queuePtyInput` returns `error.BufferFull`, `handleWrite` defers remaining chunks across poll iterations) or send an error to the client.

### 04 — Task-complete sentinel matches user output
**`src/util.zig:326-351`** — `findTaskExitMarker` does unanchored `indexOf` on `ZMX_TASK_COMPLETED:`.
```sh
zmx run sess echo ZMX_TASK_COMPLETED:42   # exits 42, list shows exit_code=42
```
Real-world trigger: nested `zmx run`, or grepping zmx source/logs.
**Fix:** Per-run random nonce in the marker (`ZMX_TASK_COMPLETED:<16-hex>:<code>`); also fixes #10.

### 05 — `tail` connects to same session N times
**`src/main.zig:296-318`** — No dedup of resolved names.
```sh
zmx tail bb bb       # bb connected twice; output duplicated
zmx tail 'b*' bb     # same when bb exists
```
**Fix:** Dedup `resolved_names` (StringHashMap or linear check).

### 06 — `write` path with `'` → shell injection
**`src/main.zig:1084`** — `file_path` interpolated raw between single quotes.
```sh
echo hi | zmx write sess "/tmp/x'; touch /tmp/pwned; echo '"
```
README warns but nothing enforces.
**Fix:** Reject `'`/`\n`/`\r` in path with `error.InvalidPath`, or escape via `'\''`.

### 07 — Shared log opened without `O_APPEND`
**`src/log.zig:17-28`** — `openFileAbsolute(.read_write)` + `seekTo(end)`. Concurrent CLI invocations overwrite each other's lines. Observed: 80 concurrent → 46-56 lines.
**Fix:** Open with `posix.open(..., .{ .APPEND = true, .CREAT = true, ... })`.
Related: `rotate()` (log.zig:91-94) leaves `self.file = null` permanently if rename fails with anything other than `FileNotFound`.

### 08 — Stale `leader_client_fd` after abrupt disconnect
**`src/main.zig:544-555`** — `closeClient()` (and `handleDetachAll()` :914-921) never clears `leader_client_fd`; only `handleDetach()` (:909) does. After kill -9 / SSH drop, the next attaching client is not promoted on `handleInit` (:841), so PTY is not resized until first keypress (line 777). FD reuse can mask this by accident.
**Fix:** In `closeClient`: `if (self.leader_client_fd == fd) self.leader_client_fd = null;`

### 09 — Documented `zmx run -d <sess> <cmd>` doesn't work
**`src/main.zig:153`** — `session_name = args.next()` consumed *before* the flag loop. `zmx run -d dev sleep 1` creates session `-d`, runs `dev sleep 1`. README and `zmx help` both show this broken example.
**Fix:** Parse leading flags before consuming session name (or fix docs to `zmx run dev -d ...`).

### 11 — IPC message log flood
**`src/ipc.zig:86`** — `std.log.info` for every `appendMessage`. One per ≤4KB of PTY output per client. 100KB output → 29 log lines; 1GB → ~250K lines, constant `rotate()` churn (compounding #07).
**Fix:** Change to `std.log.debug`.

---

## Source-confirmed bugs (probabilistic / hard to repro deterministically)

### 10 — Read-boundary split bugs (the class you asked about)
**`src/main.zig:2223`** — Daemon reads PTY into `var buf: [4096]u8` and passes `buf[0..n]` independently to three scanners with **no carry buffer**:
- `findTaskExitMarker(buf[0..n])` (:2252) — marker straddling reads → never detected, `zmx run` hangs; split mid-number → wrong exit code.
- `rewritePromptRedraw(buf[0..n])` (:2269) — `OSC 133;A...BEL` straddling reads → forwarded unmodified, #111 fix silently regresses.
- `respondToDeviceAttributes(buf[0..n])` (:2247) — `ESC[c` straddling reads → unanswered, fish waits 2s.

Also: `findTaskExitMarker` (util.zig:330) does a single `indexOf`; if the first match in a chunk fails `parseInt` (e.g. the echoed `:$?`), a valid marker later in the *same chunk* is skipped.

Client-side: `isCtrlBackslash` (main.zig:2048, util.zig:354-356) checks `buf[0]==0x1C` only — Ctrl+\ coalesced after another byte in the same `read()` is missed.

**Fix:** Add a stateful `PtyScanner` struct on `Daemon` with a small carry buffer (≤64B = max marker length). Prepend carry to each chunk before scanning, save the unconsumed tail. Unit-test by splitting a known sequence at every offset.

### 12 — `tail()` shared `SocketBuffer` across sockets
**`src/main.zig:1227, 1265`** — One `read_buf` for all polled sockets. Partial frame from socket A + bytes from socket B → corrupt header → garbage / stall.
**Fix:** `read_bufs: []SocketBuffer` parallel to `client_socket_fds`.

### 14 — Daemon crash via crafted `.Write` (u32 overflow)
**`src/main.zig:1054-1057`** — `path_len` is u32 from the wire; `@sizeOf(u32) + path_len` is evaluated in u32. `path_len ≥ 0xFFFFFFFC` overflows → ReleaseSafe panic (ReleaseFast: check passes, then OOB slice). Any local process that can connect to the unix socket kills the daemon and the user's session with a 12-byte message.
**Fix:** widen to usize before adding (mirror ipc.zig:65).

---

## Additional read-buffer-boundary issues (per follow-up audit)

| Location | Issue | Severity |
|----------|-------|----------|
| `main.zig:776-779` + `util.zig:446-477` | `isUserInput(payload)` instantiates a fresh ghostty parser per `.Input` message (= one client stdin `read()`). Non-leader client whose escape sequence splits across reads: chunk N (`\x1b[`) → returns false → **payload silently dropped** (no else branch); chunk N+1 (`92;5u`) → printable → leader switch + bare suffix injected into shell. Corrupted input + spurious leader steal. | **High** |
| `util.zig:330` | `findTaskExitMarker` does single `indexOf`; if first match in chunk fails parseInt (e.g. echoed `:$?`), valid marker later in *same chunk* is skipped. | Medium |
| `util.zig:219-230` | `rewritePromptRedraw`: if `\x1b]133;A` has no terminator in chunk but a stray BEL appears later in same chunk, everything between is treated as params → `;redraw=0` injected before unrelated BEL, corrupting output. | Medium |
| `util.zig:209-229` | `rewritePromptRedraw` is O(N²) on N unterminated `\x1b]133;A` markers; called at main.zig:827 on full serialized scrollback (potentially MB). | Low |
| `main.zig:1836-1845` | `writeFile()` Ack wait: single `sb.read()` then loop. Split 5-byte Ack header → false `error.NoAckReceived`. | Low |
| `util.zig:360` | `isUpArrow` is whole-buffer `eql` (split-unsafe) but **dead code** — no callers. | — |

**No out-of-bounds reads found** in any hand-rolled parser — every index is guarded.

## Buffer overflow / unsafe cast / DoS

| Location | Issue | Severity |
|----------|-------|----------|
| `main.zig:1055,1057` | u32 overflow in `handleWrite` path_len check → daemon panic. **See repro #14.** | **High** |
| `ipc.zig:143-161` | `SocketBuffer.read` appends without cap; `header.len=0xFFFFFFFF` + trickle → daemon OOM. | **High** |
| `main.zig:885-897` | `handleResize` accepts `rows=0`/`cols=0` from wire; if ghostty stores it, `serializeTerminalState` (util.zig:514,543-544) does `cols-1`/`rows-1` → underflow panic on next attach. | Medium |
| `main.zig:945,977,986-987` | `cmd_buf`/`cwd_buf` declared `undefined`, only prefix written, whole array sent via `asBytes(&info)` → uninitialized stack bytes on the wire. Same-uid socket so limited impact. | Medium |
| `ipc.zig:71,89` | `@intCast(data.len)` usize→u32 panics on >4GB payload (writeFile stdin). | Low |
| `main.zig:143,189,358,1753,2254` | `@intCast(timestamp())` i64→u64 panics if clock < 1970. | Low |
| `main.zig:941` | `clients.items.len - 1` underflows if empty. Currently unreachable. | Low |

## Partial-write audit

`posix.write()` callers that don't loop on `n < len`:

| Location | Impact |
|----------|--------|
| `main.zig:1615` | `history` payload → stdout, single write. Stdout is blocking so partial only on signal interrupt; low practical risk. |
| `main.zig:1319-1321` | `tail()` returns on TaskComplete after possibly-partial write → final `zmx run` output bytes can be dropped when stdout pipe is full. |
| `main.zig:1282,1698,1722` | Small fixed strings (≤20B); cosmetic. |

All other write paths (clientLoop, daemonLoop, ipc.writeAll) correctly loop.

### Other source-confirmed (no repro script)

| Location | Issue |
|----------|-------|
| `ipc.zig:60-66` | Unbounded `header.len` → malicious client can OOM daemon. Cap at e.g. 16MiB. |
| `main.zig:2271-2280` | Per-client `write_buf` unbounded → stalled client (`zmx tail \| sleep`) OOMs daemon. |
| `main.zig:1314-1324` | `tail()`: returns after partial `posix.write` if `task_complete_code` set → trailing output dropped. Also: if `TaskComplete` arrives with `stdout_buf` empty, return is gated on `len > 0` → loops back into `poll()` forever. |
| `main.zig:691-735` | Daemon child never closes/redirects fd 0/1/2 → holds launching terminal's PTY open for daemon lifetime (observed while writing repro 08). |
| `main.zig:923-937` | `handleKill` always sleeps 500ms + SIGKILL on every daemon exit, even clean shell exit. |
| `main.zig:1917-1921` | Piped-stdin to `run` only normalises *trailing* `\n`→`\r`; multi-line stdin sends interior `\n` which readline ignores. |
| `util.zig:488-580` | `serializeTerminalState`: early `return null` paths skip restoring `synchronized_output` mode → permanently mutates daemon's terminal state. Wrap restore in `defer`. |
| `util.zig:204` | `rewritePromptRedraw`: `errdefer result.deinit()` is dead (return type is `?[]u8`, not error union); `catch return null` paths leak. |

---

## UX / consistency issues

- `zmx completions <unknown>` and `zmx completions` (no arg) → silent exit 0 (main.zig:92-93).
- `zmx detach` outside a session → logs to *file*, exits 0, nothing to stderr (main.zig:1489).
- `kill` of unresponsive session prints hint to **stdout** instead of stderr.
- `error.SessionNameRequired` etc bubble out as raw Zig error traces, no usage hint.
- `tail` on non-existent exact name → raw `error.FileNotFound` (main.zig:333), not the friendly message used elsewhere.
- `run`'s "session created" line goes to stdout (main.zig:1863), polluting captured output.
- Help text shows `ctrl+\\` (double backslash) instead of `ctrl+\` (main.zig:1134).
- **README/help mismatch:** `zmx wait` (no args) with `ZMX_SESSION_PREFIX` set is documented to wait on prefix, but returns `error.SessionNameRequired` (main.zig:260).
- **Stale completions:** bash/zsh completions (completions.zig) lack `wait`, `tail`, `write`, `--force`, `--vt`, `--html`, `-d`, `--fish`. Fish has them.
- `ZMX_DIR_MODE` parse failure silently falls back to 0750 (main.zig:405-411); also umask defeats the documented `0770` example because `mkdirat` doesn't `chmod` after.

---

## Verification of secondary claims

After empirical testing, the following claims from the initial review were **corrected**:

| Claim | Verdict |
|---|---|
| zsh `NOMATCH` aborts the whole line → marker skipped | ❌ **WRONG** — aborts only the command; marker fires with `$?=1` |
| bash interactive ignores `set -e` | ❌ **WRONG** — `set -e; false` exits the shell → same as `exit` case |
| Multi-line stdin (`printf 'a\nb\n' \| zmx run`) only runs last line | ❌ **WRONG** — both lines run; bash readline accepts `\n` as well as `\r` |

And these were **confirmed**:

| Claim | Evidence |
|---|---|
| fish `'foo\'` is unterminated → `zmx run` hangs | ✅ repro #17, rc=124 |
| fish `$?` errors → `zmx run` without `--fish` on fish session hangs | ✅ "fish: $? is not the exit status" |
| fish `'\\' ` → `\` (loses backslash inside single quotes) | ✅ `fish -c "echo 'a\\\\b'"` → `a\b` |
| `handleResize{0,0}` crashes daemon | ✅ repro #16 |
| Daemon holds launching terminal's fd 0/1/2 | ✅ `/proc/<daemon>/fd/{0,1,2}` → `/dev/pts/N` |
| `handleKill` 500ms sleep on every exit (incl. clean) | ✅ measured ~500ms after `exit` |
| `Info` struct leaks uninitialized stack bytes on wire | ✅ 256 bytes of `0xaa` (ReleaseSafe poison) observed |
| bash/zsh completions missing `wait`/`tail`/`write` | ✅ completions.zig:32,72-82 |
| zsh first-run wizard eats first command's bytes | ✅ `echo HELLO` → `cho HELLO` |

---

## Shell / terminal compatibility

**Trailer `$?` vs `$status`** (main.zig:1032-1035): only bash/zsh/dash/ksh + fish handled. csh/tcsh (`$?`=is-set), nushell/xonsh/elvish/pwsh (no `$?` / no `;`) → marker never emitted → `run`/`wait` hang. `is_fish` (main.zig:1871) comes from the *client* flag, not the daemon's actual shell.

**Trailer robustness** (see repro #15): `exit`/`exec`/shell-segfault/zsh-`ERR_EXIT` → marker skipped, daemon exits on PTY EOF, `zmx run` returns **0** (main.zig:1275), real exit code lost. Readline continuation (unbalanced quote via stdin path) → marker skipped, shell survives → **`run`/`wait` hang forever**. (zsh `NOMATCH` is fine — verified: it aborts the command, not the line; marker fires with code 1.) Shell startup prompts (zsh-newuser-install, omz updater) consume the first bytes of the first `zmx run` command.

**`shellQuote`** (util.zig:117-140): POSIX `'…'\''…'` breaks on fish (`\` escapes inside `'…'`), csh (`!` expands, newlines illegal), pwsh/nu/xonsh (different escape).

**`handleWrite`** assumes `printf`/`base64`/`>` — broken on pwsh/nushell.

**Terminal**: hard-coded DA1/DA2 responses (util.zig:146) misreport capabilities; unconditional `\e[<u` kitty-pop on detach (main.zig:1696); restore seqs written without `isatty` check.

**Recommended marker redesign:** Replace `echo ZMX_TASK_COMPLETED:$?` with an OSC escape: `printf '\e]888;zmx;<nonce>;%d\a' $?`. ghostty-vt (already fed every PTY byte at main.zig:2236) swallows unknown OSC → nothing in history/scrollback; stateful parser → no boundary-split; nonce → no false-positive; in-band → SSH-safe. Also: treat PTY EOF as task-complete using `waitpid` status (main.zig:723) so `exit N` reports N instead of 0.

---

## Architectural recommendations

1. **Adopt a real arg parser** (zig-clap or ~100 LoC custom). Distinguishes flags from positionals, supports `--`, errors on unknown flags. Eliminates #01, #09, and the `--force`/`--short` `startsWith` brittleness in one move.

2. **Stateful `PtyScanner` struct.** Owns a carry buffer; exposes `scan(chunk)` returning `{exit_marker, rewritten, da_response}`. All three per-chunk scanners (#10) share one boundary-correct implementation. Unit-test by feeding a known sequence split at every byte offset.

3. **Make every queue/append fallible and bounded.** Replace raw `ArrayList(u8)` for `pty_write_buf` and `client.write_buf` with a `BoundedBuffer` whose `append` returns `error.Full`. Compiler forces callers to choose drop/backpressure/evict. Closes #03, the unbounded-write_buf OOM, and the IPC `header.len` OOM.

4. **One `resolveSessions(matchers) ![]Session`** shared by `kill`/`wait`/`tail`. Dedupes, errors on unmatched, returns owned names. Removes the four hand-rolled match loops where #02 and #05 live.

5. **Never build shell strings by concatenation.** Route every PTY-injected string (`handleWrite`, the `run` trailer, fish branch) through a single `shellQuote` helper. Closes #06 and the latent fish-quoting bug (util.zig:117-140 — `'a\'` is unterminated in fish).

6. **Robustness features for the AI-agent use-case:** `zmx exists <name>` (exit-code-only check), `zmx wait --timeout N`, `zmx run --timeout N` (auto-^C on hang), `zmx list --json`. Auto-detect shell from daemon state instead of `--fish`.
