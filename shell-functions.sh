#!/usr/bin/env bash
#
# shell-functions.sh — coda: OpenCode session and project manager
#
# Source in .bashrc or .zshrc:
#   source ~/coda/shell-functions.sh

_CODA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_CODA_ENV_FILE="${CODA_ENV_FILE:-$_CODA_DIR/.env}"

if [ "${CODA_SKIP_ENV:-false}" != "true" ] && [ -f "$_CODA_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$_CODA_ENV_FILE"; set +a
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SESSION_PREFIX="${SESSION_PREFIX:-coda-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
NEW_PROJECT_GITHUB_OWNER="${NEW_PROJECT_GITHUB_OWNER:-}"

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
CLAUDE_CREDENTIALS_PATH="${CLAUDE_CREDENTIALS_PATH:-$HOME/.claude/.credentials.json}"
CODA_HOOKS_DIR="${CODA_HOOKS_DIR:-$HOME/.config/coda/hooks}"

# Load modules
for _coda_mod in helpers hooks core project feature layout provider profile watch github; do
    # shellcheck source=/dev/null
    source "$_CODA_DIR/lib/${_coda_mod}.sh"
done
unset _coda_mod

if [ -n "${CODA_OPENCODE_CONFIG_PATH:-}" ]; then
    export OPENCODE_CONFIG="$(_coda_resolve_opencode_config_path)"
fi

# Auto-attach tmux on SSH login
if [ "$AUTO_ATTACH_TMUX" = "true" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ]; then
    tmux attach -t "$DEFAULT_TMUX_SESSION" 2>/dev/null || tmux new -s "$DEFAULT_TMUX_SESSION"
fi
