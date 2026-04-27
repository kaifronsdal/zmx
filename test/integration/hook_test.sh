#!/usr/bin/env bash
# `zmyth hook <sess>` end-to-end: nested-shell install, idempotency, error paths.
# Uses an isolated HOME so the real ~/.bashrc / ~/.zshrc are never touched.
set -u

source "$(dirname "$0")/lib.sh"

ROOT=$(mktemp -d /tmp/zmyth_hook.XXXXXX)
cleanup() {
  for s in hkbash hkzsh hkfish hkerr hkrt; do "$ZMYTH" kill "$s" -9 2>/dev/null; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# Isolated HOME + runtime dir. SHELL=bash so the *outer* zmyth shell is bash;
# the *inner* shell varies per test case.
export HOME="$ROOT/home"
export ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"
: > "$HOME/.bashrc"
: > "$HOME/.zshrc"

# ─── case 1: nested bash ──────────────────────────────────────────────────
echo "── nested bash ──"
S=hkbash
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer session never hooked"

# Enter a nested bash that does NOT source any rc (so __ZMYTH_HOOK_V is unset
# in the inner shell, simulating a remote box). Use --norc so the outer hook's
# inject doesn't leak in via inherited env / rc.
"$ZMYTH" send "$S" $'exec bash --norc -i\n' >/dev/null
sleep 0.5   # no readiness signal: inner shell is unhooked, daemon can't tell

# Precondition: inner shell is NOT hooked.
"$ZMYTH" send "$S" $'echo PRE:$__ZMYTH_HOOK_V:\n' >/dev/null
read_until "$S" '^PRE:' || die "PRE marker never appeared"
pre=$("$ZMYTH" read "$S" -n 5 | grep -a "^PRE:" | tail -1)
chk "inner shell starts unhooked" '[ "$pre" = "PRE::" ]' '$pre'

# Install.
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "hook exits 0" '[ $rc -eq 0 ]' '$rc: $out'
chk "hook reports installed" 'echo "$out" | grep -q "installed.*hook.bash"' '$out'

chk "hook file written" '[ -f "$HOME/.config/zmyth/hook.bash" ]' '$(ls -la $HOME/.config/zmyth 2>&1)'
chk "hook file matches asset byte-for-byte" \
    'cmp -s "$HOME/.config/zmyth/hook.bash" src2/assets/hook.bash' \
    '$(diff $HOME/.config/zmyth/hook.bash src2/assets/hook.bash 2>&1 | head -5)'
chk ".bashrc has source line" 'grep -q "zmyth/hook.bash" "$HOME/.bashrc"' '$(cat $HOME/.bashrc)'
chk ".bashrc line count == 1" '[ "$(grep -c zmyth $HOME/.bashrc)" -eq 1 ]' '$(cat $HOME/.bashrc)'

# Hook is now active in the inner shell.
"$ZMYTH" send "$S" $'echo POST:$__ZMYTH_HOOK_V:\n' >/dev/null
read_until "$S" '^POST:' || die "POST marker never appeared"
post=$("$ZMYTH" read "$S" -n 5 | grep -a "^POST:" | tail -1)
chk "inner shell now has __ZMYTH_HOOK_V=1" '[ "$post" = "POST:1:" ]' '$post'

# Body did NOT leak into scrollback. The OUTER local-spawn inject is visible
# (twice: kernel-echo + readline-echo — pre-existing, not under test here),
# so scope the check to the inner shell's region: everything after the install
# line. Scrollback is line-wrapped at 80 cols, so strip newlines first.
sb=$("$ZMYTH" read "$S" | tr -d '\n')
chk "install line visible in scrollback" \
    'printf "%s" "$sb" | grep -q "stty -echo; head -c "' '(scrollback elided)'
inner=${sb##*stty -echo; head -c }
chk "hook body not in inner-shell scrollback" \
    '! printf "%s" "$inner" | grep -q "__zmx_preexec()"' \
    '$(printf "%s" "$inner" | head -c 200)'

# Idempotent: second invocation writes nothing.
mtime_before=$(mtime "$HOME/.config/zmyth/hook.bash")
sleep 1.1   # mtime granularity (1s on ext4/APFS); not a readiness wait
out2=$("$ZMYTH" hook "$S" 2>&1); rc2=$?
chk "second hook exits 0" '[ $rc2 -eq 0 ]' '$rc2: $out2'
chk "second hook says already-hooked" 'echo "$out2" | grep -q "already hooked"' '$out2'
chk ".bashrc still 1 line" '[ "$(grep -c zmyth $HOME/.bashrc)" -eq 1 ]' '$(cat $HOME/.bashrc)'
mtime_after=$(mtime "$HOME/.config/zmyth/hook.bash")
chk "hook file not rewritten" '[ "$mtime_before" = "$mtime_after" ]' '$mtime_before vs $mtime_after'

nuke "$S"

# ─── case 2: nested zsh (if available) ────────────────────────────────────
if command -v zsh >/dev/null; then
  echo "── nested zsh ──"
  S=hkzsh
  SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
  wait_idle "$S" || die "outer session never hooked"
  "$ZMYTH" send "$S" $'exec zsh -f -i\n' >/dev/null
  sleep 0.5   # no readiness signal: inner zsh is unhooked
  out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
  chk "zsh: hook exits 0" '[ $rc -eq 0 ]' '$rc: $out'
  chk "zsh: hook file written" '[ -f "$HOME/.config/zmyth/hook.zsh" ]' ''
  chk "zsh: matches asset" 'cmp -s "$HOME/.config/zmyth/hook.zsh" src2/assets/hook.zsh' ''
  chk "zsh: .zshrc has source line" 'grep -q "zmyth/hook.zsh" "$HOME/.zshrc"' '$(cat $HOME/.zshrc)'
  nuke "$S"
fi

# ─── case 3: nested fish (if available) ───────────────────────────────────
if command -v fish >/dev/null; then
  echo "── nested fish ──"
  S=hkfish
  SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
  wait_idle "$S" || die "outer session never hooked"
  "$ZMYTH" send "$S" $'exec fish --no-config -i\n' >/dev/null
  sleep 0.7   # no readiness signal: inner fish is unhooked; fish startup is slow
  out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
  chk "fish: hook exits 0" '[ $rc -eq 0 ]' '$rc: $out'
  chk "fish: hook file written" '[ -f "$HOME/.config/zmyth/hook.fish" ]' ''
  chk "fish: matches asset" 'cmp -s "$HOME/.config/zmyth/hook.fish" src2/assets/hook.fish' ''
  chk "fish: conf.d/zmyth.fish written" '[ -f "$HOME/.config/fish/conf.d/zmyth.fish" ]' ''
  nuke "$S"
fi

# ─── case 4: red-team repros ──────────────────────────────────────────────
echo "── red-team repros ──"

# H1: probe survives `set -u` in target bash
S=hkrt; SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
"$ZMYTH" send "$S" $'exec bash --norc -i\n' >/dev/null; sleep 0.4   # unhooked inner
"$ZMYTH" send "$S" $'set -u\n' >/dev/null; sleep 0.2   # no observable side-effect to poll
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "H1: set -u bash → hook succeeds" '[ $rc -eq 0 ]' '$rc: $out'
nuke "$S"

# H2: zsh with ZDOTDIR — append goes to $ZDOTDIR/.zshrc not ~/.zshrc
if command -v zsh >/dev/null; then
  rm -rf "$HOME/zd"; mkdir -p "$HOME/zd"; : > "$HOME/zd/.zshrc"; : > "$HOME/.zshrc"
  S=hkrt; SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
  wait_idle "$S" || die "outer never hooked"
  "$ZMYTH" send "$S" $'exec env ZDOTDIR=$HOME/zd zsh -f -i\n' >/dev/null; sleep 0.5   # unhooked inner
  rm -f "$HOME/.config/zmyth/hook.zsh"
  "$ZMYTH" hook "$S" >/dev/null 2>&1
  chk "H2: ZDOTDIR/.zshrc gets the line" 'grep -q zmyth/hook "$HOME/zd/.zshrc"' \
      '$(cat $HOME/zd/.zshrc 2>&1)'
  chk "H2: ~/.zshrc untouched" '! grep -q zmyth/hook "$HOME/.zshrc"' '$(cat $HOME/.zshrc)'
  nuke "$S"
fi

# H4: noclobber doesn't block overwrite
S=hkrt; SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
"$ZMYTH" send "$S" $'exec bash --norc -i\n' >/dev/null; sleep 0.4   # unhooked inner
"$ZMYTH" send "$S" $'set -o noclobber\n' >/dev/null; sleep 0.2   # no observable side-effect to poll
mkdir -p "$HOME/.config/zmyth"; echo "STALE" > "$HOME/.config/zmyth/hook.bash"
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "H4: noclobber → hook succeeds" '[ $rc -eq 0 ]' '$rc: $out'
chk "H4: hook file overwritten (not STALE)" \
    '! grep -q STALE "$HOME/.config/zmyth/hook.bash"' \
    '$(head -1 $HOME/.config/zmyth/hook.bash)'
nuke "$S"

# M4/file-existence: hook file already exists → rc NOT touched again, even
# when the rc line has been moved elsewhere (so a grep would miss it).
rm -f "$HOME/.bashrc" "$HOME/.config/zmyth/hook.bash"; : > "$HOME/.bashrc"
S=hkrt; SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer never hooked"
"$ZMYTH" send "$S" $'exec bash --norc -i\n' >/dev/null; sleep 0.4   # unhooked inner
"$ZMYTH" hook "$S" >/dev/null 2>&1
chk "H3: appended rc line is [ -f ] guarded" \
    'grep -q "\[ -f .*hook.bash \] && \." "$HOME/.bashrc"' '$(cat $HOME/.bashrc)'
# Simulate: user moved the line to .bash_profile (blank .bashrc).
: > "$HOME/.bashrc"
"$ZMYTH" send "$S" $'exec bash --norc -i\n' >/dev/null; sleep 0.4   # unhooked inner
"$ZMYTH" hook "$S" >/dev/null 2>&1
chk "M4: hook file exists → blank rc stays blank" '[ ! -s "$HOME/.bashrc" ]' \
    '$(cat $HOME/.bashrc)'
nuke "$S"

# M5: hook is inert under TERM=dumb
out=$(env TERM=dumb bash --norc -c '. src2/assets/hook.bash; echo "v=$__ZMYTH_HOOK_V"' 2>&1)
chk "M5: TERM=dumb → hook inert (var unset)" 'echo "$out" | grep -q "^v=$"' '$out'
out=$(env TERM=xterm-256color bash --norc -c '. src2/assets/hook.bash; echo "v=$__ZMYTH_HOOK_V"' 2>&1)
chk "M5: TERM=xterm → hook active" 'echo "$out" | grep -q "^v=1$"' '$out'

# ─── case 5: error — not at a shell prompt (python REPL) ──────────────────
echo "── error: not a shell ──"
S=hkerr
SHELL=$(command -v bash) "$ZMYTH" run "$S" -- true >/dev/null 2>&1
wait_idle "$S" || die "outer session never hooked"
"$ZMYTH" send "$S" $'exec python3 -q\n' >/dev/null
read_until "$S" '^>>>' || sleep 0.5   # python prompt; fall back if -q hides it
out=$("$ZMYTH" hook "$S" 2>&1); rc=$?
chk "non-shell: hook exits 1" '[ $rc -eq 1 ]' '$rc: $out'
chk "non-shell: error mentions probe" 'echo "$out" | grep -qi "probe"' '$out'
nuke "$S"

# ─── summary ──────────────────────────────────────────────────────────────
echo
echo "── hook_test: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
