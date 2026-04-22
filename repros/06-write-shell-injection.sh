#!/usr/bin/env bash
# Bug: `zmx write <session> <path>` interpolates <path> between single quotes
# in a shell command without validation. README warns "must not contain single
# quotes" but nothing enforces it. A path containing a single quote breaks out
# of quoting and executes arbitrary commands in the session shell.
#
# Root cause: src/main.zig:1084 — file_path used raw in:
#   printf '%s' '<b64>' | base64 -d > '<file_path>'
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-inject
PWNED=/tmp/zmx-pwned-$$

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR" "$PWNED" /tmp/zmx-x-$$
}
trap cleanup EXIT
cleanup

zmx run inj true >/dev/null 2>&1
sleep 0.5

echo hi | zmx write inj "/tmp/zmx-x-$$'; touch $PWNED; echo '" >/dev/null 2>&1
sleep 1

if [[ -e "$PWNED" ]]; then
    echo "BUG REPRODUCED: single-quote in path executed injected command (touch $PWNED)"
    exit 1
fi
echo "OK: injected command did not execute"
exit 0
