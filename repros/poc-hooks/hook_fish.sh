# zmx shell-integration hook for fish.
# fish_posterror covers the case where the reader rejects the line with a
# syntax error: fish_prompt does NOT fire (#8832) but fish_posterror does.
# We also clear the commandline buffer so the bad input doesn't poison the
# next zmx run.
if not set -q __ZMX_HOOKED
  set -g __ZMX_HOOKED 1
  function __zmx_precmd --on-event fish_prompt
    printf '\033]2718;done;%d;%s\007' $status $PWD
  end
  function __zmx_posterror --on-event fish_posterror
    printf '\033]2718;done;125;%s\007' $PWD
  end
end
