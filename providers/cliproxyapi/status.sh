#!/usr/bin/env bash

_provider_status() {
    local config_path
    config_path=$(_coda_resolve_opencode_config_path)

    if command -v coda-core &>/dev/null; then
        CODA_API_KEY="${CLIPROXYAPI_API_KEY:-}" coda-core provider status \
            --mode "cliproxyapi" \
            --config "$config_path" \
            --base-url "${CLIPROXYAPI_BASE_URL:-}" \
            --health-url "${CLIPROXYAPI_HEALTH_URL:-}" \
            --has-opencode "$(command -v opencode &>/dev/null && echo true || echo false)"
        return $?
    fi

    echo "coda-core not found. Run install.sh to build it."
    return 1
}
