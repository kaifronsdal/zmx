#!/usr/bin/env bash
# Repros for bugs found in the 20-agent edge-case sweep. Each is expected to
# FAIL until the corresponding fix lands.
set -u
source "$(dirname "$0")/lib.sh"

ROOT=$(mktemp -d /tmp/zmyth_bugs.XXXXXX)
export HOME="$ROOT/home" ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"
cleanup() { for s in b3 b5 b12 b13; do nuke "$s"; done; rm -rf "$ROOT"; }
trap cleanup EXIT

# ─── B3: write closer missing \n wedges heredoc ──────────────────────────────
echo "── B3: zmyth write with body not ending in newline ──"
S=b3
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
# Write a body that does NOT end in \n. client.zig base64-encodes; check
# whether the heredoc closer lands on its own line.
printf 'no-trailing-newline' | "$ZMYTH" write "$S" /tmp/b3.out 2>&1
# Shell should be back at prompt (not wedged on unterminated heredoc).
if wait_idle "$S"; then
  ok "B3: shell returns to prompt after write (not wedged)"
  chk "B3: file has correct content" \
      '[ "$(cat /tmp/b3.out 2>/dev/null)" = "no-trailing-newline" ]' \
      '$(xxd /tmp/b3.out 2>/dev/null | head -2)'
else
  bad "B3: shell wedged after write (heredoc never terminated)" \
      "$("$ZMYTH" read "$S" -n 5 | tail -3)"
  # Unstick it for cleanup.
  "$ZMYTH" send "$S" $'\n__ZMX_EOF_unstick__\n\x03' >/dev/null
fi
# B3b: daemon-side robustness — even if a (hypothetical) client sends body
# without trailing \n, the closer's leading \n must keep the delimiter on its
# own line. Test by sending raw .write_data via `send` to simulate.
# (Skipped: requires raw IPC; the unit-level fix is "closer always leads \n".)
nuke "$S"; rm -f /tmp/b3.out

# ─── B5: single stalled client → leader-demote oscillation ───────────────────
echo "── B5: stalled sole attach client → no demote/re-elect oscillation ──"
S=b5
out=$(python3 - "$ZMYTH" "$ROOT" <<'PY'
import os, sys, pty, fcntl, struct, termios, time, subprocess
ZMYTH, ROOT = sys.argv[1], sys.argv[2]
env = dict(os.environ, ZMYTH_DIR=ROOT+"/run", HOME=ROOT+"/home", SHELL="/bin/bash")
env.pop("ZMYTH_SESSION", None)
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
p = subprocess.Popen([ZMYTH, "attach", "b5"], stdin=s, stdout=s, stderr=s,
                     env=env, start_new_session=True)
os.close(s); time.sleep(1.0)
# Push backlog past 256KiB so demote fires; then keep generating output for a
# few more poll iterations so any oscillation has time to spin.
subprocess.run([ZMYTH, "run", "b5", "--", "head -c 400000 /dev/zero | tr '\\0' x"],
               env=env, capture_output=True, timeout=15)
for _ in range(5):
    subprocess.run([ZMYTH, "run", "b5", "--", "echo tick"],
                   env=env, capture_output=True, timeout=5)
    time.sleep(0.1)
p.kill(); p.wait()
PY
)
# Count "demoting leader" log lines — should be at most 1 (the initial demote),
# not one per poll iteration.
log="$ROOT/home/.local/state/zmyth/b5.log"
[ -f "$log" ] || log=$(find "$ROOT" -name "b5.log" 2>/dev/null | head -1)
n=$(grep -c "demoting leader" "$log" 2>/dev/null || echo 0)
chk "B5: ≤1 'demoting leader' in log (got $n)" '[ "$n" -le 1 ]' "$n demotions"
nuke "$S"

# ─── B12: ZMYTH_SESSION set-but-empty should not refuse attach ───────────────
echo "── B12: ZMYTH_SESSION='' (set but empty) ──"
S=b12
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "session never hooked"
out=$(ZMYTH_SESSION="" timeout 2 "$ZMYTH" attach "$S" </dev/null 2>&1)
chk "B12: empty ZMYTH_SESSION not treated as 'already inside'" \
    '! echo "$out" | grep -q "already inside session"' '$out'
nuke "$S"

# ─── B13: read -f silent exit 0 on daemon death ──────────────────────────────
echo "── B13: read -f exits non-zero when daemon dies mid-stream ──"
S=b13
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "session never hooked"
"$ZMYTH" read -f "$S" >/dev/null 2>&1 &
rpid=$!
sleep 0.3
"$ZMYTH" kill "$S" -9 >/dev/null 2>&1
wait $rpid; rc=$?
chk "B13: read -f exits non-zero on daemon death" '[ $rc -ne 0 ]' "rc=$rc"

echo
echo "── bugs: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
