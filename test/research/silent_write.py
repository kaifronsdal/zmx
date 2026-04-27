#!/usr/bin/env python3
"""
Empirically test: can we write a file from inside a bracketed-paste inject
WITHOUT the file body appearing in scrollback?

We try several approaches against bash and zsh under a real PTY, then check:
  1. Did the target file get the right contents?
  2. Does the captured PTY output contain the marker string from the body?

The "inject" here mimics what zmyth's daemon does: send
    ^U  \e[200~ <script> \e[201~ \r
to a shell that has bracketed-paste enabled.
"""
import os, pty, select, fcntl, time, struct, termios, signal, tempfile, shutil, sys

MARKER = "ZMYTH_HOOK_BODY_SENTINEL_xyzzy"
BODY   = f"# hook line 1\n# {MARKER}\n# hook line 3\n"

def spawn(argv, env_extra=None):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["PS1"] = "$ "
        if env_extra:
            os.environ.update(env_extra)
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
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        buf += d
    return buf

def inject(fd, script: bytes):
    os.write(fd, b"\x15\x1b[200~" + script + b"\x1b[201~\r")

def send_raw(fd, data: bytes):
    os.write(fd, data)

def run_case(label, shell_argv, build_inject, post_inject=None):
    """build_inject(target_path) -> bytes to paste; post_inject(fd) optional."""
    if not shutil.which(shell_argv[0]):
        return (label, "skip", "skip")
    tmpdir = tempfile.mkdtemp(prefix="zmyth_silent_")
    target = os.path.join(tmpdir, "hook.sh")
    pid, fd = spawn(shell_argv)
    try:
        drain(fd, 0.7)  # initial prompt
        inject(fd, build_inject(target))
        out = drain(fd, 0.4)
        if post_inject:
            post_inject(fd)
            out += drain(fd, 0.6)
        out += drain(fd, 0.4)
        try:
            written = open(target).read()
        except FileNotFoundError:
            written = ""
        ok_write = (written == BODY)
        leaked   = MARKER.encode() in out
        return (label, ok_write, leaked)
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(fd)
        shutil.rmtree(tmpdir, ignore_errors=True)

# ─── approaches ───────────────────────────────────────────────────────────────

def A_heredoc(target):
    # Baseline: cat > file <<EOF ... EOF — body is part of the pasted command.
    return (f"cat > {target} <<'__Z__'\n{BODY}__Z__").encode()

def B_stty_heredoc(target):
    # Wrap heredoc in stty -echo / stty echo. Paste echo is a *readline* thing,
    # not a tty-echo thing, so this probably doesn't help — verify.
    return (f"stty -echo; cat > {target} <<'__Z__'\n{BODY}__Z__\nstty echo").encode()

def C_cat_then_stdin(target):
    # Paste only `cat > file`; THEN send body + ^D as raw stdin (outside paste).
    # cat reads cooked-mode stdin → tty echoes it. Expect: still leaks.
    return f"cat > {target}".encode()
def C_post(fd):
    send_raw(fd, BODY.encode() + b"\x04")

def D_stty_cat_stdin(target):
    # Paste `stty -echo; cat > file; stty echo`; THEN send body + ^D raw.
    # Now cat's stdin is read with tty echo OFF → should NOT appear.
    return f"stty -echo; cat > {target}; stty echo".encode()
def D_post(fd):
    send_raw(fd, BODY.encode() + b"\x04")

def E_base64_stdin(target):
    # Same as D but pipe through base64 -d so even if it leaked it's opaque.
    # (We removed base64 from the *hook inject* for PATH reasons; remote boxes
    # being hooked are interactive so base64 is ~always present, but verify D
    # first since it avoids the dependency entirely.)
    return f"stty -echo; base64 -d > {target}; stty echo".encode()
def E_post(fd):
    import base64
    send_raw(fd, base64.b64encode(BODY.encode()) + b"\n\x04")

CASES = [
    ("A  heredoc (baseline)",        A_heredoc,        None),
    ("B  stty -echo + heredoc",      B_stty_heredoc,   None),
    ("C  cat>file, body as stdin",   C_cat_then_stdin, C_post),
    ("D  stty -echo; cat>file; body→stdin", D_stty_cat_stdin, D_post),
    ("E  stty -echo; base64 -d>file",       E_base64_stdin,   E_post),
]

SHELLS = [
    ("bash", ["bash", "--norc", "-i"]),
    ("zsh",  ["zsh", "-f", "-i"]),
    ("fish", ["fish", "--no-config", "-i"]),
]

# For the winning approach, also dump what the user actually sees.
def show_visible(sh_name, sh_argv):
    if not shutil.which(sh_argv[0]):
        return
    tmpdir = tempfile.mkdtemp(prefix="zmyth_silent_")
    target = os.path.join(tmpdir, "hook.sh")
    pid, fd = spawn(sh_argv)
    try:
        drain(fd, 0.7)
        inject(fd, D_stty_cat_stdin(target))
        out = drain(fd, 0.4)
        D_post(fd)
        out += drain(fd, 0.8)
        # strip ANSI for readability
        import re
        clean = re.sub(rb"\x1b\][^\x07]*\x07", b"", out)
        clean = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", clean)
        print(f"\n── visible scrollback under {sh_name} (approach D) ──")
        print(clean.decode(errors="replace"))
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(fd)
        shutil.rmtree(tmpdir, ignore_errors=True)

print(f"{'approach':40s} {'shell':6s} {'file ok':8s} {'body in scrollback'}")
print("-" * 78)
for sh_name, sh_argv in SHELLS:
    for label, build, post in CASES:
        l, ok, leaked = run_case(f"{label}", sh_argv, build, post)
        if ok == "skip":
            print(f"{label:40s} {sh_name:6s} SKIP")
            continue
        ok_s   = "✓" if ok else "✗"
        leak_s = "LEAKED" if leaked else "clean"
        good   = ok and not leaked
        mark   = "  ← works" if good else ""
        print(f"{label:40s} {sh_name:6s} {ok_s:8s} {leak_s}{mark}")
    print()

for sh_name, sh_argv in SHELLS:
    show_visible(sh_name, sh_argv)
