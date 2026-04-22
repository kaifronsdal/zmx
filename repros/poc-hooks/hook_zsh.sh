# zmx shell-integration hook for zsh.
# preexec/precmd pairing distinguishes "command ran, $?=N" from
# "zle rejected the line (syntax error / Ctrl-C), $? is stale".
if [[ -z "${__ZMX_HOOKED:-}" ]]; then
  __ZMX_HOOKED=1
  typeset -g __ZMX_RAN=0
  __zmx_preexec() { __ZMX_RAN=1; }
  __zmx_precmd() {
    local __zmx_ec=$?
    if (( ! __ZMX_RAN )); then __zmx_ec=125; fi
    __ZMX_RAN=0
    printf '\033]2718;done;%d;%s\007' "$__zmx_ec" "$PWD"
  }
  autoload -Uz add-zsh-hook 2>/dev/null
  if typeset -f add-zsh-hook >/dev/null; then
    add-zsh-hook preexec __zmx_preexec
    add-zsh-hook precmd __zmx_precmd
  else
    preexec_functions+=(__zmx_preexec)
    precmd_functions+=(__zmx_precmd)
  fi
fi
