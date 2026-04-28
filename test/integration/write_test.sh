#!/usr/bin/env bash
# write_test.sh — comprehensive `zmyth write` coverage:
#   • round-trip correctness across bash/zsh/fish × {0, 3B, 100K, 5M} × {file, pipe}
#   • local-FS shortcut: depth-0 + absolute path → daemon writes directly (no opener in scrollback)
#   • gzip path: gunzip present → opener includes `gunzip`; compressible data is faster
#   • gzip fallback: gunzip absent (PATH stripped) → plain opener, still correct
#   • incompressible data: gzip skipped (random bytes don't shrink)
#   • abort: client killed mid-write → session recovers to prompt
set -u
cd "$(dirname "$0")"
. ./lib.sh

src=$(mktemp); dst=$(mktemp)
cleanup() { rm -f "$src" "$dst" "$dst.nogz"; rm -rf /tmp/zmyth-nogz-path; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Round-trip matrix. ZMYTH_WRITE_FORCE_PTY=1 forces the PTY path even at
# depth 0 so the encode/decode pipeline is exercised in every shell (without
# it, depth-0 writes take local-FS regardless of path syntax).
# ─────────────────────────────────────────────────────────────────────────────
echo "── round-trip: 3 shells × 4 sizes × file/pipe (PTY path) ──"
reldst="$(basename "$dst")"
for sh in bash zsh fish; do
  command -v "$sh" >/dev/null || { echo "  SKIP: $sh"; continue; }
  for sz in 0 3 102400 5242880; do
    head -c "$sz" /dev/urandom > "$src"
    for mode in file pipe; do
      rm -f "$dst"
      SHELL=$(command -v "$sh") ZMYTH_WRITE_FORCE_PTY=1 \
        "$ZMX" run "wt-$sh" -- "cd $(dirname "$dst")" >/dev/null 2>&1
      if [ "$mode" = file ]; then
        timeout 30 "$ZMX" write "wt-$sh" "$reldst" < "$src" 2>&1
      else
        cat "$src" | timeout 30 "$ZMX" write "wt-$sh" "$reldst" 2>&1
      fi
      "$ZMX" run "wt-$sh" -- true >/dev/null 2>&1
      cmp -s "$src" "$dst"
      chk "$sh ${sz}B $mode" "[ $? -eq 0 ]"
      nuke "wt-$sh"
    done
  done
done

# ─────────────────────────────────────────────────────────────────────────────
# Local-FS shortcut: absolute path at depth 0 → daemon writes directly.
# Verify by checking that NO `head -c` opener appears in the session scrollback.
# ─────────────────────────────────────────────────────────────────────────────
echo "── local-FS shortcut (absolute path, depth 0) ──"
head -c 1048576 /dev/urandom > "$src"; rm -f "$dst"
"$ZMX" run wt-local -- true >/dev/null 2>&1
t0=$(now_ms)
timeout 10 "$ZMX" write wt-local "$dst" < "$src"
t1=$(now_ms)
cmp -s "$src" "$dst"
chk "local-FS: 1MB round-trip" "[ $? -eq 0 ]"
chk "local-FS: fast (<100ms, got $((t1-t0))ms)" "[ $((t1-t0)) -lt 100 ]"
sb=$("$ZMX" read wt-local 2>/dev/null)
echo "$sb" | grep -q 'head -c'
chk "local-FS: no opener typed into shell" "[ $? -ne 0 ]"
echo "$sb" | grep -q 'zmyth: wrote'
chk "local-FS: trace marker in scrollback" "[ $? -eq 0 ]"
nuke wt-local

# Relative path at depth 0: daemon resolves against the shell's cwd (from
# the last `done` OSC) and STILL takes local-FS.
echo "── relative path (depth 0) → local-FS via lastCwd ──"
rm -f "$dst"
"$ZMX" run wt-rel -- "cd $(dirname "$dst")" >/dev/null 2>&1
timeout 10 "$ZMX" write wt-rel "$reldst" < "$src"
"$ZMX" run wt-rel -- true >/dev/null 2>&1
cmp -s "$src" "$dst"
chk "relative→local-FS: round-trip" "[ $? -eq 0 ]"
sb=$("$ZMX" read wt-rel 2>/dev/null)
echo "$sb" | grep -q 'head -c'
chk "relative→local-FS: no opener typed" "[ $? -ne 0 ]"
echo "$sb" | grep -q 'zmyth: wrote'
chk "relative→local-FS: trace marker in scrollback" "[ $? -eq 0 ]"
nuke wt-rel

# Paths needing shell expansion (~, $VAR) fall through to PTY so the SHELL
# expands them — the daemon's $HOME may be stale.
echo "── shell-expansion paths (~/, \$VAR) → PTY path ──"
rm -f "$HOME/.zmyth-wt-tilde"
"$ZMX" run wt-exp -- true >/dev/null 2>&1
printf 'tilde test' | timeout 10 "$ZMX" write wt-exp '~/.zmyth-wt-tilde'
"$ZMX" run wt-exp -- true >/dev/null 2>&1
chk "~/ path: round-trip" "[ \"\$(cat \"$HOME/.zmyth-wt-tilde\" 2>/dev/null)\" = 'tilde test' ]"
"$ZMX" read wt-exp 2>/dev/null | grep -q 'head -c'
chk "~/ path: PTY path used (opener typed)" "[ $? -eq 0 ]"
rm -f "$HOME/.zmyth-wt-tilde"
nuke wt-exp

# ─────────────────────────────────────────────────────────────────────────────
# gzip: gunzip present (it is on this box) → opener includes `gunzip`.
# Use a relative path so local-FS doesn't preempt.
# ─────────────────────────────────────────────────────────────────────────────
echo "── gzip: opener includes gunzip when available ──"
head -c 102400 /dev/zero > "$src"; rm -f "$dst"
ZMYTH_WRITE_FORCE_PTY=1 "$ZMX" run wt-gz -- "cd $(dirname "$dst")" >/dev/null 2>&1
timeout 10 "$ZMX" write wt-gz "$reldst" < "$src"
"$ZMX" run wt-gz -- true >/dev/null 2>&1
cmp -s "$src" "$dst"
chk "gzip: 100KB zeros round-trip" "[ $? -eq 0 ]"
"$ZMX" read wt-gz 2>/dev/null | grep -q 'gunzip'
chk "gzip: opener includes 'gunzip'" "[ $? -eq 0 ]"
nuke wt-gz

# Compressible vs incompressible: 5MB zeros via gzip should beat 5MB random.
echo "── gzip: compressible data is faster than incompressible ──"
ZMYTH_WRITE_FORCE_PTY=1 "$ZMX" run wt-gzp -- "cd $(dirname "$dst")" >/dev/null 2>&1
head -c 5242880 /dev/zero > "$src"; rm -f "$dst"
t0=$(now_ms); timeout 30 "$ZMX" write wt-gzp "$reldst" < "$src"; "$ZMX" run wt-gzp -- true >/dev/null; t1=$(now_ms)
zeros_ms=$((t1-t0))
cmp -s "$src" "$dst"; chk "gzip: 5MB zeros round-trip" "[ $? -eq 0 ]"
head -c 5242880 /dev/urandom > "$src"; rm -f "$dst"
t0=$(now_ms); timeout 30 "$ZMX" write wt-gzp "$reldst" < "$src"; "$ZMX" run wt-gzp -- true >/dev/null; t1=$(now_ms)
rand_ms=$((t1-t0))
cmp -s "$src" "$dst"; chk "gzip: 5MB random round-trip" "[ $? -eq 0 ]"
chk "gzip: zeros (${zeros_ms}ms) < random/2 (${rand_ms}ms)" "[ $zeros_ms -lt $((rand_ms / 2)) ]"
# Incompressible → gzip should be SKIPPED (gz_len ≥ plain_len). Check opener.
"$ZMX" read wt-gzp -n 20 2>/dev/null | tail -5 | grep -q 'gunzip'
chk "incompressible: gunzip NOT in last opener" "[ $? -ne 0 ]"
nuke wt-gzp

# ─────────────────────────────────────────────────────────────────────────────
# gzip fallback: shell with PATH stripped of gunzip → hook reports no-gz,
# daemon uses plain opener. (Symlink everything we need EXCEPT gunzip.)
# ─────────────────────────────────────────────────────────────────────────────
echo "── gzip fallback: gunzip absent → plain path ──"
nogz=/tmp/zmyth-nogz-path; rm -rf "$nogz"; mkdir -p "$nogz" "$nogz/home"
for b in bash head base64 stty cat sed; do
  ln -sf "$(command -v "$b")" "$nogz/$b"
done
head -c 102400 /dev/zero > "$src"; rm -f "$dst.nogz"
# HOME → empty dir so the user's ~/.bashrc (which expects a full PATH) is skipped.
PATH="$nogz" SHELL="$nogz/bash" HOME="$nogz/home" ZMYTH_WRITE_FORCE_PTY=1 \
  "$ZMX" run wt-nogz -- "cd $(dirname "$dst")" >/dev/null 2>&1
gz=$(jget wt-nogz has_gunzip)
chk "no-gunzip: hook reports has_gunzip=false (got '$gz')" "[ '$gz' = false ]"
timeout 10 "$ZMX" write wt-nogz "$(basename "$dst.nogz")" < "$src"
"$ZMX" run wt-nogz -- true >/dev/null 2>&1
cmp -s "$src" "$dst.nogz"
chk "no-gunzip: round-trip via plain path" "[ $? -eq 0 ]"
"$ZMX" read wt-nogz 2>/dev/null | grep -q 'gunzip'
chk "no-gunzip: opener does NOT include gunzip" "[ $? -ne 0 ]"
nuke wt-nogz

# ─────────────────────────────────────────────────────────────────────────────
# Abort: client killed mid-write → daemon ^C's, session returns to prompt.
# ─────────────────────────────────────────────────────────────────────────────
echo "── W1: bad path (parent dir missing) → body drained, session not flooded ──"
ZMYTH_WRITE_FORCE_PTY=1 "$ZMX" run wt-w1 -- true >/dev/null 2>&1
head -c 524288 /dev/urandom | timeout 15 "$ZMX" write wt-w1 '/nonexistent/dir/file' 2>/dev/null
"$ZMX" run wt-w1 -- true >/dev/null 2>&1
sb=$("$ZMX" read wt-w1 2>/dev/null)
# If head SIGPIPE'd early, leftover body lines would hit readline as commands.
nf=$(echo "$sb" | grep -cE 'command not found|No such file.*[A-Za-z0-9+/]{20}')
chk "W1: body not executed as commands (got $nf 'not found')" "[ $nf -eq 0 ]"
out=$(timeout 5 "$ZMX" run -j wt-w1 -- 'echo OK' 2>/dev/null | tail -1)
chk "W1: session not wedged after bad-path write" \
    "[ \"\$(echo '$out' | jq -r .exit_code 2>/dev/null)\" = 0 ]"
nuke wt-w1

echo "── W2: zsh ~nosuchuser → tty restored, no flood ──"
if command -v zsh >/dev/null; then
  ZMYTH_WRITE_FORCE_PTY=1 SHELL=$(command -v zsh) "$ZMX" run wt-w2 -- true >/dev/null 2>&1
  head -c 51200 /dev/zero | timeout 10 "$ZMX" write wt-w2 '~nosuchuserxyz/file' 2>/dev/null
  "$ZMX" run wt-w2 -- true >/dev/null 2>&1
  out=$(timeout 5 "$ZMX" run -j wt-w2 -- 'echo OK' 2>/dev/null | tail -1)
  chk "W2: zsh session not wedged after ~nosuchuser" \
      "[ \"\$(echo '$out' | jq -r .exit_code 2>/dev/null)\" = 0 ]"
  nuke wt-w2
fi

echo "── H2: single-quote in path → trace marker doesn't wedge session ──"
sqdst="/tmp/zmyth it's $$"; rm -f "$sqdst"
"$ZMX" run wt-sq -- true >/dev/null 2>&1
printf x | timeout 5 "$ZMX" write wt-sq "$sqdst"
chk "sq-path: file written" "[ \"\$(cat \"$sqdst\" 2>/dev/null)\" = x ]"
out=$(timeout 5 "$ZMX" run -j wt-sq -- 'echo OK' 2>/dev/null | tail -1)
chk "sq-path: session not wedged after trace" \
    "[ \"\$(echo '$out' | jq -r .exit_code 2>/dev/null)\" = 0 ]"
rm -f "$sqdst"; nuke wt-sq

echo "── H3: 0-byte PTY write doesn't hang on preexec+done same-chunk race ──"
ZMYTH_WRITE_FORCE_PTY=1 "$ZMX" run wt-z0 -- true >/dev/null 2>&1
ok=1
for i in $(seq 50); do
  timeout 5 "$ZMX" write wt-z0 '~/.zmyth-z0' </dev/null 2>/dev/null || { ok=0; break; }
  "$ZMX" run wt-z0 -- true >/dev/null 2>&1
done
chk "0-byte PTY write never hangs (50 iters)" "[ $ok -eq 1 ]"
rm -f ~/.zmyth-z0; nuke wt-z0

echo "── M1: \$VAR in path is literal (not shell-expanded) ──"
"$ZMX" run wt-dol -- "cd /tmp" >/dev/null 2>&1
rm -f '/tmp/$TMPDIR-zmyth'
printf 'x' | timeout 10 "$ZMX" write wt-dol '$TMPDIR-zmyth' 2>&1
"$ZMX" run wt-dol -- true >/dev/null 2>&1
chk "\$VAR path: literal file created" "[ -f '/tmp/\$TMPDIR-zmyth' ]"
rm -f '/tmp/$TMPDIR-zmyth'; nuke wt-dol

echo "── M2: relative write rejected while a command is running (stale cwd) ──"
old=$(mktemp -d); new=$(mktemp -d)
"$ZMX" run wt-stale -- "cd $old" >/dev/null 2>&1
"$ZMX" run -d wt-stale -- "cd $new && sleep 2" >/dev/null 2>&1
sleep 0.3
printf 'x' | timeout 5 "$ZMX" write wt-stale 'rel.txt' 2>/dev/null; wec=$?
"$ZMX" wait wt-stale >/dev/null 2>&1
chk "stale-cwd: write during running cmd rejected" "[ $wec -ne 0 ]"
chk "stale-cwd: file NOT in old dir" "[ ! -f '$old/rel.txt' ]"
nuke wt-stale; rm -rf "$old" "$new"

echo "── abort: client dies mid-write → session recovers ──"
head -c 10485760 /dev/urandom > "$src"; rm -f "$dst"
ZMYTH_WRITE_FORCE_PTY=1 "$ZMX" run wt-abort -- "cd $(dirname "$dst")" >/dev/null 2>&1
# `timeout 0.2` SIGTERMs the write client itself (not a wrapper subshell).
timeout 0.2 "$ZMX" write wt-abort "$reldst" < "$src" 2>/dev/null
# Session should recover: a follow-up run completes.
out=$(timeout 10 "$ZMX" run -j wt-abort -- 'echo RECOVERED' 2>/dev/null | tail -1)
chk "abort: session recovers (run completes after kill)" \
    "[ \"\$(echo '$out' | jq -r .exit_code 2>/dev/null)\" = 0 ]"
nuke wt-abort

echo
echo "── write_test: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
