#!/bin/sh
# Runs the UX specs in a disposable macOS VM, so they never touch this Mac's screen, and copies
# the log, failure screenshots and their app logs to build/ux-vm/<time>/, keeping the last 10 runs. Needs tart
# and the image, once:
#   brew install cirruslabs/cli/tart
#   tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest tilde-ux
#   scripts/ux-vm.sh [test name filter]     TILDE_UX_RECORD=1 records the window baselines
#                                           TILDE_UX_RELEASE=1 runs the release check
set -eu
PATH="$HOME/tools/tart-dl/tart.app/Contents/MacOS:$PATH"

cd "$(dirname "$0")/.."
vm="${TILDE_UX_VM:-tilde-ux}"
filter="${1:-TildeUXTests}"

# The image has the public login admin/admin; it serves only this VM on the local network.
askpass=$(mktemp)
printf "#!/bin/sh\necho admin\n" > "$askpass"
chmod +x "$askpass"
trap 'rm -f "$askpass"' EXIT
in_vm() {
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$ip" "$@"
}

if ! tart list --format json | grep -q "\"Name\" *: *\"$vm\".*running\|running.*\"Name\" *: *\"$vm\""; then
    tart set "$vm" --cpu 4 --memory 8192 --display 1728x1117
    nohup tart run --no-graphics "$vm" >/dev/null 2>&1 &
fi
ip=$(tart ip "$vm" --wait 180)
until in_vm true 2>/dev/null; do sleep 3; done

# This checkout as it is, committed or not; the VM keeps its build folders between runs.
in_vm "mkdir -p tilde && find tilde -mindepth 1 -maxdepth 1 ! -name .build ! -name build -exec rm -rf {} +"
(git ls-files; git ls-files -o --exclude-standard) | COPYFILE_DISABLE=1 tar czf - -T - | in_vm "tar xzf - -C tilde"

# The specs need the logged-in GUI session, which ssh does not give: launchd runs them there.
in_vm "rm -f \$(getconf DARWIN_USER_TEMP_DIR)/tilde-ux-failure-*(N) /tmp/tilde-ux.log; cat > /tmp/dev.tilde.ux.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.tilde.ux</string>
<key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>-lc</string><string>scripts/ux.sh "\$0"; echo "__exit \$?"</string><string>$filter</string>
</array>
<key>WorkingDirectory</key><string>/Users/admin/tilde</string>
<key>EnvironmentVariables</key><dict>
    <key>TILDE_UX_RECORD</key><string>${TILDE_UX_RECORD:-0}</string>
    <key>TILDE_UX_RELEASE</key><string>${TILDE_UX_RELEASE:-}</string>
</dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/tmp/tilde-ux.log</string>
<key>StandardErrorPath</key><string>/tmp/tilde-ux.log</string>
</dict></plist>
PLIST
run=build/ux-vm/$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
in_vm "launchctl bootout gui/\$(id -u)/dev.tilde.ux 2>/dev/null; launchctl bootstrap gui/\$(id -u) /tmp/dev.tilde.ux.plist
    until grep -q __exit /tmp/tilde-ux.log 2>/dev/null; do sleep 2; done
    launchctl bootout gui/\$(id -u)/dev.tilde.ux; cat /tmp/tilde-ux.log" > "$run/run.log" 2>&1 || true
cat "$run/run.log"
status=$(sed -n "s/^__exit //p" "$run/run.log")

# The screenshots live on this Mac, so they outlast the VM.
in_vm "cd \$(getconf DARWIN_USER_TEMP_DIR) && tar cf - tilde-ux-failure-*(N)" | tar xf - -C "$run" 2>/dev/null || true
echo "Log and screenshots: $run"
ls -d build/ux-vm/*/ | sort -r | tail -n +11 | xargs rm -rf
[ "${status:-1}" = 0 ]
