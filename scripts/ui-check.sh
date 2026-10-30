#!/bin/sh
# The check for every commit: state to picture, and state plus event to state. It takes seconds
# and uses no screen, mouse or keyboard. See Tests/Contract/README.md.
#   scripts/ui-check.sh [--record] [name filter]
set -eu
cd "$(dirname "$0")/.."
swift build --product tilde-state >/dev/null
swift build --product tilde-ui-check >/dev/null
scripts/stamp-sdk.sh "$(swift build --show-bin-path)/tilde-state"
exec "$(swift build --show-bin-path)/tilde-ui-check" "$@"
