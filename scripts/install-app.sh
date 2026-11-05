#!/bin/sh
# Builds Tilde.app and installs it in /Applications, then opens it. Refuses while a session
# is on screen in the running Tilde (saved in the last 30 s), so no work in progress is lost;
# --force installs anyway (the session is saved and offered again on launch).
set -eu

cd "$(dirname "$0")/.."
# The owner's builds make warnings errors; see Package.swift.
export TILDE_STRICT=1
sessions="${TILDE_SESSIONS:-$HOME/Library/Application Support/Tilde/Sessions}"

if [ "${1:-}" != "--force" ] && pgrep -x Tilde >/dev/null; then
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
        print(f'{record["id"]} ({len(record.get("notes", []))} notes, for {record["client"]})')
PY
)
    if [ -n "$active" ]; then
        echo "A session is in progress in Tilde: $active" >&2
        echo "Not installing. Wait until it is sent or cancelled, or pass --force." >&2
        exit 2
    fi
fi

scripts/build-app.sh
osascript -e 'quit app "Tilde"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Tilde.app
cp -R build/Tilde.app /Applications/
open /Applications/Tilde.app
echo "Installed /Applications/Tilde.app"
