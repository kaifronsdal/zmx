#!/usr/bin/env python3
"""
Spawn each program under a fresh PTY, capture the raw bytes it emits in the
first ~1.5s (i.e. up to and including its first prompt), and dump them so we
can look for sequences that distinguish "this is a shell prompt" from "this is
some other readline/line-editor".

Output: one block per program with the raw bytes cat -v style, plus a summary
table of which DEC/OSC sequences each emitted.
"""
import os, pty, select, fcntl, time, shlex, sys, re, struct, termios, signal

CASES = [
    # name,            argv,                                    needs
    ("bash --norc",    ["bash", "--norc", "-i"],                "bash"),
    ("bash (rc)",      ["bash", "-i"],                          "bash"),
    ("zsh -f",         ["zsh", "-f", "-i"],                     "zsh"),
    ("zsh (rc)",       ["zsh", "-i"],                           "zsh"),
    ("fish",           ["fish", "-i"],                          "fish"),
    ("dash",           ["dash", "-i"],                          "dash"),
    ("sh",             ["sh", "-i"],                            "sh"),
    ("python3",        ["python3", "-q"],                       "python3"),
    ("ipython",        ["ipython", "--no-banner", "--no-confirm-exit"], "ipython"),
    ("gdb",            ["gdb", "-q", "/bin/true"],              "gdb"),
    ("sqlite3",        ["sqlite3"],                             "sqlite3"),
    ("vim -u NONE",    ["vim", "-u", "NONE"],                   "vim"),
    ("nvim -u NONE",   ["nvim", "-u", "NONE", "--clean"],       "nvim"),
    ("less",           ["bash", "-c", "echo hi | less"],        "less"),
    ("node",           ["node"],                                "node"),
    ("irb",            ["irb"],                                 "irb"),
    ("psql",           ["psql", "--help"],                      "psql"),  # can't connect; just see if installed
]

# Sequences we care about, as (label, regex-on-raw-bytes)
MARKERS = [
    ("?2004h",    rb"\x1b\[\?2004h"),
    ("?1049h",    rb"\x1b\[\?1049h"),
    ("?1h",       rb"\x1b\[\?1h"),
    ("ESC=",      rb"\x1b="),
    ("[6n",       rb"\x1b\[6n"),
    ("DECSTBM",   rb"\x1b\[\d*;\d*r"),
    ("?25l",      rb"\x1b\[\?25l"),
    ("?12h/l",    rb"\x1b\[\?12[hl]"),
    ("OSC 0",     rb"\x1b\]0;"),
    ("OSC 2",     rb"\x1b\]2;"),
    ("OSC 7",     rb"\x1b\]7;"),
    ("OSC 133",   rb"\x1b\]133;"),
    ("DA1 query", rb"\x1b\[c"),
    ("DA2 query", rb"\x1b\[>c"),
    (">4;m",      rb"\x1b\[>4;\d*m"),     # xterm modifyOtherKeys
    ("?u kitty",  rb"\x1b\[\?u"),         # kitty kbd query
    ("?1004h",    rb"\x1b\[\?1004h"),     # focus events
]

def which(name):
    for d in os.environ.get("PATH","").split(":"):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None

def capture(argv, secs=1.5):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(argv[0], argv)
    # set winsize so full-screen apps initialise
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    buf = b""
    deadline = time.time() + secs
    while time.time() < deadline:
        r,_,_ = select.select([fd], [], [], 0.1)
        if not r: continue
        try:
            d = os.read(fd, 8192)
        except OSError:
            break
        if not d: break
        buf += d
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(fd)
    return buf

def catv(b: bytes, limit=500) -> str:
    out = []
    for c in b[:limit]:
        if c == 0x1b: out.append("\x1b[36m^[\x1b[0m")
        elif c == 0x07: out.append("\x1b[35m^G\x1b[0m")
        elif c == 0x0d: out.append("\\r")
        elif c == 0x0a: out.append("\\n\n")
        elif 0x20 <= c < 0x7f: out.append(chr(c))
        else: out.append(f"\x1b[33m\\x{c:02x}\x1b[0m")
    if len(b) > limit: out.append(f"\n... ({len(b)-limit} more bytes)")
    return "".join(out)

results = {}
for name, argv, need in CASES:
    if not which(need):
        print(f"── {name:14s} SKIP (not installed)")
        continue
    raw = capture(argv)
    found = {label: bool(re.search(pat, raw)) for label, pat in MARKERS}
    results[name] = (raw, found)
    print(f"\n── {name} ────────────────────────────────────────────")
    print(catv(raw))

# Summary table
print("\n\n" + "="*100)
print("SUMMARY: which markers each program emits at startup")
print("="*100)
hdr = ["program"] + [m[0] for m in MARKERS]
print("  ".join(f"{h:>9s}" for h in hdr))
for name, (_, found) in results.items():
    row = [name[:9]] + ["  ✓  " if found[m[0]] else "  ·  " for m in MARKERS]
    print("  ".join(f"{c:>9s}" for c in row))

# Analysis: which markers appear ONLY in shells, ONLY in non-shells?
print("\n" + "="*100)
SHELLS = {"bash --norc", "bash (rc)", "zsh -f", "zsh (rc)", "fish", "dash", "sh"}
print("Markers emitted by EVERY captured shell and NO non-shell (positive shell signal):")
for label, _ in MARKERS:
    in_shells = all(results[n][1][label] for n in results if n in SHELLS)
    in_others = any(results[n][1][label] for n in results if n not in SHELLS)
    if in_shells and not in_others:
        print(f"  {label}")
print("\nMarkers emitted by SOME non-shell and NO shell (negative shell signal):")
for label, _ in MARKERS:
    in_shells = any(results[n][1][label] for n in results if n in SHELLS)
    in_others = any(results[n][1][label] for n in results if n not in SHELLS)
    if in_others and not in_shells:
        which_ones = [n for n in results if n not in SHELLS and results[n][1][label]]
        print(f"  {label:10s} ← {', '.join(which_ones)}")
