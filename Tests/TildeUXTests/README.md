## Known issues

`notesInTheRealSimulator...` is not reliable: it failed once in 2 runs on the same code (the note did not hide on the other screen), cause unknown. It stays in the release check.

## The release check

`scripts/e2e-release.sh` runs 8 flows with real input and real apps: an agent session with its report; an arrow reshaped with its comment open, its label, preview and a real scroll; a rectangle, another page and a crash; a label hiding in Chrome and Safari; notes in the real Simulator; the hold key and a comment never lost; a remote machine installed from Settings, and a copied report sent to it. The VM needs `vmself` in its ssh config, its own key in `authorized_keys`, and `~/.claude` and `~/.codex` folders. Each flow prints `STEP` times to its log.

The other specs here stay as a longer check, `scripts/ux.sh`, for when a change touches windows, focus or input.

Both take over the screen: on a shared Mac, run them in the VM with `scripts/ux-vm.sh`.

# UX specs

Black-box specs of what a user sees and does. They import nothing from Tilde: they run the
built app and use only what stays true through a rewrite:

- the accessibility tree (names on screen) and real input, through `TildeDriver`;
- MCP over HTTP, as an agent;
- files on disk (the sessions folder and inbox set by `TILDE_SESSIONS` and `TILDE_INBOX`);
- pictures of whole windows, compared with `Baselines/`.

Run with `scripts/ux.sh` (or `scripts/ux.sh <spec name>`). They take over the screen for a few
minutes. `swift test` skips them. The first run asks to give `TildeDriver` and `TildeUX`
Accessibility, once. `TILDE_UX_RECORD=1 scripts/ux.sh` records the window baselines again. Baselines are compared
only on the macOS version in `Baselines/macos-version.txt` (now macOS 26, on the test Mac).

They need an unlocked, logged-in screen, and a command in the GUI session (not a plain SSH
shell). Run them on the test Mac, not on a Mac someone is using: they take the mouse and keyboard.

Each spec's name is its user story. Not covered here, because they need other apps' windows or
draw without accessibility (see the offscreen snapshots in `Tests/TildeUITests`): notes drawn
over pages, notes hidden behind other windows, notes that follow elements in other apps.
