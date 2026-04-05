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

# ===========================================================================
# coda — main entry point
# ===========================================================================
#
#   coda [name] [dir]        attach or create a session
#   coda ls                  list active sessions
#   coda switch              fzf session picker
#   coda serve [port]        headless OpenCode server
#   coda auth                wire Claude Code credentials
#   coda project <cmd>       manage projects
#   coda feature <cmd>       manage feature worktrees
#   coda help                show this help
#
coda() {
    local subcmd="${1:-}"

    case "$subcmd" in
        ls)               _coda_ls ;;
        switch)           _coda_switch ;;
        attach)           shift; _coda_attach "$@" ;;
        auth)             _coda_auth ;;
        serve)            shift; _coda_serve "$@" ;;
        project)          shift; _coda_project "$@" ;;
        feature)          shift; _coda_feature "$@" ;;
        help|--help|-h)   _coda_help ;;
        "")               _coda_attach ;;
        *)                _coda_attach "$@" ;;
    esac
}

# ===========================================================================
# coda [name] [dir]
# Attach to an existing session or create a new one running OpenCode.
# ===========================================================================
_coda_attach() {
    local name="${1:-$(basename "$PWD")}"
    local dir="${2:-$PWD}"

    # Strip prefix if the caller already included it (e.g. coda coda-myapp)
    name="${name#"$SESSION_PREFIX"}"
    local session="${SESSION_PREFIX}${name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        local count
        count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
            | grep -c "^${SESSION_PREFIX}" || true)

        if [ "$count" -ge "$MAX_CONCURRENT_SESSIONS" ]; then
            echo "At session limit ($MAX_CONCURRENT_SESSIONS). Use 'coda ls' to see running sessions."
            return 1
        fi

        tmux new-session -d -s "$session" -c "$dir" "opencode; exec \$SHELL"
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
        add)  shift; _coda_project_add "$@" ;;
        ls)   _coda_project_ls ;;
        ""|help) echo "Usage: coda project <add|ls>" ;;
        *)    echo "Unknown project subcommand: $subcmd"; echo "Usage: coda project <add|ls>"; return 1 ;;
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

  coda project add <url> [name]   Clone a repo as a bare project
  coda project ls                 List projects in PROJECTS_DIR

  coda feature start <branch> [base] [project]   New worktree + session
  coda feature done  <branch> [project]          Teardown worktree + session
  coda feature ls                                List worktrees for this project

  coda help                   Show this help

EXAMPLES
  coda project add git@github.com:user/myapp.git
  cd ~/projects/myapp/main
  coda feature start auth
  coda ls
  coda switch
  coda feature done auth

Run 'man coda' for the full manual.
EOF
}

# ===========================================================================
# Internal helpers
# ===========================================================================

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
