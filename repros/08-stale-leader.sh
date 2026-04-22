#!/usr/bin/env bash
# Bug: when the "leader" client (whose terminal size drives the PTY) drops
# WITHOUT a clean .Detach (kill -9, network drop, EOF), `leader_client_fd`
# is not cleared (src/main.zig:544-555 closeClient). On the next attach,
# handleInit (line 841) sees a non-null leader and does NOT promote the new
# client, so the PTY is not resized to the new terminal until the user
# types something (line 777).
#
# Verification: attach (becomes leader), kill -9 the client, attach again,
# then check the daemon log. With the bug, only ONE "setting new leader"
# line appears; if fixed, a second appears for the re-attach.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-leader
unset ZMX_SESSION   # attach() switches instead of creating if this is set

cleanup() {
    [[ -n "${PY1:-}" ]] && kill -9 "$PY1" 2>/dev/null
    [[ -n "${PY2:-}" ]] && kill -9 "$PY2" 2>/dev/null
    zmx kill ldtest --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

# Helper: attach in a fake PTY (rows cols), drain output, run forever.
attach_bg() {
    python3 -c '
import os,pty,sys,fcntl,termios,struct,signal
pid,fd=pty.fork()
if pid==0: os.execvp("zmx",["zmx","attach","ldtest"])
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack("HHHH",int(sys.argv[1]),int(sys.argv[2]),0,0))
os.kill(pid,signal.SIGWINCH)
sys.stderr.write(str(pid)+"\n");sys.stderr.flush()
while True:
 try:
  if not os.read(fd,4096): break
 except OSError: break
' "$1" "$2" 2>"$3" >/dev/null &
}

attach_bg 24 80 /tmp/zmx-pid1
PY1=$!
sleep 1.5
ZMX1=$(head -1 /tmp/zmx-pid1)
kill -9 "$ZMX1" 2>/dev/null   # abrupt client death (no .Detach)
kill -9 "$PY1" 2>/dev/null    # daemon holds PTY fds (separate bug); free wrapper
wait "$PY1" 2>/dev/null
sleep 0.5

attach_bg 40 120 /tmp/zmx-pid2
PY2=$!
sleep 1.5

LOG="$ZMX_DIR/logs/ldtest.log"
LEADER_COUNT=$(grep -c "setting new leader" "$LOG")
UNSET_COUNT=$(grep -c "unsetting leader" "$LOG")
rm -f /tmp/zmx-pid1 /tmp/zmx-pid2

echo "Daemon log: 'setting new leader' count = $LEADER_COUNT (expected 2)"
echo "Daemon log: 'unsetting leader' count   = $UNSET_COUNT (expected 1)"
echo
# Note: we don't check `stty size` here because the kernel typically reuses
# the closed fd number for the next accept(), so the second client
# accidentally matches the stale leader_client_fd and resize "works" by
# luck. The log check is the reliable signal.

if (( UNSET_COUNT == 0 )); then
    echo "BUG REPRODUCED: leader_client_fd not cleared on abrupt disconnect"
    echo "  (closeClient() lacks the leader_client_fd=null that handleDetach() has)"
    exit 1
fi
echo "OK: leader cleared on abrupt disconnect"
exit 0
