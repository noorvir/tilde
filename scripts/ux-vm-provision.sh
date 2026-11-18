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
# The look the window baselines were recorded with.
defaults delete -g AppleAccentColor 2>/dev/null || true
defaults delete -g AppleHighlightColor 2>/dev/null || true
defaults write -g AppleKeyboardUIMode -int 0

sudo defaults write /Library/Preferences/com.apple.screensaver idleTime 0
sudo pmset -a displaysleep 0 sleep 0

for app in dev.tilde.ux dev.tilde.driver dev.tilde.app; do
    for service in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent; do
        sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
            "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$service', '$app', 0, 2, 4, 1, 'UNUSED', 0, strftime('%s', 'now'));"
    done
done
# The Camera, to film a phone on a cable, is in the user's database. Without it, a phone spec
# would stop at the question.
for app in dev.tilde.ux dev.tilde.app; do
    sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
        "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceCamera', '$app', 0, 2, 4, 1, 'UNUSED', 0, strftime('%s', 'now'));"
done
# ssh may read and write other apps' data, such as replayd's below, without a question on
# the VM's screen.
for service in kTCCServiceSystemPolicyAllFiles kTCCServiceSystemPolicyAppData; do
    sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$service', '/usr/libexec/sshd-keygen-wrapper', 1, 2, 4, 1, 'UNUSED', 0, strftime('%s', 'now'));"
done
sudo killall tccd 2>/dev/null || true
# No "bypass the system private window picker" question; ux-vm.sh does this again at each run.
"$(dirname "$0")/ux-vm-approve.sh"
# The size of a MacBook screen, in the layout the window baselines were recorded in.
swift "$(dirname "$0")/ux-vm-display.swift"
# Nothing left on the screen for the specs to click by mistake.
killall Terminal 2>/dev/null || true
sudo killall tccd 2>/dev/null || true
