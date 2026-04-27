# Shared helpers for zmyth integration tests. Source, don't execute.
# shellcheck shell=bash

# ── Binary resolution ───────────────────────────────────────────────────────
# build.zig sets $ZMYTH to the just-built binary; manual runs fall back to
# zig-out/bin/zmyth relative to the repo root (two dirs up from this file).
ZMYTH=${ZMYTH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/zig-out/bin/zmyth}
ZMX=$ZMYTH   # alias used by older scripts

[ -x "$ZMYTH" ] || { echo "FATAL: $ZMYTH not executable (build with: zig build zmyth)"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

# ── Assertion bookkeeping ───────────────────────────────────────────────────
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n" "$1"
        [ -n "${2-}" ] && printf "    got: %s\n" "$2"; }
# chk LABEL 'COND' ['DETAIL']
#   COND is eval'd; on failure DETAIL (if given) is eval-echoed for context,
#   else the condition itself is shown.
chk() {
  if eval "$2"; then ok "$1"
  elif [ $# -ge 3 ]; then bad "$1" "$(eval "echo $3" 2>&1)"
  else bad "$1" "[$2]"
  fi
}
die() { printf "\033[31mFATAL\033[0m %s\n" "$1"; exit 1; }

# ── Session helpers ─────────────────────────────────────────────────────────
nuke() { for n in "$@"; do "$ZMYTH" kill -9 "$n" >/dev/null 2>&1; done; sleep 0.1; }

# jget SESS FIELD → field value from `ls -j` for the named session (jq, so
# field-order changes in the JSON don't break callers).
jget() { "$ZMYTH" ls -j 2>/dev/null | jq -r --arg n "$1" '.[]|select(.name==$n).'"$2"; }

# wait_for SESS JQ-FILTER → poll `ls -j` until FILTER (with $n bound to SESS)
# yields a value. 5s budget @ 100ms.
wait_for() {
  local s=$1 f=$2 _i
  for _i in $(seq 1 50); do
    "$ZMYTH" ls -j 2>/dev/null | jq -e --arg n "$s" "$f" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}
# Common case: session is hooked and idle (ready for the next `send`/`run`).
wait_idle() { wait_for "$1" '.[]|select(.name==$n and .hooked and (.cmd_running|not))'; }

# read_until SESS REGEX [LINES] → poll `read -n LINES` until REGEX appears in
# scrollback. Replaces `send … ; sleep N ; read | grep` patterns where the
# marker itself is the readiness signal. 5s budget @ 100ms.
read_until() {
  local s=$1 re=$2 n=${3:-20} _i
  for _i in $(seq 1 50); do
    "$ZMYTH" read "$s" -n "$n" 2>/dev/null | grep -aqE "$re" && return 0
    sleep 0.1
  done
  return 1
}

# ── Portability shims (macOS/BSD) ───────────────────────────────────────────
# `timeout` is GNU-coreutils-only; macOS lacks it unless coreutils is brewed.
# perl is always present on macOS, so alarm+exec gives us a drop-in for the
# `timeout N cmd args...` form (no flags, integer seconds).
if ! command -v timeout >/dev/null; then
  timeout() { perl -e 'alarm shift; exec @ARGV' -- "$@"; }
fi
# `stat -c %a` is GNU; BSD stat spells it `-f %Lp`.
sock_perms() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# BSD date has no %N, so use python3 (already required by attach_test.py).
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
# `stat -c %Y` is GNU; BSD spells it `-f %m`.
mtime()  { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
