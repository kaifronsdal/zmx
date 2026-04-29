#!/usr/bin/env bash
# Prompt-engine integration matrix for zmyth.
#
# Validates that the OSC 2718 hook (announce -> inject -> precmd) survives
# real prompt engines (starship, oh-my-posh) which themselves seize
# PROMPT_COMMAND / precmd_functions / fish_prompt. The PoC under
# repros/poc-hooks/ proved the design; this drives the actual binary.
#
# For each (shell ∈ bash zsh fish) × (engine ∈ none starship oh-my-posh):
#   - temp $HOME with an rc that initialises the engine
#   - `zmyth run -j` a command with a known nonzero exit code
#   - assert ec is propagated and via=osc_done (i.e. hook survived the engine)

set -uo pipefail

source "$(dirname "$0")/lib.sh"

export ZMYTH_DIR=$(mktemp -d /tmp/zmyth-pe-itest-XXXXXX)
export XDG_STATE_HOME="$ZMYTH_DIR/state"
unset ZMYTH_SESSION ZDOTDIR

trap '"$ZMX" kill -9 "*" 2>/dev/null; pkill -9 -f "$ZMYTH_DIR" 2>/dev/null; rm -rf "$ZMYTH_DIR"' EXIT

# ── locate / install prompt engines ─────────────────────────────────────────
# Prefer PATH; fall back to /tmp/zmyth-pe (and /tmp/bin where the PoC put
# them). Install only if missing — skip the cell otherwise.
PE_BIN=/tmp/zmyth-pe
mkdir -p "$PE_BIN"
export PATH="$PE_BIN:/tmp/bin:$PATH"

ensure_starship() {
  command -v starship >/dev/null && return 0
  echo "# starship not found; installing to $PE_BIN ..." >&2
  curl -sS https://starship.rs/install.sh 2>/dev/null \
    | sh -s -- -y -b "$PE_BIN" >/dev/null 2>&1
  command -v starship >/dev/null
}

ensure_omp() {
  command -v oh-my-posh >/dev/null && return 0
  echo "# oh-my-posh not found; installing to $PE_BIN ..." >&2
  local arch; arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
  curl -fsSL -o "$PE_BIN/oh-my-posh" \
    "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-$arch" 2>/dev/null \
    && chmod +x "$PE_BIN/oh-my-posh"
  command -v oh-my-posh >/dev/null
}

declare -A HAVE
HAVE[none]=1
ensure_starship && HAVE[starship]=1 || echo "SKIP engine: starship (install failed / unavailable)"
ensure_omp      && HAVE[omp]=1      || echo "SKIP engine: oh-my-posh (install failed / unavailable)"

# ── bookkeeping ─────────────────────────────────────────────────────────────
SKIP=0
declare -A CELL   # CELL[shell,engine] = PASS|FAIL|SKIP|<detail>

# Write the engine's init line for $shell into the rc file zmyth's shim will
# source: ~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish (see src/spawn.zig).
write_rc() {
  local home=$1 shell=$2 engine=$3 init=""
  case "$engine" in
    none)     init=": # no engine" ;;
    starship) case "$shell" in
                fish) init="starship init fish | source" ;;
                *)    init='eval "$(starship init '"$shell"')"' ;;
              esac ;;
    omp)      case "$shell" in
                fish) init="oh-my-posh init fish | source" ;;
                *)    init='eval "$(oh-my-posh init '"$shell"')"' ;;
              esac ;;
  esac
  case "$shell" in
    bash) printf '%s\n' "$init" >"$home/.bashrc" ;;
    zsh)  printf '%s\n' "$init" >"$home/.zshrc" ;;
    fish) mkdir -p "$home/.config/fish"
          printf '%s\n' "$init" >"$home/.config/fish/config.fish" ;;
  esac
}

# ── matrix ──────────────────────────────────────────────────────────────────
SHELLS=(bash zsh fish)
ENGINES=(none starship omp)

for shell in "${SHELLS[@]}"; do
  if ! command -v "$shell" >/dev/null; then
    echo "SKIP shell: $shell (not installed)"
    for e in "${ENGINES[@]}"; do CELL[$shell,$e]="SKIP"; done
    SKIP=$((SKIP+${#ENGINES[@]}))
    continue
  fi
  shpath=$(command -v "$shell")

  for engine in "${ENGINES[@]}"; do
    label="$shell+$engine"
    if [ -z "${HAVE[$engine]:-}" ]; then
      CELL[$shell,$engine]="SKIP"
      SKIP=$((SKIP+1))
      echo "SKIP: $label (engine unavailable)"
      continue
    fi

    sess="pe-$shell-$engine"
    home=$(mktemp -d "$ZMYTH_DIR/home-$shell-$engine-XXXX")
    write_rc "$home" "$shell" "$engine"

    # Isolate: HOME + XDG_CONFIG_HOME so the engine can't read the real
    # user's config; XDG_CACHE_HOME so omp/starship cache writes stay local.
    zrun() {
      HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" \
      XDG_CACHE_HOME="$home/.cache" \
      SHELL="$shpath" \
      timeout 30 "$ZMX" run -j "$sess" -- "$@" 2>&1 | tr -d '\0'
    }

    # First run: cold session (engine init + zmyth hook injection).
    out=$(zrun 'sh -c "exit 17"')
    json=$(tail -n1 <<<"$out")
    ec1=$(jq -r '.exit_code // "?"' <<<"$json" 2>/dev/null)
    via1=$(jq -r '.via // "?"'      <<<"$json" 2>/dev/null)

    # Second run: warm session. Catches engines that re-clobber
    # PROMPT_COMMAND / precmd on every prompt cycle.
    out2=$(zrun 'sh -c "exit 17"')
    json2=$(tail -n1 <<<"$out2")
    ec2=$(jq -r '.exit_code // "?"' <<<"$json2" 2>/dev/null)
    via2=$(jq -r '.via // "?"'      <<<"$json2" 2>/dev/null)

    if [ "$ec1" = 17 ] && [ "$via1" = osc_done ] && \
       [ "$ec2" = 17 ] && [ "$via2" = osc_done ]; then
      ok "$label  ec=17 via=osc_done (cold+warm)"
      CELL[$shell,$engine]="PASS"
    else
      bad "$label  cold[ec=$ec1 via=$via1] warm[ec=$ec2 via=$via2]"
      CELL[$shell,$engine]="FAIL"
      echo "  ── tail($sess) ──" >&2
      sed 's/^/  │ /' <<<"$out2" | tail -n 8 >&2
    fi

    nuke "$sess"
    rm -rf "$home"
  done
done

# ── matrix table ────────────────────────────────────────────────────────────
echo
echo "─── prompt-engine matrix ──────────────────────"
printf '%-6s' ""
for e in "${ENGINES[@]}"; do printf '%-12s' "$e"; done
echo
for s in "${SHELLS[@]}"; do
  printf '%-6s' "$s"
  for e in "${ENGINES[@]}"; do printf '%-12s' "${CELL[$s,$e]:--}"; done
  echo
done
echo "───────────────────────────────────────────────"
echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL>0))
