#!/usr/bin/env bash
# Bug: handleWrite (src/main.zig:1054-1057) decodes a u32 path_len from the
# IPC payload then checks `payload.len < @sizeOf(u32) + path_len`. The
# addition is performed in u32 (comptime_int 4 coerces to u32), so a
# path_len >= 0xFFFFFFFC overflows. In ReleaseSafe this PANICS the daemon,
# killing the user's session. Any local process that can connect to the
# unix socket can trigger this.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-pathlen
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

zmx run pl true >/dev/null 2>&1
sleep 0.5
zmx list | grep -q 'name=pl' || { echo "setup failed"; exit 2; }

# Send a raw .Write message with path_len = 0xFFFFFFFF.
# Header is `packed struct { tag: u8, len: u32 }` -> @sizeOf=8 (40 bits padded
# to backing-int alignment). Layout: [tag:1][len:4 LE][pad:3].
# .Write tag = 12. Payload: [u32 path_len][...].
python3 - "$ZMX_DIR/pl" <<'EOF'
import socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
TAG_WRITE = 12
payload = struct.pack("<I", 0xFFFFFFFF)   # path_len that overflows 4+u32
header = struct.pack("<BIxxx", TAG_WRITE, len(payload))  # 8 bytes
s.sendall(header + payload)
s.close()
EOF
sleep 0.5

LIST=$(zmx list 2>/dev/null | grep 'name=pl')
echo "After crafted message: $LIST"
echo

if echo "$LIST" | grep -qE 'err=|unreachable'; then
    echo "BUG REPRODUCED: daemon crashed on path_len=0xFFFFFFFF (u32 overflow at main.zig:1055)"
    exit 1
fi
if echo "$LIST" | grep -q 'pid='; then
    echo "OK: daemon survived crafted .Write message"
    exit 0
fi
echo "BUG REPRODUCED: daemon gone after crafted .Write message"
exit 1
