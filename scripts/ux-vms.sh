#!/bin/sh
# Runs all the UX specs in the two test VMs at the same time, for one result in about half the
# time of one VM: the remote machine, the browser, the automatic update, the copied report and
# the paste and the full-screen recording specs in the second VM, the rest in the first. Each half has the time limit of
# scripts/ux.sh. The logs are in build/ux-vm/.
#   scripts/ux-vms.sh     TILDE_UX_VMS="<first vm> <second vm>", by default "tilde-ux tilde-ux-2"
set -eu
cd "$(dirname "$0")/.."
set -- ${TILDE_UX_VMS:-tilde-ux tilde-ux-2}
first=$1
second=$2
# About half of the time, as measured: the specs of the second VM.
split="aNodeIsInstalled|aClickInAnotherBrowser|anUpdateInstallsByItself|aCopiedReport|aPasteInACommentBox|theHUDShowsOverAFullScreenApp|aWireframeOnAWindow"

# Built once, here: both runs copy it.
proxy/build.sh
mkdir -p build/ux-vm
started=$(date +%s)
TILDE_UX_VM=$second TILDE_UX_PROXY_BUILT=1 scripts/ux-vm.sh "$split" > "build/ux-vm/$second.log" 2>&1 &
other=$!
status=0
TILDE_UX_VM=$first TILDE_UX_PROXY_BUILT=1 TILDE_UX_SKIP="$split" scripts/ux-vm.sh > "build/ux-vm/$first.log" 2>&1 || status=$?
wait "$other" || status=$?
for vm in "$first" "$second"; do
    echo "=== $vm"
    cat "build/ux-vm/$vm.log"
done
echo "Both VMs took $(($(date +%s) - started)) s, with the build and the copy."
exit "$status"
