#!/usr/bin/env bash
# Bug: `zmx tail` does not dedupe resolved session names. The same session
# given twice (or matched by both a wildcard and an exact name) is connected
# twice -> duplicated output.
#
# Root cause: src/main.zig:296-318. Exact-match names are appended
# unconditionally (line 314-318) with no dedup against earlier resolution.
# Simplest case: `zmx tail bb bb`.
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-tailbug

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

# One long-lived session is enough.
zmx run bb sleep 30 >/dev/null 2>&1 &
RUN_PID=$!
sleep 0.5

# Tail it with the same exact name twice. With the bug, two client sockets
# are opened to the bb daemon. (Also reproduces with `zmx tail 'b*' bb`.)
zmx tail bb bb >/dev/null 2>&1 &
TAIL_PID=$!
sleep 0.5

# `zmx list` reports clients=N for each session (the listing connection itself
# is subtracted server-side). Expected: 2 (one `zmx run` foreground client +
# one tail). Buggy: 3 (run + two tails).
LIST_OUT=$(zmx list)
echo "$LIST_OUT"
CLIENTS=$(echo "$LIST_OUT" | grep -E 'name=bb\b' | sed -E 's/.*clients=([0-9]+).*/\1/')

kill "$TAIL_PID" 2>/dev/null || true
kill "$RUN_PID" 2>/dev/null || true

echo
if [[ "$CLIENTS" -gt 2 ]]; then
    echo "BUG REPRODUCED: bb has clients=$CLIENTS (expected 2) -> tail connected twice"
    exit 1
else
    echo "OK: bb has clients=$CLIENTS"
    exit 0
fi
