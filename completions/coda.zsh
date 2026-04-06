#compdef coda
# zsh completion for coda
# Sourced automatically by install.sh via ~/.zshrc
#
# Manual install (add to fpath before compinit):
#   fpath=(/path/to/coda/completions $fpath)
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
            echo "${d:t}"
        fi
    done
}

_coda_project_branches() {
    local name="${1:-}"
    local dir="${PROJECTS_DIR:-$HOME/projects}/$name"
    [[ -d "$dir/.bare" ]] || return
    git -C "$dir" branch --format='%(refname:short)' 2>/dev/null
}

_coda_layouts() {
    _coda_list_layouts 2>/dev/null
}

_coda() {
    local state line
    typeset -A opt_args

    _arguments -C \
        '--profile[Config profile to use]:profile:($(_coda_list_profiles 2>/dev/null))' \
        '--layout[tmux layout override]:layout:($(_coda_layouts))' \
        '1: :->subcommand' \
        '*: :->args' \
        && return 0

    case $state in
        subcommand)
            local subcommands sessions
            sessions=($(_coda_sessions))
            local -a all_completions
            all_completions=(
                'attach:attach to an existing session'
                'ls:list active sessions'
                'switch:fzf session picker with preview'
                'serve:start OpenCode in headless server mode'
                'auth:wire Claude Code credentials to OpenCode'
                'project:manage projects'
                'feature:manage feature worktrees'
                'layout:manage and apply tmux layouts'
                'profile:manage config profiles'
                'watch:monitor sessions for attention signals'
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
                attach)
                    local sessions=($(_coda_sessions))
                    _describe 'session' sessions
                    ;;
                project)
                    _coda_project_args
                    ;;
                feature)
                    _coda_feature_args
                    ;;
                layout)
                    _coda_layout_args
                    ;;
                profile)
                    _coda_profile_args
                    ;;
                watch)
                    _coda_watch_args
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
        '2: :->arg1' \
        '3: :->arg2' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds
            subcmds=(
                'add:clone a repo as a bare project'
                'workon:open a project session (create worktree if needed)'
                'ls:list all projects'
            )
            _describe 'project subcommand' subcmds
            ;;
        arg1)
            case $line[1] in
                add) _urls ;;
                workon)
                    local projects=($(_coda_projects))
                    _describe 'project' projects
                    ;;
            esac
            ;;
        arg2)
            case $line[1] in
                workon)
                    local branches=($(_coda_project_branches "$line[2]"))
                    _describe 'branch' branches
                    ;;
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
                'finish:commit, push, create PR, then teardown'
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
                finish|done)
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
                finish|done)
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

_coda_layout_args() {
    local state line
    _arguments -C \
        '1: :->subcmd' \
        '2: :->name' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds layouts
            subcmds=(
                'apply:apply a layout to the current session'
                'ls:list available layouts'
                'show:show layout file contents'
                'create:create a new layout from template'
            )
            layouts=($(_coda_layouts))
            _describe 'layout subcommand or name' subcmds -- layouts
            ;;
        name)
            case $line[1] in
                apply|show)
                    local layouts=($(_coda_layouts))
                    _describe 'layout' layouts
                    ;;
            esac
            ;;
    esac
}

_coda_profile_args() {
    local state line
    _arguments -C \
        '1: :->subcmd' \
        '2: :->name' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds
            subcmds=(
                'ls:list profiles and layouts'
                'create:create a new profile'
                'show:show profile settings'
            )
            _describe 'profile subcommand' subcmds
            ;;
        name)
            case $line[1] in
                show)
                    local profiles=($(_coda_list_profiles 2>/dev/null))
                    _describe 'profile' profiles
                    ;;
            esac
            ;;
    esac
}

_coda_watch_args() {
    local state line
    _arguments -C \
        '1: :->subcmd' \
        && return 0

    case $state in
        subcmd)
            local -a subcmds
            subcmds=(
                'start:start the watcher'
                'stop:stop the watcher'
                'status:check if watcher is running'
            )
            _describe 'watch subcommand' subcmds
            ;;
    esac
}

_coda "$@"
