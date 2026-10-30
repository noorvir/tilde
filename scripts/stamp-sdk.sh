#!/bin/sh
# Swift Package builds record the minimum macOS as the SDK, and macOS then draws the old style.
# This records the real SDK, so the app looks as this macOS does. Minimum stays macOS 14.
#   scripts/stamp-sdk.sh <binary>...
set -eu
sdk=$(xcrun --show-sdk-version)
for binary in "$@"; do
    xcrun vtool -set-build-version macos 14.0 "$sdk" -replace -output "$binary.stamped" "$binary" 2>/dev/null
    mv "$binary.stamped" "$binary"
    codesign -f -s - "$binary" 2>/dev/null
done
