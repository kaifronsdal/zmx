if [[ -z "${__ZMYTH_HOOK_V:-}" && "${TERM-}" != dumb && -n "${TERM-}" && "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
  __ZMYTH_HOOK_V=1
  __ZMX_T0=
  __ZMX_AT_PROMPT=
  __ZMX_IN_PC=
  __zmx_save_ec() { __ZMX_EC=$?; __ZMX_IN_PC=1; return $__ZMX_EC; }
  __zmx_preexec() {
    [[ -n "${COMP_LINE:-}" ]] && return
    [[ -n "$__ZMX_IN_PC" ]] && return
    [[ "$BASH_COMMAND" == __zmx_* ]] && return
    [[ -z "$__ZMX_AT_PROMPT" ]] && return
    __ZMX_AT_PROMPT=
    __ZMX_T0=${EPOCHREALTIME:-}
    printf '\033]2718;preexec;%s\007' "$$"
  }
  __zmx_precmd() {
    local dur=0
    if [[ -n "$__ZMX_T0" ]]; then
      local t1=${EPOCHREALTIME:-}
      if [[ -n "$t1" ]]; then
        local s0=${__ZMX_T0%[.,]*} u0=${__ZMX_T0#*[.,]}000000
        local s1=${t1%[.,]*} u1=${t1#*[.,]}000000
        dur=$(( (10#$s1 - 10#$s0) * 1000 + (10#${u1:0:6} - 10#${u0:0:6}) / 1000 ))
        (( dur < 0 )) && dur=0
      fi
    fi
    __ZMX_T0=
    __ZMX_IN_PC=
    printf '\033]2718;done;%s;%d;%d;b;%s\007' "$$" "${__ZMX_EC:-$?}" "$dur" "$PWD"
    __ZMX_AT_PROMPT=1
    return $__ZMX_EC
  }
  __ZMX_PRIOR_DEBUG=$(trap -p DEBUG | sed -n "s/^trap -- '\(.*\)' DEBUG$/\1/p")
  trap '__zmx_preexec; '"${__ZMX_PRIOR_DEBUG:-:}" DEBUG
  if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == 'declare -a'* ]]; then
    PROMPT_COMMAND=(__zmx_save_ec "${PROMPT_COMMAND[@]}" __zmx_precmd)
  else
    PROMPT_COMMAND="__zmx_save_ec;${PROMPT_COMMAND:+${PROMPT_COMMAND%;};}__zmx_precmd"
  fi
  bind 'set enable-bracketed-paste on' 2>/dev/null
  bind -m vi-command '"\e[200~": bracketed-paste-begin' 2>/dev/null
  bind -m vi-command '"\C-u": unix-line-discard' 2>/dev/null
fi
