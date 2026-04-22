#!/usr/bin/env bash
# Bug: README and `zmx help` show the example `zmx run -d dev sleep 10`, but
# the parser consumes the FIRST positional as session_name before scanning
# flags. So `zmx run -d dev sleep 10` creates a session literally named "-d"
# and runs `dev sleep 10` inside it.
#
# Root cause: src/main.zig:153 — `session_name = args.next()` before flag loop.
# Doc: src/main.zig help text + README.md "zmx run -d dev sleep 10".
set -euo pipefail

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-dpos

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1 || true
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

zmx run -d dev sleep 1 >/dev/null 2>&1 || true
sleep 0.3
LIST=$(zmx list --short 2>/dev/null)

echo "Command:  zmx run -d dev sleep 1   (per README example)"
echo "Sessions: ${LIST:-<none>}"
echo

if echo "$LIST" | grep -qx -- "-d"; then
    echo "BUG REPRODUCED: session named '-d' was created; documented example is wrong"
    exit 1
fi
if echo "$LIST" | grep -qx "dev"; then
    echo "OK: session 'dev' created as documented"
    exit 0
fi
echo "INCONCLUSIVE: neither session found"
exit 2
