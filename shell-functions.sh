#!/usr/bin/env bash
#
# shell-functions.sh - OpenCode + tmux + git worktree workflow functions
#
# Source this in your .bashrc or .zshrc:
#   source ~/path/to/shell-functions.sh

_RDSF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_RDSF_SCRIPT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$_RDSF_SCRIPT_DIR/.env"
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SESSION_PREFIX="${SESSION_PREFIX:-oc-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
OPENCODE_BASE_PORT="${OPENCODE_BASE_PORT:-4096}"
OPENCODE_PORT_RANGE="${OPENCODE_PORT_RANGE:-10}"
MAX_CONCURRENT_SESSIONS="${MAX_CONCURRENT_SESSIONS:-5}"
AUTO_ATTACH_TMUX="${AUTO_ATTACH_TMUX:-true}"
DEFAULT_TMUX_SESSION="${DEFAULT_TMUX_SESSION:-default}"

# ---------------------------------------------------------------------------
# oc - Create or attach to an OpenCode tmux session
#
#   oc              -> uses current directory basename as session name
#   oc myproject    -> creates/attaches session "oc-myproject"
#   oc myproject /path/to/dir -> session in specific directory
# ---------------------------------------------------------------------------
oc() {
    local name="${1:-$(basename "$PWD")}"
    local dir="${2:-$PWD}"
    local session="${SESSION_PREFIX}${name}"

    local count
    count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${SESSION_PREFIX}" | wc -l | tr -d ' ')

    if ! tmux has-session -t "$session" 2>/dev/null; then
        if [ "$count" -ge "$MAX_CONCURRENT_SESSIONS" ]; then
            echo "At session limit ($MAX_CONCURRENT_SESSIONS). Kill one first:"
            ocs
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

# ---------------------------------------------------------------------------
# ocs - List all active OpenCode sessions
# ---------------------------------------------------------------------------
ocs() {
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name} (#{session_windows} windows, created #{session_created})' \
        2>/dev/null | grep "^${SESSION_PREFIX}")

    if [ -z "$sessions" ]; then
        echo "No active OpenCode sessions."
        echo "Start one with: oc <project-name>"
    else
        echo "Active OpenCode sessions:"
        echo "$sessions" | while read -r line; do
            echo "  $line"
        done
    fi
}

# ---------------------------------------------------------------------------
# tm - fzf-powered tmux session switcher with pane preview
# ---------------------------------------------------------------------------
tm() {
    if ! command -v fzf &>/dev/null; then
        echo "fzf not installed. Install it: sudo apt install fzf"
        return 1
    fi

    local session
    session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | fzf --preview 'tmux capture-pane -t {} -p -S -30' \
              --preview-window=right:50% \
              --header="Select session (ESC to cancel)")

    if [ -n "$session" ]; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
    fi
}

# ---------------------------------------------------------------------------
# setup-project - Clone a repo using the bare repository pattern
#
#   setup-project git@github.com:user/repo.git
#   setup-project https://github.com/user/repo.git
#   setup-project git@github.com:user/repo.git custom-name
# ---------------------------------------------------------------------------
setup-project() {
    local repo="$1"
    local name="${2:-$(basename "$repo" .git)}"

    if [ -z "$repo" ]; then
        echo "Usage: setup-project <repo-url> [project-name]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ -d "$project_dir/.bare" ]; then
        echo "Project already set up: $project_dir"
        echo "  Fetching latest..."
        git -C "$project_dir" fetch --all --quiet
        echo "  Done. Worktrees:"
        git -C "$project_dir" worktree list 2>/dev/null | sed 's/^/    /'
        return 0
    fi

    if [ -d "$project_dir" ]; then
        echo "Directory exists but is not a bare repo project: $project_dir"
        echo "  Remove it first or choose a different name."
        return 1
    fi

    echo "Setting up bare repo: $name"
    mkdir -p "$project_dir"
    git clone --bare "$repo" "$project_dir/.bare"
    echo "gitdir: ./.bare" > "$project_dir/.git"

    git -C "$project_dir" config remote."$GIT_REMOTE".fetch \
        "+refs/heads/*:refs/remotes/${GIT_REMOTE}/*"
    git -C "$project_dir" config worktree.useRelativePaths true
    git -C "$project_dir" fetch --all --quiet

    if [ ! -d "$project_dir/$DEFAULT_BRANCH" ]; then
        git -C "$project_dir" worktree add "$project_dir/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"
    fi

    echo "Done. Project at: $project_dir"
    echo "  Main worktree: $project_dir/$DEFAULT_BRANCH"
    echo ""
    echo "Next: cd $project_dir/$DEFAULT_BRANCH"
}

# ---------------------------------------------------------------------------
# feature - Create a worktree + OpenCode tmux session for a feature branch
#
#   feature auth                -> worktree from main, branch "auth"
#   feature auth develop        -> worktree from develop
#   feature auth develop myapp  -> explicit project name
#
# Must be run from inside a project directory (bare repo root or a worktree).
# ---------------------------------------------------------------------------
feature() {
    local branch="$1"
    local base="${2:-$DEFAULT_BRANCH}"
    local project_name="${3:-}"

    if [ -z "$branch" ]; then
        echo "Usage: feature <branch-name> [base-branch] [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a bare repo project. Run from a project directory."
        return 1
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local worktree_dir="$project_root/$branch"

    if [ -d "$worktree_dir" ]; then
        echo "Worktree already exists: $worktree_dir"
        echo "Attaching to existing session..."
        oc "${project_name}--${branch}" "$worktree_dir"
        return 0
    fi

    echo "Creating worktree: $branch (from $base)"
    git -C "$project_root" worktree add -b "$branch" "$worktree_dir" "$base"

    oc "${project_name}--${branch}" "$worktree_dir"
}

# ---------------------------------------------------------------------------
# done-feature - Clean up a feature: kill session, remove worktree, delete branch
#
#   done-feature auth           -> clean up "auth" worktree
#   done-feature auth myapp     -> explicit project name
# ---------------------------------------------------------------------------
done-feature() {
    local branch="$1"
    local project_name="${2:-}"

    if [ -z "$branch" ]; then
        echo "Usage: done-feature <branch-name> [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a bare repo project. Run from a project directory."
        return 1
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local session="${SESSION_PREFIX}${project_name}--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Cleaning up feature: $branch"

    if tmux has-session -t "$session" 2>/dev/null; then
        echo "  Killing tmux session: $session"
        tmux kill-session -t "$session"
    fi

    if [ -d "$worktree_dir" ]; then
        echo "  Removing worktree: $worktree_dir"
        git -C "$project_root" worktree remove "$worktree_dir" --force
    fi

    if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        echo "  Deleting local branch: $branch"
        git -C "$project_root" branch -D "$branch"
    fi

    echo "Done."
}

# ---------------------------------------------------------------------------
# list-features - Show all worktrees for the current project
# ---------------------------------------------------------------------------
list-features() {
    local project_root
    project_root=$(_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a bare repo project."
        return 1
    fi

    echo "Worktrees for $(basename "$project_root"):"
    git -C "$project_root" worktree list | while read -r line; do
        echo "  $line"
    done
}

# ---------------------------------------------------------------------------
# oc-serve - Start OpenCode in headless server mode on the next available port
#
#   oc-serve              -> find free port, start server
#   oc-serve 4099         -> use specific port
# ---------------------------------------------------------------------------
oc-serve() {
    local port="${1:-}"

    if [ -z "$port" ]; then
        port=$(_find_free_port)
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

# ---------------------------------------------------------------------------
# oc-auth-setup - Configure OpenCode to use Claude Code auth on this machine
#
# Linux uses ~/.claude/.credentials.json as the credential source. This helper
# verifies Claude Code auth is present and installs the OpenCode auth plugin.
#
#   oc-auth-setup         -> verify Claude auth, install plugin globally
# ---------------------------------------------------------------------------
oc-auth-setup() {
    if ! command -v claude &>/dev/null; then
        echo "claude CLI not found. Install Claude Code first."
        return 1
    fi

    if ! command -v opencode &>/dev/null; then
        echo "opencode not found. Install OpenCode first."
        return 1
    fi

    if ! claude auth status >/dev/null 2>&1; then
        echo "Claude Code is not authenticated yet. Run: claude auth login"
        return 1
    fi

    if [ ! -f "$HOME/.claude/.credentials.json" ]; then
        echo "Missing $HOME/.claude/.credentials.json"
        echo "Run 'claude' once after login so Claude Code writes Linux OAuth credentials."
        return 1
    fi

    echo "Installing OpenCode Claude auth plugin..."
    opencode plugin opencode-claude-auth -g

    echo ""
    echo "Claude Code auth status:"
    claude auth status
    echo ""
    echo "OpenCode Anthropic models:"
    opencode models anthropic
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_find_project_root() {
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

_find_free_port() {
    local port=$OPENCODE_BASE_PORT
    local max=$((OPENCODE_BASE_PORT + OPENCODE_PORT_RANGE))
    while [ "$port" -le "$max" ]; do
        # Use ss (always available on Ubuntu) with lsof as a fallback
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        elif command -v lsof &>/dev/null; then
            lsof -i :"$port" &>/dev/null 2>&1 || { echo "$port"; return; }
        else
            # Last resort: try binding
            (echo "" >/dev/tcp/127.0.0.1/"$port") 2>/dev/null || { echo "$port"; return; }
        fi
        port=$((port + 1))
    done
}

# ---------------------------------------------------------------------------
# Auto-attach tmux on SSH login
# ---------------------------------------------------------------------------
if [ "$AUTO_ATTACH_TMUX" = "true" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ]; then
    tmux attach -t "$DEFAULT_TMUX_SESSION" 2>/dev/null || tmux new -s "$DEFAULT_TMUX_SESSION"
fi
