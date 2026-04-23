#compdef zmyth

_zmyth_sessions() {
    local -a sessions
    local out
    out=$(zmyth ls -q 2>/dev/null)
    if [[ -n "$out" ]]; then
        sessions=(${(f)out})
    fi
    _describe 'session' sessions
}

_zmyth() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->verb' \
        '*:: :->args' \
        && return 0

    case $state in
        verb)
            local -a verbs
            verbs=(
                'attach:Attach to a session (auto-create)'
                'run:Run a command in a session'
                'send:Send raw input to a session PTY'
                'read:Read session output / scrollback'
                'ls:List sessions'
                'wait:Wait for command(s) to finish'
                'kill:Kill session(s)'
                'mv:Rename a session'
                'detach:Detach client(s) from a session'
                'version:Show version'
                'help:Show help'
                'completions:Print shell completion script'
            )
            _describe 'command' verbs
            ;;
        args)
            case $words[1] in
                attach)
                    _arguments '1: :_zmyth_sessions' '*:: :_normal'
                    ;;
                run)
                    _arguments \
                        '-d[detach: do not wait for exit]' \
                        '-j[JSON result line]' \
                        '1: :_zmyth_sessions' \
                        '*:: :_normal'
                    ;;
                send)
                    _arguments '1: :_zmyth_sessions'
                    ;;
                read)
                    _arguments \
                        '-f[follow]' \
                        '-s[screen snapshot]' \
                        '-n[tail N lines]:lines:' \
                        '--vt[VT-formatted output]' \
                        '--html[HTML-formatted output]' \
                        '1: :_zmyth_sessions'
                    ;;
                ls)
                    _arguments \
                        '-j[JSON output]' \
                        '-q[names only]'
                    ;;
                wait)
                    _arguments \
                        '-j[JSON output]' \
                        '*: :_zmyth_sessions'
                    ;;
                kill)
                    _arguments \
                        '-9[SIGKILL]' \
                        '*: :_zmyth_sessions'
                    ;;
                mv)
                    _arguments '1: :_zmyth_sessions' '2:new name:'
                    ;;
                detach)
                    _arguments '1: :_zmyth_sessions'
                    ;;
                completions)
                    _arguments '1:shell:(bash zsh fish)'
                    ;;
            esac
            ;;
    esac
}

if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
    _zmyth "$@"
else
    compdef _zmyth zmyth
fi
