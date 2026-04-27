#!/usr/bin/env bash
# Repro: with no attach client, an app's terminal query (DSR \e[6n) goes
# unanswered. The app waits on its read timeout. After the write_pty fix,
# ghostty's shadow terminal answers and the read returns immediately.
set -u

source "$(dirname "$0")/lib.sh"

ROOT=$(mktemp -d /tmp/zmyth_hq.XXXXXX)
export HOME="$ROOT/home" ZMYTH_DIR="$ROOT/run"
mkdir -p "$HOME" "$ZMYTH_DIR"

cleanup() { "$ZMYTH" kill hq -9 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

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

# ─── Stalled attach client must not suppress headless replies ────────────────
# An attach client whose terminal is catatonic (half-open SSH) won't relay the
# query to a real terminal. The daemon should treat it as "not really there"
# for write_pty purposes, same as it does for leader election.
echo "── DSR with a stalled (non-draining) attach client ──"
out=$(python3 - "$ZMYTH" "$ROOT" "$PROBE" <<'PY'
import os, sys, pty, fcntl, struct, termios, time, subprocess, re
ZMYTH, ROOT, PROBE = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ, ZMYTH_DIR=ROOT+"/run", HOME=ROOT+"/home", SHELL="/bin/bash")
env.pop("ZMYTH_SESSION", None)
# Attach via a pty we NEVER read from. Master stays open in THIS process for
# the duration so the attach client doesn't get HUP-detached.
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
p = subprocess.Popen([ZMYTH, "attach", "hq2"], stdin=s, stdout=s, stderr=s,
                     env=env, start_new_session=True)
os.close(s)
time.sleep(1.0)
# Generate enough output that the daemon's write backlog to this client crosses
# leader_demote_backlog (256KiB) but stays under the 4MiB drop limit.
subprocess.run([ZMYTH, "run", "hq2", "--", "head -c 400000 /dev/zero | tr '\\0' x"],
               env=env, capture_output=True, timeout=15)
time.sleep(0.3)
# Confirm the attach client is still alive (master held open here).
assert p.poll() is None, "attach client exited early — test setup invalid"
# Probe: stalled client is "attached" but can't relay; ghostty should answer.
r = subprocess.run([ZMYTH, "run", "hq2", "--", PROBE],
                   env=env, capture_output=True, text=True, timeout=10)
m_ = re.search(r"(GOT_REPLY|NO_REPLY) (\d+)", r.stdout)
print(m_.group(0) if m_ else "NO_OUTPUT")
p.kill(); p.wait()
PY
)
echo "  result: ${out}ms"
case "$out" in
  GOT_REPLY*) ok "DSR answered despite stalled attach client (${out#GOT_REPLY }ms)" ;;
  NO_REPLY*)  bad "stalled attach client suppressed ghostty reply" "${out}ms" ;;
  *)          bad "probe produced no recognizable output" "$out" ;;
esac
"$ZMYTH" kill hq2 -9 2>/dev/null

echo
echo "── headless_query: $PASS passed, $FAIL failed ──"
[ $FAIL -eq 0 ]
