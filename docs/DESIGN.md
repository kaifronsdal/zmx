# zmyth design

This document explains how zmyth works, from the problem it solves up to the
module layout, for someone with no prior context. It's the "why" companion to
the source; implementation details that change often live in the file-level
`//!` doc comments.

## The problem

You want two things that existing tools each give you half of:

1. **A shell that survives disconnection.** SSH drops, you close the laptop,
  the terminal tab dies — the shell and whatever it was running keep going,
   and you can reattach later. tmux/screen/dtach do this.
2. **Programmatic command execution with results.** From a script or an agent:
  "run `make` in that session, tell me the exit code and how long it took."
   tmux can `send-keys` but can't tell you when the command finished or what it
   returned; you're back to scraping output.

zmyth's predecessor, zmx, did (2) by appending a marker to every command —
`make; echo __ZMX_DONE__$?` — and grepping for it in the PTY output. That
breaks when the command is multi-line, when the output happens to contain the
marker string, when the prompt framework wraps the line, and a dozen other ways
catalogued in `[archive/FINDINGS.md](archive/FINDINGS.md)`.

zmyth's answer is to have the shell *itself* announce command boundaries, over
a side channel that doesn't appear in scrollback.

## The core mechanism: OSC 2718

Shells have hooks that fire around command execution:


| shell | before a command runs | after it finishes   |
| ----- | --------------------- | ------------------- |
| bash  | `DEBUG` trap          | `PROMPT_COMMAND`    |
| zsh   | `preexec`             | `precmd`            |
| fish  | `fish_preexec` event  | `fish_prompt` event |


zmyth installs a function on each that emits an **OSC sequence** — `ESC ] ... BEL`. Terminals render OSCs invisibly (they're how shells set the window
title), so nothing appears in scrollback, and the bytes pass through SSH/PTYs
untouched. We use the private code `2718` (Euler's number; unclaimed):

```
ESC ] 2718;preexec;<pid> BEL                          # line accepted, about to run
ESC ] 2718;done;<pid>;<ec>;<dur_ms>;<shell+cap>;<cwd> BEL   # command finished
ESC ] 2718;probe;b=<ver>,z=<ver>,f=<ver>,h=<hookver> BEL    # shell-detection reply
```

The daemon runs a small streaming `**Scanner**` over the PTY output that picks
these out (handling sequences split across `read()` boundaries), alongside a
full **ghostty-vt `Terminal`** that renders everything for attach/scrollback.
The shell hook is ~30 lines per shell (`[lib/assets/hook.](../src/lib/assets)*`);
loading it is the only intrusion zmyth makes into the user's environment.

### Why OSC, not the alternatives

- **vs. `; echo MARKER$?`** — output can't forge it (a private OSC in user
output is astronomically unlikely, and the `done` carries the shell's pid so
a forgery from a different process is detectable). Works with multi-line
commands, heredocs, `&&`/`||` chains, fish (no `$?`).
- **vs. OSC 133 (iTerm2/FinalTerm shell integration)** — 133 marks prompt
boundaries but doesn't carry pid (so nested shells are indistinguishable),
and starship/oh-my-posh already emit it, so we'd collide. zmyth *reads* 133
as a fallback signal in unhooked shells but doesn't rely on it.
- **vs. a side-channel socket from the hook** — OSCs ride the PTY, so they
work over SSH/docker/su without needing the remote to reach the daemon's
socket.

## Process model

```
┌──────────┐  unix socket   ┌──────────┐  pty pair   ┌─────────┐
│  client  │◄──────────────►│  daemon  │◄───────────►│  shell  │
│ (zmyth   │   ipc.Framer   │ (one per │   Session   │  bash/  │
│  attach/ │                │ session) │   tracks    │  zsh/   │
│  run/…)  │                │          │   state     │  fish   │
└──────────┘                └──────────┘             └─────────┘
```

- **One daemon per session.** `zmyth attach foo` forks a daemon if `foo`
doesn't exist, then connects. The daemon owns a PTY master, spawns the shell
on the slave, and runs a single-threaded `poll()` loop over the PTY + a
listening Unix socket + N connected clients.
- **Clients are short-lived** (`run`, `read`, `ls`) or long-lived (`attach`).
Multiple attaches share one PTY; the most-recently-typing client is "leader"
and its terminal size wins.
- **No central server.** Each session is independent; `zmyth ls` just globs
the socket directory and probes each one concurrently.

### Why one-daemon-per-session

A single multiplexing server (tmux model) would mean one crash takes every
session with it, and one client's `read` of a 100MB scrollback would stall
every other session's I/O in a single-threaded loop. Per-session daemons cost
~2MB RSS each and isolate failures completely. The trade-off is `ls` has to
fan out — solved with one nonblocking `poll()` over N connects.

## The `Session` state machine

`Session` (`[lib/session.zig](../src/lib/session.zig)`) is the heart. It owns
three pieces of state that the OSC events drive simultaneously:

### Layer stack

A "layer" is one nested shell: the local bash is layer 0; `ssh remote` inside
it is layer 1; `docker exec` inside that is layer 2. Each layer is keyed by
the **pid in its `done` OSC** — that's the one stable identifier that survives
the network hop (the daemon never sees the remote pid via any other channel).

- `done` from a **new** pid → push a layer (a freshly-hooked nested shell
reached its first prompt).
- `done` from a pid **below** the top → pop down to it (the nested shell
exited; this is the *parent's* `done` for the `ssh` command itself).
- `?2004h` (bracketed-paste-on) with no `done` → push a *degraded* layer
(an unhooked nested shell — we can see it's at a prompt but know nothing
else). If a real `done` later arrives from it, the placeholder is adopted.

This is why nested shells "just work" once hooked: the daemon doesn't model
SSH or docker at all, it just tracks which pid is on top.

### Run queue

A `zmyth run` request is queued, typed when the top layer is idle, marked
*accepted* when its `preexec` arrives, and completed when its `done` arrives
with the exit code. The six ways a request can complete:


| `Via`             | when                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------- |
| `osc_done`        | the hook's `done` reported the exit code (normal)                                                                   |
| `prompt_fallback` | unhooked layer; `?2004h` (and OSC 133;D if present) said "back at prompt"                                           |
| `at_prompt`       | `run -i`: a *nested* prompt appeared (the command was `ssh`/`docker exec`)                                          |
| `line_rejected`   | typed but no `preexec` within the acceptance window → shell is at a continuation prompt (unclosed quote); `^C` sent |
| `layer_exited`    | the layer this was typed into vanished (ssh dropped) before `done`                                                  |
| `pty_eof`         | the shell process exited                                                                                            |


### Hook install

`zmyth hook` (for nested shells the daemon can't pre-hook) types a one-line
**probe** that's valid bash/zsh/fish syntax and emits a `probe` OSC reporting
which shell answered and whether the hook is already installed. If not, it
types an **install** one-liner that writes the hook script via
`head -c N > ~/.config/zmyth/hook.<shell>`, sources it, and appends one
guarded line to the rc. Probe and install are themselves `RunRequest`s with
`.kind = .hook_`*, so they reuse the run queue's preexec/done tracking.

### Why one state machine, not three modules

A single `done` from a new pid simultaneously: pushes a layer, may complete a
`run -i` request one level down, and may complete a hook install. Splitting
into three modules would mean each holds a pointer to the others and the event
dispatch becomes a negotiation. Colocating them means `onDone()` is 40 lines
that touch all three directly.

## Typing commands: bracketed paste

When the daemon types a queued command it sends:

```
^U  ESC [200~  <command>  ESC [201~  CR
```

`^U` clears any junk on the line; the bracketed-paste markers tell the line
editor "this is a paste, don't interpret it" — so `!`, `^`, tabs, and newlines
are literal, history expansion doesn't fire, and a multi-line command arrives
as one unit. The trailing `CR` accepts it.

**The acceptance window:** after typing, the daemon waits for `preexec` (or
`done`, or `?2004h`) to confirm the line was accepted. If nothing arrives
within `max(1s, 3× observed RTT)` — adaptive so a hooked shell over a 400ms
SSH link isn't ^C'd at the 1s floor — the shell is at a continuation prompt
(the command had an unclosed quote/brace) and the daemon sends `^C` and
reports `line_rejected`. The first command at a layer has no RTT observation,
so it gets a higher 5s floor.

## `write`: streaming files over the PTY

`zmyth write <sess> <path>` streams stdin to a file inside the session — the
only way to get a file onto a remote when the session is `ssh → docker exec`
deep and there's no direct `scp` path.

The naive approach (heredoc inside a bracketed paste) hits ~190 KB/s because
the line editor buffers the entire paste byte-by-byte. zmyth instead:

1. Types a short opener: `stty -icanon -echo; head -c N | base64 -d > path; stty icanon echo`
2. Waits for `preexec` (positive signal that `head` owns the tty — bytes sent
  before that are eaten by the line editor's over-read)
3. Streams the base64 body, with per-chunk acks for backpressure

That's ~32 MB/s — the kernel PTY ceiling. If the target reports `gunzip` is
available (probed once when the hook loads), the body is gzipped first. And if
the session is at depth 1 (local shell, same filesystem namespace as the
daemon), the daemon shortcuts to a direct `open()/write()` at ~300 MB/s.

The opener is **drain-wrapped** — `head -c N | { base64 -d > path || cat > /dev/null; }` — so a bad path (ENOENT, EACCES) doesn't leave N bytes of base64
in the PTY input queue for readline to execute as commands.

## Headless terminal queries

Apps inside the session probe the terminal: `ESC [6n` (cursor position),
`ESC [c` (device attributes), `ESC [?2026$p` (sync-output support). Normally
the user's real terminal answers. When no client is attached, ghostty's shadow
`Terminal` answers instead — so `vim` or `chafa` started headlessly doesn't sit
on a 2-second query timeout.

The daemon flips this with `Session.setLeaderAttached()`: when a healthy
attached client exists, ghostty stays silent (the real terminal answers via
passthrough); when not, ghostty answers from session state.

## `Session` is clock-pure

Every `Session` entry point takes `now_ns: i128`; nothing inside reads the
wall clock. This means:

- **Tests are deterministic.** A timeout test passes `now = deadline - 1` then
`now = deadline` instead of sleeping.
- **Replay/fuzz works.** Feed a recorded byte+timestamp stream through two
`Session`s and `expectEqualDeep(a.state(), b.state())`.
- **The poll timeout is exact.** `nextDeadline()` returns the absolute ns at
which `tick()` will next fire something; the daemon sleeps until then
instead of waking every 300ms to check.

The daemon is the one place that calls `std.time.nanoTimestamp()` and threads
it down.

## Module layout

```
src/
  lib/                ← exported `zmyth` module
    root.zig          re-exports below
    protocol.zig      Scanner — PTY-output OSC parser
    input.zig         Classifier — PTY-input keystroke-vs-report parser
    hook.zig          rc snippets, probe/install builders, spawnSpec, write opener
    session.zig       Session state machine (clock-pure, fd-free)
    term_state.zig    ghostty serialization for attach/read
    pty.zig           Pty/RawMode/forkExec — optional POSIX tier
    assets/hook.*     the shell-side rc snippets
  posix/              ← binary-only platform code
    compat.zig        ppoll/self-pipe signal race fix
    paths.zig         XDG dirs, socket paths
  main.zig            argv → client.<verb>()
  client.zig          one fn per CLI verb
  daemon.zig          poll loop, IPC dispatch, per-client state
  ipc.zig             socket framing (Tag enum, Framer)
  spawn.zig           materialise hook.spawnSpec + env-symlink refresh
  assets/completions.*
```

### The library boundary

`lib/` is exported as a Zig module; the binary imports `Session`/`hook`/etc.
through `@import("zmyth")` — the same surface an embedder gets — so the
boundary is compiler-enforced, not just documented. The three tiers:

- **Parsers** — `Scanner`, `Classifier`, `hook.*`. Pure byte-stream functions;
std + ghostty-vt only. Reusable by anything that wants OSC-2718.
- `**Session`** — the state machine. Clock-pure, fd-free; you drive it from
your own event loop with seven calls (`feedPty`/`pendingInput`/`consumeInput`
/`tick`/`drainEvents`/`nextDeadline`/`state`).
- `**posix**` — `Pty`/`RawMode`/`forkExec`. Optional; native embedders only.

`hook.spawnSpec(shell, opts)` returns the per-shell rc-loading recipe as data
(`{argv, env_set, env_strip, files}`) — *what* to write and exec, not the
syscalls — so the ZDOTDIR-hijack dance is reusable whether the embedder forks,
`posix_spawn`s, or stages files over SSH.

**Not exported:** the daemon's poll loop (process-global signal state is the
embedder's event loop's job), `paths.zig` (our XDG layout), `ipc.zig` (our
socket protocol). The daemon *is* the thin wrapper #127 describes; `Session`
is clock-pure precisely so you can write a different one.

## Walk-through: `zmyth run foo -- exit 7`

1. **client** parses argv, calls `daemon.ensure("foo")`. No socket at
  `$XDG_RUNTIME_DIR/zmyth/foo.sock` → fork. Child becomes the daemon; parent
   waits for the socket to appear, then connects.
2. **daemon** (child): `setsid`, redirect stdio to log, `Pty.open()`,
  `hook.spawnSpec(.bash, …)` → write `bashrc` shim → `forkExec(bash --rcfile  shim -i)`, `Session.init()`, bind+listen, enter `poll()` loop.
3. **shell** sources `~/.bashrc`, then the hook. Hook's first `PROMPT_COMMAND`
  emits `ESC]2718;done;<pid>;0;0;bg;/home/u BEL`.
4. **daemon** `read()`s that from PTY master → `session.feedPty(bytes, now)`.
  Scanner emits `.done` → `onDone`: new pid → push layer 0 (hooked, bash,
   has-gunzip, cwd=/home/u). `state().idle = true`.
5. **client** sends IPC `.run{interactive=0, "exit 7"}`.
6. **daemon** `dispatch()` → `session.run(client_id, "exit 7", .{}, now)`.
  `canType()` (idle, hooked, not alt-screen) → `typeCommand`: queue
   `^U ESC[200~ exit 7 ESC[201~ CR` into `pendingInput()`, stamp `flush_mark`.
7. **daemon** poll loop: PTY writable → `write()` those bytes →
  `session.consumeInput(n, now)` stamps `flushed_ns`.
8. **shell** readline accepts the paste. `DEBUG` trap fires → emits
  `ESC]2718;preexec;<pid> BEL`. Runs `exit 7`. Shell is about to exit, but
   bash runs `PROMPT_COMMAND` one more ti— no, `exit` skips that. Actually:
   bash exits with status 7. PTY slave closes.
9. **daemon** `read()` → `preexec` OSC → `onPreexec`: mark request `accepted`,
  record `last_preexec_latency_ns`. Then `read()` returns 0 (EOF).
   `handlePtyEof`: `waitpid` → status 7. `session.onPtyEof(status, now)`:
   complete the request with `via=.pty_eof, exit_code=7`.
10. **daemon** `routeEvents()`: `drainEvents()` returns one `.run_done{cookie=
  client_id, ec=7, via=.pty_eof}`. Send IPC` .run_done`to that client.   Send`.eof` to all clients. Clean up socket/lock/rc-dir, exit.
11. **client** receives `.run_done`, prints nothing (not `-j`), `exit(7)`.

(A non-exiting command would get `via=.osc_done` at step 9 from the `done` OSC
instead; the daemon stays up.)

## Prior art

- **zmx** — the direct ancestor; same process model and ghostty-vt
integration. zmyth replaces the marker mechanism and rewrites the daemon
loop. See `[archive/REDESIGN-NOTES.md](archive/REDESIGN-NOTES.md)` for the
planning notes and `[archive/FINDINGS.md](archive/FINDINGS.md)` for the
bug catalogue that motivated it.
- **Warp** — the announce → inject-hooks → precmd-OSC pattern is theirs;
zmyth's protocol is a simplified subset (positional fields instead of
JSON-in-DCS, no custom line editor).
- **iTerm2 / OSC 133** — the "shell integration via OSC" idea. zmyth reads
OSC 133;D as a fallback exit-code signal in unhooked shells.
- **tmux** — `update-environment` is the model for the SSH_AUTH_SOCK symlink
refresh; control-mode was considered and rejected (heavy, needs remote tmux).

