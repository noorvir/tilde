#!/bin/sh
# The check before a release, or to be sure: real clicks and keys, real Safari, Chrome and
# Simulator. At most 3 minutes. It takes over the screen: on a Mac in use, run it in the VM.
exec env TILDE_UX_RELEASE=1 "$(dirname "$0")/ux.sh"
