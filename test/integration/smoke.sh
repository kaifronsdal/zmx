#!/usr/bin/env bash
# Integration smoke tests for zmyth.
# Each scenario is independent: unique session name(s), cleaned up at the end
# of its block with `nuke`. PASS/FAIL per check; exit 0 iff all pass.
#
# Scenarios marked "# BUG:" expose known zmyth defects — they currently FAIL by
# design and should flip to PASS once src2/ is fixed. Do not weaken the
# assertion to make them pass.

set -uo pipefail

ZMX="${ZMX:-$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/zmyth}"
export ZMYTH_DIR=$(mktemp -d /tmp/zmyth-itest-XXXXXX)
export XDG_STATE_HOME="$ZMYTH_DIR/state"
unset ZMYTH_SESSION
export SHELL=${SHELL:-/bin/bash}

# Hard cleanup: `zmyth kill` (SIGTERM) is currently ineffective against
# interactive shells (see scenario 12b), so pkill any daemon rooted in our
# private ZMYTH_DIR, then remove the dir.
trap '"$ZMX" kill -9 "*" 2>/dev/null; pkill -9 -f "$ZMYTH_DIR" 2>/dev/null; rm -rf "$ZMYTH_DIR"' EXIT

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1  -- [$2]"; fi; }
nuke() { for n in "$@"; do "$ZMX" kill -9 "$n" >/dev/null 2>&1; done; sleep 0.1; }

[ -x "$ZMX" ] || { echo "FATAL: $ZMX not executable"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

# ── Portability shims (macOS/BSD) ───────────────────────────────────────────
# `timeout` is GNU-coreutils-only; macOS lacks it unless coreutils is brewed.
# perl is always present on macOS, so alarm+exec gives us a drop-in for the
# `timeout N cmd args...` form used below (no flags, integer seconds).
if ! command -v timeout >/dev/null; then
  timeout() { perl -e 'alarm shift; exec @ARGV' -- "$@"; }
fi
# `stat -c %a` is GNU; BSD stat spells it `-f %Lp`.
sock_perms() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Helper: extract a field from the trailing -j line of `run` output.
# Usage: jrun <field> <args...>   (echoes field value, returns run's ec)
jrun() {
  local field=$1; shift
  local out; out=$("$ZMX" run -j "$@" 2>/dev/null); local ec=$?
  echo "$out" | tail -n1 | jq -r ".$field" 2>/dev/null
  return $ec
}

# Helper: monotonic ms. BSD date has no %N, so use python3 (already required
# for scenarios 33/36 and attach_test.py).
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Basic exit codes (bash). Auto-creates session.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run -j t1 -- 'true' >/dev/null;     check "01a run true ec=0"    "[ $? -eq 0 ]"
"$ZMX" run -j t1 -- '(exit 42)' >/dev/null; check "01b run (exit 42)"   "[ $? -eq 42 ]"
"$ZMX" run -j t1 -- false >/dev/null;      check "01c run false ec=1"   "[ $? -eq 1 ]"
via=$(jrun via t1 -- 'true')
check "01d exit-code via osc_done (hooks active)" "[ '$via' = osc_done ]"
nuke t1

# ─────────────────────────────────────────────────────────────────────────────
# 2. zsh + fish shell integration
# ─────────────────────────────────────────────────────────────────────────────
if command -v zsh >/dev/null; then
  SHELL=$(command -v zsh) "$ZMX" run -j tz -- '(exit 17)' >/dev/null
  check "02a zsh (exit 17)" "[ $? -eq 17 ]"
  via=$(SHELL=$(command -v zsh) jrun via tz -- 'true')
  check "02b zsh hooked (osc_done)" "[ '$via' = osc_done ]"
  nuke tz
else
  echo "SKIP: 02a/02b (zsh not installed)"
fi
if command -v fish >/dev/null; then
  SHELL=$(command -v fish) "$ZMX" run -j tf -- 'false' >/dev/null
  check "02c fish false ec=1" "[ $? -eq 1 ]"
  via=$(SHELL=$(command -v fish) jrun via tf -- 'true')
  check "02d fish hooked (osc_done)" "[ '$via' = osc_done ]"
  nuke tf
else
  echo "SKIP: 02c/02d (fish not installed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. No marker pollution (#04 fix): user-echoed legacy marker is inert; OSC
#    sequences are swallowed by the VT and never appear in scrollback.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t3 -- 'true' >/dev/null
"$ZMX" run t3 -- 'echo ZMX_TASK_COMPLETED:99' >/dev/null
check "03a legacy marker string is inert (ec=0, not 99)" "[ $? -eq 0 ]"
out=$("$ZMX" read t3 -n 5)
check "03b OSC 2718 swallowed from scrollback" "! grep -q 2718 <<<\"\$out\""
check "03c command output preserved" "grep -q 'ZMX_TASK_COMPLETED:99' <<<\"\$out\""
nuke t3

# ─────────────────────────────────────────────────────────────────────────────
# 4. PTY-EOF path (#15 fix): `exit N` kills the shell; exit code recovered
#    from waitpid, not lost.
# ─────────────────────────────────────────────────────────────────────────────
via=$(jrun via te -- 'exit 7'); ec=$?
check "04a exit 7 -> ec=7"       "[ $ec -eq 7 ]"
check "04b exit 7 -> via=pty_eof" "[ '$via' = pty_eof ]"
# session should be gone
"$ZMX" ls -q | grep -qx te
check "04c session removed after shell exit" "[ $? -ne 0 ]"

# ─────────────────────────────────────────────────────────────────────────────
# 5. `run` arg parsing (#01,#09 fix): everything after `--` is the command,
#    even if it looks like a flag.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t5 -- -d >/dev/null 2>&1; ec=$?
check "05a '-- -d' treated as command (ec=127, not 0)" "[ $ec -eq 127 ]"
"$ZMX" run -d t5 -- 'true' >/dev/null; ec=$?
check "05b '-d' before name parsed as flag" "[ $ec -eq 0 ]"
err=$("$ZMX" run t5 'true' 2>&1 >/dev/null); ec=$?
check "05c missing -- rejected" "[ $ec -eq 2 ] && grep -q -- '--' <<<\"\$err\""
nuke t5

# ─────────────────────────────────────────────────────────────────────────────
# 6. kill nonexistent (#02 fix)
# ─────────────────────────────────────────────────────────────────────────────
err=$("$ZMX" kill nonesuch 2>&1); ec=$?
check "06  kill nonexistent -> ec!=0 + 'no such'" \
      "[ $ec -ne 0 ] && grep -qi 'no such' <<<\"\$err\""

# ─────────────────────────────────────────────────────────────────────────────
# 7. ls -j schema
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t7 -- 'true' >/dev/null
"$ZMX" ls -j | jq -e '.[0] | has("name") and has("pid") and has("hooked") and has("cwd")' >/dev/null
check "07a ls -j has name/pid/hooked/cwd" "[ $? -eq 0 ]"
"$ZMX" ls -j | jq -e '.[] | select(.name=="t7") | .last_exit == 0' >/dev/null
check "07b ls -j last_exit reflects last run" "[ $? -eq 0 ]"
nuke t7

# ─────────────────────────────────────────────────────────────────────────────
# 8. Concurrent ls (#132): N sessions probed in one poll, not N×timeout.
# ─────────────────────────────────────────────────────────────────────────────
for s in p1 p2 p3 p4 p5; do "$ZMX" run "$s" -- true >/dev/null; done
t0=$(now_ms); "$ZMX" ls >/dev/null; t1=$(now_ms)
check "08  ls over 5 sessions < 1000ms (got $((t1-t0))ms)" "[ $((t1-t0)) -lt 1000 ]"
nuke p1 p2 p3 p4 p5

# ─────────────────────────────────────────────────────────────────────────────
# 9. send + read: raw PTY input round-trips to scrollback. Match start-of-line
#    so we hit the executed echo's output, not the prompt-echoed input line.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t9 -- 'true' >/dev/null
printf 'echo SEND-%s-OK\r' "$$" | "$ZMX" send t9 -
sleep 0.3
"$ZMX" read t9 -n 5 | grep -qE "^SEND-$$-OK"
check "09  send + read round-trip (executed, not just echoed)" "[ $? -eq 0 ]"
nuke t9

# ─────────────────────────────────────────────────────────────────────────────
# 10. read -s (screen) shows command output on the visible grid.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t10 -- 'echo SCREEN-MARKER' >/dev/null
"$ZMX" read t10 -s | grep -q SCREEN-MARKER
check "10  read -s contains SCREEN-MARKER" "[ $? -eq 0 ]"
nuke t10

# ─────────────────────────────────────────────────────────────────────────────
# 11. mv (#46): rename socket; renamed session still usable.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t11 -- 'true' >/dev/null
"$ZMX" mv t11 renamed11; ec=$?
check "11a mv ec=0" "[ $ec -eq 0 ]"
"$ZMX" ls -q | grep -qx renamed11
check "11b ls shows new name" "[ $? -eq 0 ]"
"$ZMX" ls -q | grep -qx t11
check "11c ls no longer shows old name" "[ $? -ne 0 ]"
"$ZMX" run renamed11 -- 'true' >/dev/null
check "11d run on renamed session works" "[ $? -eq 0 ]"
nuke renamed11

# ─────────────────────────────────────────────────────────────────────────────
# 12. glob kill
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run g-a -- true >/dev/null
"$ZMX" run g-b -- true >/dev/null
"$ZMX" kill -9 'g-*'; sleep 0.3
left=$("$ZMX" ls -q | grep -c '^g-' || true)
check "12a kill -9 'g-*' removes both" "[ $left -eq 0 ]"

# BUG: zmyth kill (SIGTERM) sends the signal to the interactive shell, which
# ignores SIGTERM. Daemon should either SIGHUP the shell, close the PTY
# master, or treat .kill as a daemon-shutdown request. Currently a no-op.
"$ZMX" run g-c -- true >/dev/null
"$ZMX" kill g-c; sleep 0.5
"$ZMX" ls -q | grep -qx g-c
check "12b kill (SIGTERM) terminates session" "[ $? -ne 0 ]"
nuke g-c

# ─────────────────────────────────────────────────────────────────────────────
# 13. Large output across read boundaries (#10 fix): 100KB of base64 noise
#     before the precmd OSC; exit code must still be recovered.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t13 -- true >/dev/null   # warm: get hooks installed first
ec_json=$(jrun exit_code t13 -- 'head -c 100000 /dev/urandom | base64; (exit 13)'); ec=$?
check "13  large output -> ec=13 (json=$ec_json)" "[ $ec -eq 13 ] && [ '$ec_json' = 13 ]"
nuke t13

# ─────────────────────────────────────────────────────────────────────────────
# 14. Backgrounded command: `sleep 5 &` returns to prompt immediately.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t14 -- true >/dev/null
t0=$(now_ms); "$ZMX" run -j t14 -- 'sleep 5 &' >/dev/null; ec=$?; t1=$(now_ms)
check "14  'sleep 5 &' ec=0 in <1000ms (got $((t1-t0))ms)" \
      "[ $ec -eq 0 ] && [ $((t1-t0)) -lt 1000 ]"
nuke t14

# ─────────────────────────────────────────────────────────────────────────────
# 15. Ctrl-C exit code: SIGINT -> last_exit=130.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t15 -- true >/dev/null
"$ZMX" run -d t15 -- 'sleep 10'
sleep 0.3
printf '\x03' | "$ZMX" send t15 -
sleep 0.5
last=$("$ZMX" ls -j | jq '.[] | select(.name=="t15") | .last_exit')
check "15  Ctrl-C -> last_exit=130 (got $last)" "[ '$last' = 130 ]"
nuke t15

# ─────────────────────────────────────────────────────────────────────────────
# 16. Two concurrent `run` on same session queue and both complete.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t16 -- true >/dev/null
tmp=$(mktemp)
( "$ZMX" run -j t16 -- 'sleep 0.3; (exit 5)' 2>/dev/null | tail -n1 >>"$tmp" ) &
( "$ZMX" run -j t16 -- '(exit 6)'           2>/dev/null | tail -n1 >>"$tmp" ) &
wait
got5=$(jq -r .exit_code <"$tmp" | grep -cx 5 || true)
got6=$(jq -r .exit_code <"$tmp" | grep -cx 6 || true)
check "16  concurrent runs -> both ec=5 and ec=6 reported" \
      "[ $got5 -eq 1 ] && [ $got6 -eq 1 ]"
rm -f "$tmp"
nuke t16

# ─────────────────────────────────────────────────────────────────────────────
# 17. Invalid session name rejected.
# ─────────────────────────────────────────────────────────────────────────────
err=$("$ZMX" run '../etc' -- true 2>&1); ec=$?
check "17a invalid name '../etc' -> ec=2 + 'invalid'" \
      "[ $ec -eq 2 ] && grep -qi invalid <<<\"\$err\""
err=$("$ZMX" run 'a b' -- true 2>&1); ec=$?
check "17b invalid name 'a b' -> ec=2" "[ $ec -eq 2 ]"

# ─────────────────────────────────────────────────────────────────────────────
# 18. help / version / unknown verb
# ─────────────────────────────────────────────────────────────────────────────
out=$("$ZMX" version); ec=$?
check "18a version ec=0 contains 'zmyth'" "[ $ec -eq 0 ] && grep -q zmyth <<<\"\$out\""
"$ZMX" help >/dev/null
check "18b help ec=0" "[ $? -eq 0 ]"
"$ZMX" bogusverb >/dev/null 2>&1
check "18c unknown verb ec=2" "[ $? -eq 2 ]"
"$ZMX" >/dev/null 2>&1
check "18d no args ec=2" "[ $? -eq 2 ]"

# ─────────────────────────────────────────────────────────────────────────────
# 19. fish backslash arg (#17 fix): trailing \ in arg no longer hangs.
# ─────────────────────────────────────────────────────────────────────────────
if command -v fish >/dev/null; then
  # $'..\\' yields ONE trailing backslash (the original '..\\' is two, which
  # fish accepts as an escaped backslash and executes via osc_done).
  out=$(SHELL=$(command -v fish) timeout 10 "$ZMX" run -j tfq -- $'printf %s foo\\' 2>/dev/null); ec=$?
  via=$(tail -n1 <<<"$out" | jq -r .via 2>/dev/null)
  check "19  fish trailing-\\ -> line_rejected (no hang; via=$via)" \
        "[ $ec -ne 124 ] && [ '$via' = line_rejected ]"
  nuke tfq
else
  echo "SKIP: 19 (fish not installed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 20. write: text via base64 heredoc (#06/#03/#14 fix).
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t20 -- true >/dev/null
dst=/tmp/zmyth-write-test.txt; rm -f "$dst"
echo "hello write" | "$ZMX" write t20 "$dst"; ec=$?
sleep 0.3
check "20a write ec=0" "[ $ec -eq 0 ]"
check "20b write text round-trip" "[ \"\$(cat '$dst' 2>/dev/null)\" = 'hello write' ]"
rm -f "$dst"
nuke t20

# ─────────────────────────────────────────────────────────────────────────────
# 21. write: 10KB random binary survives base64 transport intact.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t21 -- true >/dev/null
src=$(mktemp); dst=$(mktemp); rm -f "$dst"
head -c 10240 /dev/urandom > "$src"
"$ZMX" write t21 "$dst" < "$src"
sleep 1
diff -q "$src" "$dst" >/dev/null 2>&1
check "21  write 10KB binary round-trip" "[ $? -eq 0 ]"
rm -f "$src" "$dst"
nuke t21

# ─────────────────────────────────────────────────────────────────────────────
# 22. wait: blocks on the daemon (no polling) until run completes.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t22 -- true >/dev/null
"$ZMX" run -d t22 -- 'sleep 0.5; (exit 9)'
sleep 0.1
t0=$(now_ms); "$ZMX" wait t22; ec=$?; t1=$(now_ms)
check "22a wait returns ec=9" "[ $ec -eq 9 ]"
check "22b wait actually blocked (~400ms, got $((t1-t0))ms)" \
      "[ $((t1-t0)) -gt 250 ] && [ $((t1-t0)) -lt 2000 ]"
# Idle session: wait returns immediately with last_exit.
t0=$(now_ms); "$ZMX" wait t22; ec=$?; t1=$(now_ms)
check "22c wait on idle returns immediately ec=9 (got $((t1-t0))ms)" \
      "[ $ec -eq 9 ] && [ $((t1-t0)) -lt 200 ]"
nuke t22

# ── 23: ensure() race — two clients create the same session concurrently ────
nuke race23
( "$ZMX" run -j race23 -- 'sh -c "exit 3"' >"$ZMYTH_DIR/r23a" 2>&1 ) &
( "$ZMX" run -j race23 -- 'sh -c "exit 4"' >"$ZMYTH_DIR/r23b" 2>&1 ) &
wait
a_ec=$(grep -ao '{"exit_code":[^}]*}' "$ZMYTH_DIR/r23a" | jq -r .exit_code 2>/dev/null)
b_ec=$(grep -ao '{"exit_code":[^}]*}' "$ZMYTH_DIR/r23b" | jq -r .exit_code 2>/dev/null)
locks=$(grep -c 'lock acquired' "$XDG_STATE_HOME/zmyth/race23.log" 2>/dev/null || echo 0)
check "23a race: both runs completed (got $a_ec,$b_ec)" \
  "[[ '$a_ec $b_ec' == '3 4' || '$a_ec $b_ec' == '4 3' ]]"
check "23b race: exactly one daemon won lock (got $locks)" "[[ $locks -eq 1 ]]"
nuke race23

# ─────────────────────────────────────────────────────────────────────────────
# 24. read -f (follow): tails new output as it arrives.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run t24 -- true >/dev/null
"$ZMX" read t24 -f >"$ZMYTH_DIR/follow.out" 2>&1 &
fpid=$!
sleep 0.2
"$ZMX" run t24 -- 'echo FOLLOW-MARK' >/dev/null
sleep 0.3
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
grep -q FOLLOW-MARK "$ZMYTH_DIR/follow.out"
check "24  read -f streams new output" "[ $? -eq 0 ]"
nuke t24

# ─────────────────────────────────────────────────────────────────────────────
# 25. mv onto existing name must refuse (no clobber).
# BUG: handleRename calls posix.rename without checking for an existing target
#      socket, so the live m-b daemon is silently orphaned. Daemon should
#      stat/connect the target first and queueErr if it exists.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run m-a -- true >/dev/null
"$ZMX" run m-b -- true >/dev/null
"$ZMX" mv m-a m-b >/dev/null 2>&1; ec=$?
check "25a mv onto existing name -> ec!=0" "[ $ec -ne 0 ]"
"$ZMX" ls -q | grep -qx m-a
check "25b source session still present" "[ $? -eq 0 ]"
nuke m-a m-b

# ─────────────────────────────────────────────────────────────────────────────
# 26. run -j output ordering: command stdout precedes the trailing JSON line.
#     Regression for the File.writer pwritev bug (positional writer clobbered
#     stream-written output).
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run -j tord -- 'echo BEFORE-JSON' >"$ZMYTH_DIR/ord.out" 2>&1
tail -1 "$ZMYTH_DIR/ord.out" | jq -e '.exit_code == 0' >/dev/null
check "26a run -j: last line is JSON exit_code=0" "[ $? -eq 0 ]"
grep -q BEFORE-JSON "$ZMYTH_DIR/ord.out"
check "26b run -j: command output present before JSON" "[ $? -eq 0 ]"
nuke tord

# ── 27: attach (PTY harness) ────────────────────────────────────────────────
if python3 "$(dirname "$0")/attach_test.py" >"$ZMYTH_DIR/attach.log" 2>&1; then
  ok "27  attach pty harness (8 sub-checks)"
else
  bad "27  attach pty harness"; cat "$ZMYTH_DIR/attach.log"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Hostile-environment scenarios (30–36)
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# 30. HOME unset: stateDir() must fall back to runtimeDir/state instead of
#     crashing on the missing HOME/XDG_STATE_HOME lookup.
# ─────────────────────────────────────────────────────────────────────────────
env -u HOME -u XDG_STATE_HOME ZMYTH_DIR="$ZMYTH_DIR" "$ZMX" run -j h30 -- true >/dev/null 2>&1
check "30  HOME unset -> ec=0 (stateDir falls back)" "[ $? -eq 0 ]"
nuke h30

# ─────────────────────────────────────────────────────────────────────────────
# 31. SHELL=/nonexistent: daemon exec fails. Client must surface a useful
#     diagnostic (DaemonStartTimeout), not the misleading legacy NoSuchSession.
# ─────────────────────────────────────────────────────────────────────────────
err=$(SHELL=/nonexistent "$ZMX" run -j h31 -- true 2>&1); ec=$?
check "31  SHELL=/nonexistent -> ec!=0, informative error (got: $err)" \
      "[ $ec -ne 0 ] && ! grep -qi 'NoSuchSession' <<<\"\$err\""
nuke h31

# ─────────────────────────────────────────────────────────────────────────────
# 32. SHELL=dash (unsupported): dash has no PROMPT_COMMAND/DEBUG/?2004h, so the
#     daemon refuses `run` immediately with an explanatory error rather than
#     hanging. attach/send/read still work.
# ─────────────────────────────────────────────────────────────────────────────
if command -v dash >/dev/null; then
  err=$(SHELL=$(command -v dash) timeout 5 "$ZMX" run -j h32 -- true 2>&1 >/dev/null); ec=$?
  check "32a SHELL=dash -> run rejected fast (ec=125, not hang)" "[ $ec -eq 125 ]"
  check "32b error mentions 'shell integration unavailable'" \
    "grep -qi 'integration unavailable' <<<\"\$err\""
  nuke h32
else
  echo "SKIP: 32 (dash not installed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 33. Socket path > sun_path (108): client should reject up front with a
#     length/path diagnostic rather than spawning a daemon that silently
#     fails to bind and surfacing only DaemonStartTimeout.
# ─────────────────────────────────────────────────────────────────────────────
err=$(ZMYTH_DIR="$ZMYTH_DIR/$(python3 -c 'print("x"*90)')" "$ZMX" run h33 -- true 2>&1); ec=$?
check "33  socket path >108 -> ec!=0, mentions length/long/path (got: $err)" \
      "[ $ec -ne 0 ] && grep -qiE 'length|long|path' <<<\"\$err\""

# ─────────────────────────────────────────────────────────────────────────────
# 34. umask 000: socket must be fchmod'd to 0600 after bind regardless of the
#     caller's umask, so other users on the box can't connect.
# ─────────────────────────────────────────────────────────────────────────────
( umask 000; "$ZMX" run h34 -- true >/dev/null 2>&1 )
perm=$(sock_perms "$ZMYTH_DIR/h34.sock" 2>/dev/null || echo 999)
check "34  umask 000 -> socket perms <=700 (got $perm)" "[ '$perm' -le 700 ]"
nuke h34

# ─────────────────────────────────────────────────────────────────────────────
# 35. Large output: exit-code reporting survives a firehose. The OSC done
#     marker must be parsed correctly after a wall of preceding bytes.
#     Note: ghostty-vt is ~700x slower in Debug builds (~50KB/s vs ~50MB/s in
#     ReleaseSafe), so the size is tuned to complete in <15s under Debug.
# ─────────────────────────────────────────────────────────────────────────────
timeout 30 "$ZMX" run -j h35 -- 'head -c 500000 /dev/zero | tr "\0" x; (exit 13)' >/dev/null 2>&1
check "35  500KB output -> ec=13" "[ $? -eq 13 ]"
nuke h35

# ─────────────────────────────────────────────────────────────────────────────
# 36. max_clients saturation: hold 70 idle connections (>max_clients=64); a
#     fresh `run` must be rejected. After releasing them, `run` works again.
# ─────────────────────────────────────────────────────────────────────────────
"$ZMX" run h36 -- true >/dev/null 2>&1
python3 -c "
import socket, time
ss = []
for _ in range(70):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect('$ZMYTH_DIR/h36.sock'); ss.append(s)
    except OSError:
        pass
print('READY', flush=True)
time.sleep(30)
" >"$ZMYTH_DIR/h36.ready" &
hogpid=$!
for _ in $(seq 50); do grep -q READY "$ZMYTH_DIR/h36.ready" 2>/dev/null && break; sleep 0.1; done
timeout 5 "$ZMX" run h36 -- true >/dev/null 2>&1; ec=$?
check "36a max_clients saturated -> run rejected (ec!=0)" "[ $ec -ne 0 ]"
kill "$hogpid" 2>/dev/null; wait "$hogpid" 2>/dev/null; sleep 0.3
timeout 5 "$ZMX" run h36 -- true >/dev/null 2>&1; ec=$?
check "36b connections released -> run succeeds" "[ $ec -eq 0 ]"
nuke h36

# ─────────────────────────────────────────────────────────────────────────────
# 37/38 require bash ≥4 for bracketed-paste support. macOS /bin/bash is 3.2,
# so prefer `command -v bash` (picks up brew bash 5.x on PATH) and skip if the
# resolved bash is still <4.
# ─────────────────────────────────────────────────────────────────────────────
BASH_BIN=$(command -v bash)
BASH_MAJOR=$("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}')

# ─────────────────────────────────────────────────────────────────────────────
# 37. bash `set -o vi`, prompt left in NORMAL mode: typeCommand's ^U and
#     ESC[200~ are unbound in the default vi-command keymap, so the wrapper
#     would be parsed as vi motions. hook.bash must bind them in vi-command.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$BASH_MAJOR" -ge 4 ]; then
  home37=$(mktemp -d); printf 'set -o vi\n' >"$home37/.bashrc"
  HOME="$home37" SHELL="$BASH_BIN" "$ZMX" run h37 -- true >/dev/null
  printf '\033' | "$ZMX" send h37 -   # ESC -> readline vi NORMAL mode
  sleep 0.6                           # > readline keyseq-timeout (500ms)
  timeout 10 "$ZMX" run -j h37 -- '(exit 7)' >/dev/null
  check "37  bash vi-mode, prompt in NORMAL -> run ec=7" "[ $? -eq 7 ]"
  rm -rf "$home37"; nuke h37
else
  echo "SKIP: 37 (bash $BASH_MAJOR.x lacks bracketed-paste; need >=4)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 38. bash `set enable-bracketed-paste off`: readline never emits ?2004h and
#     the user has opted out of paste detection. hook.bash must force it back
#     on so `run`'s bracketed-paste wrapper and the ?2004h prompt fallback
#     both work.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$BASH_MAJOR" -ge 4 ]; then
  home38=$(mktemp -d)
  printf "bind 'set enable-bracketed-paste off'\n" >"$home38/.bashrc"
  via=$(HOME="$home38" SHELL="$BASH_BIN" jrun via h38 -- '(exit 3)'); ec=$?
  check "38  bash enable-bracketed-paste off -> run ec=3 via osc_done" \
        "[ $ec -eq 3 ] && [ '$via' = osc_done ]"
  rm -rf "$home38"; nuke h38
else
  echo "SKIP: 38 (bash $BASH_MAJOR.x lacks bracketed-paste; need >=4)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
echo "$PASS passed, $FAIL failed"
exit $((FAIL>0))
