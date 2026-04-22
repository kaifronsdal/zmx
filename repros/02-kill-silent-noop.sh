#!/usr/bin/env bash
# Bug: `zmx kill <name>` on a non-existent session silently exits 0 with no
# output. Typos go unnoticed; scripts can't detect failure.
#
# Root cause: src/main.zig:231-246 — kill iterates EXISTING sessions and only
# acts on matches. An exact name with no match falls through with no error.
# Compare `zmx history nonexistent` which DOES report an error.
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-killbug

cleanup() { rm -rf "$ZMX_DIR"; }
trap cleanup EXIT
cleanup

set +e
OUT=$(zmx kill does-not-exist 2>&1)
RC=$?
set -e

echo "Command:  zmx kill does-not-exist"
echo "Output:   ${OUT:-<empty>}"
echo "Exit code: $RC"
echo

if [[ $RC -eq 0 && -z "$OUT" ]]; then
    echo "BUG REPRODUCED: kill of non-existent session exits 0 with no error"
    exit 1
fi
echo "OK: kill reported an error"
exit 0
