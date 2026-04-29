#!/usr/bin/env python3
"""
Integration test for `zmyth attach`: the interactive raw-mode pump.

Covers what smoke.sh cannot (needs a controlling TTY):
  - attach auto-creates a session and replays state
  - keystrokes typed on the master reach the inner shell
  - Ctrl-\\ detaches cleanly with exit code 0, session survives
  - re-attach replays scrollback (previous output visible)
  - SIGWINCH on the client propagates a resize to the inner PTY

Exit 0 iff every step passes.
"""
import os
import pty
import sys
import json
import time
import fcntl
import errno
import select
import shutil
import signal
import struct
import termios
import tempfile
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ZMX = os.environ.get("ZMX", os.path.join(HERE, "..", "..", "zig-out", "bin", "zmyth"))
ZMX = os.path.abspath(ZMX)

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")


def check(label, cond, extra=""):
    if cond:
        ok(label)
    else:
        bad(f"{label}  {extra}")


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class Attach:
    """One `zmyth attach` process running under a fresh PTY pair."""

    def __init__(self, env, name, rows, cols):
        self.master, slave = pty.openpty()
        set_winsize(self.master, rows, cols)
        # nonblocking master for the read pump
        fl = fcntl.fcntl(self.master, fcntl.F_GETFL)
        fcntl.fcntl(self.master, fcntl.F_SETFL, fl | os.O_NONBLOCK)

        # New session so the child treats the slave as its own tty (raw-mode
        # tcsetattr works regardless, but setsid keeps signal/pg semantics
        # clean for the SIGWINCH test).
        self.proc = subprocess.Popen(
            [ZMX, "attach", name],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            start_new_session=True,
        )
        os.close(slave)
        self.buf = bytearray()

    def pump(self, timeout):
        """Drain master into self.buf until `timeout` elapses or EOF."""
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return
            r, _, _ = select.select([self.master], [], [], remaining)
            if not r:
                return
            try:
                d = os.read(self.master, 4096)
            except OSError as e:
                if e.errno in (errno.EIO, errno.EBADF):
                    return  # slave closed
                raise
            if not d:
                return
            self.buf += d

    def read_until(self, needle: bytes, timeout=5.0):
        """Pump until `needle` appears in the accumulated buffer; return True
        on match, False on timeout."""
        deadline = time.time() + timeout
        while needle not in self.buf:
            remaining = deadline - time.time()
            if remaining <= 0:
                return False
            r, _, _ = select.select([self.master], [], [], min(0.2, remaining))
            if not r:
                continue
            try:
                d = os.read(self.master, 4096)
            except OSError as e:
                if e.errno in (errno.EIO, errno.EBADF):
                    break
                raise
            if not d:
                break
            self.buf += d
        return needle in self.buf

    def write(self, data: bytes):
        os.write(self.master, data)

    def wait_exit(self, timeout=5.0):
        """Drain output and poll until the attach process exits; return
        exit code or None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.1)
            ec = self.proc.poll()
            if ec is not None:
                self.pump(0.1)  # drain any trailing bytes
                return ec
        return None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass


def main():
    if not os.access(ZMX, os.X_OK):
        print(f"FATAL: {ZMX} not executable", file=sys.stderr)
        return 1

    tmpdir = tempfile.mkdtemp(prefix="zmyth-attach-")
    env = dict(os.environ)
    env["ZMYTH_DIR"] = tmpdir
    env["XDG_STATE_HOME"] = os.path.join(tmpdir, "state")
    # Use whatever $SHELL the user has (zsh on stock macOS; bash 5+ on most
    # Linux). Do NOT force /bin/bash: on macOS that's bash 3.2, whose readline
    # lacks bracketed-paste, so `run`'s typed commands become `200~cmd201~`.
    env["SHELL"] = os.environ.get("SHELL") or shutil.which("zsh") or shutil.which("bash") or "/bin/sh"
    env["TERM"] = "xterm-256color"
    env.pop("ZMYTH_SESSION", None)

    name = "atest"

    # ── Step 1-2: spawn attach on a 30×100 PTY ───────────────────────────────
    a = Attach(env, name, rows=30, cols=100)

    # ── Step 3: wait for shell prompt (state replay + first prompt). bash
    #    emits CSI ?2004h (bracketed-paste-on) at each prompt; that's a
    #    rc-agnostic prompt marker. Fall back to '$ '. ──────────────────────────
    got_prompt = a.read_until(b"\x1b[?2004h", timeout=5.0) or a.read_until(b"$ ", timeout=1.0)
    check("attach: shell prompt within 5s", got_prompt,
          extra=repr(bytes(a.buf[-120:])))

    # zmyth injects shell hooks right after the first prompt; the injection
    # itself consumes stdin, so keystrokes sent now would be swallowed. Wait
    # for the SECOND ?2004h (the post-inject prompt) before typing.
    a.buf.clear()
    a.read_until(b"\x1b[?2004h", timeout=3.0)

    # ── Step 4: type a command, see its output ───────────────────────────────
    a.buf.clear()
    a.write(b"echo ATTACH-WORKS\r")
    got_echo = a.read_until(b"ATTACH-WORKS\r\n", timeout=5.0)
    check("attach: typed command output appears", got_echo,
          extra=repr(bytes(a.buf[-120:])))

    # ── Step 5: Ctrl-\ detaches; attach process exits 0 ──────────────────────
    a.write(b"\x1c")
    ec = a.wait_exit(timeout=5.0)
    check("attach: Ctrl-\\ detach -> exit 0", ec == 0, extra=f"ec={ec!r}")
    a.close()

    # ── Step 6: session survives detach ──────────────────────────────────────
    ls = subprocess.run([ZMX, "ls", "-q"], env=env, capture_output=True, text=True)
    check("attach: session survives detach (ls -q)", name in ls.stdout.split(),
          extra=repr(ls.stdout))

    # ── Step 7: re-attach; state replay contains prior output ────────────────
    b = Attach(env, name, rows=30, cols=100)
    got_replay = b.read_until(b"ATTACH-WORKS", timeout=5.0)
    check("attach: state replay shows prior output", got_replay,
          extra=repr(bytes(b.buf[-200:])))

    # Drain to a fresh prompt before resizing.
    b.read_until(b"\x1b[?2004h", timeout=2.0)
    b.buf.clear()

    # ── Step 8: resize PTY to 25×90, deliver SIGWINCH, verify inner shell
    #    sees the new size. (`stty size` reads the inner PTY directly — no
    #    terminfo dependency.) ─────────────────────────────────────────────────
    set_winsize(b.master, 25, 90)
    os.kill(b.proc.pid, signal.SIGWINCH)
    time.sleep(0.2)  # let .resize frame propagate to daemon → inner PTY
    b.write(b"echo SIZE-$(stty size | tr ' ' x)\r")
    # Output line is preceded by the preexec OSC's BEL terminator, not LF —
    # match the bare token (it cannot appear in the echoed input, which
    # contains the unexpanded `$(stty size ...)`).
    got_size = b.read_until(b"SIZE-25x90", timeout=5.0)
    check("attach: SIGWINCH resize -> inner PTY 25x90", got_size,
          extra=repr(bytes(b.buf[-200:])))

    # ── Step 9: detach again, then kill ──────────────────────────────────────
    b.write(b"\x1c")
    ec2 = b.wait_exit(timeout=5.0)
    check("attach: second Ctrl-\\ detach -> exit 0", ec2 == 0, extra=f"ec={ec2!r}")
    b.close()

    kill = subprocess.run([ZMX, "kill", "-9", name], env=env, capture_output=True)
    time.sleep(0.3)
    ls2 = subprocess.run([ZMX, "ls", "-q"], env=env, capture_output=True, text=True)
    check("attach: kill -9 removes session", name not in ls2.stdout.split(),
          extra=f"kill_ec={kill.returncode} ls={ls2.stdout!r}")

    def ls_json():
        out = subprocess.check_output([ZMX, "ls", "-j"], env=env, text=True)
        return json.loads(out) if out.strip() else []

    def wait_ready(att, fresh):
        """Drain replay/inject noise until the inner shell is at a quiet prompt.
        `fresh` => session was just auto-created, so wait past hook injection."""
        if not att.read_until(b"\x1b[?2004h", timeout=5.0):
            att.read_until(b"$ ", 1.0)
        if fresh:
            att.buf.clear()
            att.read_until(b"\x1b[?2004h", timeout=3.0)
        att.buf.clear()

    spawned = []  # Attach instances to force-close in finally

    # ─────────────────────────────────────────────────────────────────────────
    # Scenario A: multi-client fan-out + leader handoff
    # ─────────────────────────────────────────────────────────────────────────
    try:
        A = Attach(env, "mc", rows=30, cols=100); spawned.append(A)
        wait_ready(A, fresh=True)
        B = Attach(env, "mc", rows=30, cols=100); spawned.append(B)
        # B attaches to existing session: just drain the state replay.
        B.pump(0.5); B.buf.clear()

        A.write(b"echo FAN-OUT-MARK\r")
        a_got = A.read_until(b"FAN-OUT-MARK\r\n", timeout=5.0)
        check("multi-client: leader A sees own output", a_got,
              extra=repr(bytes(A.buf[-120:])))
        # Broadcast: B should receive the same PTY bytes.
        B.pump(1.0)
        check("multi-client: follower B receives broadcast",
              b"FAN-OUT-MARK" in B.buf, extra=repr(bytes(B.buf[-120:])))

        # A detaches → B should be promoted to leader.
        A.write(b"\x1c")
        eca = A.wait_exit(timeout=5.0)
        check("multi-client: A detach -> exit 0", eca == 0, extra=f"ec={eca!r}")
        A.close()

        B.buf.clear()
        B.write(b"echo NEW-LEADER\r")
        b_got = B.read_until(b"NEW-LEADER\r\n", timeout=5.0)
        check("multi-client: B promoted, input reaches shell", b_got,
              extra=repr(bytes(B.buf[-120:])))

        B.write(b"\x1c")
        B.wait_exit(timeout=5.0)
        B.close()
    except Exception as e:
        bad(f"multi-client: scenario crashed: {e!r}")
    finally:
        subprocess.run([ZMX, "kill", "-9", "mc"], env=env, capture_output=True)

    # ─────────────────────────────────────────────────────────────────────────
    # Scenario A2: second attach steals leader → PTY resizes to new client.
    # Repro for the "stale orphan holds leader at wrong width" Ink-corruption
    # bug: A is the orphan (211 cols, never types again), B is the user's fresh
    # attach (119 cols). PTY must be at B's size before B types anything.
    # ─────────────────────────────────────────────────────────────────────────
    try:
        A = Attach(env, "ldr", rows=31, cols=211); spawned.append(A)
        wait_ready(A, fresh=True)
        # Confirm A's size took.
        A.write(b"echo SZA-$(stty size | tr ' ' x)\r")
        check("leader-steal: first attach sets PTY 31x211",
              A.read_until(b"SZA-31x211", timeout=3.0),
              extra=repr(bytes(A.buf[-120:])))

        # B attaches at a DIFFERENT, smaller size and never types. PTY should
        # immediately resize to B's size (B is the freshest attach). Query via
        # `zmyth run` so neither attach client sends .input (which would itself
        # re-promote and mask the result).
        B = Attach(env, "ldr", rows=31, cols=119); spawned.append(B)
        B.pump(0.6)
        r = subprocess.run([ZMX, "run", "ldr", "--", "stty size | tr ' ' x"],
                           env=env, capture_output=True, text=True, timeout=10)
        check("leader-steal: second attach resizes PTY to its 31x119 (no input)",
              "31x119" in r.stdout, extra=repr(r.stdout[-150:]))

        # A types (real user input) → A re-promotes → PTY back to 211.
        A.buf.clear()
        A.write(b"echo SZC-$(stty size | tr ' ' x)\r")
        check("leader-steal: input from A re-promotes (PTY back to 211)",
              A.read_until(b"SZC-31x211", timeout=3.0),
              extra=repr(bytes(A.buf[-150:])))

        for c in (A, B):
            c.write(b"\x1c"); c.wait_exit(timeout=3.0); c.close()
    except Exception as e:
        bad(f"leader-steal: scenario crashed: {e!r}")
    finally:
        subprocess.run([ZMX, "kill", "-9", "ldr"], env=env, capture_output=True)

    # ─────────────────────────────────────────────────────────────────────────
    # Scenario B: daemon SIGKILL while attached → clean exit + termios restored
    # ─────────────────────────────────────────────────────────────────────────
    try:
        C = Attach(env, "dk", rows=30, cols=100); spawned.append(C)
        wait_ready(C, fresh=True)

        # Confirm raw mode is in effect (sanity: ICANON cleared on our slave).
        lflag_raw = termios.tcgetattr(C.master)[3]
        raw_ok = not (lflag_raw & termios.ICANON)

        sessions = ls_json()
        dpid = next(s["pid"] for s in sessions if s["name"] == "dk")
        os.kill(dpid, signal.SIGKILL)

        ecc = C.wait_exit(timeout=3.0)
        check("daemon-kill: attach exits within 3s on socket EOF",
              ecc is not None, extra=f"ec={ecc!r}")
        check("daemon-kill: attach exit code is non-zero",
              ecc is not None and ecc != 0, extra=f"ec={ecc!r}")
        check("daemon-kill: 'connection lost' message",
              b"connection to daemon lost" in C.buf,
              extra=repr(bytes(C.buf[-150:])))

        # RawMode.leave() should have restored cooked termios on its stdin
        # (our PTY slave). Master and slave share one termios struct on Linux,
        # so we can inspect via the master fd we still hold.
        lflag = termios.tcgetattr(C.master)[3]
        restored = bool(lflag & termios.ICANON) and bool(lflag & termios.ECHO)
        check("daemon-kill: termios restored (ICANON|ECHO)",
              restored,
              extra=f"raw_ok={raw_ok} lflag_raw={lflag_raw:#x} lflag_now={lflag:#x}")
        C.close()
    except Exception as e:
        bad(f"daemon-kill: scenario crashed: {e!r}")
    finally:
        subprocess.run([ZMX, "kill", "-9", "dk"], env=env, capture_output=True)

    # ─────────────────────────────────────────────────────────────────────────
    # Scenario C: alt-screen gates `run`
    # ─────────────────────────────────────────────────────────────────────────
    p = None
    try:
        # Warm: create session + install hooks by running a no-op.
        subprocess.run([ZMX, "run", "alt", "--", "true"], env=env,
                       capture_output=True, timeout=10)
        # Enter vi (alt-screen app). -u NONE for deterministic startup.
        subprocess.run([ZMX, "send", "alt", "vi -u NONE /tmp/zmyth-alt-x\r"],
                       env=env, capture_output=True)

        deadline = time.time() + 2.0
        alt_on = False
        while time.time() < deadline:
            try:
                sess = next(s for s in ls_json() if s["name"] == "alt")
                if sess.get("alt_screen"):
                    alt_on = True
                    break
            except StopIteration:
                pass
            time.sleep(0.05)
        if not alt_on:
            print("DEBUG alt scrollback:", subprocess.run([ZMX, "read", "alt", "-n", "20"], env=env, capture_output=True, text=True).stdout, file=sys.stderr)
        check("alt-gate: vi flips alt_screen=true", alt_on,
              extra=repr(ls_json()))

        # `run` should block while alt-screen is active.
        p = subprocess.Popen([ZMX, "run", "-j", "alt", "--", "echo", "AFTER-VI"],
                             env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        time.sleep(0.5)
        check("alt-gate: run blocks while alt-screen active",
              p.poll() is None, extra=f"poll={p.poll()!r}")

        # Quit vi → alt-screen drops → run should proceed.
        subprocess.run([ZMX, "send", "alt", ":q!\r"], env=env,
                       capture_output=True)
        try:
            p.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            pass
        check("alt-gate: run completes after vi exits, ec=0",
              p.returncode == 0, extra=f"ec={p.returncode!r}")

        rd = subprocess.check_output([ZMX, "read", "alt", "-n", "10"],
                                     env=env, text=True)
        check("alt-gate: read shows AFTER-VI", "AFTER-VI" in rd,
              extra=repr(rd[-200:]))
    except Exception as e:
        bad(f"alt-gate: scenario crashed: {e!r}")
    finally:
        if p is not None and p.poll() is None:
            p.kill(); p.wait()
        subprocess.run([ZMX, "kill", "-9", "alt"], env=env, capture_output=True)

    # ── Cleanup ──────────────────────────────────────────────────────────────
    for att in spawned:
        att.close()
    subprocess.run([ZMX, "kill", "-9", "*"], env=env, capture_output=True)
    subprocess.run(["pkill", "-9", "-f", tmpdir], capture_output=True)
    subprocess.run(["rm", "-rf", tmpdir])

    print()
    print(f"{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
