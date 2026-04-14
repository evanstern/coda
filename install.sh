#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
if [ -d "$PROJECT_ROOT/.bare" ] && [ -d "$PROJECT_ROOT/main" ]; then
    STABLE_DIR="$PROJECT_ROOT/main"
else
    STABLE_DIR="$SCRIPT_DIR"
fi

# --- Parse CLI options (override .env and defaults) ---

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Install coda core: shell functions, completions, man page, and Go helper.

Options:
  --projects-dir DIR     Where projects live (default: ~/projects)
  --skip-go              Don't build the coda-core Go binary
  --skip-mcp             Don't set up the MCP server
  --skip-man             Don't install the man page
  --help                 Show this help

All options can also be set via .env or environment variables:
  PROJECTS_DIR, SKIP_GO, SKIP_MCP, SKIP_MAN
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --projects-dir)  PROJECTS_DIR="$2"; shift 2 ;;
        --projects-dir=*) PROJECTS_DIR="${1#*=}"; shift ;;
        --skip-go)       SKIP_GO=true; shift ;;
        --skip-mcp)      SKIP_MCP=true; shift ;;
        --skip-man)      SKIP_MAN=true; shift ;;
        --help|-h)       usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# --- Load .env (CLI options above take precedence) ---

if [ ! -f "$SCRIPT_DIR/.env" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo "Created .env from template. Edit $SCRIPT_DIR/.env to customise."
    echo ""
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SKIP_GO="${SKIP_GO:-false}"
SKIP_MCP="${SKIP_MCP:-false}"
SKIP_MAN="${SKIP_MAN:-false}"

# --- Helpers ---

step()  { echo ""; echo "==> $*"; }
ok()    { echo "    [ok] $*"; }
info()  { echo "    $*"; }
warn()  { echo "    [warn] $*"; }

# --- Check core dependencies ---

step "Checking core dependencies"

_missing=0
for dep in bash git tmux; do
    if command -v "$dep" &>/dev/null; then
        ok "$dep"
    else
        warn "$dep is REQUIRED but not found"
        _missing=1
    fi
done

if [ "$_missing" -eq 1 ]; then
    echo ""
    echo "ERROR: Missing required dependencies. Install them and re-run."
    exit 1
fi

_optional_missing=()
for dep in jq fzf curl; do
    if command -v "$dep" &>/dev/null; then
        ok "$dep"
    else
        _optional_missing+=("$dep")
    fi
done

if ! command -v go &>/dev/null; then
    _optional_missing+=("go")
fi
if ! command -v node &>/dev/null; then
    _optional_missing+=("node")
fi

if [ ${#_optional_missing[@]} -gt 0 ]; then
    info "Optional (some features disabled without these): ${_optional_missing[*]}"
fi

# --- Banner ---

echo ""
echo "===================================================="
echo "  coda v$(grep -oP 'CODA_VERSION="\K[^"]+' "$SCRIPT_DIR/shell-functions.sh" 2>/dev/null || echo '?') — Install"
echo "===================================================="
echo ""

# ===========================================================================
# 1. coda-core Go binary (layout snapshot helper)
# ===========================================================================

step "[1/5] coda-core binary"

if [ "$SKIP_GO" = "true" ]; then
    info "Skipping (--skip-go)"
elif ! command -v go &>/dev/null; then
    info "Go not found — skipping coda-core build"
    info "Layout snapshot will not be available"
else
    _coda_core_stale=false
    _coda_core_installed="$HOME/.local/bin/coda-core"
    mkdir -p "$(dirname "$_coda_core_installed")"
    if [ ! -f "$_coda_core_installed" ]; then
        _coda_core_stale=true
    else
        for _gofile in "$SCRIPT_DIR"/cmd/coda-core/*.go; do
            [ -f "$_gofile" ] && [ "$_gofile" -nt "$_coda_core_installed" ] && _coda_core_stale=true
        done
    fi
    if [ "$_coda_core_stale" = "false" ]; then
        ok "coda-core — up to date"
    else
        info "Building coda-core..."
        (cd "$SCRIPT_DIR" && go build -o "$_coda_core_installed" ./cmd/coda-core/)
        ok "coda-core built and installed to ~/.local/bin/"
    fi
fi

# ===========================================================================
# 2. MCP server
# ===========================================================================

step "[2/5] MCP server"

MCP_DIR="$STABLE_DIR/mcp-server"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
MCP_SERVER_PATH="$STABLE_DIR/mcp-server/server.js"

if [ "$SKIP_MCP" = "true" ]; then
    info "Skipping (--skip-mcp)"
elif [ ! -d "$MCP_DIR" ]; then
    info "MCP server directory not found — skipping"
elif ! command -v node &>/dev/null; then
    info "Node.js not found — skipping MCP server"
    info "Install Node.js to enable MCP support for OpenCode agents"
else
    if [ ! -d "$MCP_DIR/node_modules" ] || [ "$MCP_DIR/package.json" -nt "$MCP_DIR/node_modules/.package-lock.json" ]; then
        info "Installing MCP server dependencies..."
        (cd "$MCP_DIR" && npm install --no-fund --no-audit --loglevel=error)
    fi

    mkdir -p "$HOME/.config/opencode"
    if [ ! -f "$OPENCODE_CONFIG" ]; then
        printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {}\n}\n' > "$OPENCODE_CONFIG"
    fi

    if command -v jq &>/dev/null; then
        _mcp_current=$(jq -r '.mcp.coda.command[1] // ""' "$OPENCODE_CONFIG" 2>/dev/null || true)
        if [ "$_mcp_current" = "$MCP_SERVER_PATH" ]; then
            ok "MCP server — already registered in opencode.json"
        else
            jq --arg path "$MCP_SERVER_PATH" '.mcp.coda = {"type": "local", "command": ["node", $path], "enabled": true}' \
                "$OPENCODE_CONFIG" > "$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
            ok "MCP server registered in opencode.json"
        fi
    else
        info "jq not found — add MCP manually to opencode.json:"
        info "  {\"mcp\":{\"coda\":{\"type\":\"local\",\"command\":[\"node\",\"$MCP_SERVER_PATH\"],\"enabled\":true}}}"
    fi
fi

# ===========================================================================
# 3. Shell functions and completions
# ===========================================================================

step "[3/5] Shell functions and completions"

RC_FILES=()
[ -f "$HOME/.bashrc" ] && RC_FILES+=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ] && RC_FILES+=("$HOME/.zshrc")

SOURCE_LINE="source \"$STABLE_DIR/shell-functions.sh\""
SOURCE_LINES=("$SOURCE_LINE")
if [ "$SCRIPT_DIR" != "$STABLE_DIR" ]; then
    SOURCE_LINES+=("[ -f \"$SCRIPT_DIR/shell-functions.sh\" ] && source \"$SCRIPT_DIR/shell-functions.sh\"")
fi

if [ "${#RC_FILES[@]}" -gt 0 ]; then
    for SHELL_RC in "${RC_FILES[@]}"; do
        sed -i '/# coda — OpenCode session manager/d' "$SHELL_RC"
        sed -i '\|source .*/shell-functions\.sh|d' "$SHELL_RC"
        printf '\n# coda — OpenCode session manager\n' >> "$SHELL_RC"
        for line in "${SOURCE_LINES[@]}"; do
            printf '%s\n' "$line" >> "$SHELL_RC"
        done
        ok "Shell functions updated in $SHELL_RC"
    done
else
    info "No shell RC found. Add manually:"
    info "  $SOURCE_LINE"
fi

if [ -f "$HOME/.bashrc" ]; then
    COMPLETION_LINES=("source \"$STABLE_DIR/completions/coda.bash\"")
    if [ "$SCRIPT_DIR" != "$STABLE_DIR" ]; then
        COMPLETION_LINES+=("[ -f \"$SCRIPT_DIR/completions/coda.bash\" ] && source \"$SCRIPT_DIR/completions/coda.bash\"")
    fi
    sed -i '/# coda tab completion/d' "$HOME/.bashrc"
    sed -i '\|source .*/completions/coda\.bash|d' "$HOME/.bashrc"
    printf '\n# coda tab completion\n' >> "$HOME/.bashrc"
    for line in "${COMPLETION_LINES[@]}"; do
        printf '%s\n' "$line" >> "$HOME/.bashrc"
    done
    ok "Bash completion updated in ~/.bashrc"
fi

if [ -f "$HOME/.zshrc" ]; then
    if [ "$SCRIPT_DIR" != "$STABLE_DIR" ]; then
        FPATH_LINE="fpath=($SCRIPT_DIR/completions $STABLE_DIR/completions \$fpath)"
    else
        FPATH_LINE="fpath=($STABLE_DIR/completions \$fpath)"
    fi
    sed -i '/# coda tab completion/d' "$HOME/.zshrc"
    sed -i '\|completions/coda|d' "$HOME/.zshrc"
    printf '\n# coda tab completion\n%s\n' "$FPATH_LINE" >> "$HOME/.zshrc"
    if ! grep -Eq '(^|[[:space:];&|])compinit([[:space:];&|]|$)' "$HOME/.zshrc"; then
        printf 'autoload -Uz compinit && compinit\n' >> "$HOME/.zshrc"
    fi
    ok "Zsh completion updated in ~/.zshrc"
fi

# ===========================================================================
# 4. Man page
# ===========================================================================

step "[4/5] Man page"

if [ "$SKIP_MAN" = "true" ]; then
    info "Skipping (--skip-man)"
else
    MAN_DIR="/usr/local/share/man/man1"
    if sudo mkdir -p "$MAN_DIR" 2>/dev/null; then
        sudo cp "$SCRIPT_DIR/man/coda.1" "$MAN_DIR/coda.1"
        sudo mandb -q 2>/dev/null || true
        ok "Man page installed (man coda)"
    else
        info "Could not install man page (no sudo?)"
    fi
fi

# ===========================================================================
# 5. Directories and .env
# ===========================================================================

step "[5/5] Directories"

mkdir -p "$PROJECTS_DIR"
mkdir -p "$HOME/.config/coda/layouts"
mkdir -p "$HOME/.config/coda/profiles"
mkdir -p "$HOME/.config/coda/hooks"
mkdir -p "$HOME/.config/coda/providers"
mkdir -p "$HOME/.config/coda/notifications"
mkdir -p "$HOME/.config/coda/plugins"
mkdir -p "$HOME/.local/bin"
ok "$PROJECTS_DIR, ~/.config/coda/{layouts,profiles,hooks,providers,notifications,plugins}"

# ===========================================================================
# Done
# ===========================================================================

echo ""
echo "===================================================="
echo "  Install complete!"
echo "===================================================="
echo ""
echo "Reload your shell:"
[ -f "$HOME/.bashrc" ] && echo "  source ~/.bashrc"
[ -f "$HOME/.zshrc" ] && echo "  source ~/.zshrc"
echo ""
echo "Install plugins:"
echo "  coda plugin install git@github.com:evanstern/coda-provider-claude-auth.git"
echo "  coda plugin install git@github.com:evanstern/coda-watch.git"
echo "  coda plugin install git@github.com:evanstern/coda-github.git"
echo ""
echo "Start your first project:"
echo "  coda project start --repo <git-repo-url>"
