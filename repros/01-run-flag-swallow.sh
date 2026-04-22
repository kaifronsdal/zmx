#!/usr/bin/env bash
# Bug: `zmx run` parses -d/--fish flags with startsWith() and scans ALL args,
# not just leading ones. Any command argument beginning with "-d" or "--fish"
# is silently consumed as a zmx flag and removed from the command.
#
# Root cause: src/main.zig:159-171
#
# Impact: `zmx run sess ls -d /tmp` runs `ls /tmp` (lists contents) detached,
# instead of `ls -d /tmp` (prints "/tmp"). Affects find -depth, rm -d, date -d,
# any tool with -d* or --fish* flags.
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-flagbug

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

# `ls -d /` prints exactly "/". If -d is swallowed, `ls /` lists root contents.
zmx run t1 ls -d / >/dev/null 2>&1
sleep 0.5
OUT=$(zmx history t1 | grep -v ZMX_TASK | grep -v '^\$' | grep -v '^$' | head -5)

echo "Command sent:    zmx run t1 ls -d /"
echo "Expected output: /"
echo "Actual output:"
echo "$OUT"
echo

if [[ "$OUT" == "/" ]]; then
    echo "OK: -d was passed through to ls"
    exit 0
fi
echo "BUG REPRODUCED: -d was consumed by zmx, command became 'ls /'"
exit 1
