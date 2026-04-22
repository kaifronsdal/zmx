#!/usr/bin/env bash
# Bug: handleResize (src/main.zig:885-897) accepts rows=0/cols=0 from the
# wire and passes them to ghostty's term.resize(), which panics. Any local
# process that can reach the unix socket kills the daemon with a 12-byte
# message.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-resize
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

zmx run rz true >/dev/null 2>&1
sleep 0.4
zmx list | grep -q 'name=rz.*pid=' || { echo "setup failed"; exit 2; }

# Header packed{tag:u8,len:u32} -> @sizeOf=8. Resize tag=2. Payload packed{rows:u16,cols:u16}.
python3 - "$ZMX_DIR/rz" <<'EOF'
import socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(struct.pack("<BIxxx", 2, 4) + struct.pack("<HH", 0, 0))
time.sleep(0.3)
EOF
sleep 0.3

LIST=$(zmx list 2>/dev/null | grep 'name=rz')
echo "After Resize{0,0}: $LIST"
echo

if echo "$LIST" | grep -qE 'err=|unreachable'; then
    echo "BUG REPRODUCED: daemon crashed on Resize{rows=0,cols=0}"
    exit 1
fi
echo "OK: daemon survived"
exit 0
