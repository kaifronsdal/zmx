#!/usr/bin/env bash
# Bug: `zmx run` detects task completion by scanning PTY output for the string
# "ZMX_TASK_COMPLETED:<n>". The match is unanchored, so if the USER's command
# prints that string, zmx records the wrong exit code and returns early.
#
# Root cause: src/util.zig findTaskExitMarker() — substring scan, no anchor.
#
# Real-world impact: a script that greps zmx's own logs/source, or a nested
# `zmx run`, leaks the marker into output and corrupts task status.
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-sentinel

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

# Print a fake sentinel with code 42, then exit 0.
# If zmx is correct: exit_code=0. If buggy: exit_code=42.
set +e
zmx run stest echo ZMX_TASK_COMPLETED:42 >/dev/null 2>&1
RC=$?
set -e
sleep 0.3
LISTED=$(zmx list | grep stest | sed -E 's/.*exit_code=([0-9]+).*/\1/')

echo "zmx run exit code:    $RC"
echo "zmx list exit_code=:  $LISTED"
echo

if [[ "$RC" == "42" || "$LISTED" == "42" ]]; then
    echo "BUG REPRODUCED: fake sentinel in output hijacked exit code (got 42, expected 0)"
    exit 1
fi
echo "OK: real exit code 0 was recorded"
exit 0
