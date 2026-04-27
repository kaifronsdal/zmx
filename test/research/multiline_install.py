#!/usr/bin/env python3
r"""
Verify: paste a multi-line install script where line 2 is
`stty -echo; cat > FILE; stty echo`, then stream the file body + ^D,
and confirm lines 3+ run AFTER cat returns. All three shells.
"""
import os, pty, select, fcntl, time, struct, termios, signal, shutil, tempfile, re

def spawn(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", PS1="$ ")
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    return pid, fd

def drain(fd, secs):
    buf, deadline = b"", time.time() + secs
    while time.time() < deadline:
        if not select.select([fd], [], [], 0.05)[0]: continue
        try: d = os.read(fd, 65536)
        except OSError: break
        if not d: break
        buf += d
    return buf

BODY = {
    "bash": ": SENTINEL_xyzzy\n__zmx_hooked=1\n",
    "zsh":  ": SENTINEL_xyzzy\n__zmx_hooked=1\n",
    "fish": ": SENTINEL_xyzzy\nset -g __zmx_hooked 1\n",
}

def install_script(sh, d, rc):
    hook = f"{d}/hook.{sh}"
    if sh == "fish":
        return (
            f"mkdir -p {d}\n"
            f"stty -echo; cat > {hook}; stty echo\n"
            f"grep -q zmyth {rc}; or echo 'source {hook}' >> {rc}\n"
            f"set -gx LC_ZMYTH testnonce; source {hook}\n"
            f"echo AFTER_CAT_RAN"
        ).encode()
    return (
        f"mkdir -p {d}\n"
        f"stty -echo; cat > {hook}; stty echo\n"
        f"grep -q zmyth {rc} 2>/dev/null || echo '. {hook}' >> {rc}\n"
        f"LC_ZMYTH=testnonce . {hook}\n"
        f"echo AFTER_CAT_RAN"
    ).encode()

SHELLS = [("bash", ["bash","--norc","-i"]), ("zsh", ["zsh","-f","-i"]),
          ("fish", ["fish","--no-config","-i"])]

print(f"{'shell':6s} {'hook file':10s} {'rc appended':12s} {'lines 3+ ran':13s} {'body leaked'}")
print("-"*60)
for sh, argv in SHELLS:
    if not shutil.which(argv[0]): print(f"{sh:6s} SKIP"); continue
    tmp = tempfile.mkdtemp(prefix="zmyth_ml_")
    rc  = f"{tmp}/rc"
    open(rc, "w").write("# existing rc\n")
    pid, fd = spawn(argv)
    try:
        drain(fd, 0.6)
        os.write(fd, b"\x15\x1b[200~" + install_script(sh, tmp, rc) + b"\x1b[201~\r")
        out = drain(fd, 0.4)
        os.write(fd, BODY[sh].encode() + b"\x04")
        out += drain(fd, 0.8)
        # verify sourcing took effect in parent
        os.write(fd, b"\x15\x1b[200~echo HOOKVAR=$__zmx_hooked\x1b[201~\r")
        out += drain(fd, 0.5)
        hook_ok = os.path.exists(f"{tmp}/hook.{sh}") and open(f"{tmp}/hook.{sh}").read() == BODY[sh]
        rc_ok   = "hook." in open(rc).read()
        after   = b"AFTER_CAT_RAN" in out and b"HOOKVAR=1" in out
        leaked  = b"SENTINEL_xyzzy" in out
        f = lambda b: "ok" if b else "FAIL"
        print(f"{sh:6s} {f(hook_ok):10s} {f(rc_ok):12s} {f(after):13s} {'LEAKED' if leaked else 'clean'}")
        # show what user sees (ANSI-stripped) for bash
        if sh == "bash":
            clean = re.sub(rb"\x1b\][^\x07]*\x07", b"", out)
            clean = re.sub(rb"\x1b[\[=>][0-9;?]*[a-zA-Z]?", b"", clean)
            print("\n  visible scrollback (bash):")
            for ln in clean.decode(errors="replace").splitlines():
                if ln.strip(): print("   |", ln)
            print()
    finally:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); os.close(fd)
        shutil.rmtree(tmp, ignore_errors=True)
