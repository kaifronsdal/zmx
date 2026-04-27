#!/usr/bin/env python3
r"""
Test (a) condensed shell-probe one-liners and (b) `source /dev/stdin` as the
step-2 receiver, across bash/zsh/fish under a real PTY.
"""
import os, pty, select, fcntl, time, struct, termios, signal, shutil, re, tempfile

def spawn(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["PS1"] = "$ "
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    return pid, fd

def drain(fd, secs):
    buf = b""
    deadline = time.time() + secs
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r: continue
        try: d = os.read(fd, 65536)
        except OSError: break
        if not d: break
        buf += d
    return buf

def inject(fd, script: bytes):
    os.write(fd, b"\x15\x1b[200~" + script + b"\x1b[201~\r")

SHELLS = [
    ("bash", ["bash", "--norc", "-i"]),
    ("zsh",  ["zsh", "-f", "-i"]),
    ("fish", ["fish", "--no-config", "-i"]),
]

# ─── (a) probe one-liners ────────────────────────────────────────────────────
PROBES = {
    "P1 semicolon-chain":
        rb"""test -n "$BASH_VERSION"&&printf '\033]2718;hello;bash\007';test -n "$ZSH_VERSION"&&printf '\033]2718;hello;zsh\007';test -n "$FISH_VERSION"&&printf '\033]2718;hello;fish\007'""",
    "P2 single printf, positional":
        rb"""printf '\033]2718;probe;%s;%s;%s\007' "$BASH_VERSION" "$ZSH_VERSION" "$FISH_VERSION" """,
    "P3 single printf, tagged":
        rb"""printf '\033]2718;probe;b=%s,z=%s,f=%s\007' "$BASH_VERSION" "$ZSH_VERSION" "$FISH_VERSION" """,
}

print("─── probe one-liners ───")
print(f"{'probe':30s} {'shell':6s} {'OSC payload received'}")
print("-"*70)
for plabel, probe in PROBES.items():
    for sh, argv in SHELLS:
        if not shutil.which(argv[0]):
            print(f"{plabel:30s} {sh:6s} SKIP"); continue
        pid, fd = spawn(argv)
        try:
            drain(fd, 0.6)
            inject(fd, probe)
            out = drain(fd, 0.8)
            m = re.search(rb"\x1b\]2718;([^\x07\x1b]*)", out)
            payload = m.group(1).decode(errors="replace") if m else "(none)"
            print(f"{plabel:30s} {sh:6s} {payload}")
        finally:
            os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); os.close(fd)
    print()

# Also: probe in a NON-shell (python3) — must produce nothing / error.
print("─── probe in non-shell (python3 REPL) ───")
pid, fd = spawn(["python3", "-q"])
try:
    drain(fd, 0.6)
    inject(fd, PROBES["P2 single printf, positional"])
    out = drain(fd, 0.8)
    m = re.search(rb"\x1b\]2718;([^\x07\x1b]*)", out)
    print("OSC payload:", m.group(1).decode() if m else "(none — good)")
    print("got SyntaxError:", b"SyntaxError" in out)
finally:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); os.close(fd)

# ─── (b) source /dev/stdin as step-2 receiver ────────────────────────────────
print("\n─── step-2: `stty -echo; source /dev/stdin; stty echo` then stream installer ───")
INSTALLER_BODY = {
    "bash": b"mkdir -p {d}\ncat > {d}/hook.bash <<'__Z__'\nHOOK_BASH_LINE_1\nHOOK_BASH_LINE_2\n__Z__\n__zmx_ok=1\n",
    "zsh":  b"mkdir -p {d}\ncat > {d}/hook.zsh <<'__Z__'\nHOOK_ZSH_LINE_1\nHOOK_ZSH_LINE_2\n__Z__\n__zmx_ok=1\n",
    "fish": b"mkdir -p {d}\nprintf '%s\\n' 'HOOK_FISH_LINE_1' 'HOOK_FISH_LINE_2' > {d}/hook.fish\nset __zmx_ok 1\n",
}
RECV = {
    "bash": b'stty -echo; eval "$(cat)"; stty echo',
    "zsh":  b'stty -echo; eval "$(cat)"; stty echo',
    "fish": b'stty -echo; source; stty echo',
}
RECV2 = {  # /dev/stdin variant
    "bash": b'stty -echo; source /dev/stdin; stty echo',
    "zsh":  b'stty -echo; source /dev/stdin; stty echo',
    "fish": b'stty -echo; source /dev/stdin; stty echo',
}
RECV3 = {  # fish: pipe through cat so source reads a pipe, not the tty
    "bash": b'stty -echo; source /dev/stdin; stty echo',
    "zsh":  b'stty -echo; source /dev/stdin; stty echo',
    "fish": b'stty -echo; cat | source; stty echo',
}
INSTALLER_BODY["fish"] = b"mkdir -p {d}\nprintf '%s\\n' 'HOOK_FISH_LINE_1' 'HOOK_FISH_LINE_2' > {d}/hook.fish\nset -g __zmx_ok 1\n"

for label, recv in [("eval $(cat) / source", RECV), ("source /dev/stdin", RECV2), ("fish: cat|source", RECV3)]:
    print(f"\n  receiver = {label}")
    print(f"  {'shell':6s} {'file ok':8s} {'var set in parent':18s} {'body in scrollback'}")
    for sh, argv in SHELLS:
        if not shutil.which(argv[0]): continue
        tmpdir = tempfile.mkdtemp(prefix="zmyth_recv_")
        pid, fd = spawn(argv)
        try:
            drain(fd, 0.6)
            inject(fd, recv[sh])
            drain(fd, 0.3)
            body = INSTALLER_BODY[sh].replace(b"{d}", tmpdir.encode())
            os.write(fd, body + b"\x04")
            out = drain(fd, 0.6)
            # check var set in parent shell (proves `source` ran in current shell)
            inject(fd, b'echo "MARK:$__zmx_ok"')
            out2 = drain(fd, 0.5)
            file_ok = os.path.exists(f"{tmpdir}/hook.{sh}") and \
                      open(f"{tmpdir}/hook.{sh}").read().count("HOOK_") == 2
            var_ok  = b"MARK:1" in out2
            leaked  = b"HOOK_" in out
            print(f"  {sh:6s} {'ok' if file_ok else 'FAIL':8s} {'ok' if var_ok else 'FAIL':18s} {'LEAKED' if leaked else 'clean'}")
        finally:
            os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); os.close(fd)
            shutil.rmtree(tmpdir, ignore_errors=True)
