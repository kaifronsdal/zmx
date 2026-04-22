#!/usr/bin/env python3
"""
PoC harness for the Warp-style "announce -> inject hooks -> read OSC" approach.

Protocol under test:
  1. Shell rc emits announce:  ESC ] 2718;hello;<shell> BEL
  2. Harness sees announce, types the matching hook script into the PTY.
  3. Hook installs a precmd that emits:  ESC ] 2718;done;<exit>;<pwd> BEL
  4. Harness sends commands and reads exit codes from the OSC, never from
     scraped text.

The harness keeps a stateful OSC parser so sequences split across read()
boundaries are handled correctly.
"""
import os, pty, select, time, fcntl, termios, struct, base64, signal

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
HOOKS = {
    "bash": open(f"{HOOK_DIR}/hook_bash.sh").read(),
    "zsh":  open(f"{HOOK_DIR}/hook_zsh.sh").read(),
    "fish": open(f"{HOOK_DIR}/hook_fish.sh").read(),
}

OSC_START = b"\x1b]2718;"
BEL = b"\x07"
ST  = b"\x1b\\"
BP_ON  = b"\x1b[?2004h"

class OscScanner:
    """Stateful scanner: accumulates bytes, yields (kind, params) for OSC 2718
    and 'prompt' for CSI ?2004h. Boundary-safe."""
    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data
        events = []
        while True:
            # OSC 2718
            i = self.buf.find(OSC_START)
            j = self.buf.find(BP_ON)
            if i == -1 and j == -1:
                # keep at most a tail that could be a partial prefix
                if len(self.buf) > 32:
                    del self.buf[:-32]
                break
            if j != -1 and (i == -1 or j < i):
                events.append(("prompt", None))
                del self.buf[:j + len(BP_ON)]
                continue
            # i is the OSC start
            tail = self.buf[i + len(OSC_START):]
            t_bel = tail.find(BEL)
            t_st  = tail.find(ST)
            cands = [t for t in (t_bel, t_st) if t != -1]
            if not cands:
                # incomplete OSC; keep from i onward
                del self.buf[:i]
                break
            t = min(cands)
            payload = bytes(tail[:t]).decode("utf-8", "replace")
            term_len = 1 if t == t_bel else 2
            del self.buf[: i + len(OSC_START) + t + term_len]
            parts = payload.split(";")
            events.append(("osc", parts))
        return events


class Session:
    def __init__(self, argv, env=None, rows=24, cols=100):
        self.scanner = OscScanner()
        self.announced_shell = None
        self.hooked = False
        self.eof = False
        self.events = []   # list of ("done", exit_code, pwd)
        e = dict(os.environ)
        if env: e.update(env)
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(argv[0], argv, e)
        self.pid = pid
        self.fd = fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        # nonblocking
        fl = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)

    def _pump(self, timeout):
        deadline = time.time() + timeout
        out = b""
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], max(0, deadline - time.time()))
            if not r:
                break
            try:
                d = os.read(self.fd, 4096)
            except OSError:
                self.eof = True
                break
            if not d:
                self.eof = True
                break
            out += d
            for ev in self.scanner.feed(d):
                self._handle(ev)
        return out

    def _handle(self, ev):
        kind, val = ev
        if kind == "osc":
            if val[0] == "hello":
                self.announced_shell = val[1] if len(val) > 1 else "?"
                self._inject_hook(self.announced_shell)
                self.events.append(("hello", self.announced_shell, None))
            elif val[0] == "done":
                ec = int(val[1]) if len(val) > 1 and val[1].isdigit() else None
                pwd = val[2] if len(val) > 2 else ""
                self.events.append(("done", ec, pwd))
        elif kind == "prompt":
            self.events.append(("prompt", None, None))

    def _inject_hook(self, shell):
        script = HOOKS.get(shell)
        if not script:
            return
        b64 = base64.b64encode(script.encode()).decode()
        if shell == "fish":
            cmd = f"echo {b64} | base64 -d | source\r"
        else:
            cmd = f'eval "$(echo {b64} | base64 -d)"\r'
        os.write(self.fd, cmd.encode())
        self.hooked = True

    def wait_announce(self, timeout=5):
        t0 = time.time()
        while time.time() - t0 < timeout:
            self._pump(0.2)
            if self.announced_shell:
                # drain the post-inject prompt
                self._pump(0.5)
                return self.announced_shell
        return None

    def run(self, cmd, timeout=5):
        """Type cmd, return (exit_code|None, completed_via). No trailer appended.
        Prepends Ctrl-U to clear any stuck input (fish keeps bad input in the
        buffer after a syntax error)."""
        before = len(self.events)
        os.write(self.fd, ("\x15" + cmd + "\r").encode())
        t0 = time.time()
        while time.time() - t0 < timeout:
            self._pump(0.2)
            for ev in self.events[before:]:
                if ev[0] == "done":
                    return ev[1], "osc-done"
            # fallback: prompt without done
            if any(e[0] == "prompt" for e in self.events[before:]):
                # give a beat in case 'done' arrives just after 2004h
                self._pump(0.2)
                for ev in self.events[before:]:
                    if ev[0] == "done":
                        return ev[1], "osc-done"
                return None, "prompt-fallback"
            if self.eof:
                _, ws = os.waitpid(self.pid, os.WNOHANG)
                ec = os.waitstatus_to_exitcode(ws) if ws else None
                return ec, "pty-eof"
        return None, "timeout"

    def type(self, s):
        os.write(self.fd, s.encode())
        self._pump(0.3)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        try: os.close(self.fd)
        except OSError: pass


def announce_rc(shell):
    return "printf '\\033]2718;hello;%s\\007'\n" % shell


if __name__ == "__main__":
    # quick self-test: bash
    rc = "/tmp/zmx-poc-bashrc"
    with open(rc, "w") as f:
        f.write(announce_rc("bash"))
    s = Session(["bash", "--rcfile", rc, "-i"])
    sh = s.wait_announce()
    print("announced:", sh, "hooked:", s.hooked)
    print("run 'true' ->", s.run("true"))
    print("run 'false' ->", s.run("false"))
    print("run 'exit 7' ->", s.run("exit 7"))
    s.close()
