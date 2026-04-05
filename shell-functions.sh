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
OPENCODE_BASE_PORT="${OPENCODE_BASE_PORT:-4096}"
OPENCODE_PORT_RANGE="${OPENCODE_PORT_RANGE:-10}"
MAX_CONCURRENT_SESSIONS="${MAX_CONCURRENT_SESSIONS:-5}"
AUTO_ATTACH_TMUX="${AUTO_ATTACH_TMUX:-true}"
DEFAULT_TMUX_SESSION="${DEFAULT_TMUX_SESSION:-default}"
DEFAULT_LAYOUT="${DEFAULT_LAYOUT:-three-pane}"
DEFAULT_NVIM_APPNAME="${DEFAULT_NVIM_APPNAME:-nvim}"
CODA_PROFILES_DIR="${CODA_PROFILES_DIR:-$HOME/.config/coda/profiles}"

# ===========================================================================
# coda — main entry point
# ===========================================================================
#
#   coda [name] [dir]             attach or create a session
#   coda ls                       list active sessions
#   coda switch                   fzf session picker
#   coda serve [port]             headless OpenCode server
#   coda auth                     wire Claude Code credentials
#   coda project <cmd>            manage projects
#   coda feature <cmd>            manage feature worktrees
#   coda profile <cmd>            manage layout/config profiles
#   coda help                     show this help
#
# Global flags (any position):
#   --profile <name>              use a config profile for this session
#   --layout <name>               override the tmux layout
#
coda() {
    local _coda_profile="" _coda_layout=""
    local args=()

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
        ls)               _coda_ls ;;
        switch)           _coda_switch ;;
        attach)           if [ "${#args[@]}" -gt 1 ]; then
                              _coda_attach "${args[1]#"$SESSION_PREFIX"}" "${args[@]:2}"
                          else
                              _coda_attach
                          fi
                          ;;
        auth)             _coda_auth ;;
        serve)            _coda_serve "${args[@]:1}" ;;
        project)          _coda_project "${args[@]:1}" ;;
        feature)          _coda_feature "${args[@]:1}" ;;
        profile)          _coda_profile_cmd "${args[@]:1}" ;;
        help|--help|-h)   _coda_help ;;
        "")               _coda_attach ;;
        *)                _coda_attach "${args[0]#"$SESSION_PREFIX"}" "${args[@]:1}" ;;
    esac

    unset CODA_PROFILE CODA_LAYOUT
}

# ===========================================================================
# coda [name] [dir]
# Attach to an existing session or create a new one running OpenCode.
# ===========================================================================
_coda_attach() {
    local name="${1:-$(basename "$PWD")}"
    local dir="${2:-$PWD}"
    local session="${SESSION_PREFIX}${name}"

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
        local count
        count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
            | grep -c "^${SESSION_PREFIX}" || true)

        if [ "$count" -ge "$MAX_CONCURRENT_SESSIONS" ]; then
            echo "At session limit ($MAX_CONCURRENT_SESSIONS). Use 'coda ls' to see running sessions."
            return 1
        fi

        _coda_load_layout "$layout" || return 1
        _layout_apply "$session" "$dir" "$nvim_appname"
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
# Install the opencode-claude-auth plugin to share Claude Code credentials.
# ===========================================================================
_coda_auth() {
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

# ===========================================================================
# coda project <add|ls>
# ===========================================================================
_coda_project() {
    local subcmd="${1:-}"
    case "$subcmd" in
        add)    shift; _coda_project_add "$@" ;;
        workon) shift; _coda_project_workon "$@" ;;
        ls)     _coda_project_ls ;;
        ""|help) echo "Usage: coda project <add|workon|ls>" ;;
        *)    echo "Unknown project subcommand: $subcmd"; echo "Usage: coda project <add|workon|ls>"; return 1 ;;
    esac
}

# coda project add <repo-url> [name]
_coda_project_add() {
    local repo="${1:-}"
    local name="${2:-$(basename "${repo%.git}")}"

    if [ -z "$repo" ]; then
        echo "Usage: coda project add <repo-url> [name]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ -d "$project_dir/.bare" ]; then
        echo "Project already set up: $project_dir"
        echo "Fetching latest..."
        git -C "$project_dir" fetch --all --quiet
        echo "Worktrees:"
        git -C "$project_dir" worktree list 2>/dev/null | sed 's/^/  /'
        return 0
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

    if [ ! -d "$project_dir/$DEFAULT_BRANCH" ]; then
        git -C "$project_dir" worktree add \
            "$project_dir/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"
    fi

    echo ""
    echo "Project ready: $project_dir"
    echo "  cd $project_dir/$DEFAULT_BRANCH"
}

# coda project workon <name> [branch]
_coda_project_workon() {
    local name="${1:-}"
    local branch="${2:-$DEFAULT_BRANCH}"

    if [ -z "$name" ]; then
        echo "Usage: coda project workon <name> [branch]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir/.bare" ]; then
        echo "Not a coda project: $name"
        echo "Add it first: coda project add <repo-url> $name"
        return 1
    fi

    local worktree_dir="$project_dir/$branch"

    if [ ! -d "$worktree_dir" ]; then
        echo "Creating worktree: $branch"
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null ||
           git -C "$project_dir" show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git -C "$project_dir" worktree add "$worktree_dir" "$branch"
        else
            git -C "$project_dir" worktree add -b "$branch" "$worktree_dir" "$DEFAULT_BRANCH"
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
        echo "Add one with: coda project add <repo-url>"
    fi
}

# ===========================================================================
# coda feature <start|done|ls>
# ===========================================================================
_coda_feature() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start) shift; _coda_feature_start "$@" ;;
        done)  shift; _coda_feature_done "$@" ;;
        ls)    _coda_feature_ls ;;
        ""|help) echo "Usage: coda feature <start|done|ls>" ;;
        *)    echo "Unknown feature subcommand: $subcmd"; echo "Usage: coda feature <start|done|ls>"; return 1 ;;
    esac
}

# coda feature start <branch> [base] [project]
_coda_feature_start() {
    local branch="${1:-}"
    local base="${2:-$DEFAULT_BRANCH}"
    local project_name="${3:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature start <branch> [base-branch] [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        echo "cd into a project first, or run: coda project add <url>"
        return 1
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

    local session="${SESSION_PREFIX}${project_name}--${branch}"
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
    echo "Available layouts:"
    for f in "$_CODA_DIR"/layouts/*.sh; do
        [ -f "$f" ] || continue
        echo "  $(basename "${f%.sh}")"
    done

    echo ""
    echo "Current defaults: layout=$DEFAULT_LAYOUT  nvim=$DEFAULT_NVIM_APPNAME"
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
  coda auth                   Wire Claude Code credentials to OpenCode

  coda project add <url> [name]        Clone a repo as a bare project
  coda project workon <name> [branch]  Open a project session (create worktree if needed)
  coda project ls                      List projects in PROJECTS_DIR

  coda feature start <branch> [base] [project]   New worktree + session
  coda feature done  <branch> [project]          Teardown worktree + session
  coda feature ls                                List worktrees for this project

  coda profile ls                  List profiles and layouts
  coda profile create <name>       Create a new profile
  coda profile show <name>         Show profile settings

  coda help                   Show this help

GLOBAL FLAGS
  --profile <name>            Use a config profile (layout + nvim config)
  --layout <name>             Override the tmux layout for this session

EXAMPLES
  coda project add git@github.com:user/myapp.git
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

_coda_load_layout() {
    local name="$1"
    local layout_file="$_CODA_DIR/layouts/${name}.sh"

    if [ ! -f "$layout_file" ]; then
        echo "Unknown layout: $name"
        echo "Available: $(ls "$_CODA_DIR/layouts/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' ' ')"
        return 1
    fi

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
        if [ -f "$dir/.git" ] && grep -q "gitdir: ./.bare" "$dir/.git" 2>/dev/null; then
            echo "$dir"
            return
        fi
        if [ -d "$dir/.bare" ]; then
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
