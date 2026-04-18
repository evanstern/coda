#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/testlib.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export HOME="$TEST_TMPDIR/home"
mkdir -p "$HOME"

source "$ROOT_DIR/lib/plugin.sh"

printf 'Running plugin dependency detection tests...\n'

# _coda_plugin_find_dep should find commands on PATH
assert_eq 0 "$(_coda_plugin_find_dep bash && echo 0 || echo 1)" \
    "should find bash via command -v"

# _coda_plugin_find_dep should NOT find a nonexistent command
assert_eq 1 "$(_coda_plugin_find_dep __coda_test_nonexistent_thing__ && echo 0 || echo 1)" \
    "should not find nonexistent command"

# _coda_plugin_find_dep should find binaries in ~/.opencode/bin/
mkdir -p "$HOME/.opencode/bin"
printf '#!/bin/sh\necho hello\n' > "$HOME/.opencode/bin/fake-opencode"
chmod +x "$HOME/.opencode/bin/fake-opencode"

# Call in current shell (not subshell) so PATH mutation is visible
_coda_plugin_find_dep fake-opencode
assert_eq 0 "$?" "should find binary in ~/.opencode/bin/"

# After finding in fallback dir, PATH should include the dir
case ":$PATH:" in
    *":$HOME/.opencode/bin:"*) ;;
    *) fail "~/.opencode/bin should be on PATH after find_dep" ;;
esac

# _coda_plugin_find_dep should find binaries in ~/.local/bin/
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho hello\n' > "$HOME/.local/bin/fake-local-tool"
chmod +x "$HOME/.local/bin/fake-local-tool"
assert_eq 0 "$(_coda_plugin_find_dep fake-local-tool && echo 0 || echo 1)" \
    "should find binary in ~/.local/bin/"

# Plugin load should NOT emit warnings by default
mkdir -p "$TEST_TMPDIR/test-plugin"
cat > "$TEST_TMPDIR/test-plugin/plugin.json" <<'JSON'
{
  "name": "test-plugin",
  "version": "0.1.0",
  "dependencies": {
    "system": ["__coda_test_missing_dep__"]
  }
}
JSON
unset CODA_DEBUG
stderr_output="$(_coda_plugin_load test-plugin "$TEST_TMPDIR/test-plugin" 2>&1 1>/dev/null)"
assert_eq "" "$stderr_output" \
    "missing dep should not emit warning without CODA_DEBUG"

# Plugin load SHOULD emit debug message with CODA_DEBUG=1
export CODA_DEBUG=1
stderr_output="$(_coda_plugin_load test-plugin "$TEST_TMPDIR/test-plugin" 2>&1 1>/dev/null)"
assert_contains "$stderr_output" "debug:" \
    "missing dep should emit debug message with CODA_DEBUG=1"
unset CODA_DEBUG

printf 'PASS: plugin dependency detection tests\n'
