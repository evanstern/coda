#!/usr/bin/env bash

_provider_status() {
    local config_path
    config_path=$(_coda_resolve_opencode_config_path)

    echo "Provider mode: claude-auth"
    echo "OpenCode config: $config_path"

    if command -v claude &>/dev/null; then
        echo "claude CLI: found"
        if claude auth status >/dev/null 2>&1; then
            echo "Claude auth: authenticated"
        else
            echo "Claude auth: not authenticated (run: claude auth login)"
        fi
    else
        echo "claude CLI: missing (run install.sh)"
    fi

    if command -v opencode &>/dev/null; then
        echo "opencode: found"
    else
        echo "opencode: missing"
    fi
}
