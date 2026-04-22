#!/usr/bin/env bash
# Bug: `zmx tail` with multiple sessions uses ONE ipc.SocketBuffer for all
# sockets (src/main.zig:1227, used at 1265). A partial IPC frame from
# session A left in the buffer is extended with bytes from session B,
# corrupting frame parsing -> garbage output, dropped/duplicated bytes, or
# stall waiting for a misparsed giant payload length.
#
# Reproduction is timing-dependent (needs a partial read on one socket
# followed by a read on another before the first completes). We drive two
# high-volume sessions and check that every output line is one of the two
# expected patterns; any garbage line indicates frame corruption.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-tailbuf
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR" /tmp/zmx-tail-out
}
trap cleanup EXIT
cleanup

zmx run aa true >/dev/null 2>&1
zmx run cc true >/dev/null 2>&1
sleep 0.5

# Two sessions producing distinct tagged lines as fast as possible.
zmx run -d aa 'for i in $(seq 2000); do echo AAAA-$i; done' >/dev/null 2>&1
zmx run -d cc 'for i in $(seq 2000); do echo CCCC-$i; done' >/dev/null 2>&1

timeout 5 zmx tail aa cc > /tmp/zmx-tail-out 2>&1
sleep 0.2

# Strip ANSI/CR and the prompt/marker noise; every remaining line should be
# AAAA-N or CCCC-N. Anything else = corrupted framing.
BAD=$(tr -d '\r' < /tmp/zmx-tail-out \
      | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
      | grep -vE '^(AAAA|CCCC)-[0-9]+$' \
      | grep -vE 'ZMX_TASK_COMPLETED|^\s*$|^\[zmx:|^command sent|^for i' \
      | head -5)

echo "Unexpected lines in interleaved tail output:"
echo "${BAD:-<none>}"
echo

if [[ -n "$BAD" ]]; then
    echo "BUG REPRODUCED: shared SocketBuffer corrupted multi-session tail output"
    exit 1
fi
echo "Could not trigger in this run (bug is structural; see src/main.zig:1227)"
exit 0
