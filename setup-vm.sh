#!/usr/bin/env bash
#
# setup-vm.sh - Bootstrap an Ubuntu Server 24.04 VM for AI-assisted development
#
# Idempotent: safe to run multiple times. Skips already-installed components.
#
# Usage:
#   chmod +x setup-vm.sh
#   ./setup-vm.sh
#
# What this does NOT do:
#   - Install Tailscale (do that separately, see docs)
#   - Install OpenCode (install method may change, see https://opencode.ai)
#   - Configure SSH keys or firewall rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config if available
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
fi

NODE_MAJOR_VERSION="${NODE_MAJOR_VERSION:-20}"
NVIM_MIN_VERSION="${NVIM_MIN_VERSION:-0.11.0}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"

echo "=== Coda Setup ==="
echo ""
echo "Node.js version: $NODE_MAJOR_VERSION"
echo "Neovim min ver:  >= ${NVIM_MIN_VERSION}"
echo "Projects dir:    $PROJECTS_DIR"
echo ""

# --- System packages ---

echo "[1/7] Updating system packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

echo "[2/7] Installing core tools..."
sudo apt-get install -y -qq \
    git \
    tmux \
    mosh \
    curl \
    wget \
    build-essential \
    htop \
    jq \
    unzip \
    ca-certificates \
    gnupg

# --- Neovim ---

# version_ge <a> <b>: returns 0 (true) if a >= b
version_ge() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

echo "[3/7] Installing Neovim (requires >= ${NVIM_MIN_VERSION})..."
NVIM_INSTALLED_VERSION=""
if command -v nvim &>/dev/null; then
    NVIM_INSTALLED_VERSION="$(nvim --version | head -1 | sed 's/NVIM v//')"
fi

if [ -n "$NVIM_INSTALLED_VERSION" ] && version_ge "$NVIM_INSTALLED_VERSION" "$NVIM_MIN_VERSION"; then
    echo "  Neovim ${NVIM_INSTALLED_VERSION} already installed, skipping"
else
    if [ -n "$NVIM_INSTALLED_VERSION" ]; then
        echo "  Neovim ${NVIM_INSTALLED_VERSION} is too old (need >= ${NVIM_MIN_VERSION}), upgrading..."
    fi
    NVIM_ARCHIVE="nvim-linux-x86_64.tar.gz"
    NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/${NVIM_ARCHIVE}"
    NVIM_INSTALL_DIR="/opt/nvim"
    TMP_DIR="$(mktemp -d)"
    curl -fsSL "$NVIM_URL" -o "$TMP_DIR/${NVIM_ARCHIVE}"
    sudo rm -rf "$NVIM_INSTALL_DIR"
    sudo mkdir -p "$NVIM_INSTALL_DIR"
    sudo tar -C "$NVIM_INSTALL_DIR" --strip-components=1 -xzf "$TMP_DIR/${NVIM_ARCHIVE}"
    rm -rf "$TMP_DIR"
    # Symlink into /usr/local/bin so it's on PATH without shell restarts
    sudo ln -sf "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim
    echo "  Neovim $(nvim --version | head -1) installed to $NVIM_INSTALL_DIR"
fi

# --- Node.js ---

echo "[4/7] Installing Node.js ${NODE_MAJOR_VERSION}..."
if command -v node &>/dev/null; then
    echo "  Node.js $(node --version) already installed, skipping"
else
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_VERSION}.x nodistro main" \
        | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq nodejs
    echo "  Node.js $(node --version) installed"
fi

# --- fzf ---

echo "[5/7] Installing fzf..."
if command -v fzf &>/dev/null; then
    echo "  fzf already installed, skipping"
elif [ -d "$HOME/.fzf" ]; then
    echo "  fzf directory exists but binary not in PATH, re-running installer"
    "$HOME/.fzf/install" --all --no-bash --no-zsh --no-fish
else
    git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
    "$HOME/.fzf/install" --all --no-bash --no-zsh --no-fish
    echo "  fzf installed"
fi

# --- tmux Plugin Manager ---

echo "[6/7] Installing tmux plugin manager (TPM)..."
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ -d "$TPM_DIR/.git" ]; then
    echo "  TPM already installed, updating"
    git -C "$TPM_DIR" pull --quiet 2>/dev/null || true
elif [ -d "$TPM_DIR" ]; then
    echo "  TPM directory exists but incomplete, re-cloning"
    rm -rf "$TPM_DIR"
    git clone --quiet https://github.com/tmux-plugins/tpm "$TPM_DIR"
    echo "  TPM installed to $TPM_DIR"
else
    git clone --quiet https://github.com/tmux-plugins/tpm "$TPM_DIR"
    echo "  TPM installed to $TPM_DIR"
    echo "  After starting tmux, press prefix + I to install plugins"
fi

# --- Directory structure ---

echo "[7/7] Creating directory structure..."
mkdir -p "$PROJECTS_DIR"
mkdir -p "$HOME/.config/opencode"
echo "  Created $PROJECTS_DIR"
echo "  Created $HOME/.config/opencode"

# --- Summary ---

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Install Tailscale:  curl -fsSL https://tailscale.com/install.sh | sh"
echo "  2. Install OpenCode:   see https://opencode.ai/docs/installation"
echo "  3. Sign in to Claude:  claude auth login"
echo "  4. Copy tmux config:   cp tmux.conf ~/.tmux.conf"
echo "  5. Copy .env:          cp .env.example .env  (then edit)"
echo "  6. Source functions:   echo 'source $SCRIPT_DIR/shell-functions.sh' >> ~/.bashrc"
echo "  7. Enable Claude auth: coda auth"
echo "  8. Start tmux:         tmux"
echo "  9. Install plugins:    prefix + I (inside tmux)"
echo ""
