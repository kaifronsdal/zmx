if not set -q __ZMYTH_HOOK_V; and set -q TERM; and test "$TERM" != dumb
  set -g __ZMYTH_HOOK_V 1
  function __zmx_preexec --on-event fish_preexec
    printf '\033]2718;preexec;%s\007' $fish_pid
  end
  function __zmx_precmd --on-event fish_prompt
    set -l ec $status
    if set -q __ZMX_POSTERR
      set -e __ZMX_POSTERR
      return
    end
    set -l dur 0
    set -q CMD_DURATION; and set dur $CMD_DURATION
    printf '\033]2718;done;%s;%d;%d;f;%s\007' $fish_pid $ec $dur $PWD
  end
  function __zmx_posterror --on-event fish_posterror
    set -g __ZMX_POSTERR 1
    printf '\033]2718;done;%s;125;0;f;%s\007' $fish_pid $PWD
  end
end
