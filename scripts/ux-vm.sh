#!/bin/sh
# Runs the UX specs in a disposable macOS VM, so they never touch this Mac's screen, and copies
# the log and failure screenshots to build/ux-vm/. Needs tart and the image, once:
#   brew install cirruslabs/cli/tart
#   tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest tilde-ux
#   scripts/ux-vm.sh [test name filter]     TILDE_UX_RECORD=1 records the window baselines
set -eu
PATH="$HOME/tools/tart-dl/tart.app/Contents/MacOS:$PATH"

cd "$(dirname "$0")/.."
vm="${TILDE_UX_VM:-tilde-ux}"
filter="${1:-TildeUXTests}"
branch=$(git rev-parse --abbrev-ref HEAD)
remote=$(git remote get-url origin)

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

in_vm "test -d tilde || git clone \"$remote\" tilde; cd tilde && git fetch origin \"$branch\" && git checkout -q --detach FETCH_HEAD"
status=0
in_vm "cd tilde && TILDE_UX_RECORD=${TILDE_UX_RECORD:-0} scripts/ux.sh \"$filter\"" 2>&1 | tee build/ux-vm.log || status=1

mkdir -p build/ux-vm
mv build/ux-vm.log build/ux-vm/run.log
SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "admin@$ip:\$(getconf DARWIN_USER_TEMP_DIR)/tilde-ux-failure-*.png" build/ux-vm/ 2>/dev/null || true
exit "$status"
