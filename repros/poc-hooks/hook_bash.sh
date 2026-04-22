# zmx shell-integration hook for bash.
# bash sets $? on syntax errors at the prompt (unlike zsh), so PROMPT_COMMAND
# alone is sufficient. Prepend so we capture $? before other hooks.
if [[ -z "${__ZMX_HOOKED:-}" ]]; then
  __ZMX_HOOKED=1
  __zmx_precmd() {
    local __zmx_ec=$?
    printf '\033]2718;done;%d;%s\007' "$__zmx_ec" "$PWD"
    return $__zmx_ec
  }
  if [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="__zmx_precmd;${PROMPT_COMMAND}"
  else
    PROMPT_COMMAND="__zmx_precmd"
  fi
fi
