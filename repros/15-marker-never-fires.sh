#!/usr/bin/env bash
# Bug: the `; echo ZMX_TASK_COMPLETED:$?` trailer never fires when the user's
# command terminates the shell itself (`exit`, `exec`), so the daemon never
# records an exit code. `zmx run` then returns 0 (tail() returns 0 on socket
# EOF, src/main.zig:1275) -> false success, real exit code lost.
#
# `zmx wait` does NOT hang in this case because the daemon exits on PTY EOF
# and the session disappears -> wait completes. But the exit code is wrong.
#
# Cases where the marker is skipped but the SHELL SURVIVES (readline waiting
# on unbalanced quote/heredoc via stdin path, csh syntax error) cause
# `zmx run` and `zmx wait` to hang forever. (zsh NOMATCH is fine — verified.)
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-marker
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

zmx run mt true >/dev/null 2>&1
sleep 0.3

set +e
timeout 3 zmx run mt exit 5 >/dev/null 2>&1
RC=$?
set -e

echo "Command:        zmx run mt exit 5"
echo "zmx run rc:     $RC (expected 5)"
echo

if [[ $RC -ne 5 ]]; then
    echo "BUG REPRODUCED: shell-terminating command -> marker never fires -> wrong exit code"
    exit 1
fi
echo "OK"
exit 0
