#!/usr/bin/env bash
# Hook-script edge cases that don't need a full zmyth session: source the
# asset directly under hostile shell options/locales and verify no
# error/abort. These run as plain shell tests, no daemon.
set -u
source "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$HERE/../../src2/assets"

echo "── hook.bash under set -e (B9: arithmetic returning false aborts) ──"
out=$(bash --norc -ec '
  set -e
  PROMPT_COMMAND=""
  source '"$ASSETS"'/hook.bash
  __ZMX_EC=0
  __zmx_precmd      # dur computation: (( dur < 0 )) returns 1 when false
  echo SURVIVED
' 2>&1)
chk "B9: hook.bash precmd survives set -e" 'echo "$out" | grep -q SURVIVED' '$out'

echo "── H4: hook.bash cap probe under set -e WITHOUT gunzip ──"
nogz=$(mktemp -d); ln -sf "$(command -v sed)" "$nogz/sed"
out=$(bash --norc -c '
  set -e
  PATH='"$nogz"'   # sed for the DEBUG-trap parse; no gunzip
  PROMPT_COMMAND=""
  source '"$ASSETS"'/hook.bash
  echo "SURVIVED $__ZMX_CAP"
' 2>&1)
rm -rf "$nogz"
chk "H4: cap probe survives set -e w/o gunzip" 'echo "$out" | grep -q "SURVIVED b$"' '$out'

echo "── hook.bash under comma-decimal locale (B8) ──"
# Find an installed locale with comma decimal_point.
comma_loc=$(locale -a 2>/dev/null | grep -iE '^(de_DE|fr_FR|nl_NL|es_ES|ru_RU)' | head -1)
if [ -z "$comma_loc" ]; then
  echo "  SKIP: no comma-decimal locale installed"
else
  out=$(env LC_NUMERIC="$comma_loc" bash --norc -c '
    set -e
    PROMPT_COMMAND=""
    source '"$ASSETS"'/hook.bash
    # Force EPOCHREALTIME to be read so the comma-decimal split path runs.
    __ZMX_AT_PROMPT=1; __ZMX_IN_PC=""
    __zmx_preexec 2>/dev/null
    __ZMX_EC=0
    __zmx_precmd
    echo SURVIVED
  ' 2>&1)
  chk "B8: hook.bash survives LC_NUMERIC=$comma_loc" 'echo "$out" | grep -q SURVIVED' '$out'
fi

echo "── hook.bash with prior DEBUG trap containing single-quote ──"
out=$(bash --norc -c '
  trap "echo prior'\''trap" DEBUG
  source '"$ASSETS"'/hook.bash
  : trigger
  echo SURVIVED
' 2>&1)
chk "prior DEBUG trap with single-quote: hook loads" 'echo "$out" | grep -q SURVIVED' '$out'

if command -v fish >/dev/null; then
  echo "── hook.fish: posterror + prompt → only one done (B10) ──"
  # Trigger a syntax error; count done OSCs emitted.
  n=$(fish --no-config -c '
    source '"$ASSETS"'/hook.fish
    function fish_prompt; __zmx_precmd; end
    emit fish_posterror
    emit fish_prompt
  ' 2>&1 | grep -ao $'\033]2718;done;' | wc -l)
  chk "B10: posterror+prompt emits exactly one done" '[ "$n" -eq 1 ]' "n=$n"
fi

echo
echo "── hook_assets: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
