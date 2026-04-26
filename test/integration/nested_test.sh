#!/usr/bin/env bash
# `run -i` → nested layer → `hook` → nested `run` → pop. End-to-end PID-stack.
set -u

ZMYTH=${ZMYTH:-./zig-out/bin/zmyth}
ROOT=$(mktemp -d /tmp/zmyth_nest.XXXXXX)
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n    got: %s\n" "$1" "$2"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1" "$(eval "echo $3" 2>&1)"; fi }
die() { printf "\033[31mFATAL\033[0m %s\n" "$1"; exit 1; }

cleanup() { "$ZMYTH" kill nst -9 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT
[ -x "$ZMYTH" ] || die "binary not found at $ZMYTH"

export HOME="$ROOT/home" ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"; : > "$HOME/.bashrc"

wait_idle() {
  for _ in $(seq 1 50); do
    "$ZMYTH" ls -j 2>/dev/null | grep -q "\"name\":\"$1\".*\"hooked\":true.*\"cmd_running\":false" && return 0
    sleep 0.1
  done; return 1
}
runj() {  # run -j and extract a field from the trailing JSON line
  local out; out=$("$ZMYTH" run -j "$@" 2>/dev/null); local rc=$?
  echo "$out" | tail -1; return $rc
}
jget() {  # jget <field> → bare value from `ls -j`
  "$ZMYTH" ls -j 2>/dev/null | grep -o "\"$1\":[^,}]*" | head -1 | cut -d: -f2
}

S=nst
echo "── outer layer ──"
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
chk "depth=1 after spawn" '[ "$(jget depth)" = 1 ]' '$(jget depth)'

echo "── run -i into nested bash (unhooked) ──"
# Subshell, NOT exec → distinct pid → pid-stack push.
j=$(runj -i "$S" -- 'bash --norc -i'); rc=$?
chk "run -i exits 0" '[ $rc -eq 0 ]' '$rc: $j'
chk "run -i via=at_prompt" 'echo "$j" | grep -q at_prompt' '$j'
chk "depth=2 after run -i" '[ "$(jget depth)" = 2 ]' '$(jget depth)'
chk "top unhooked (degraded)" '[ "$(jget hooked)" = false ]' '$(jget hooked)'

echo "── hook the nested layer ──"
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "hook exits 0" '[ $rc -eq 0 ]' '$rc: $out'
chk "hook reports installed" 'echo "$out" | grep -q "installed.*hook.bash"' '$out'
chk "top now hooked" '[ "$(jget hooked)" = true ]' '$(jget hooked)'
chk "depth still 2 (placeholder adopted, not stacked)" '[ "$(jget depth)" = 2 ]' '$(jget depth)'

echo "── nested run → exit code propagates from inner layer ──"
j=$(runj "$S" -- 'sh -c "exit 7"'); rc=$?
chk "nested run ec=7" '[ $rc -eq 7 ]' '$rc: $j'
chk "nested run via=osc_done" 'echo "$j" | grep -q "\"via\":\"osc_done\""' '$j'

echo "── exit nested → pop to outer ──"
j=$(runj "$S" -- 'exit 3'); rc=$?
# `exit` in inner bash: inner dies (no done from inner), outer's precmd fires
# done with bash's exit code → pop layer → request completes via layer_exited.
chk "exit-run ec=3 (outer's done carries inner's exit status)" '[ $rc -eq 3 ]' '$rc: $j'
chk "exit-run via=layer_exited" 'echo "$j" | grep -q layer_exited' '$j'
chk "depth=1 after pop" '[ "$(jget depth)" = 1 ]' '$(jget depth)'

echo "── outer layer still works ──"
"$ZMYTH" run "$S" -- 'exit 42' >/dev/null 2>&1; rc=$?
chk "outer run ec=42" '[ $rc -eq 42 ]' '$rc'

echo "── run -i on a non-shell command → osc_done, no push ──"
j=$(runj -i "$S" -- 'true'); rc=$?
chk "run -i true ec=0 via=osc_done" '[ $rc -eq 0 ] && echo "$j" | grep -q osc_done' '$rc: $j'
chk "depth still 1" '[ "$(jget depth)" = 1 ]' '$(jget depth)'

echo "── run -i into nested with file-installed hook → at_prompt + hooked ──"
# Hook is now in ~/.bashrc; a plain `bash -i` (no --norc) auto-hooks.
j=$(runj -i "$S" -- 'bash -i'); rc=$?
chk "run -i (file-hooked) via=at_prompt" 'echo "$j" | grep -q at_prompt' '$j'
chk "top hooked immediately (no zmyth hook needed)" '[ "$(jget hooked)" = true ]' '$(jget hooked)'
"$ZMYTH" run "$S" -- 'exit 0' >/dev/null 2>&1

echo
echo "── nested_test: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
