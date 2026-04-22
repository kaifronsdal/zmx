#!/usr/bin/env bash
# Bug: `zmx write` silently truncates/corrupts files larger than ~190KB.
#
# Root cause: src/main.zig:1068-1090 (handleWrite) queues all base64 chunks
# synchronously via queuePtyInput() in one daemon-loop iteration with no
# draining between chunks. queuePtyInput (src/main.zig:749-757) drops payloads
# once the buffer exceeds PTY_WRITE_BUF_MAX (256KB). Dropped chunks are logged
# as a warning but the client still gets .Ack -> "file created" success.
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-writebug
IN=/tmp/zmx-write-in
OUT=/tmp/zmx-write-out

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR" "$IN" "$OUT"
}
trap cleanup EXIT
cleanup

# Create a session with a live shell.
zmx run wtest true >/dev/null 2>&1
sleep 0.5

# 500KB input.
head -c 500000 /dev/urandom > "$IN"
IN_SUM=$(sha256sum "$IN" | cut -d' ' -f1)

zmx write wtest "$OUT" < "$IN"
sleep 4   # let the shell drain printf|base64 chunks

OUT_SIZE=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
OUT_SUM=$(sha256sum "$OUT" 2>/dev/null | cut -d' ' -f1 || echo none)

echo "Input:  500000 bytes  $IN_SUM"
echo "Output: $OUT_SIZE bytes  $OUT_SUM"
DROPPED=$(grep -c "pty input dropped" "$ZMX_DIR/logs/wtest.log" 2>/dev/null || echo 0)
echo "Daemon log 'pty input dropped' count: $DROPPED"
echo

if [[ "$IN_SUM" == "$OUT_SUM" ]]; then
    echo "OK: file transferred intact"
    exit 0
fi
echo "BUG REPRODUCED: output differs from input (silent corruption)"
exit 1
