#!/usr/bin/env bash
#
# core.sh — coda entry point, session attach/ls/switch/serve/help
#

coda() {
    local _coda_profile="" _coda_layout=""
    local args=()
    local status=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --profile)    _coda_profile="$2"; shift 2 ;;
            --profile=*)  _coda_profile="${1#--profile=}"; shift ;;
            --layout)     _coda_layout="$2"; shift 2 ;;
            --layout=*)   _coda_layout="${1#--layout=}"; shift ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    [ -n "$_coda_profile" ] && CODA_PROFILE="$_coda_profile"
    [ -n "$_coda_layout" ] && CODA_LAYOUT="$_coda_layout"

    local subcmd="${args[0]:-}"

    case "$subcmd" in
        ls)               _coda_ls; status=$? ;;
        switch)           _coda_switch; status=$? ;;
        attach)           if [ "${#args[@]}" -gt 1 ]; then
                              _coda_attach "${args[1]#"$SESSION_PREFIX"}" "${args[@]:2}"
                           else
                              _coda_attach
                           fi
                          status=$?
                          ;;
        auth)             _coda_auth; status=$? ;;
        provider)         _coda_provider "${args[@]:1}"; status=$? ;;
        serve)            _coda_serve "${args[@]:1}"; status=$? ;;
        project)          _coda_project "${args[@]:1}"; status=$? ;;
        feature)          _coda_feature "${args[@]:1}"; status=$? ;;
        layout)           _coda_layout_cmd "${args[@]:1}"; status=$? ;;
        profile)          _coda_profile_cmd "${args[@]:1}"; status=$? ;;
        watch)            _coda_watch "${args[@]:1}"; status=$? ;;
        help|--help|-h)   _coda_help; status=$? ;;
        "")               _coda_attach; status=$? ;;
        *)                _coda_attach "${args[0]#"$SESSION_PREFIX"}" "${args[@]:1}"; status=$? ;;
    esac

    unset CODA_PROFILE CODA_LAYOUT
    return "$status"
}

_coda_attach() {
    local name="${1:-$(basename "$PWD")}"
    local dir="${2:-$PWD}"
    local session="${SESSION_PREFIX}$(_coda_sanitize_session_name "$name")"

    local layout="${CODA_LAYOUT:-$DEFAULT_LAYOUT}"
    local nvim_appname="${CODA_NVIM_APPNAME:-$DEFAULT_NVIM_APPNAME}"
    local profile="${CODA_PROFILE:-}"

    if [ -n "$profile" ]; then
        local profile_file
        profile_file=$(_coda_resolve_profile "$profile")
        if [ -z "$profile_file" ]; then
            echo "Unknown profile: $profile"
            echo "Available: $(_coda_list_profiles | tr '\n' ' ')"
            return 1
        fi
        set -a; source "$profile_file"; set +a
        layout="${CODA_LAYOUT:-$layout}"
        nvim_appname="${CODA_NVIM_APPNAME:-$nvim_appname}"
    fi

    if ! tmux has-session -t "$session" 2>/dev/null; then
        _coda_load_layout "$layout" || return 1

        if declare -f _layout_init &>/dev/null; then
            _layout_init "$session" "$dir" "$nvim_appname"
        elif declare -f _layout_apply &>/dev/null; then
            _layout_apply "$session" "$dir" "$nvim_appname"
        else
            echo "Layout '$layout' has no _layout_init or _layout_apply function."
            return 1
        fi

        tmux set-environment -t "$session" CODA_DIR "$dir"
    fi

    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$session"
    else
        tmux attach -t "$session"
    fi
}

_coda_ls() {
    local sessions
    sessions=$(tmux list-sessions \
        -F '#{session_name}  (#{session_windows}w, created #{t:session_created})' \
        2>/dev/null | grep "^${SESSION_PREFIX}" || true)

    if [ -z "$sessions" ]; then
        echo "No active sessions."
        echo "Start one with: coda [name]"
    else
        echo "Active sessions:"
        echo "$sessions" | while IFS= read -r line; do
            echo "  $line"
        done
    fi
}

_coda_switch() {
    if ! command -v fzf &>/dev/null; then
        echo "fzf not found. Re-run install.sh to install it."
        return 1
    fi

    local session
    session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | fzf --preview 'tmux capture-pane -t {} -p -S -30' \
              --preview-window=right:50% \
              --header="Select session  (ESC to cancel)")

    if [ -n "$session" ]; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
    fi
}

_coda_serve() {
    local port="${1:-}"

    if [ -z "$port" ]; then
        port=$(_coda_find_free_port)
        if [ -z "$port" ]; then
            echo "No free ports in range ${OPENCODE_BASE_PORT}-$((OPENCODE_BASE_PORT + OPENCODE_PORT_RANGE))"
            return 1
        fi
    fi

    local _default_permission='{"*":"allow"}'
    local permission="${OPENCODE_HEADLESS_PERMISSION:-$_default_permission}"

    echo "Starting OpenCode server on port $port"
    echo "  Attach with: opencode attach http://localhost:$port"
    echo ""

    OPENCODE_PERMISSION="$permission" opencode serve --port "$port"
}

_coda_help() {
    cat <<'EOF'
coda — OpenCode session and project manager

USAGE
  coda [name] [dir]           Attach or create a session (default: current dir)
  coda ls                     List active sessions
  coda switch                 fzf session picker with preview
  coda serve [port]           Start OpenCode in headless server mode
  coda auth                   Wire the active provider into OpenCode
  coda provider status        Show provider diagnostics

  coda project start                              Reconnect to main/master session
  coda project start --repo <url> [name]          Clone a repo as a bare project
  coda project start --new <name> [-m "..."]      Create a new repo on GitHub
  coda project workon <name> [branch]             Open a project session
  coda project close [--delete]                   Close project sessions, optionally delete folders
  coda project ls                                 List projects in PROJECTS_DIR

  coda feature start <branch> [base] [project]   New worktree + session
  coda feature done  <branch> [project]          Teardown worktree + session
  coda feature finish [--force]                  Teardown current feature (agent-safe)
  coda feature ls                                List worktrees for this project

  coda layout <name>                Apply a layout to the current session
  coda layout ls                   List available layouts
  coda layout show <name>          Show layout file contents
  coda layout create <name>        Create a new layout from template
  coda layout create <name> --snapshot  Capture current window layout

  coda profile ls                  List profiles
  coda profile create <name>       Create a new profile
  coda profile show <name>         Show profile settings

  coda watch                       Start monitoring sessions (bell on idle)
  coda watch stop                  Stop the watcher
  coda watch status                Check if watcher is running

  coda help                   Show this help

GLOBAL FLAGS
  --profile <name>            Use a config profile (layout + nvim config)
  --layout <name>             Override the tmux layout for this session

EXAMPLES
  coda project start --repo git@github.com:user/myapp.git
  coda project start --new my-tool -m "CLI for managing widgets"
  cd ~/projects/myapp/main
  coda feature start auth
  coda --profile experimental feature start auth
  coda --layout classic myapp
  coda ls
  coda switch
  coda feature done auth

Run 'man coda' for the full manual.
EOF
}
