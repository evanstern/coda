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

_coda_project_branches() {
    local name="${1:-}"
    local dir="${PROJECTS_DIR:-$HOME/projects}/$name"
    [ -d "$dir/.bare" ] || return
    git -C "$dir" branch --format='%(refname:short)' 2>/dev/null
}

_coda_layouts() {
    _coda_list_layouts 2>/dev/null
}

_coda_profiles() {
    _coda_list_profiles 2>/dev/null
}

_coda_hook_events() {
    echo "pre-session-create post-session-create post-session-attach post-project-create post-project-clone pre-project-close post-feature-create pre-feature-teardown post-feature-finish post-layout-apply"
}

_coda_providers() {
    _coda_list_providers 2>/dev/null
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

    local top_subcommands="attach ls switch serve auth project feature layout profile hooks watch provider github help"

    # Word positions:
    #   words[0] = coda
    #   words[1] = subcommand
    #   words[2] = sub-subcommand or first arg
    #   words[3] = second arg ...

    if [[ "$prev" == "--profile" ]]; then
        local profiles
        profiles=$(_coda_profiles)
        COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
        return 0
    fi

    if [[ "$prev" == "--layout" ]]; then
        local layouts
        layouts=$(_coda_layouts)
        COMPREPLY=($(compgen -W "$layouts" -- "$cur"))
        return 0
    fi

    if [[ "${words[1]}" == "project" ]] && [[ "${words[2]}" == "start" ]] && [[ "$cword" -ge 3 ]]; then
        case "$prev" in
            --repo|--new|--message|-m)
                COMPREPLY=()
                return 0
                ;;
            *)
                if [[ "$cur" == -* ]]; then
                    COMPREPLY=($(compgen -W "--repo --new --message -m" -- "$cur"))
                fi
                return 0
                ;;
        esac
    fi

    if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--profile --layout" -- "$cur"))
        return 0
    fi

    case "$cword" in
        1)
            local sessions
            sessions=$(_coda_sessions)
            COMPREPLY=($(compgen -W "$top_subcommands $sessions" -- "$cur"))
            ;;
        2)
            case "${words[1]}" in
                project)
                    COMPREPLY=($(compgen -W "start workon close ls" -- "$cur"))
                    ;;
                feature)
                    COMPREPLY=($(compgen -W "start done finish ls" -- "$cur"))
                    ;;
                layout)
                    local layouts
                    layouts=$(_coda_layouts)
                    COMPREPLY=($(compgen -W "apply ls show create $layouts" -- "$cur"))
                    ;;
                profile)
                    COMPREPLY=($(compgen -W "ls create show" -- "$cur"))
                    ;;
                watch)
                    COMPREPLY=($(compgen -W "start stop status" -- "$cur"))
                    ;;
                hooks)
                    COMPREPLY=($(compgen -W "ls events create run" -- "$cur"))
                    ;;
                provider)
                    COMPREPLY=($(compgen -W "status ls" -- "$cur"))
                    ;;
                github)
                    COMPREPLY=($(compgen -W "token comment status" -- "$cur"))
                    ;;
                attach)
                    local sessions
                    sessions=$(_coda_sessions)
                    COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
                    ;;
                serve)
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
                profile)
                    case "${words[2]}" in
                        show)
                            local profiles
                            profiles=$(_coda_profiles)
                            COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
                            ;;
                    esac
                    ;;
                hooks)
                    case "${words[2]}" in
                        ls|create|run)
                            local events
                            events=$(_coda_hook_events)
                            COMPREPLY=($(compgen -W "$events" -- "$cur"))
                            ;;
                    esac
                    ;;
                layout)
                    case "${words[2]}" in
                        apply|show)
                            local layouts
                            layouts=$(_coda_layouts)
                            COMPREPLY=($(compgen -W "$layouts" -- "$cur"))
                            ;;
                        create)
                            COMPREPLY=($(compgen -W "--snapshot" -- "$cur"))
                            ;;
                    esac
                    ;;
                feature)
                    case "${words[2]}" in
                        start)
                            local branches
                            branches=$(_coda_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                        done)
                            local branches
                            branches=$(_coda_worktree_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                        finish)
                            COMPREPLY=($(compgen -W "--force" -- "$cur"))
                            ;;
                    esac
                    ;;
                project)
                    case "${words[2]}" in
                        close)
                            COMPREPLY=($(compgen -W "--delete" -- "$cur"))
                            ;;
                        workon)
                            local projects
                            projects=$(_coda_projects)
                            COMPREPLY=($(compgen -W "$projects" -- "$cur"))
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
                            local branches
                            branches=$(_coda_branches)
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
                            ;;
                        done)
                            local projects
                            projects=$(_coda_projects)
                            COMPREPLY=($(compgen -W "$projects" -- "$cur"))
                            ;;
                    esac
                    ;;
                project)
                    case "${words[2]}" in
                        workon)
                            local branches
                            branches=$(_coda_project_branches "${words[3]}")
                            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
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

complete -F _coda_complete coda coda-dev
