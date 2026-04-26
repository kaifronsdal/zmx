#!/usr/bin/env bash
# Repro: with no attach client, an app's terminal query (DSR \e[6n) goes
# unanswered. The app waits on its read timeout. After the write_pty fix,
# ghostty's shadow terminal answers and the read returns immediately.
set -u

ZMYTH=${ZMYTH:-./zig-out/bin/zmyth}
ROOT=$(mktemp -d /tmp/zmyth_hq.XXXXXX)
export HOME="$ROOT/home" ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n    got: %s\n" "$1" "$2"; }

cleanup() { "$ZMYTH" kill hq -9 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT
[ -x "$ZMYTH" ] || { echo "FATAL: $ZMYTH not found"; exit 1; }

# A tiny prober: emit \e[6n to /dev/tty, read the reply from /dev/tty with a
# 1.5s timeout, report whether a reply arrived and how long it took.
PROBE="$ROOT/probe.sh"
OUT="$ROOT/out.txt"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
exec 3<>/dev/tty
t0=$(date +%s%N)
printf '\033[6n' >&3
IFS= read -r -t 1.5 -d R resp <&3
rc=$?
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ $rc -eq 0 ]; then echo "GOT_REPLY ${ms}"; else echo "NO_REPLY ${ms}"; fi
SH
chmod +x "$PROBE"

echo "── headless DSR query (no attach client) ──"
# Create session via run (no attach). The probe runs with only the `run`
# client connected — which doesn't pump stdin, so without write_pty the
# query has no responder.
SHELL=$(command -v bash) "$ZMYTH" run hq -- "$PROBE" > "$OUT" 2>&1
out=$(grep -ao 'GOT_REPLY [0-9]*\|NO_REPLY [0-9]*' "$OUT" | tail -1)
echo "  result: ${out}ms"

case "$out" in
  GOT_REPLY*)
    ms=${out#GOT_REPLY }
    if [ "$ms" -lt 500 ]; then ok "DSR answered in ${ms}ms (<500ms)"
    else bad "DSR answered but slow" "${ms}ms"; fi ;;
  NO_REPLY*)
    bad "DSR query timed out — no responder when headless" "${out}ms" ;;
  *)
    bad "probe produced no recognizable output" "$(cat -v "$OUT" | tail -5)" ;;
esac

"$ZMYTH" kill hq -9 2>/dev/null
echo
echo "── headless_query: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
