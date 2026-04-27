#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (script lives in scripts/, repo is one dir up)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(git describe --tags --dirty --always 2>/dev/null || echo dev)"
DEST="${XDG_BIN_HOME:-$HOME/.local/bin}"
BINARY="coda-dev"

mkdir -p "$DEST"
go build -ldflags "-X main.Version=$VERSION" -o "$DEST/$BINARY" ./cmd/coda
echo "installed: $DEST/$BINARY ($VERSION)"

# Collision warning: v2 shell-functions.sh defines a function named
# 'coda-dev'. In interactive bash it shadows this binary because bash
# resolves functions before $PATH. Warn the user; do not block install.
if [ -n "${BASH_VERSION:-}" ] && type coda-dev 2>/dev/null | grep -q 'is a function'; then
    cat <<EOF >&2

warning: a shell function named 'coda-dev' is defined in your shell.
         it will shadow $DEST/$BINARY in interactive shells, so
         'coda-dev version' will run the v2 shim, not v3.

         to invoke v3 explicitly:
             $DEST/$BINARY version

         to fix permanently, see card #183 (rename or remove the v2
         coda-dev shell function).
EOF
fi
