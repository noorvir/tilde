#!/bin/sh
# The check for every commit: state to picture, and state plus event to state. It takes seconds
# and uses no screen, mouse or keyboard. See Tests/Contract/README.md.
#   scripts/ui-check.sh [--record] [name filter]
set -eu
cd "$(dirname "$0")/.."
# The owner's builds make warnings errors; see Package.swift.
export TILDE_STRICT=1
swift build --product tilde-state >/dev/null
# The checker compares every pixel; a debug build of it takes most of the time.
swift build -c release --product tilde-ui-check >/dev/null
TILDE_STATE=.build/debug/tilde-state
scripts/stamp-sdk.sh "$TILDE_STATE"
export TILDE_STATE
exec .build/release/tilde-ui-check "$@"
