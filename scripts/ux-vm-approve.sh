#!/bin/sh
# Runs inside the disposable UX VM, before each run: dates the test apps' screen capture
# approvals now, so that no "bypass the system private window picker" question comes during the
# run, and quits System Settings, which macOS opens again at each start of the VM. Never run
# this on a real Mac. scripts/ux-vm-provision.sh and scripts/ux-vm.sh run it.
set -eu

if [ "$(whoami)" != admin ] || [ "$(sysctl -n kern.hv_vmm_present)" != 1 ]; then
    echo "This script is only for the UX VM." >&2
    exit 2
fi

# The dates say it was just asked. macOS 26.6 asks again for dates in the future, and it asked
# again 6 days after the last question, so each run sets them. Both are replaced, as
# replayd writes the real date when it asks. A managed preference
# (forceBypassScreenCaptureAlert) does not work: without a profile, macOS removes it.
approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
here=$(cd "$(dirname "$0")/.." && pwd)
now=$(date -u '+%a %b %d %H:%M:%S UTC %Y')
for app in TildeDriver TildeUX Tilde; do
    entry=":file\\:///${here#/}/build/$app.app/"
    /usr/libexec/PlistBuddy -c "Add $entry dict" "$approvals" 2>/dev/null || true
    for key in kScreenCapturePrivacyHintDate kScreenCaptureApprovalLastAlerted; do
        /usr/libexec/PlistBuddy -c "Delete $entry:$key" "$approvals" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add $entry:$key date $now" "$approvals"
    done
done
# replayd reads the file only when it starts, and it outlives killall: launchd starts it again.
launchctl kickstart -k "gui/$(id -u)/com.apple.replayd"
killall "System Settings" 2>/dev/null || true

# A question that is up already would take the specs' clicks: the run stops instead. The specs
# never click it.
if pgrep -x UserNotificationCenter >/dev/null; then
    echo "A macOS question is on the VM's screen (UserNotificationCenter), such as the screen capture one: answer it on that screen, then run again." >&2
    exit 5
fi
