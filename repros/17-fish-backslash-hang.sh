#!/usr/bin/env bash
# Bug: shellQuote (src/util.zig:117-140) wraps args in single quotes using
# the POSIX '\'' trick. For an arg ending in backslash, e.g. `foo\`, it
# produces `'foo\'`. In POSIX shells that's `foo\`. In fish, `\'` inside
# single quotes is an ESCAPED quote, so the string is unterminated -> fish
# waits at a continuation prompt -> `zmx run` hangs forever.
#
# Requires fish.
set -uo pipefail
command -v fish >/dev/null || { echo "SKIP: fish not installed"; exit 0; }

export PATH=/home/ubuntu/GitHub/zmx/zig-out/bin:$PATH
export ZMX_DIR=/tmp/zmx-test-fishbs
unset ZMX_SESSION

cleanup() {
    zmx kill '*' --force >/dev/null 2>&1
    rm -rf "$ZMX_DIR"
}
trap cleanup EXIT
cleanup

SHELL=$(command -v fish) zmx run ft --fish true >/dev/null 2>&1
sleep 0.5

set +e
timeout 3 zmx run ft --fish printf %s 'tail\' >/dev/null 2>&1
RC=$?
set -e

echo "Command:  zmx run ft --fish printf %s 'tail\\'"
echo "rc=$RC (124=hung)"
echo

if [[ $RC -eq 124 ]]; then
    echo "BUG REPRODUCED: shellQuote produces 'tail\\' which is unterminated in fish -> hang"
    exit 1
fi
echo "OK"
exit 0
