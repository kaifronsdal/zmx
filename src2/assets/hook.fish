if not set -q __ZMX_HOOKED
  set -g __ZMX_HOOKED 1
  set -g __ZMX_NONCE '__ZMX_NONCE__'
  function __zmx_preexec --on-event fish_preexec
    printf '\033]2718;preexec;%s\007' $__ZMX_NONCE
  end
  function __zmx_precmd --on-event fish_prompt
    set -l ec $status
    set -l dur 0
    set -q CMD_DURATION; and set dur $CMD_DURATION
    printf '\033]2718;done;%s;%d;%d;%s\007' $__ZMX_NONCE $ec $dur $PWD
  end
  function __zmx_posterror --on-event fish_posterror
    printf '\033]2718;done;%s;125;0;%s\007' $__ZMX_NONCE $PWD
  end
end
