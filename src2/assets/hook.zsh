if [[ -z "${__ZMX_HOOKED:-}" ]]; then
  __ZMX_HOOKED=1
  zmodload zsh/datetime 2>/dev/null
  typeset -g __ZMX_NONCE='__ZMX_NONCE__'
  typeset -g __ZMX_RAN=0
  typeset -g __ZMX_T0=
  __zmx_preexec() {
    __ZMX_RAN=1
    __ZMX_T0=${EPOCHREALTIME:-}
    printf '\033]2718;preexec;%s\007' "$__ZMX_NONCE"
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
    printf '\033]2718;done;%s;%d;%d;%s\007' "$__ZMX_NONCE" "$__zmx_ec" "$dur" "$PWD"
  }
  autoload -Uz add-zsh-hook 2>/dev/null
  if typeset -f add-zsh-hook >/dev/null; then
    add-zsh-hook preexec __zmx_preexec
    add-zsh-hook precmd __zmx_precmd
  else
    preexec_functions+=(__zmx_preexec)
    precmd_functions+=(__zmx_precmd)
  fi
  typeset -ga zle_bracketed_paste=($'\e[?2004h' $'\e[?2004l')
  bindkey -M vicmd '^[[200~' bracketed-paste 2>/dev/null
  bindkey -M vicmd '^U' kill-whole-line 2>/dev/null
fi
