#!/usr/bin/env bash
#
# install.sh - Bootstrap an Ubuntu Server VM for AI-assisted development
#
# Idempotent: safe to run multiple times. Each step checks whether it has
# already been done and skips or updates as appropriate.
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# Overrides (environment variables or .env):
#   SKIP_TAILSCALE=true      Skip Tailscale installation
#   SKIP_OPENCODE=true       Skip OpenCode installation
#   SKIP_CLAUDE=true         Skip Claude Code CLI installation
#   SKIP_OHMYPOSH=true       Skip Oh My Posh installation
#   SKIP_YAZI=true           Skip yazi file manager installation
#   SKIP_LAZYGIT=true        Skip lazygit installation
#   NODE_MAJOR_VERSION=20    Node.js major version (default: 20)
#   NVIM_MIN_VERSION=0.11.0  Minimum acceptable Neovim version
#   PROJECTS_DIR=~/projects  Where git repos live

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve a stable path for lines written to shell RC files.
# In a bare-repo + worktree layout, SCRIPT_DIR may point to an ephemeral
# feature worktree that gets deleted by "coda feature done".  We detect this
# and pin to the permanent "main" worktree instead.
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
if [ -d "$PROJECT_ROOT/.bare" ] && [ -d "$PROJECT_ROOT/main" ]; then
    STABLE_DIR="$PROJECT_ROOT/main"
else
    STABLE_DIR="$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Load config — create .env from template if it doesn't exist yet
# ---------------------------------------------------------------------------

if [ ! -f "$SCRIPT_DIR/.env" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo "Created .env from template. Edit $SCRIPT_DIR/.env to customise."
    echo ""
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

# Defaults (environment or .env take precedence over these)
NODE_MAJOR_VERSION="${NODE_MAJOR_VERSION:-20}"
NVIM_MIN_VERSION="${NVIM_MIN_VERSION:-0.11.0}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-false}"
SKIP_OPENCODE="${SKIP_OPENCODE:-false}"
SKIP_CLAUDE="${SKIP_CLAUDE:-false}"
SKIP_OHMYPOSH="${SKIP_OHMYPOSH:-false}"
SKIP_YAZI="${SKIP_YAZI:-false}"
SKIP_LAZYGIT="${SKIP_LAZYGIT:-false}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

step() { echo ""; echo "==> $*"; }
ok()   { echo "    [ok] $*"; }
info() { echo "    $*"; }

version_ge() {
    # Returns 0 (true) if version $1 >= $2
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

# Detect architecture for Neovim download
case "$(uname -m)" in
    x86_64)  NVIM_ARCH="nvim-linux-x86_64" ;;
    aarch64) NVIM_ARCH="nvim-linux-arm64"  ;;
    *)
        echo "Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo "===================================================="
echo "  Coda — Install"
echo "===================================================="
echo ""
echo "  Node.js version : v${NODE_MAJOR_VERSION}"
echo "  Neovim minimum  : >= ${NVIM_MIN_VERSION}"
echo "  Projects dir    : ${PROJECTS_DIR}"
echo "  Tailscale       : $([ "$SKIP_TAILSCALE" = "true" ] && echo "skip" || echo "install")"
echo "  OpenCode        : $([ "$SKIP_OPENCODE"  = "true" ] && echo "skip" || echo "install")"
echo "  Claude CLI      : $([ "$SKIP_CLAUDE"    = "true" ] && echo "skip" || echo "install")"
echo "  Oh My Posh      : $([ "$SKIP_OHMYPOSH" = "true" ] && echo "skip" || echo "install")"
echo "  yazi            : $([ "$SKIP_YAZI"     = "true" ] && echo "skip" || echo "install")"
echo "  lazygit         : $([ "$SKIP_LAZYGIT"  = "true" ] && echo "skip" || echo "install")"
echo ""

# ===========================================================================
# 1. System packages
# ===========================================================================

step "[1/13] System packages"

sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    git \
    tmux \
    mosh \
    curl \
    wget \
    build-essential \
    htop \
    jq \
    lsof \
    unzip \
    ca-certificates \
    gnupg

ok "Core packages installed"

# ===========================================================================
# 2. Neovim
# ===========================================================================

step "[2/13] Neovim (>= ${NVIM_MIN_VERSION})"

NVIM_INSTALLED_VERSION=""
if command -v nvim &>/dev/null; then
    NVIM_INSTALLED_VERSION="$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')"
fi

if [ -n "$NVIM_INSTALLED_VERSION" ] && version_ge "$NVIM_INSTALLED_VERSION" "$NVIM_MIN_VERSION"; then
    ok "Neovim ${NVIM_INSTALLED_VERSION} — up to date"
else
    if [ -n "$NVIM_INSTALLED_VERSION" ]; then
        info "Upgrading from ${NVIM_INSTALLED_VERSION} (need >= ${NVIM_MIN_VERSION})..."
    else
        info "Installing Neovim..."
    fi

    NVIM_ARCHIVE="${NVIM_ARCH}.tar.gz"
    NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/${NVIM_ARCHIVE}"
    NVIM_INSTALL_DIR="/opt/nvim"
    TMP_DIR="$(mktemp -d)"

    curl -fsSL "$NVIM_URL" -o "$TMP_DIR/${NVIM_ARCHIVE}"
    sudo rm -rf "$NVIM_INSTALL_DIR"
    sudo mkdir -p "$NVIM_INSTALL_DIR"
    sudo tar -C "$NVIM_INSTALL_DIR" --strip-components=1 -xzf "$TMP_DIR/${NVIM_ARCHIVE}"
    rm -rf "$TMP_DIR"
    sudo ln -sf "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim

    ok "Neovim $(nvim --version | head -1) installed to $NVIM_INSTALL_DIR"
fi

# ===========================================================================
# 3. Node.js
# ===========================================================================

step "[3/13] Node.js ${NODE_MAJOR_VERSION}"

INSTALLED_NODE_MAJOR=0
if command -v node &>/dev/null; then
    INSTALLED_NODE_MAJOR="$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)"
fi

if [ "${INSTALLED_NODE_MAJOR}" -ge "${NODE_MAJOR_VERSION}" ] 2>/dev/null; then
    ok "Node.js $(node --version) — up to date (major >= ${NODE_MAJOR_VERSION})"
else
    info "Installing Node.js ${NODE_MAJOR_VERSION} via NodeSource..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_VERSION}.x nodistro main" \
        | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq nodejs
    ok "Node.js $(node --version) installed"
fi

# ===========================================================================
# 4. OpenCode
# ===========================================================================

step "[4/13] OpenCode"

mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
# Add to ~/.bashrc or ~/.zshrc:
export PATH="$HOME/.npm-global/bin:$PATH"

if [ "$SKIP_OPENCODE" = "true" ]; then
    info "Skipping (SKIP_OPENCODE=true)"
elif command -v opencode &>/dev/null; then
    ok "opencode — already installed"
else
    info "Installing OpenCode..."
    npm install -g opencode-ai@latest
    ok "OpenCode installed"
fi

# ===========================================================================
# 5. Claude Code CLI
# ===========================================================================

step "[5/13] Claude Code CLI"

if [ "$SKIP_CLAUDE" = "true" ]; then
    info "Skipping (SKIP_CLAUDE=true)"
elif command -v claude &>/dev/null; then
    ok "claude — already installed"
else
    info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    ok "Claude Code CLI installed"
fi

# ===========================================================================
# 6. fzf
# ===========================================================================

step "[6/13] fzf"

if command -v fzf &>/dev/null; then
    ok "fzf $(fzf --version 2>/dev/null | head -1) — already installed"
elif [ -d "$HOME/.fzf/.git" ]; then
    info "Updating existing fzf..."
    git -C "$HOME/.fzf" pull --quiet
    "$HOME/.fzf/install" --bin
    sudo ln -sf "$HOME/.fzf/bin/fzf" /usr/local/bin/fzf
    ok "fzf updated"
else
    info "Installing fzf..."
    git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
    "$HOME/.fzf/install" --bin
    sudo ln -sf "$HOME/.fzf/bin/fzf" /usr/local/bin/fzf
    ok "fzf installed"
fi

# ===========================================================================
# 7. yazi (terminal file manager — used by four-pane layout)
# ===========================================================================

step "[7/13] yazi"

if [ "$SKIP_YAZI" = "true" ]; then
    info "Skipping (SKIP_YAZI=true)"
elif command -v yazi &>/dev/null; then
    ok "yazi $(yazi --version 2>/dev/null | head -1) — already installed"
else
    info "Installing yazi..."
    case "$(uname -m)" in
        x86_64)  YAZI_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) YAZI_ARCH="aarch64-unknown-linux-gnu" ;;
        *)       YAZI_ARCH="" ;;
    esac
    if [ -n "$YAZI_ARCH" ]; then
        TMP_DIR="$(mktemp -d)"
        curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${YAZI_ARCH}.zip" \
            -o "$TMP_DIR/yazi.zip"
        unzip -o "$TMP_DIR/yazi.zip" -d "$TMP_DIR" >/dev/null
        sudo install "$TMP_DIR/yazi-${YAZI_ARCH}/yazi" /usr/local/bin/yazi
        rm -rf "$TMP_DIR"
        ok "yazi $(yazi --version 2>/dev/null | head -1) installed"
    else
        info "Unsupported architecture for yazi: $(uname -m)"
    fi
fi

# ===========================================================================
# 8. lazygit (terminal git UI — used by four-pane layout)
# ===========================================================================

step "[8/13] lazygit"

if [ "$SKIP_LAZYGIT" = "true" ]; then
    info "Skipping (SKIP_LAZYGIT=true)"
elif command -v lazygit &>/dev/null; then
    ok "lazygit $(lazygit --version 2>/dev/null | sed 's/.*version=//' | cut -d, -f1) — already installed"
else
    info "Installing lazygit..."
    LAZYGIT_VERSION="$(curl -fsSL 'https://api.github.com/repos/jesseduffield/lazygit/releases/latest' | jq -r '.tag_name' | sed 's/v//')"
    case "$(uname -m)" in
        x86_64)  LAZYGIT_ARCH="x86_64" ;;
        aarch64) LAZYGIT_ARCH="arm64"   ;;
        *)       LAZYGIT_ARCH="" ;;
    esac
    if [ -n "$LAZYGIT_ARCH" ]; then
        TMP_DIR="$(mktemp -d)"
        curl -fsSL "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz" \
            -o "$TMP_DIR/lazygit.tar.gz"
        tar xf "$TMP_DIR/lazygit.tar.gz" -C "$TMP_DIR" lazygit
        sudo install "$TMP_DIR/lazygit" /usr/local/bin/lazygit
        rm -rf "$TMP_DIR"
        ok "lazygit ${LAZYGIT_VERSION} installed"
    else
        info "Unsupported architecture for lazygit: $(uname -m)"
    fi
fi

# ===========================================================================
# 9. Oh My Posh
# ===========================================================================

step "[9/13] Oh My Posh"

if [ "$SKIP_OHMYPOSH" = "true" ]; then
    info "Skipping (SKIP_OHMYPOSH=true)"
elif command -v oh-my-posh &>/dev/null; then
    ok "oh-my-posh $(oh-my-posh version 2>/dev/null) — already installed"
else
    info "Installing Oh My Posh..."
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin"
    ok "Oh My Posh installed to ~/.local/bin"
fi

# ===========================================================================
# 10. tmux Plugin Manager (TPM)
# ===========================================================================

step "[10/13] tmux Plugin Manager (TPM)"

TPM_DIR="$HOME/.tmux/plugins/tpm"

if [ -d "$TPM_DIR/.git" ]; then
    git -C "$TPM_DIR" pull --quiet 2>/dev/null || true
    ok "TPM updated"
elif [ -d "$TPM_DIR" ]; then
    info "Incomplete TPM directory found, re-cloning..."
    rm -rf "$TPM_DIR"
    git clone --quiet https://github.com/tmux-plugins/tpm "$TPM_DIR"
    ok "TPM installed"
else
    git clone --quiet https://github.com/tmux-plugins/tpm "$TPM_DIR"
    ok "TPM installed to $TPM_DIR"
fi

# ===========================================================================
# 11. Tailscale
# ===========================================================================

step "[11/13] Tailscale"

if [ "$SKIP_TAILSCALE" = "true" ]; then
    info "Skipping (SKIP_TAILSCALE=true)"
elif command -v tailscale &>/dev/null; then
    ok "Tailscale $(tailscale --version 2>/dev/null | head -1) — already installed"
else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
fi

# ===========================================================================
# 12. coda-core (Go helper binary)
# ===========================================================================

step "[12/13] coda-core binary"

if [ -f "$SCRIPT_DIR/coda-core" ] && [ "$SCRIPT_DIR/coda-core" -nt "$SCRIPT_DIR/cmd/coda-core/main.go" ]; then
    ok "coda-core — up to date"
elif command -v go &>/dev/null; then
    info "Building coda-core..."
    (cd "$SCRIPT_DIR" && go build -o coda-core ./cmd/coda-core/)
    cp "$SCRIPT_DIR/coda-core" "$HOME/.local/bin/coda-core"
    ok "coda-core built and installed to ~/.local/bin/"
else
    info "Go not found — skipping coda-core build"
    info "Shell functions will use built-in fallbacks"
fi

# ===========================================================================
# 13. Config files, shell integration, SSH
# ===========================================================================

step "[13/13] Config files, completions, and man page"

# --- tmux config ---

if [ -f "$HOME/.tmux.conf" ] && diff -q "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf" &>/dev/null; then
    ok "~/.tmux.conf — up to date"
else
    if [ -f "$HOME/.tmux.conf" ]; then
        cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.backup.$(date +%Y%m%d%H%M%S)"
    fi
    cp "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf"
    ok "~/.tmux.conf installed"
fi

# --- OpenCode TUI keybinds ---

mkdir -p "$HOME/.config/opencode"

if [ -f "$HOME/.config/opencode/tui.json" ] && diff -q "$SCRIPT_DIR/tui.json.example" "$HOME/.config/opencode/tui.json" &>/dev/null; then
    ok "~/.config/opencode/tui.json — up to date"
else
    if [ -f "$HOME/.config/opencode/tui.json" ]; then
        cp "$HOME/.config/opencode/tui.json" "$HOME/.config/opencode/tui.json.backup.$(date +%Y%m%d%H%M%S)"
    fi
    cp "$SCRIPT_DIR/tui.json.example" "$HOME/.config/opencode/tui.json"
    ok "~/.config/opencode/tui.json installed"
fi

# --- Helper scripts (tmux pane picker, etc.) ---

mkdir -p "$HOME/.local/bin"
for script in "$SCRIPT_DIR"/scripts/*; do
    [ -f "$script" ] || continue
    name="$(basename "${script%.sh}")"
    cp "$script" "$HOME/.local/bin/$name"
    chmod +x "$HOME/.local/bin/$name"
done
ok "Helper scripts installed to ~/.local/bin/"

# --- Shell functions and completions ---

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
    info "No shell RC found. Add these lines manually:"
    info "  $SOURCE_LINE"
    if [ "$SCRIPT_DIR" != "$STABLE_DIR" ]; then
        info "  [ -f \"$SCRIPT_DIR/shell-functions.sh\" ] && source \"$SCRIPT_DIR/shell-functions.sh\""
    fi
fi

# --- Tab completion ---

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

# --- Oh My Posh prompt ---

if [ "$SKIP_OHMYPOSH" != "true" ] && command -v oh-my-posh &>/dev/null; then
    if [ -f "$HOME/.bashrc" ]; then
        if grep -qF "oh-my-posh init" "$HOME/.bashrc" 2>/dev/null; then
            ok "Oh My Posh — already initialized in ~/.bashrc"
        else
            printf '\n# Oh My Posh prompt\nexport PATH="$HOME/.local/bin:$PATH"\neval "$(oh-my-posh init bash)"\n' >> "$HOME/.bashrc"
            ok "Oh My Posh initialized in ~/.bashrc"
        fi
    fi

    if [ -f "$HOME/.zshrc" ]; then
        if grep -qF "oh-my-posh init" "$HOME/.zshrc" 2>/dev/null; then
            ok "Oh My Posh — already initialized in ~/.zshrc"
        else
            printf '\n# Oh My Posh prompt\nexport PATH="$HOME/.local/bin:$PATH"\neval "$(oh-my-posh init zsh)"\n' >> "$HOME/.zshrc"
            ok "Oh My Posh initialized in ~/.zshrc"
        fi
    fi
fi

# --- Man page ---

MAN_DIR="/usr/local/share/man/man1"
if sudo mkdir -p "$MAN_DIR" 2>/dev/null; then
    sudo cp "$SCRIPT_DIR/man/coda.1" "$MAN_DIR/coda.1"
    sudo mandb -q 2>/dev/null || true
    ok "Man page installed (man coda)"
else
    info "Could not install man page (no sudo?). Install manually:"
    info "  sudo cp $SCRIPT_DIR/man/coda.1 /usr/local/share/man/man1/"
fi

# --- SSH server keepalive ---

if grep -q "^ClientAliveInterval" /etc/ssh/sshd_config 2>/dev/null; then
    ok "SSH keepalive — already configured"
else
    printf '\nClientAliveInterval 60\nClientAliveCountMax 3\n' \
        | sudo tee -a /etc/ssh/sshd_config >/dev/null
    sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
    ok "SSH keepalive configured (60s interval, 3 retries)"
fi

# --- Directories ---

mkdir -p "$PROJECTS_DIR"
mkdir -p "$HOME/.config/opencode"
mkdir -p "${CODA_LAYOUTS_DIR:-$HOME/.config/coda/layouts}"
mkdir -p "${CODA_PROFILES_DIR:-$HOME/.config/coda/profiles}"
ok "Directories: $PROJECTS_DIR, ~/.config/opencode, ~/.config/coda/{layouts,profiles}"

# --- tmux plugins (headless install via TPM batch mode) ---

if [ -x "$TPM_DIR/bin/install_plugins" ] && [ -f "$HOME/.tmux.conf" ]; then
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins" \
        "$TPM_DIR/bin/install_plugins" 2>/dev/null || true
    ok "tmux plugins installed"
fi

# ===========================================================================
# Done
# ===========================================================================

echo ""
echo "===================================================="
echo "  Install complete!"
echo "===================================================="
echo ""
echo "Next steps:"
echo ""

if [ "$SKIP_TAILSCALE" != "true" ] && command -v tailscale &>/dev/null; then
    if ! tailscale status &>/dev/null 2>&1; then
        echo "  1. Connect to Tailscale:"
        echo "       sudo tailscale up"
        echo ""
    fi
fi

echo "  Reload your shell:"
if [ -f "$HOME/.bashrc" ]; then
    echo "       source ~/.bashrc"
fi
if [ -f "$HOME/.zshrc" ]; then
    echo "       source ~/.zshrc"
fi
echo ""
echo "  Provider-aware OpenCode setup:"
echo "       # Claude path"
echo "       claude auth login"
echo "       coda auth"
echo ""
echo "       # CLIProxyAPI path"
echo "       # edit .env: CODA_PROVIDER_MODE=cliproxyapi"
echo "       # edit .env: CLIPROXYAPI_BASE_URL=http://localhost:8317/v1"
echo "       coda auth"
echo "       coda provider status"
echo ""
echo "  Start a tmux session:"
echo "       tmux"
echo ""
echo "  Start your first project:"
echo "       coda project start --repo <git-repo-url>"
echo ""
