if [[ -z "${__ZMYTH_HOOK_V:-}" && "${TERM-}" != dumb && -n "${TERM-}" ]]; then
  typeset -g __ZMYTH_HOOK_V=2
  typeset -g __ZMX_CAP=z; command -v gunzip >/dev/null 2>&1 && __ZMX_CAP=zg
  zmodload zsh/datetime 2>/dev/null
  typeset -g __ZMX_RAN=0
  typeset -g __ZMX_T0=
  __zmx_preexec() {
    __ZMX_RAN=1
    __ZMX_T0=${EPOCHREALTIME:-}
    builtin printf '\033]2718;preexec;%s\007' "$$"
  }
  __zmx_precmd() {
    local __zmx_ec=$?
    local dur=0
    if (( ! __ZMX_RAN )); then __zmx_ec=125; fi
    if [[ -n "$__ZMX_T0" && -n "${EPOCHREALTIME:-}" ]]; then
      local df=$(( (EPOCHREALTIME - __ZMX_T0) * 1000 ))
      dur=${df%.*}
      (( dur < 0 )) && dur=0
    fi
    __ZMX_RAN=0
    __ZMX_T0=
    builtin printf '\033]2718;done;%s;%d;%d;%s;%s\007' "$$" "$__zmx_ec" "$dur" "$__ZMX_CAP" "$PWD"
  }
  typeset -ga preexec_functions precmd_functions
  preexec_functions+=(__zmx_preexec)
  precmd_functions+=(__zmx_precmd)
  typeset -ga zle_bracketed_paste=($'\e[?2004h' $'\e[?2004l')
  bindkey -M vicmd '^[[200~' bracketed-paste 2>/dev/null
  bindkey -M vicmd '^U' kill-whole-line 2>/dev/null
fi
