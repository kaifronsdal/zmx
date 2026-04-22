#!/usr/bin/env bash
# Bug: the shared global log {ZMX_DIR}/logs/zmx.log is opened WITHOUT O_APPEND
# (src/log.zig:17-28: openFileAbsolute(.read_write) then seekTo(end)). Every
# `zmx` CLI invocation writes to this file. Concurrent invocations each seek
# to their own snapshot of end-of-file and overwrite each other's bytes.
#
# Demonstration: each `zmx run <existing-session> true` writes exactly one
# "socket path=..." line to zmx.log. Run N of them concurrently. With
# O_APPEND we'd get N lines; with seek+write we get far fewer (and torn
# lines that don't start with '[').
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-logbug
LOG="$ZMX_DIR/logs/zmx.log"

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

zmx run lt true >/dev/null 2>&1
sleep 0.5
: > "$LOG"

N=80
for i in $(seq $N); do
    zmx run lt true >/dev/null 2>&1 &
done
wait

LINES=$(wc -l < "$LOG")
TORN=$(grep -c '^[^[]' "$LOG"); true
echo "Concurrent $N invocations -> log lines: $LINES (expected $N)"
echo "Torn lines (not starting with '['): $TORN"
echo "Sample of log tail:"
tail -5 "$LOG"
echo

if (( LINES < N )) || (( TORN > 0 )); then
    echo "BUG REPRODUCED: concurrent log writes lost/torn (no O_APPEND)"
    exit 1
fi
echo "OK"
exit 0
