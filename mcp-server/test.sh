#!/usr/bin/env bash
#
# test.sh — Smoke test for the coda MCP server
#
# Verifies the server starts, registers all expected tools, and can
# execute a live tool call (coda_ls).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/server.js"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [pass] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

# --- Check deps ---
if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    echo "node_modules missing. Run: npm install" >&2
    exit 1
fi

# --- Helper: send JSON-RPC messages and capture response ---
mcp_call() {
    local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
    local notify='{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n%s\n%s\n' "$init" "$notify" "$1" | timeout 10 node "$SERVER" 2>/dev/null
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

# --- Test 2: All tools registered ---
echo "2. Tool registration"
tools_response=$(mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | tail -1)

EXPECTED_TOOLS=(
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
    coda_watch_status
    coda_watch_start
    coda_watch_stop
    coda_provider_status
    coda_layout_ls
    coda_layout_show
    coda_help
)

missing=0
for tool in "${EXPECTED_TOOLS[@]}"; do
    if ! echo "$tools_response" | grep -q "\"$tool\""; then
        fail "Missing tool: $tool"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -eq 0 ]; then
    pass "All ${#EXPECTED_TOOLS[@]} tools registered"
fi

# --- Test 3: Live tool call (coda_ls) ---
echo "3. Live tool call"
ls_response=$(mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"coda_ls","arguments":{}}}' | tail -1)
if echo "$ls_response" | grep -q '"type":"text"'; then
    pass "coda_ls returned text content"
else
    fail "coda_ls did not return expected format"
fi

# --- Test 4: Tool call with bad args returns error gracefully ---
echo "4. Error handling"
err_response=$(mcp_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"coda_layout_show","arguments":{}}}' | tail -1)
if echo "$err_response" | grep -qi 'error\|exit code\|invalid\|required'; then
    pass "Bad args handled gracefully"
else
    fail "Bad args call did not return an error response"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
