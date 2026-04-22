#!/usr/bin/env bash
# Bug: ZMX_TASK_COMPLETED detection (src/util.zig:326-351) is called with
# each individual 4096-byte PTY read() chunk (src/main.zig:2223,2252) and
# keeps NO state between chunks. If the marker straddles a chunk boundary,
# the exit code is missed.
#
# This is non-deterministic because chunk boundaries depend on kernel PTY
# buffering, prompt length, and command-echo length. We sweep padding sizes
# around plausible 4096-byte boundaries and report any miss.
#
# Note: even when this script passes, the structural defect remains; it is
# probabilistic. See repros/04-sentinel-false-positive.sh for the related
# unanchored-match bug, which IS deterministic.
set -uo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-split
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR" /tmp/zmx-pad.sh
}
trap cleanup EXIT
cleanup

cat > /tmp/zmx-pad.sh <<'EOF'
#!/bin/bash
head -c "$1" /dev/zero | tr '\0' x
exit 7
EOF
chmod +x /tmp/zmx-pad.sh

# Warm session.
zmx run st true >/dev/null 2>&1
sleep 0.4

FAIL=0
# Sweep two boundary regions: ~1*4096 and ~2*4096 minus typical overhead.
for PAD in $(seq 3850 4100) $(seq 7950 8200); do
    timeout 4 zmx run st /tmp/zmx-pad.sh "$PAD" >/dev/null 2>&1
    EC=$(zmx list 2>/dev/null | grep 'name=st' | grep -oE 'exit_code=[0-9]+' | cut -d= -f2)
    if [[ "$EC" != "7" ]]; then
        echo "PAD=$PAD -> exit_code='${EC:-<missing>}' (expected 7)"
        FAIL=1
    fi
done

echo
if (( FAIL )); then
    echo "BUG REPRODUCED: marker split across read boundary -> wrong/missing exit code"
    exit 1
fi
echo "Could not trigger split in this environment (bug is structural; see source)"
exit 0
