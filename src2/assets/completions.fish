function __zmyth_sessions
    zmyth ls -q 2>/dev/null
end

function __zmyth_verb
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __zmyth_after
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2; and contains -- $cmd[2] $argv
end

complete -c zmyth -f

# Verbs
complete -c zmyth -n '__zmyth_verb' -a 'attach' -d 'Attach to a session (auto-create)'
complete -c zmyth -n '__zmyth_verb' -a 'run'    -d 'Run a command in a session'
complete -c zmyth -n '__zmyth_verb' -a 'send'   -d 'Send raw input to a session PTY'
complete -c zmyth -n '__zmyth_verb' -a 'read'   -d 'Read session output / scrollback'
complete -c zmyth -n '__zmyth_verb' -a 'ls'     -d 'List sessions'
complete -c zmyth -n '__zmyth_verb' -a 'wait'   -d 'Wait for command(s) to finish'
complete -c zmyth -n '__zmyth_verb' -a 'kill'   -d 'Kill session(s)'
complete -c zmyth -n '__zmyth_verb' -a 'hook'   -d 'Install shell hook into nested shell'
complete -c zmyth -n '__zmyth_verb' -a 'detach' -d 'Detach client(s) from a session'
complete -c zmyth -n '__zmyth_verb' -a 'version' -d 'Show version'
complete -c zmyth -n '__zmyth_verb' -a 'help'   -d 'Show help'
complete -c zmyth -n '__zmyth_verb' -a 'completions' -d 'Print shell completion script'

# Session-name positionals
complete -c zmyth -n '__zmyth_after attach run send read wait kill hook detach' -a '(__zmyth_sessions)' -d 'Session'

# completions <shell>
complete -c zmyth -n '__zmyth_after completions' -a 'bash zsh fish' -d 'Shell'

# Per-verb flags
complete -c zmyth -n '__zmyth_after run'  -s d -d 'Detach: do not wait for exit'
complete -c zmyth -n '__zmyth_after run'  -s j -d 'JSON result line'
complete -c zmyth -n '__zmyth_after read' -s f -d 'Follow'
complete -c zmyth -n '__zmyth_after read' -s s -d 'Screen snapshot'
complete -c zmyth -n '__zmyth_after read' -s n -r -d 'Tail N lines'
complete -c zmyth -n '__zmyth_after ls'   -s j -d 'JSON output'
complete -c zmyth -n '__zmyth_after ls'   -s q -d 'Names only'
complete -c zmyth -n '__zmyth_after wait' -s j -d 'JSON output'
complete -c zmyth -n '__zmyth_after kill' -s 9 -d 'SIGKILL'
