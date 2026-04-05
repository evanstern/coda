# bash completion for coda
# Sourced automatically by install.sh via ~/.bashrc
#
# Manual install:
#   source /path/to/coda/completions/coda.bash

_coda_sessions() {
    # Active tmux session names (strip the prefix for user-facing display)
    local prefix="${SESSION_PREFIX:-coda-}"
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${prefix}" \
        | sed "s/^${prefix}//"
}

_coda_branches() {
    # Local git branches in the current project root
    local root
    root=$(_coda_find_project_root 2>/dev/null) || return
    git -C "$root" branch --format='%(refname:short)' 2>/dev/null
}

_coda_worktree_branches() {
    # Branches that have an active worktree (for 'feature done' completion)
    local root
    root=$(_coda_find_project_root 2>/dev/null) || return
    git -C "$root" worktree list --porcelain 2>/dev/null \
        | grep '^branch' \
        | sed 's|branch refs/heads/||'
}

_coda_projects() {
    local dir="${PROJECTS_DIR:-$HOME/projects}"
    [ -d "$dir" ] || return
    for d in "$dir"/*/; do
        if [ -d "${d}.bare" ] || [ -f "${d}.git" ]; then
            basename "$d"
        fi
    done
}

_coda_complete() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    local top_subcommands="ls switch serve auth project feature help"

    # Word positions:
    #   words[0] = coda
    #   words[1] = subcommand
    #   words[2] = sub-subcommand or first arg
    #   words[3] = second arg ...

    case "$cword" in
        1)
            # First argument: top-level subcommands or a session name
            local sessions
            sessions=$(_coda_sessions)
            COMPREPLY=($(compgen -W "$top_subcommands $sessions" -- "$cur"))
            ;;
        2)
            case "${words[1]}" in
                project)
                    COMPREPLY=($(compgen -W "add ls" -- "$cur"))
                    ;;
                feature)
                    COMPREPLY=($(compgen -W "start done ls" -- "$cur"))
                    ;;
                serve)
                    # Port numbers in the configured range
                    local base="${OPENCODE_BASE_PORT:-4096}"
                    local ports=""
                    for i in 0 1 2 3 4 5 6 7 8 9; do
                        ports="$ports $((base + i))"
                    done
                    COMPREPLY=($(compgen -W "$ports" -- "$cur"))
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            ;;
        3)
            case "${words[1]}" in
                feature)
                    case "${words[2]}" in
                        start)
                            # Suggest existing local branches
                            local branches
                            branches=$(_coda_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                        done)
                            # Suggest branches that have a worktree
                            local branches
                            branches=$(_coda_worktree_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                    esac
                    ;;
                project)
                    case "${words[2]}" in
                        add)
                            # Directory completion for local paths
                            COMPREPLY=($(compgen -d -- "$cur"))
                            ;;
                    esac
                    ;;
            esac
            ;;
        4)
            case "${words[1]}" in
                feature)
                    case "${words[2]}" in
                        start)
                            # base branch argument
                            local branches
                            branches=$(_coda_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                        done)
                            # project name argument
                            local projects
                            projects=$(_coda_projects)
                            COMPREPLY=($(compgen -W "$projects" -- "$cur"))
                            ;;
                    esac
                    ;;
            esac
            ;;
        5)
            case "${words[1]}" in
                feature)
                    case "${words[2]}" in
                        start)
                            # project name argument (3rd positional)
                            local projects
                            projects=$(_coda_projects)
                            COMPREPLY=($(compgen -W "$projects" -- "$cur"))
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac

    return 0
}

complete -F _coda_complete coda
