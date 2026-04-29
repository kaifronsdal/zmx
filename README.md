# zmyth

A terminal session manager: persist a shell, attach/detach without killing
it, run commands and get exit codes back, stream files into nested shells.

zmyth is a from-scratch rewrite of [zmx](https://github.com/neurosnap/zmx).
It keeps zmx's model — one daemon per session, one Unix socket, native
terminal scrollback via [ghostty-vt](https://github.com/ghostty-org/ghostty)
— and replaces the `; echo MARKER` exit-code mechanism with a shell-
integration protocol (OSC 2718) that's robust to multi-line commands,
output that contains the marker, prompt customisation, and nested shells.
See [`docs/DESIGN.md`](docs/DESIGN.md) for the protocol and
[`docs/FINDINGS.md`](docs/FINDINGS.md) for the bugs in the original
approach that motivated it.

## Install

```sh
zig build -Doptimize=ReleaseSafe
# binary at ./zig-out/bin/zmyth
```

Requires Zig 0.15.2. Linux and macOS; bash ≥4, zsh, or fish.

## Usage

```
zmyth attach <name> [-- cmd...]      interactive (auto-create); Ctrl-\ to detach
zmyth run    <name> -- <cmd...>      run cmd, propagate exit code
       -d  detach (don't wait)   -j  trailing JSON result line
       -i  return when a nested prompt appears (ssh, docker exec)
zmyth send   <name> [- | text]       raw PTY input, no waiting
zmyth read   <name> [-f] [-s] [-n N] scrollback / follow / screen
zmyth write  <name> <path>           stdin → file inside the session
zmyth ls     [glob] [-j|-q]
zmyth wait   <name|glob>... [-j]
zmyth kill   <name|glob>... [-9]
zmyth hook   [<name>]                install shell integration into a nested shell
zmyth detach [<name>]
```

The shell integration is loaded automatically for the local session shell.
For nested shells (ssh, docker exec, su) run `zmyth hook` once you're at the
inner prompt — it writes `~/.config/zmyth/hook.<shell>` and adds one line to
the rc, so subsequent connects are hooked from the start.

## How it differs from zmx

| | zmx | zmyth |
|---|---|---|
| exit-code mechanism | `; echo MARKER$?` trailer | shell `precmd`/`preexec` hooks emit OSC 2718 |
| multi-line / heredoc commands | breaks (marker on wrong line) | works |
| output containing the marker | false positive | impossible (private OSC) |
| nested shells | unsupported | per-layer pid-stack; `zmyth hook` installs |
| `write` | heredoc-in-paste, ~190 KB/s, 750 KB cap | preexec-gated `head -c N`, ~32 MB/s PTY / ~300 MB/s local-FS, gzip when target has gunzip |
| headless terminal queries | hang until timeout | ghostty answers DSR/DA/DECRQM/XTWINOPS |
| prompt engines (starship, omp, p10k) | marker collides with OSC 133 | works (tested in CI) |

## Development

```sh
zig build test               # unit tests
zig build test-integration   # bash-driven integration suite (needs bash/zsh/fish)
zig build test-prompt-engines  # 3-shell × 3-engine matrix (downloads engines)
zig build test-all           # unit + integration
zig build release            # cross-compiled tarballs into zig-out/dist/
```

## License

MIT. zmyth began as a fork of zmx (© 2025 Eric Bower, MIT); the source has
since been entirely rewritten, but the project structure, ghostty-vt
integration, and several design decisions originate there.
