#!/usr/bin/env bash
#
# test.sh — Smoke test for the coda MCP server
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/server.js"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [pass] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    echo "node_modules missing. Run: npm install" >&2
    exit 1
fi

mcp_call() {
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
    local notify='{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n%s\n%s\n' "$init" "$notify" "$1" | timeout 10 node "$SERVER" 2>/dev/null
}

mcp_call_env() {
    local env_args="$1"
    local msg="$2"
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
    local notify='{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n%s\n%s\n' "$init" "$notify" "$msg" | timeout 10 env $env_args node "$SERVER" 2>/dev/null
}

echo "MCP Server Tests"
echo "================="
echo ""

# --- Test 1: Server initializes ---
echo "1. Server initialization"
response=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}\n' | timeout 5 node "$SERVER" 2>/dev/null || true)
if echo "$response" | grep -q '"name":"coda"'; then
    pass "Server starts and identifies as 'coda'"
else
    fail "Server did not return expected identity"
fi

# --- Test 2: All core tools registered ---
echo "2. Core tool registration"
tools_response=$(mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | tail -1)

CORE_TOOLS=(
    coda_ls
    coda_project_ls
    coda_feature_ls
    coda_feature_start
    coda_feature_done
    coda_feature_finish
    coda_project_clone
    coda_project_create
    coda_project_workon
    coda_project_close
    coda_layout_ls
    coda_layout_show
    coda_help
)

missing=0
for tool in "${CORE_TOOLS[@]}"; do
    if ! echo "$tools_response" | grep -q "\"$tool\""; then
        fail "Missing core tool: $tool"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -eq 0 ]; then
    pass "All ${#CORE_TOOLS[@]} core tools registered"
fi

# --- Test 3: Plugin tools NOT in core list ---
echo "3. Plugin tools absent from core"
PLUGIN_TOOLS=(coda_watch_status coda_watch_start coda_watch_stop coda_provider_status)
leaked=0
for tool in "${PLUGIN_TOOLS[@]}"; do
    if echo "$tools_response" | grep -q "\"$tool\""; then
        fail "Plugin tool leaked into core: $tool"
        leaked=$((leaked + 1))
    fi
done
if [ "$leaked" -eq 0 ]; then
    pass "No plugin tools in core-only list"
fi

# --- Test 4: Live tool call (coda_ls) ---
echo "4. Live tool call"
ls_response=$(mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"coda_ls","arguments":{}}}' | tail -1)
if echo "$ls_response" | grep -q '"type":"text"'; then
    pass "coda_ls returned text content"
else
    fail "coda_ls did not return expected format"
fi

# --- Test 5: Bad args handled gracefully ---
echo "5. Error handling"
err_response=$(mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"coda_layout_show","arguments":{}}}' | tail -1)
if echo "$err_response" | grep -qi 'error\|exit code\|invalid\|required'; then
    pass "Bad args handled gracefully"
else
    fail "Bad args call did not return an error response"
fi

# --- Test 6: Dynamic plugin tool registration ---
echo "6. Dynamic plugin tools"
TMPDIR_PLUGIN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PLUGIN"' EXIT

mkdir -p "$TMPDIR_PLUGIN/plugins/mock-plugin"
cat > "$TMPDIR_PLUGIN/plugins/mock-plugin/plugin.json" << 'PLUGIN_EOF'
{
  "name": "mock-plugin",
  "provides": {
    "mcp_tools": {
      "coda_mock_test": {
        "description": "A mock test tool",
        "command": ["help"]
      }
    }
  }
}
PLUGIN_EOF

cat > "$TMPDIR_PLUGIN/config.json" << 'CONFIG_EOF'
{"plugins": {"git@github.com:test/mock-plugin.git": {"enabled": true}}}
CONFIG_EOF

plugin_tools_response=$(mcp_call_env \
    "CODA_CONFIG_PATH=$TMPDIR_PLUGIN/config.json CODA_PLUGINS_DIR=$TMPDIR_PLUGIN/plugins" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | tail -1)

if echo "$plugin_tools_response" | grep -q '"coda_mock_test"'; then
    pass "Dynamic plugin tool coda_mock_test registered"
else
    fail "Dynamic plugin tool coda_mock_test not found"
fi

# Verify core tools still present alongside plugin tools
if echo "$plugin_tools_response" | grep -q '"coda_ls"'; then
    pass "Core tools still present with plugin tools"
else
    fail "Core tools missing when plugin tools loaded"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
