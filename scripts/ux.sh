#!/bin/sh
# Runs the black-box UX specs in Tests/TildeUXTests against the built app, like a user would.
# They post real input and take over the screen for a few minutes. Needs TildeDriver and
# TildeUX with Accessibility, once; the script says so when they are missing.
#   scripts/ux.sh [test name filter]        TILDE_UX_RECORD=1 records the window baselines
set -eu

cd "$(dirname "$0")/.."
sessions="$HOME/Library/Application Support/Tilde/Sessions"
filter="${1:-TildeUXTests}"

# The real Tilde would answer the same shortcuts: it goes away for the run, unless in use.
real_running=0
if pgrep -f '/Applications/Tilde.app/Contents/MacOS/Tilde' >/dev/null; then
    active=$(python3 - "$sessions" <<'PY'
import json, os, sys, time
from datetime import datetime
root = sys.argv[1]
for name in os.listdir(root) if os.path.isdir(root) else []:
    try:
        record = json.load(open(os.path.join(root, name, "session.json")))
    except Exception:
        continue
    updated = datetime.fromisoformat(record["updated"].replace("Z", "+00:00")).timestamp()
    if record.get("state") == "active" and time.time() - updated < 30:
        print(record["id"])
PY
)
    if [ -n "$active" ]; then
        echo "A session is in progress in Tilde: $active. Send or cancel it first." >&2
        exit 2
    fi
    real_running=1
fi

scripts/build-app.sh >/dev/null
swift build --product tilde-ux-fixture >/dev/null
scripts/build-driver.sh >/dev/null

# A copy with its own identity: its own user defaults and permissions.
rm -rf build/TildeUX.app
cp -R build/Tilde.app build/TildeUX.app
plutil -replace CFBundleIdentifier -string dev.tilde.ux build/TildeUX.app/Contents/Info.plist
codesign --force --sign - --identifier dev.tilde.ux -r='designated => identifier "dev.tilde.ux"' build/TildeUX.app 2>/dev/null

pkill -f TildeDriver.app/Contents/MacOS/TildeDriver 2>/dev/null || true
sleep 1
open build/TildeDriver.app
sleep 2
status=$(curl -s --max-time 3 http://127.0.0.1:7320/status || echo '{}')
case "$status" in
    *'"accessibility":true'*|*'"accessibility" : true'*) ;;
    *)
        echo "TildeDriver needs Accessibility: System Settings → Privacy & Security → Accessibility." >&2
        echo "Turn on $PWD/build/TildeDriver.app and $PWD/build/TildeUX.app, then run this again." >&2
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        exit 3
        ;;
esac

if [ "$real_running" = 1 ]; then
    osascript -e 'quit app "Tilde"' 2>/dev/null || true
    sleep 1
fi
status=0
# The flows that need real input and real apps; Tests/Contract covers the rest without them.
release_flows="aLabelHidesWhen|eachShapeBecomes|aShapeIsEdited|anArrowEndSnaps|aDrawnArrowsLabel|aDrawingsLabelStays|theCommentBoxSteps|aCommentIsNeverLost|anAgentOpens|aNoteInABrowser|InTheRealSimulator|holdingTheKey|afterACrash"
limit=${TILDE_UX_LIMIT:-180}
if [ -n "${TILDE_UX_RELEASE:-}" ]; then
    set -- --filter "$release_flows"
else
    set -- --filter "$filter"
fi
swift build --build-tests >/dev/null
started=$(date +%s)
TILDE_UX=1 TILDE_UX_APP="$PWD/build/TildeUX.app" TILDE_UX_FIXTURE="$(swift build --show-bin-path)/tilde-ux-fixture" swift test --skip-build "$@" || status=$?
took=$(($(date +%s) - started))
echo "Took $took s (limit $limit s)."
if [ "$took" -gt "$limit" ]; then
    echo "Over the time limit." >&2
    status=4
fi
pkill -f TildeDriver.app/Contents/MacOS/TildeDriver 2>/dev/null || true
if [ "$real_running" = 1 ]; then
    open /Applications/Tilde.app
fi
exit "$status"
