#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODE="standard"
ARGS=()

for arg in "$@"; do
  if [ "$arg" = "--mcp" ]; then
    MODE="mcp"
  else
    ARGS+=("$arg")
  fi
done

if [ "$MODE" = "mcp" ]; then
  exec "$REPO_ROOT/pair_loop_mcp.sh" --codex-first "${ARGS[@]}"
fi

exec "$REPO_ROOT/pair_loop.sh" --codex-first "${ARGS[@]}"
