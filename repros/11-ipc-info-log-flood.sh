#!/usr/bin/env bash
# Bug: ipc.appendMessage (src/ipc.zig:86) logs at INFO level for EVERY IPC
# message. The daemon sends one .Output message per <=4KB of PTY output per
# client. A high-throughput command floods the daemon log and triggers
# rotate() repeatedly. Should be debug level.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-logflood
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

# 100KB of output -> >=25 .Output messages -> >=25 log lines just for IPC.
zmx run ft head -c 100000 /dev/zero >/dev/null 2>&1
sleep 0.5

LOG="$ZMX_DIR/logs/ft.log"
IPC_LINES=$(grep -c "sending ipc message tag=Output" "$LOG")
echo "Log lines for 100KB of output: $IPC_LINES 'sending ipc message tag=Output'"
echo

if (( IPC_LINES >= 20 )); then
    echo "BUG REPRODUCED: every IPC message logged at info level (log flood)"
    exit 1
fi
echo "OK"
exit 0
