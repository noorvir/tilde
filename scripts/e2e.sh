#!/bin/sh
# Runs the in-process end-to-end check (MCP, browser, overlay, HUD, comment box, send).
# Needs no macOS permissions. The test page loads React from unpkg.com.
#   scripts/e2e.sh             built-in agent; exit code 0 means every check passed
#   scripts/e2e.sh --external  wait for a real agent on http://127.0.0.1:7312/mcp
set -eu

cd "$(dirname "$0")/.."
swift build --product tilde-e2e
exec .build/debug/tilde-e2e --out build/e2e "$@"
