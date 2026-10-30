#!/bin/sh
# The check before a release: notes in real Safari, Chrome, System Settings and the Simulator.
# On a Mac in use, run it in the VM: it takes over the screen.
exec env TILDE_UX_REAL_APPS=1 TILDE_UX_LIMIT=120 "$(dirname "$0")/ux.sh"
