#!/usr/bin/env bash

_provider_auth() {
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

    local creds_path="${CLAUDE_CREDENTIALS_PATH:-$HOME/.claude/.credentials.json}"
    if [ ! -f "$creds_path" ]; then
        echo "Missing $creds_path"
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
