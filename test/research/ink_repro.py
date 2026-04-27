#!/usr/bin/env python3
r"""
Reproduce Claude Code-style rendering corruption under original zmx.

Mimics Ink's redraw: render N lines, then on each frame do
  ESC[<N>A  (cursor up N)
  for each line: ESC[2K + content + \n
If the inner PTY width != outer terminal width, N is computed wrong and
the cursor-up overshoots/undershoots → duplication.

We drive `zmx attach` under a PTY of known size and check whether the
inner PTY agrees, and whether the redraw lands cleanly.
"""
import os, pty, select, fcntl, time, struct, termios, signal, sys, tempfile, shutil, re

ZMX = os.environ.get("ZMX", "zmx")
OUTER_ROWS, OUTER_COLS = 30, 100

def spawn(argv, env=None):
    pid, fd = pty.fork()
    if pid == 0:
        if env: os.environ.update(env)
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", OUTER_ROWS, OUTER_COLS, 0, 0))
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    return pid, fd

def drain(fd, secs):
    buf, dl = b"", time.time() + secs
    while time.time() < dl:
        if not select.select([fd], [], [], 0.05)[0]: continue
        try: d = os.read(fd, 65536)
        except OSError: break
        if not d: break
        buf += d
    return buf

root = tempfile.mkdtemp(prefix="zmx_ink_")
sess = "inkrepro"
env = {"ZMX_DIR": root, "HOME": os.environ["HOME"]}

# A minimal Ink-style renderer.
ink_script = r"""
import sys, os, time, shutil
cols = shutil.get_terminal_size().columns
rows = shutil.get_terminal_size().lines
sys.stderr.write(f"INNER_SIZE rows={rows} cols={cols}\n")
sys.stderr.flush()
# A line slightly narrower than 100 cols. If inner thinks cols=80, this "wraps"
# to 2 logical rows in Ink's model; if cols=100, it's 1 row.
line = "X" * 95
last_h = 0
for frame in range(6):
    out = ""
    if last_h:
        out += f"\033[{last_h}A"
    body = [f"\033[2K[{frame}] {line}"] * 4
    out += "\n".join(body) + "\n"
    last_h = len(body)
    sys.stdout.write(out); sys.stdout.flush()
    time.sleep(0.15)
sys.stdout.write("INK_DONE\n"); sys.stdout.flush()
"""

try:
    pid, fd = spawn([ZMX, "attach", sess], env=env)
    drain(fd, 1.5)
    # Check inner PTY size.
    os.write(fd, b"stty size\r")
    sz = drain(fd, 0.6)
    m = re.search(rb"(\d+)\s+(\d+)", sz)
    inner = (int(m.group(1)), int(m.group(2))) if m else None
    print(f"outer = {OUTER_ROWS}×{OUTER_COLS}   inner pty = {inner}")
    match = inner == (OUTER_ROWS, OUTER_COLS)
    print(f"  {'OK ' if match else 'MISMATCH'}: inner pty size {'==' if match else '!='} outer")

    # Run the Ink-style renderer.
    os.write(fd, b"python3 - <<'PYEOF'\r" + ink_script.encode() + b"\rPYEOF\r")
    out = drain(fd, 2.5)
    # After 6 frames overwriting in place, only the LAST frame's marker should
    # be visible. Count how many distinct frame markers survive in the final
    # screen (strip ANSI, look at last 30 lines).
    plain = re.sub(rb"\x1b\[[\d;?]*[a-zA-Z]", b"", out)
    plain = re.sub(rb"\x1b\][^\x07]*\x07", b"", plain)
    tail = b"\n".join(plain.split(b"\n")[-30:])
    frames_seen = sorted(set(re.findall(rb"\[(\d)\] X", tail)))
    print(f"  frame markers visible in final screen: {frames_seen}")
    if len(frames_seen) <= 1:
        print("  OK: only final frame visible (clean overwrite)")
    else:
        print(f"  CORRUPTED: {len(frames_seen)} frames overlapping (duplication)")

    # Show the inner-reported size from the script's own measurement.
    m2 = re.search(rb"INNER_SIZE rows=(\d+) cols=(\d+)", out)
    if m2:
        print(f"  python shutil.get_terminal_size() inside session: rows={m2.group(1).decode()} cols={m2.group(2).decode()}")

finally:
    os.system(f"ZMX_DIR={root} {ZMX} kill {sess} 2>/dev/null")
    try: os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    except: pass
    try: os.close(fd)
    except: pass
    shutil.rmtree(root, ignore_errors=True)
