#!/usr/bin/env bash
# `run -i` → nested layer → `hook` → nested `run` → pop. End-to-end PID-stack.
set -u

source "$(dirname "$0")/lib.sh"

ROOT=$(mktemp -d /tmp/zmyth_nest.XXXXXX)
cleanup() { "$ZMYTH" kill nst -9 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

export HOME="$ROOT/home" ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"; : > "$HOME/.bashrc"

runj() {  # run -j and emit the trailing JSON line
  local out; out=$("$ZMYTH" run -j "$@" 2>/dev/null); local rc=$?
  echo "$out" | tail -1; return $rc
}

S=nst
echo "── outer layer ──"
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
chk "depth=1 after spawn" '[ "$(jget "$S" depth)" = 1 ]' '$(jget "$S" depth)'

echo "── run -i into nested bash (unhooked) ──"
# Subshell, NOT exec → distinct pid → pid-stack push.
j=$(runj -i "$S" -- 'bash --norc -i'); rc=$?
chk "run -i exits 0" '[ $rc -eq 0 ]' '$rc: $j'
chk "run -i via=at_prompt" 'echo "$j" | grep -q at_prompt' '$j'
chk "depth=2 after run -i" '[ "$(jget "$S" depth)" = 2 ]' '$(jget "$S" depth)'
chk "top unhooked (degraded)" '[ "$(jget "$S" hooked)" = false ]' '$(jget "$S" hooked)'

echo "── hook the nested layer ──"
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "hook exits 0" '[ $rc -eq 0 ]' '$rc: $out'
chk "hook reports installed" 'echo "$out" | grep -q "installed.*hook.bash"' '$out'
chk "top now hooked" '[ "$(jget "$S" hooked)" = true ]' '$(jget "$S" hooked)'
chk "depth still 2 (placeholder adopted, not stacked)" '[ "$(jget "$S" depth)" = 2 ]' '$(jget "$S" depth)'

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
chk "depth=1 after pop" '[ "$(jget "$S" depth)" = 1 ]' '$(jget "$S" depth)'

echo "── outer layer still works ──"
"$ZMYTH" run "$S" -- 'exit 42' >/dev/null 2>&1; rc=$?
chk "outer run ec=42" '[ $rc -eq 42 ]' '$rc'

echo "── run -i on a non-shell command → osc_done, no push ──"
j=$(runj -i "$S" -- 'true'); rc=$?
chk "run -i true ec=0 via=osc_done" '[ $rc -eq 0 ] && echo "$j" | grep -q osc_done' '$rc: $j'
chk "depth still 1" '[ "$(jget "$S" depth)" = 1 ]' '$(jget "$S" depth)'

echo "── run -i into nested with file-installed hook → at_prompt + hooked ──"
# Hook is now in ~/.bashrc; a plain `bash -i` (no --norc) auto-hooks.
j=$(runj -i "$S" -- 'bash -i'); rc=$?
chk "run -i (file-hooked) via=at_prompt" 'echo "$j" | grep -q at_prompt' '$j'
chk "top hooked immediately (no zmyth hook needed)" '[ "$(jget "$S" hooked)" = true ]' '$(jget "$S" hooked)'
"$ZMYTH" run "$S" -- 'exit 0' >/dev/null 2>&1

echo
echo "── nested_test: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
