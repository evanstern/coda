#compdef coda
# zsh completion for coda
# Sourced automatically by install.sh via ~/.zshrc
#
# Manual install (add to fpath before compinit):
#   fpath=(/path/to/remote-dev-server/completions $fpath)
#   autoload -Uz compinit && compinit

_coda_sessions() {
    local prefix="${SESSION_PREFIX:-coda-}"
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${prefix}" \
        | sed "s/^${prefix}//"
}

_coda_branches() {
    local root
    root=$(_coda_find_project_root 2>/dev/null) || return
    git -C "$root" branch --format='%(refname:short)' 2>/dev/null
}

_coda_worktree_branches() {
    local root
    root=$(_coda_find_project_root 2>/dev/null) || return
    git -C "$root" worktree list --porcelain 2>/dev/null \
        | grep '^branch' \
        | sed 's|branch refs/heads/||'
}

_coda_projects() {
    local dir="${PROJECTS_DIR:-$HOME/projects}"
    [[ -d "$dir" ]] || return
    for d in "$dir"/*/; do
        if [[ -d "${d}.bare" ]] || [[ -f "${d}.git" ]]; then
            echo "${d:t}"  # basename in zsh
        fi
    done
}

_coda() {
    local state line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*: :->args' \
        && return 0

    case $state in
        subcommand)
            local subcommands sessions
            sessions=($(_coda_sessions))
            local -a all_completions
            all_completions=(
                'ls:list active sessions'
                'switch:fzf session picker with preview'
                'serve:start OpenCode in headless server mode'
                'auth:wire Claude Code credentials to OpenCode'
                'project:manage projects'
                'feature:manage feature worktrees'
                'help:show usage'
            )
            # Add existing sessions as completions
            for s in $sessions; do
                all_completions+=("$s:attach to session coda-$s")
            done
            _describe 'subcommand' all_completions
            ;;

        args)
            case $line[1] in
                project)
                    _coda_project_args
                    ;;
                feature)
                    _coda_feature_args
                    ;;
                serve)
                    local base="${OPENCODE_BASE_PORT:-4096}"
                    local -a ports
                    for i in {0..9}; do ports+=($((base + i))); done
                    _describe 'port' ports
                    ;;
            esac
            ;;
    esac
}

_coda_project_args() {
    local state line
    _arguments -C \
        '1: :->subcmd' \
        '*: :->rest' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds
            subcmds=(
                'add:clone a repo as a bare project'
                'ls:list all projects'
            )
            _describe 'project subcommand' subcmds
            ;;
        rest)
            case $line[1] in
                add) _urls ;;
            esac
            ;;
    esac
}

_coda_feature_args() {
    local state line
    _arguments -C \
        '1: :->subcmd' \
        '2: :->branch' \
        '3: :->base' \
        '4: :->project' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds
            subcmds=(
                'start:create a worktree and session for a branch'
                'done:teardown a worktree and its session'
                'ls:list worktrees for the current project'
            )
            _describe 'feature subcommand' subcmds
            ;;
        branch)
            case $line[1] in
                start)
                    local branches=($(_coda_branches))
                    _describe 'branch' branches
                    ;;
                done)
                    local branches=($(_coda_worktree_branches))
                    _describe 'worktree branch' branches
                    ;;
            esac
            ;;
        base)
            case $line[1] in
                start)
                    local branches=($(_coda_branches))
                    _describe 'base branch' branches
                    ;;
                done)
                    local projects=($(_coda_projects))
                    _describe 'project name' projects
                    ;;
            esac
            ;;
        project)
            case $line[1] in
                start)
                    local projects=($(_coda_projects))
                    _describe 'project name' projects
                    ;;
            esac
            ;;
    esac
}

_coda "$@"
