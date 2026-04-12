#!/usr/bin/env bash
#
# shell-functions.sh — coda: OpenCode session and project manager
#
# Source in .bashrc or .zshrc:
#   source ~/coda/shell-functions.sh

_CODA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_CODA_DIR/.env" ]; then
    # shellcheck source=/dev/null
    set -a; source "$_CODA_DIR/.env"; set +a
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SESSION_PREFIX="${SESSION_PREFIX:-coda-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
NEW_PROJECT_GITHUB_OWNER="evanstern"

_coda_sanitize_session_name() {
    printf '%s' "$1" | tr '.' '-'
}

_coda_detect_default_branch() {
    local project_dir="$1"
    local ref
    ref=$(git -C "$project_dir/.bare" symbolic-ref HEAD 2>/dev/null)
    if [ -n "$ref" ]; then
        printf '%s' "${ref#refs/heads/}"
    else
        printf '%s' "$DEFAULT_BRANCH"
    fi
}
OPENCODE_BASE_PORT="${OPENCODE_BASE_PORT:-4096}"
OPENCODE_PORT_RANGE="${OPENCODE_PORT_RANGE:-10}"
AUTO_ATTACH_TMUX="${AUTO_ATTACH_TMUX:-true}"
DEFAULT_TMUX_SESSION="${DEFAULT_TMUX_SESSION:-default}"
DEFAULT_LAYOUT="${DEFAULT_LAYOUT:-four-pane}"
DEFAULT_NVIM_APPNAME="${DEFAULT_NVIM_APPNAME:-nvim}"
CODA_PROFILES_DIR="${CODA_PROFILES_DIR:-$HOME/.config/coda/profiles}"
CODA_LAYOUTS_DIR="${CODA_LAYOUTS_DIR:-$HOME/.config/coda/layouts}"
CODA_PROVIDER_MODE="${CODA_PROVIDER_MODE:-claude-auth}"
CLIPROXYAPI_BASE_URL="${CLIPROXYAPI_BASE_URL:-http://localhost:8317/v1}"
CLIPROXYAPI_HEALTH_URL="${CLIPROXYAPI_HEALTH_URL:-}"
CLIPROXYAPI_API_KEY="${CLIPROXYAPI_API_KEY:-}"

# ===========================================================================
# coda — main entry point
# ===========================================================================
#
#   coda [name] [dir]             attach or create a session
#   coda ls                       list active sessions
#   coda switch                   fzf session picker
#   coda serve [port]             headless OpenCode server
#   coda auth                     wire provider credentials/config
#   coda provider <cmd>           provider commands
#   coda project <cmd>            manage projects
#   coda feature <cmd>            manage feature worktrees
#   coda layout <cmd|name>        manage/apply tmux layouts
#   coda profile <cmd>            manage layout/config profiles
#   coda watch <cmd>              monitor sessions for attention signals
#   coda help                     show this help
#
# Global flags (any position):
#   --profile <name>              use a config profile for this session
#   --layout <name>               override the tmux layout
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

# ===========================================================================
# coda [name] [dir]
# Attach to an existing session or create a new one running OpenCode.
# ===========================================================================
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

# ===========================================================================
# coda ls
# List all active coda sessions.
# ===========================================================================
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

# ===========================================================================
# coda switch
# fzf-powered session picker with pane preview.
# ===========================================================================
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

# ===========================================================================
# coda serve [port]
# Start OpenCode in headless server mode.
# ===========================================================================
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

# ===========================================================================
# coda auth
# ===========================================================================
_coda_auth() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    case "$mode" in
        claude-auth) _coda_auth_claude ;;
        cliproxyapi) _coda_auth_cliproxyapi ;;
    esac
}

_coda_auth_claude() {
    if ! command -v claude &>/dev/null; then
        echo "claude CLI not found. Install Claude Code first (re-run install.sh)."
        return 1
    fi

    if ! command -v opencode &>/dev/null; then
        echo "opencode not found. Re-run install.sh."
        return 1
    fi

    if ! claude auth status >/dev/null 2>&1; then
        echo "Not authenticated. Run: claude auth login"
        return 1
    fi

    if [ ! -f "$HOME/.claude/.credentials.json" ]; then
        echo "Missing $HOME/.claude/.credentials.json"
        echo "Run 'claude' once after login so it writes the credentials file."
        return 1
    fi

    echo "Installing opencode-claude-auth plugin..."
    opencode plugin opencode-claude-auth -g

    echo ""
    echo "Claude auth status:"
    claude auth status
    echo ""
    echo "Available Anthropic models:"
    opencode models anthropic
}

_coda_auth_cliproxyapi() {
    if ! command -v opencode &>/dev/null; then
        echo "opencode not found. Re-run install.sh."
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "jq not found. Re-run install.sh."
        return 1
    fi

    _coda_validate_api_key "$CLIPROXYAPI_API_KEY" || return 1

    local base_url
    base_url=$(_coda_normalize_url "$CLIPROXYAPI_BASE_URL") || {
        echo "Invalid CLIPROXYAPI_BASE_URL: $CLIPROXYAPI_BASE_URL"
        echo "Expected http://... or https://..."
        return 1
    }

    local config_path
    config_path=$(_coda_resolve_opencode_config_path)

    local config_dir
    config_dir=$(dirname "$config_path")
    mkdir -p "$config_dir"

    local models_json=""
    if ! models_json=$(_coda_discover_cliproxyapi_models "$base_url"); then
        echo "Warning: could not discover models from ${base_url}/models"
        echo "Writing fallback CLIProxyAPI provider config instead."
        models_json=$(_coda_fallback_cliproxyapi_models)
    fi

    if ! _coda_merge_cliproxyapi_provider "$config_path" "$base_url" "$models_json"; then
        return 1
    fi

    echo "Updated OpenCode config: $config_path"
    echo "Provider mode: cliproxyapi"
    echo "Base URL: $base_url"
}

_coda_provider() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        status) _coda_provider_status ;;
        ""|help)
            echo "Usage: coda provider <status>"
            ;;
        *)
            echo "Unknown provider subcommand: $subcmd"
            echo "Usage: coda provider <status>"
            return 1
            ;;
    esac
}

_coda_provider_status() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    local config_path
    config_path=$(_coda_resolve_opencode_config_path)
    local provider_block_present="unknown"
    local provider_auth_present="unknown"

    echo "Provider mode: $mode"
    echo "OpenCode config: $config_path"

    if command -v opencode &>/dev/null; then
        echo "opencode: found"
    else
        echo "opencode: missing"
    fi

    if command -v jq &>/dev/null && [ -f "$config_path" ]; then
        if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
            echo "cliproxyapi provider block: config is not a valid JSON object ($config_path)"
        elif ! jq -e '(.provider | type) == "object"' "$config_path" >/dev/null 2>&1; then
            provider_block_present="no"
        elif jq -e '.provider.cliproxyapi != null' "$config_path" >/dev/null 2>&1; then
            provider_block_present="yes"
            if jq -e '.provider.cliproxyapi.options.apiKey? != null and .provider.cliproxyapi.options.apiKey != ""' "$config_path" >/dev/null 2>&1; then
                provider_auth_present="yes"
            else
                provider_auth_present="no"
            fi
        else
            provider_block_present="no"
        fi
    elif [ -f "$config_path" ]; then
        echo "cliproxyapi provider block: unknown (jq not found)"
    else
        echo "cliproxyapi provider block: config file not found (run: coda auth)"
    fi

    if [ "$mode" = "cliproxyapi" ]; then
        _coda_validate_api_key "$CLIPROXYAPI_API_KEY" || return 1

        local base_url health_url models_url

        base_url=$(_coda_normalize_url "$CLIPROXYAPI_BASE_URL") || {
            echo "Base URL: invalid ($CLIPROXYAPI_BASE_URL)"
            return 1
        }

        models_url="${base_url}/models"

        if [ -n "$CLIPROXYAPI_HEALTH_URL" ]; then
            health_url=$(_coda_normalize_url "$CLIPROXYAPI_HEALTH_URL") || {
                echo "Health URL: invalid ($CLIPROXYAPI_HEALTH_URL)"
                return 1
            }
        else
            health_url=""
        fi

        if [ "$provider_block_present" = "yes" ]; then
            if [ -n "$CLIPROXYAPI_API_KEY" ] && [ "$provider_auth_present" = "no" ]; then
                echo "cliproxyapi provider block: present, but missing proxy auth (re-run: coda auth)"
            else
                echo "cliproxyapi provider block: present (configuration ready; runtime not proven)"
            fi

            if [ "$provider_auth_present" = "yes" ]; then
                echo "Managed proxy auth: present in provider block"
            else
                echo "Managed proxy auth: absent from provider block"
            fi
        elif [ "$provider_block_present" = "no" ]; then
            echo "cliproxyapi provider block: absent (run: coda auth)"
        fi

        if [ -n "$CLIPROXYAPI_API_KEY" ]; then
            echo "Proxy API key env: set in CLIPROXYAPI_API_KEY"
        else
            echo "Proxy API key env: not set (optional)"
        fi

        _coda_print_url_status "Base URL" "$base_url"
        if [ -n "$health_url" ]; then
            _coda_print_url_status "Health URL" "$health_url"
        else
            echo "Health URL: skipped (CLIPROXYAPI_HEALTH_URL not set)"
        fi
        _coda_print_models_status "$models_url"
        echo "Readiness note: config and HTTP probes are not end-to-end runtime proof."
    fi
}

# ===========================================================================
# coda project <add|ls>
# ===========================================================================
_coda_project() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start)  shift; _coda_project_start "$@" ;;
        add)    shift; _coda_project_add "$@" ;;
        workon) shift; _coda_project_workon "$@" ;;
        close)  shift; _coda_project_close "$@" ;;
        ls)     _coda_project_ls ;;
        ""|help) echo "Usage: coda project <start|workon|close|ls>" ;;
        *)    echo "Unknown project subcommand: $subcmd"; echo "Usage: coda project <start|workon|close|ls>"; return 1 ;;
    esac
}

# coda project start [--repo <url>] [--new <name>] [--message|-m "..."]
_coda_project_start() {
    local repo="" new_name="" message=""
    local positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)      repo="$2"; shift 2 ;;
            --repo=*)    repo="${1#--repo=}"; shift ;;
            --new)       new_name="$2"; shift 2 ;;
            --new=*)     new_name="${1#--new=}"; shift ;;
            --message)   message="$2"; shift 2 ;;
            --message=*) message="${1#--message=}"; shift ;;
            -m)          message="$2"; shift 2 ;;
            *)           positional+=("$1"); shift ;;
        esac
    done

    if [ -n "$new_name" ]; then
        _coda_project_start_new "$new_name" "$message"
    elif [ -n "$repo" ]; then
        _coda_project_add "$repo" "${positional[0]:-}"
    else
        _coda_project_start_reconnect
    fi
}

# coda project start (no args) — reconnect to existing main/master session
_coda_project_start_reconnect() {
    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        echo ""
        echo "Usage:"
        echo "  coda project start                           Reconnect (from inside a project)"
        echo "  coda project start --repo <url> [name]       Clone an existing repo"
        echo "  coda project start --new <name> [-m \"...\"]   Create a new repo"
        return 1
    fi

    local project_name
    project_name=$(basename "$project_root")
    local branch
    branch=$(_coda_detect_default_branch "$project_root")
    local sanitized
    sanitized=$(_coda_sanitize_session_name "$project_name")

    # Look for session on default branch (without branch suffix — as created by project start --repo)
    local session="${SESSION_PREFIX}${sanitized}"
    if tmux has-session -t "$session" 2>/dev/null; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
        return 0
    fi

    # Also check with branch suffix (e.g., coda-myapp--main)
    local session_branch="${SESSION_PREFIX}${sanitized}--${branch}"
    if tmux has-session -t "$session_branch" 2>/dev/null; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session_branch"
        else
            tmux attach -t "$session_branch"
        fi
        return 0
    fi

    echo "No active session found for project: $project_name"
    echo ""
    echo "Start one with:"
    echo "  coda project workon $project_name"
    echo "  coda                                (from within the project)"
    return 1
}

# coda project start --new <name> [--message "..."]
_coda_project_start_new() {
    local name="$1"
    local message="$2"
    local project_dir="$PROJECTS_DIR/$name"
    local repo_url="git@github.com:${NEW_PROJECT_GITHUB_OWNER}/${name}.git"
    local branch="$DEFAULT_BRANCH"
    local worktree_dir="$project_dir/$branch"

    if [ -z "$name" ]; then
        echo "Usage: coda project start --new <repo-name> [--message \"...\"]"
        return 1
    fi

    if ! command -v gh &>/dev/null; then
        echo "GitHub CLI (gh) is required for --new."
        echo "Install: https://cli.github.com/"
        return 1
    fi

    if [ -d "$project_dir" ]; then
        echo "Directory already exists: $project_dir"
        return 1
    fi

    echo "Creating repository: ${NEW_PROJECT_GITHUB_OWNER}/${name}"
    if ! gh repo create "${NEW_PROJECT_GITHUB_OWNER}/${name}" --private; then
        echo "Failed to create repository on GitHub."
        return 1
    fi

    mkdir -p "$project_dir" "$worktree_dir"
    if ! git init --bare --initial-branch="$branch" "$project_dir/.bare" --quiet; then
        rm -rf "$project_dir"
        echo "Failed to create local bare repository."
        return 1
    fi

    printf 'gitdir: ./.bare\n' > "$project_dir/.git"
    git -C "$project_dir" config worktree.useRelativePaths true

    if ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" \
        checkout --orphan "$branch" >/dev/null 2>&1; then
        rm -rf "$project_dir"
        echo "Failed to create initial worktree."
        return 1
    fi

    echo "# $name" > "$worktree_dir/README.md"
    if [ -n "$message" ]; then
        printf '%s\n' "$message" > "$worktree_dir/AGENTS.md"
    fi

    if ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" add -A ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" commit -m "Initial commit" --quiet ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" remote add "$GIT_REMOTE" "$repo_url" ||
        ! git -C "$project_dir" config remote."$GIT_REMOTE".fetch \
            "+refs/heads/*:refs/remotes/${GIT_REMOTE}/*" ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" push -u "$GIT_REMOTE" "$branch" --quiet; then
        rm -rf "$project_dir"
        echo "Failed to bootstrap the new repository."
        return 1
    fi

    rm -rf "$worktree_dir"
    if ! git -C "$project_dir" worktree add "$worktree_dir" "$branch" >/dev/null 2>&1; then
        rm -rf "$project_dir"
        echo "Failed to register the initial worktree."
        return 1
    fi

    echo ""
    echo "Project ready: $project_dir"
    echo "Opening session in $worktree_dir"
    _coda_attach "$name" "$worktree_dir"
}

# coda project add <repo-url> [name]  (kept as internal helper; use 'coda project start --repo')
_coda_project_add() {
    local repo="${1:-}"
    local name="${2:-$(basename "${repo%.git}")}"

    if [ -z "$repo" ]; then
        echo "Usage: coda project start --repo <repo-url> [name]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ -d "$project_dir/.bare" ]; then
        echo "Project already set up: $project_dir"
        echo "Fetching latest..."
        git -C "$project_dir" fetch --all --quiet
        echo "Worktrees:"
        git -C "$project_dir" worktree list 2>/dev/null | sed 's/^/  /'

        local branch
        branch=$(_coda_detect_default_branch "$project_dir")

        if [ ! -d "$project_dir/$branch" ]; then
            git -C "$project_dir" worktree add \
                "$project_dir/$branch" "$branch"
        fi

        echo ""
        echo "Opening session in $project_dir/$branch"
        _coda_attach "$name" "$project_dir/$branch"
        return $?
    fi

    if [ -d "$project_dir" ]; then
        echo "Directory exists but is not a coda project: $project_dir"
        echo "Remove it first or choose a different name."
        return 1
    fi

    echo "Cloning $repo..."
    mkdir -p "$project_dir"
    git clone --bare "$repo" "$project_dir/.bare"
    echo "gitdir: ./.bare" > "$project_dir/.git"

    git -C "$project_dir" config remote."$GIT_REMOTE".fetch \
        "+refs/heads/*:refs/remotes/${GIT_REMOTE}/*"
    git -C "$project_dir" config worktree.useRelativePaths true
    git -C "$project_dir" fetch --all --quiet

    local branch
    branch=$(_coda_detect_default_branch "$project_dir")

    if [ ! -d "$project_dir/$branch" ]; then
        git -C "$project_dir" worktree add \
            "$project_dir/$branch" "$branch"
    fi

    echo ""
    echo "Project ready: $project_dir"
    echo "Opening session in $project_dir/$branch"
    _coda_attach "$name" "$project_dir/$branch"
}

# coda project workon <name> [branch]
_coda_project_workon() {
    local name="${1:-}"
    local branch="${2:-}"

    if [ -z "$name" ]; then
        echo "Usage: coda project workon <name> [branch]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir/.bare" ]; then
        echo "Not a coda project: $name"
        echo "Add it first: coda project start --repo <repo-url>"
        return 1
    fi

    if [ -z "$branch" ]; then
        branch=$(_coda_detect_default_branch "$project_dir")
    fi

    local worktree_dir="$project_dir/$branch"

    if [ ! -d "$worktree_dir" ]; then
        echo "Creating worktree: $branch"
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null ||
           git -C "$project_dir" show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git -C "$project_dir" worktree add "$worktree_dir" "$branch"
        else
            git -C "$project_dir" worktree add -b "$branch" "$worktree_dir" \
                "$(_coda_detect_default_branch "$project_dir")"
        fi
    fi

    _coda_attach "${name}--${branch}" "$worktree_dir"
}

# coda project ls
_coda_project_ls() {
    if [ ! -d "$PROJECTS_DIR" ]; then
        echo "No projects directory: $PROJECTS_DIR"
        return 1
    fi

    local found=0
    for d in "$PROJECTS_DIR"/*/; do
        if [ -d "${d}.bare" ] || [ -f "${d}.git" ]; then
            echo "  $(basename "$d")  →  $d"
            found=1
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo "No projects found in $PROJECTS_DIR"
        echo "Add one with: coda project start --repo <repo-url>"
    fi
}

_coda_project_close() {
    local delete=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --delete) delete=true; shift ;;
            *) echo "Usage: coda project close [--delete]"; return 1 ;;
        esac
    done

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    local requested_project_root="$project_root"

    local physical_project_root
    physical_project_root=$(cd "$project_root" 2>/dev/null && pwd -P)
    if [ -z "$physical_project_root" ]; then
        echo "Could not resolve project path: $project_root"
        return 1
    fi
    project_root="$physical_project_root"

    local physical_projects_dir=""
    if [ "$delete" = true ]; then
        physical_projects_dir=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P)
        if [ -z "$physical_projects_dir" ]; then
            echo "Could not resolve PROJECTS_DIR: $PROJECTS_DIR"
            return 1
        fi

        case "$project_root" in
            "$physical_projects_dir"|"$physical_projects_dir"/*) ;;
            *)
                echo "Refusing to delete project outside PROJECTS_DIR: $project_root"
                return 1
                ;;
        esac
    fi

    local project_name
    project_name=$(basename "$project_root")

    local sanitized
    sanitized=$(_coda_sanitize_session_name "$project_name")

    local -a sessions=()
    local session_name
    while IFS= read -r session_name; do
        case "$session_name" in
            "${SESSION_PREFIX}${sanitized}"|"${SESSION_PREFIX}${sanitized}"--*)
                sessions+=("$session_name")
                ;;
        esac
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

    if [ "$delete" = true ]; then
        echo "Closing project: $project_name"
        echo "  Teardown backgrounded (sessions + project folder)."
    else
        echo "Closing project: $project_name"
        echo "  Teardown backgrounded (sessions only)."
    fi

    (
        sleep 1

        local session
        for session in "${sessions[@]}"; do
            if tmux has-session -t "$session" 2>/dev/null; then
                tmux kill-session -t "$session"
            fi
        done

        if [ "$delete" = true ] && [ -d "$project_root" ]; then
            rm -rf "$project_root"
            if [ "$requested_project_root" != "$project_root" ] && [ -L "$requested_project_root" ]; then
                rm -f "$requested_project_root"
            fi
        fi
    ) &
    disown 2>/dev/null || true
    return 0
}

# ===========================================================================
# coda feature <start|done|ls>
# ===========================================================================
_coda_feature() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start)  shift; _coda_feature_start "$@" ;;
        done)   shift; _coda_feature_done "$@" ;;
        finish) shift; _coda_feature_finish "$@" ;;
        ls)     _coda_feature_ls ;;
        ""|help) echo "Usage: coda feature <start|done|finish|ls>" ;;
        *)    echo "Unknown feature subcommand: $subcmd"; echo "Usage: coda feature <start|done|finish|ls>"; return 1 ;;
    esac
}

# coda feature start <branch> [base] [project]
_coda_feature_start() {
    local branch="${1:-}"
    local base="${2:-}"
    local project_name="${3:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature start <branch> [base-branch] [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        echo "cd into a project first, or run: coda project start --repo <url>"
        return 1
    fi

    if [ -z "$base" ]; then
        base=$(_coda_detect_default_branch "$project_root")
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local worktree_dir="$project_root/$branch"

    if [ -d "$worktree_dir" ]; then
        echo "Worktree already exists: $worktree_dir"
        echo "Attaching to existing session..."
        _coda_attach "${project_name}--${branch}" "$worktree_dir"
        return 0
    fi

    echo "Creating worktree: $branch (from $base)"
    git -C "$project_root" worktree add -b "$branch" "$worktree_dir" "$base"

    _coda_attach "${project_name}--${branch}" "$worktree_dir"
}

# coda feature done <branch> [project]
_coda_feature_done() {
    local branch="${1:-}"
    local project_name="${2:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature done <branch> [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local session="${SESSION_PREFIX}$(_coda_sanitize_session_name "$project_name")--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Cleaning up feature: $branch"

    if tmux has-session -t "$session" 2>/dev/null; then
        echo "  Killing session: $session"
        tmux kill-session -t "$session"
    fi

    if [ -d "$worktree_dir" ]; then
        echo "  Removing worktree: $worktree_dir"
        git -C "$project_root" worktree remove "$worktree_dir" --force
    fi

    if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        echo "  Deleting branch: $branch"
        git -C "$project_root" branch -D "$branch"
    fi

    echo "Done."
}

# coda feature finish [--force]
_coda_feature_finish() {
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) echo "Usage: coda feature finish [--force]"; return 1 ;;
        esac
    done

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    local project_name
    project_name=$(basename "$project_root")

    local branch
    branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        echo "Could not detect current branch."
        return 1
    fi

    local default_branch
    default_branch=$(_coda_detect_default_branch "$project_root")
    if [ "$branch" = "$default_branch" ]; then
        echo "You are on $default_branch. Switch to a feature branch first."
        return 1
    fi

    if [ "$force" = false ]; then
        if ! git -C "$PWD" diff --quiet 2>/dev/null || ! git -C "$PWD" diff --cached --quiet 2>/dev/null; then
            echo "Uncommitted changes detected. Commit or stash before finishing."
            echo "  git status:"
            git -C "$PWD" status --short
            echo ""
            echo "To discard changes and tear down anyway: coda feature finish --force"
            return 1
        fi

        if [ -n "$(git -C "$PWD" ls-files --others --exclude-standard 2>/dev/null)" ]; then
            echo "Untracked files detected. Commit or remove them before finishing."
            echo "  Untracked:"
            git -C "$PWD" ls-files --others --exclude-standard | sed 's/^/    /'
            echo ""
            echo "To discard and tear down anyway: coda feature finish --force"
            return 1
        fi
    fi

    local session="${SESSION_PREFIX}$(_coda_sanitize_session_name "$project_name")--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Finishing feature: $branch"

    (
        sleep 1
        if tmux has-session -t "$session" 2>/dev/null; then
            tmux kill-session -t "$session"
        fi
        if [ -d "$worktree_dir" ]; then
            git -C "$project_root" worktree remove "$worktree_dir" --force 2>/dev/null
        fi
        if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            git -C "$project_root" branch -D "$branch" 2>/dev/null
        fi
    ) &
    disown

    echo "  Teardown backgrounded (session, worktree, branch)."
}

# coda feature ls
_coda_feature_ls() {
    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    echo "Worktrees for $(basename "$project_root"):"
    git -C "$project_root" worktree list | while IFS= read -r line; do
        echo "  $line"
    done
}

# ===========================================================================
# coda profile <ls|create|show>
# ===========================================================================
_coda_profile_cmd() {
    local subcmd="${1:-}"
    case "$subcmd" in
        ls)     _coda_profile_ls ;;
        create) shift; _coda_profile_create "$@" ;;
        show)   shift; _coda_profile_show "$@" ;;
        ""|help) echo "Usage: coda profile <ls|create|show>" ;;
        *)      echo "Unknown profile subcommand: $subcmd"; return 1 ;;
    esac
}

_coda_profile_ls() {
    echo "Available profiles:"
    local found=0
    local name

    for name in $(_coda_list_profiles); do
        local source="repo"
        [ -f "$CODA_PROFILES_DIR/${name}.env" ] && source="user"
        echo "  $name  ($source)"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        echo "  (none)"
        echo "Create one with: coda profile create <name>"
    fi

    echo ""
    echo "Current defaults: layout=$DEFAULT_LAYOUT  nvim=$DEFAULT_NVIM_APPNAME"
    echo "Run 'coda layout ls' to see available layouts."
}

_coda_profile_create() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda profile create <name>"
        return 1
    fi

    mkdir -p "$CODA_PROFILES_DIR"
    local profile_file="$CODA_PROFILES_DIR/${name}.env"

    if [ -f "$profile_file" ]; then
        echo "Profile already exists: $profile_file"
        return 1
    fi

    cat > "$profile_file" <<TMPL
# Coda profile: $name
# Used with: coda --profile $name [session]

# tmux layout (see available: coda profile ls)
CODA_LAYOUT="$DEFAULT_LAYOUT"

# Neovim config directory name (~/.config/<CODA_NVIM_APPNAME>/)
CODA_NVIM_APPNAME="nvim-${name}"
TMPL

    echo "Created: $profile_file"
    echo "Edit to customize, then use: coda --profile $name [session]"
}

_coda_profile_show() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda profile show <name>"
        return 1
    fi

    local profile_file
    profile_file=$(_coda_resolve_profile "$name")
    if [ -z "$profile_file" ]; then
        echo "Unknown profile: $name"
        return 1
    fi

    echo "Profile: $name ($profile_file)"
    echo "---"
    cat "$profile_file"
}

# ===========================================================================
# coda layout <apply|ls|show|create|name>
# ===========================================================================
_coda_layout_cmd() {
    local subcmd="${1:-}"
    case "$subcmd" in
        apply)  shift; _coda_layout_apply "$@" ;;
        ls)     _coda_layout_ls ;;
        show)   shift; _coda_layout_show "$@" ;;
        create) shift; _coda_layout_create "$@" ;;
        ""|help) cat <<'EOF'
Usage: coda layout <apply|ls|show|create|name>

  coda layout <name>           Apply layout to current session (shorthand)
  coda layout apply <name>     Apply layout to current session
  coda layout ls               List available layouts
  coda layout show <name>      Show layout file contents
  coda layout create <name>    Create a new layout from template
EOF
        ;;
        *)      _coda_layout_apply "$subcmd" "$@" ;;
    esac
}

_coda_layout_apply() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout apply <name>"
        echo "       coda layout <name>"
        return 1
    fi

    if [ -z "${TMUX:-}" ]; then
        echo "Not inside a tmux session. Attach first: coda attach <session>"
        return 1
    fi

    local session
    session=$(tmux display-message -p '#{session_name}')

    local dir
    dir=$(tmux show-environment -t "$session" CODA_DIR 2>/dev/null | sed 's/^CODA_DIR=//')
    if [ -z "$dir" ] || [ "${dir:0:1}" = "-" ]; then
        dir=$(tmux display-message -p '#{pane_current_path}')
    fi

    local nvim_appname="${CODA_NVIM_APPNAME:-$DEFAULT_NVIM_APPNAME}"

    _coda_load_layout "$name" || return 1

    if declare -f _layout_spawn &>/dev/null; then
        _layout_spawn "$session" "$dir" "$nvim_appname"
    else
        echo "Layout '$name' does not support spawning into existing sessions."
        echo "Add a _layout_spawn() function to the layout file."
        return 1
    fi
}

_coda_layout_ls() {
    echo "Available layouts:"
    local seen="" name source
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$_CODA_DIR/layouts"/*.sh; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.sh}")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
            source="user"
        else
            source="builtin"
        fi
        echo "  $name  ($source)"
    done
    echo ""
    echo "Default: $DEFAULT_LAYOUT"
    echo ""
    echo "Apply to current session:  coda layout <name>"
    echo "Create a new layout:       coda layout create <name>"
}

_coda_layout_show() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout show <name>"
        return 1
    fi

    local layout_file=""
    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    fi

    if [ -z "$layout_file" ]; then
        echo "Unknown layout: $name"
        return 1
    fi

    echo "Layout: $name ($layout_file)"
    echo "---"
    cat "$layout_file"
}

_coda_layout_create() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout create <name>"
        return 1
    fi

    mkdir -p "$CODA_LAYOUTS_DIR"
    local layout_file="$CODA_LAYOUTS_DIR/${name}.sh"

    if [ -f "$layout_file" ]; then
        echo "Layout already exists: $layout_file"
        return 1
    fi

    cat > "$layout_file" <<TMPL
#!/usr/bin/env bash
#
# ${name}.sh — tmux layout
#
# \$1 = session name    \$2 = working directory    \$3 = NVIM_APPNAME
#
# Layout:
#   ┌──────────────────────────────────────┐
#   │         (your layout here)            │
#   └──────────────────────────────────────┘
#
# Tips:
#   - End commands with "; exec \\\$SHELL" so the pane falls back to a shell
#   - Use -c "\$dir" on split/new-window to set the starting directory
#   - Use tmux send-keys for multi-command setup sequences
#   - Navigate panes with: select-pane -t "\$session" -L/-R/-U/-D
#   - See 'man tmux' for split-window, new-window, select-pane options

_layout_init() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"
    local cols="\${COLUMNS:-200}" rows="\${LINES:-50}"

    tmux new-session -d -s "\$session" -x "\$cols" -y "\$rows" -c "\$dir" "opencode; exec \\\$SHELL"

    # Add panes — use -l (absolute) not -p (percentage); -p is broken on tmux 3.4:
    # local half=\$(( cols / 2 ))
    # tmux split-window -h -t "\$session" -c "\$dir" -l "\$half" \\
    #     "NVIM_APPNAME=\$nvim_appname nvim .; exec \\\$SHELL"
    # tmux select-pane -t "\$session" -L
}

_layout_spawn() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"

    local script
    script=\$(mktemp "\${TMPDIR:-/tmp}/coda-layout.XXXXXX")
    cat > "\$script" <<SPAWN
#!/usr/bin/env bash
rm -f "\\\$0"
# Add splits here — use -l (absolute) not -p (percentage):
# pw=\\\$(tmux display-message -p '#{pane_width}')
# tmux split-window -h -c "\$dir" -l \\\$(( pw / 2 )) \\
#     "NVIM_APPNAME=\$nvim_appname nvim .; exec \\\\\\\$SHELL"
# tmux select-pane -t "\\\$TMUX_PANE"
opencode; exec "\\\$SHELL"
SPAWN
    chmod +x "\$script"
    tmux new-window -t "\$session" -c "\$dir" "\$script"
}
TMPL

    echo "Created: $layout_file"
    echo "Edit it, then apply: coda layout $name"
}

# ===========================================================================
# coda watch <start|stop|status>
# ===========================================================================
_coda_watch() {
    local subcmd="${1:-start}"
    local watcher_session="coda-watcher"

    case "$subcmd" in
        start)  _coda_watch_start "$watcher_session" ;;
        stop)   _coda_watch_stop "$watcher_session" ;;
        status) _coda_watch_status "$watcher_session" ;;
        ""|help) echo "Usage: coda watch <start|stop|status>" ;;
        *)    echo "Unknown watch subcommand: $subcmd"; echo "Usage: coda watch <start|stop|status>"; return 1 ;;
    esac
}

_coda_watch_start() {
    local watcher_session="$1"

    if tmux has-session -t "$watcher_session" 2>/dev/null; then
        echo "Watcher already running."
        echo "  View:  tmux attach -t $watcher_session"
        echo "  Stop:  coda watch stop"
        return 0
    fi

    tmux new-session -d -s "$watcher_session" "$_CODA_DIR/coda-watcher.sh"
    echo "Watcher started."
    echo "  View:  tmux attach -t $watcher_session"
    echo "  Stop:  coda watch stop"
}

_coda_watch_stop() {
    local watcher_session="$1"

    if ! tmux has-session -t "$watcher_session" 2>/dev/null; then
        echo "Watcher is not running."
        return 0
    fi

    tmux kill-session -t "$watcher_session"
    echo "Watcher stopped."
}

_coda_watch_status() {
    local watcher_session="$1"

    if tmux has-session -t "$watcher_session" 2>/dev/null; then
        local created
        created=$(tmux display-message -t "$watcher_session" -p '#{t:session_created}' 2>/dev/null)
        echo "Watcher: running (since $created)"
        echo "  View:  tmux attach -t $watcher_session"
        echo "  Stop:  coda watch stop"
    else
        echo "Watcher: stopped"
        echo "  Start: coda watch"
    fi
}

# ===========================================================================
# coda help
# ===========================================================================
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

# ===========================================================================
# Internal helpers
# ===========================================================================

_coda_list_layouts() {
    local seen="" name
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$_CODA_DIR/layouts"/*.sh; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.sh}")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        echo "$name"
    done
}

_coda_provider_mode() {
    case "${CODA_PROVIDER_MODE:-claude-auth}" in
        ""|claude-auth)
            echo "claude-auth"
            ;;
        cliproxyapi)
            echo "cliproxyapi"
            ;;
        *)
            echo "Invalid CODA_PROVIDER_MODE: ${CODA_PROVIDER_MODE}" >&2
            echo "Expected: claude-auth or cliproxyapi" >&2
            return 1
            ;;
    esac
}

_coda_expand_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

_coda_resolve_opencode_config_path() {
    if [ -n "${CODA_OPENCODE_CONFIG_PATH:-}" ]; then
        _coda_expand_path "$CODA_OPENCODE_CONFIG_PATH"
    else
        echo "$HOME/.config/opencode/opencode.json"
    fi
}

if [ -n "${CODA_OPENCODE_CONFIG_PATH:-}" ]; then
    export OPENCODE_CONFIG="$(_coda_resolve_opencode_config_path)"
fi

_coda_validate_api_key() {
    local key="$1"
    if [ -z "$key" ]; then
        return 0
    fi
    case "$key" in
        *$'\r'*|*$'\n'*)
            echo "CLIPROXYAPI_API_KEY contains CR/LF characters; rejected to prevent header injection." >&2
            return 1
            ;;
    esac
}

_coda_normalize_url() {
    local url="${1:-}"
    url="${url%/}"

    case "$url" in
        http://*|https://*)
            echo "$url"
            ;;
        *)
            return 1
            ;;
    esac
}

_coda_probe_url() {
    local url="$1"

    if ! command -v curl &>/dev/null; then
        echo "curl not found"
        return 2
    fi

    curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "$url" 2>/dev/null
}

_coda_print_url_status() {
    local label="$1"
    local url="$2"
    local code

    code=$(_coda_probe_url "$url")
    case "$?" in
        0)
            if [ "$code" = "000" ]; then
                echo "$label: unreachable ($url)"
            elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
                echo "$label: reachable ($url, HTTP $code)"
            else
                echo "$label: reachable with non-2xx response ($url, HTTP $code)"
            fi
            ;;
        2)
            echo "$label: unavailable (curl not found)"
            ;;
        *)
            echo "$label: unreachable ($url)"
            ;;
    esac
}

_coda_print_models_status() {
    local models_url="$1"

    if ! command -v curl &>/dev/null; then
        echo "Models endpoint: unavailable (curl not found)"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "Models endpoint: unavailable (jq not found)"
        return 0
    fi

    local response
    if ! response=$(_coda_fetch_cliproxyapi_models_response "$models_url"); then
        echo "Models endpoint: unreachable ($models_url)"
        return 0
    fi

    local http_code response_body
    http_code=${response##*$'\n'}
    response_body=${response%$'\n'*}

    if [ "$http_code" = "000" ]; then
        echo "Models endpoint: unreachable ($models_url)"
        return 0
    fi

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        if [ -n "$CLIPROXYAPI_API_KEY" ]; then
            echo "Models endpoint: unauthorized ($models_url, HTTP $http_code; configured proxy API key was rejected)"
        else
            echo "Models endpoint: unauthorized ($models_url, HTTP $http_code; set CLIPROXYAPI_API_KEY if your proxy requires auth)"
        fi
        return 0
    fi

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Models endpoint: reachable with non-2xx response ($models_url, HTTP $http_code)"
        return 0
    fi

    local count
    count=$(printf '%s' "$response_body" | jq -r 'if ((.data? | type) == "array") then (.data | length) else 0 end' 2>/dev/null)
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        echo "Models endpoint: reachable ($models_url, HTTP $http_code, $count models)"
    else
        echo "Models endpoint: reachable but returned no usable models ($models_url, HTTP $http_code)"
    fi
}

_coda_fallback_cliproxyapi_models() {
    cat <<'EOF'
{
  "gpt-4o": {
    "name": "gpt-4o"
  },
  "gpt-4.1": {
    "name": "gpt-4.1"
  },
  "claude-opus-4-6": {
    "name": "claude-opus-4-6"
  },
  "claude-haiku-4-5-20251001": {
    "name": "claude-haiku-4-5-20251001"
  },
  "claude-sonnet-4-5-20250929": {
    "name": "claude-sonnet-4-5-20250929"
  }
}
EOF
}

_coda_discover_cliproxyapi_models() {
    local base_url="$1"

    if ! command -v curl &>/dev/null; then
        return 1
    fi

    local response
    response=$(_coda_fetch_cliproxyapi_models_response "${base_url}/models") || return 1

    local http_code models_json
    http_code=${response##*$'\n'}
    models_json=${response%$'\n'*}

    if [ "$http_code" = "000" ] || [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        return 1
    fi

    local normalized
    normalized=$(printf '%s' "$models_json" | jq -c '
        if ((.data? | type) == "array") then
            reduce .data[] as $model ({};
                if ($model | type) == "object" and ($model.id // "") != "" then
                    ($model.id) as $id
                    | . + { ($id): { name: ($model.name // $id) } }
                elif ($model | type) == "string" and $model != "" then
                    . + { ($model): { name: ($model) } }
                else
                    .
                end
            )
        else
            {}
        end
    ' 2>/dev/null) || return 1

    if [ "$normalized" = "{}" ]; then
        return 1
    fi

    echo "$normalized"
}

_coda_merge_cliproxyapi_provider() {
    local config_path="$1"
    local base_url="$2"
    local models_json="$3"
    local api_key="${CLIPROXYAPI_API_KEY:-}"
    local config_dir
    config_dir=$(dirname "$config_path")

    local input_json='{}'
    if [ -f "$config_path" ]; then
        if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
            echo "Existing OpenCode config is not valid JSON object: $config_path"
            return 1
        fi
        input_json=$(jq -c '.' "$config_path") || return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "$config_dir/opencode.json.XXXXXX") || return 1

    if ! printf '%s' "$input_json" | jq --arg base_url "$base_url" --arg api_key "$api_key" --argjson models "$models_json" '
        .provider = (if (.provider | type) == "object" then .provider else {} end)
        | .provider.cliproxyapi = {
            npm: "@ai-sdk/openai-compatible",
            name: "CLIProxyAPI",
            options: ({
                baseURL: $base_url
            } + if $api_key != "" then {
                apiKey: $api_key
            } else {} end),
            models: $models
        }
    ' > "$tmp_file"; then
        rm -f "$tmp_file"
        echo "Failed to merge CLIProxyAPI provider config."
        return 1
    fi

    mv "$tmp_file" "$config_path"
}

_coda_fetch_cliproxyapi_models_response() {
    local models_url="$1"

    if [ -n "$CLIPROXYAPI_API_KEY" ]; then
        local header_file
        header_file=$(mktemp) || return 1
        printf 'Authorization: Bearer %s' "$CLIPROXYAPI_API_KEY" > "$header_file"
        curl --silent --show-error --max-time 5 \
            -H @"$header_file" \
            --write-out '\n%{http_code}' "$models_url" 2>/dev/null
        local rc=$?
        rm -f "$header_file"
        return $rc
    else
        curl --silent --show-error --max-time 5 \
            --write-out '\n%{http_code}' "$models_url" 2>/dev/null
    fi
}

_coda_load_layout() {
    local name="$1"
    local layout_file=""

    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    fi

    if [ -z "$layout_file" ]; then
        echo "Unknown layout: $name"
        echo "Available: $(_coda_list_layouts | tr '\n' ' ')"
        return 1
    fi

    unset -f _layout_init _layout_spawn _layout_apply 2>/dev/null

    # shellcheck source=/dev/null
    source "$layout_file"
}

_coda_resolve_profile() {
    local name="${1:-default}"
    local user_profile="$CODA_PROFILES_DIR/${name}.env"
    local repo_profile="$_CODA_DIR/profiles/${name}.env"

    if [ -f "$user_profile" ]; then
        echo "$user_profile"
    elif [ -f "$repo_profile" ]; then
        echo "$repo_profile"
    fi
}

_coda_list_profiles() {
    local seen=""
    local name

    for f in "$CODA_PROFILES_DIR"/*.env "$_CODA_DIR/profiles"/*.env; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.env}")
        case "$seen" in
            *"|$name|"*) continue ;;
        esac
        seen="$seen|$name|"
        echo "$name"
    done
}

_coda_find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.bare" ] && [ -f "$dir/.git" ] && grep -q "gitdir: ./.bare" "$dir/.git" 2>/dev/null; then
            echo "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
}

_coda_find_free_port() {
    local port=$OPENCODE_BASE_PORT
    local max=$((OPENCODE_BASE_PORT + OPENCODE_PORT_RANGE))
    while [ "$port" -le "$max" ]; do
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        elif command -v lsof &>/dev/null; then
            lsof -i :"$port" &>/dev/null 2>&1 || { echo "$port"; return; }
        else
            (echo "" >/dev/tcp/127.0.0.1/"$port") 2>/dev/null || { echo "$port"; return; }
        fi
        port=$((port + 1))
    done
}

# ===========================================================================
# Auto-attach tmux on SSH login
# ===========================================================================
if [ "$AUTO_ATTACH_TMUX" = "true" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ]; then
    tmux attach -t "$DEFAULT_TMUX_SESSION" 2>/dev/null || tmux new -s "$DEFAULT_TMUX_SESSION"
fi
