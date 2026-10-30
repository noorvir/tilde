#!/bin/sh
# Runs inside the disposable UX VM, once: installs Chrome and grants Tilde's test apps the
# permissions the specs need. Never run this on a real Mac: it writes the TCC database.
#   scripts/ux-vm-provision.sh    (needs System Integrity Protection off in the VM)
set -eu

if [ "$(whoami)" != admin ] || [ "$(sysctl -n kern.hv_vmm_present)" != 1 ]; then
    echo "This script is only for the UX VM." >&2
    exit 2
fi
if csrutil status | grep -q enabled; then
    echo "System Integrity Protection is on: turn it off in the VM's recovery mode first." >&2
    exit 3
fi

[ -d "/Applications/Google Chrome.app" ] || brew install --cask google-chrome
xattr -dr com.apple.quarantine "/Applications/Google Chrome.app" 2>/dev/null || true
# A grey accent: blue on screen can then only be a note. System Settings has blue controls.
defaults write -g AppleAccentColor -int -1
defaults write -g AppleHighlightColor -string "0.847059 0.847059 0.862745 Graphite"

sudo defaults write /Library/Preferences/com.apple.screensaver idleTime 0
sudo pmset -a displaysleep 0 sleep 0

for app in dev.tilde.ux dev.tilde.driver dev.tilde.app; do
    for service in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent; do
        sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
            "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$service', '$app', 0, 2, 4, 1, 'UNUSED', 0, strftime('%s', 'now'));"
    done
done
# No "bypass the window picker" question at all.
sudo mkdir -p "/Library/Managed Preferences"
managed="/Library/Managed Preferences/com.apple.applicationaccess.plist"
sudo plutil -create xml1 "$managed"
sudo plutil -insert forceBypassScreenCaptureAlert -bool true "$managed"
sudo chmod 644 "$managed"
# And no question: its date is far away, for apps that have asked.
approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
here=$(cd "$(dirname "$0")/.." && pwd)
for app in TildeDriver TildeUX Tilde; do
    /usr/libexec/PlistBuddy -c "Add :file\\:///${here#/}/build/$app.app/ dict" "$approvals" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :file\\:///${here#/}/build/$app.app/:kScreenCapturePrivacyHintDate" "$approvals" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :file\\:///${here#/}/build/$app.app/:kScreenCapturePrivacyHintDate date Sat Jan 01 00:00:00 UTC 2050" "$approvals"
    /usr/libexec/PlistBuddy -c "Add :file\\:///${here#/}/build/$app.app/:kScreenCaptureApprovalLastAlerted date Sat Jan 01 00:00:00 UTC 2050" "$approvals" 2>/dev/null || true
done
killall replayd 2>/dev/null || true
# Nothing left on the screen for the specs to click by mistake.
killall Terminal 2>/dev/null || true
sudo killall tccd 2>/dev/null || true
