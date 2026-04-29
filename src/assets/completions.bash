_zmyth_sessions() {
    zmyth ls -q 2>/dev/null
}

_zmyth_completions() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local verbs="attach run send read ls wait kill hook detach version help completions"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$verbs" -- "$cur"))
        return 0
    fi

    local verb="${COMP_WORDS[1]}"

    # After `--` in run/attach, fall through to default (command/file) completion.
    local i
    for ((i=2; i < COMP_CWORD; i++)); do
        if [[ "${COMP_WORDS[i]}" == "--" ]]; then
            return 0
        fi
    done

    case "$verb" in
        attach|send|detach)
            if [[ $COMP_CWORD -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$(_zmyth_sessions)" -- "$cur"))
            fi
            ;;
        run)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-d -j --" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_zmyth_sessions)" -- "$cur"))
            fi
            ;;
        read)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-f -s -n" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_zmyth_sessions)" -- "$cur"))
            fi
            ;;
        ls)
            COMPREPLY=($(compgen -W "-j -q" -- "$cur"))
            ;;
        wait)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-j" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_zmyth_sessions)" -- "$cur"))
            fi
            ;;
        kill)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-9" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_zmyth_sessions)" -- "$cur"))
            fi
            ;;
        completions)
            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
            ;;
    esac
}

complete -o bashdefault -o default -F _zmyth_completions zmyth
