#!/bin/sh
# The checks for every commit, in one command: the unit and behaviour tests, then the UI
# contract (a picture of each state and a row for each rule, see Tests/Contract/README.md).
# About 30 s; it uses no screen, mouse or keyboard.
#   scripts/check.sh
set -eu
cd "$(dirname "$0")/.."
TILDE_STRICT=1 swift test
scripts/ui-check.sh
