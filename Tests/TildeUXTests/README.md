# UX specs

The real-app layer: about 5 flows that only the built app with real input can prove. Everything
else is in `Tests/Contract` (a picture of each state, a row for each rule), which runs in seconds
on every commit. The run fails above 3 minutes (`TILDE_UX_LIMIT`, 180 s).

They import nothing from Tilde: they run the built app and use only what stays true through a
rewrite:

- the accessibility tree (names on screen) and real input, through `TildeDriver`;
- MCP over HTTP, as an agent, and MCP over a node's socket, through `tproxy`;
- files on disk (the sessions folder and inbox set by `TILDE_SESSIONS` and `TILDE_INBOX`);
- blue pixels on screen, for notes drawn without accessibility.

## The flows

1. **An agent opens a page, the user notes it, and the agent gets a report with images**
   (`anAgentOpens…`): the menu's items before a session; `start_annotation` with a url opens
   Tilde's browser, paused; a click while paused, and one with ⌥ held while annotating, reach
   the page; a note on the page; ⌘↩; `wait_for_annotation` returns the comment and an image.
2. **A machine is installed from Settings and linked by its socket** (`aNodeIsInstalled…`):
   Install in Settings; the entries start `tproxy` with the socket and hold no token; modes and
   hashes; another user is refused; one agent process lives through two tunnel drops (a
   changed `tproxy` is replaced, a cut wait says to call again, a held wait gets the report);
   Remove.
3. **A copied report goes to the remote machine with its images** (`aCopiedReport…`): a local
   session with a note and a clip, ⌘↩, "Copied", the report folder on the machine; a machine
   that cannot be reached gets its own warning and the report still copies.
4. **A rectangle leaves a label that hides on another page, and a crash leaves only its note**
   (`aRectangleLeaves…`): drawing on the canvas, with the R key picking the rectangle (not
   recording mode); a note on another app's window that hides on its other page and follows
   the window; the app killed once the session is saved; Restore brings the note back.
5. **Two clips reach the agent as videos** (`twoClipsReachTheAgentAsVideos`): the R key into
   recording mode, which starts by choosing, and Esc keeps the screen; record, Space pauses,
   resume, stop; the clip in the preview's player; Esc asks before it drops a clip; the record
   toggle chooses at once, and a click on a window chooses it; Send while recording; both
   videos play, the first leaves out its pause, and the second has the window's shape.
6. **A click in another browser offers Tilde's browser, which unloads the page on close**
   (`aClickInAnotherBrowser…`): a click on a page in Safari opens the comment box and "Open in
   Tilde's browser", which stays after Esc; the button opens the page in Tilde's browser,
   which runs it; ⌘W closes the window and the page stops (it asks the test server for
   `/beat` while it runs).

## Where the other stories are

| Story (old spec) | Now |
|---|---|
| A local session goes to the clipboard; Esc pauses, then closes when empty | `hud-local-1-note`; rows "Esc while annotating pauses…", "Esc while paused with no notes closes at once" |
| Esc with notes pauses, asks, Esc keeps, ↩ discards | `hud-confirm-cancel-1`; rows "Esc while paused with notes asks…", "Esc on a question dismisses it", "↩ on Discard and close ends the session" |
| The HUD moves and snaps back home | `home-outline`, `home-outline-snapped`; rows "…within 40 pt of home snaps there", "Dropped 40 pt or more from home…" |
| A tooltip stays whole inside the HUD | `tooltip` |
| Double-tap ⌃ starts and resumes, and does nothing while annotating | rows "⌃ tapped twice…", "A press longer than 300 ms…", "A second press more than 300 ms…", "A key or click between…", "Another modifier with it…", "The start double tap…" (3), "One double tap for start and pause…" |
| The shortcut recorder takes a double tap | `settings-shortcuts-recording-*`; row "⌥ tapped twice is a double tap of ⌥…" |
| Settings has its four pages | `settings-general-*`, `settings-agents-*`, `settings-shortcuts-*`, `settings-history-*` |
| The menu has its items | flow 1 |
| History restores a session and asks before replacing notes | `settings-history-*`, `hud-confirm-restore`; rows "A restore with notes asks first", "↩ on Replace restores the saved notes" |
| The browser takes an address and hosts the HUD in its toolbar | `browser-toolbar-*`; flow 1 opens a page there |
| The browser first opens at full height and half width | rows "The browser first opens at the full height…", "On a small screen…" |
| A note on small text hides on another page with the same layout | rows "Another title is another page in a native app", "Two bad readings hide it", "Two good readings show it", "A reading between the thresholds changes nothing" |
| A label in Chrome and Safari hides when its content is not on screen | rows "The same address with its element gone: the picture decides", "An element out of its window has no label", "Another address is another page…", "Within 8 points of a label is on it…" |
| A note in a single page app hides on a route with the same content | row "A single page app route is another page" |
| A note follows the browser's back and forward keys | rows "The same address is the same page…", "Another address is another page…" |
| A note in Tilde's browser hides on another page | `browser-notes`; the page rows above |
| Notes in Tilde's browser move with the page as it scrolls | `overlay-page-notes` (drawn where the page reports its elements) |
| Notes in the real Simulator hide on another screen | rows "A region in a window without elements: content changed, twice, hides it", "…content restored, twice, shows it" |
| A note in a native app hides on another pane | rows "Another title is another page in a native app", "A picture with nothing alike hides at once" |
| The hold key is a setting | `settings-shortcuts-*` |
| The hold key works, a comment is never lost | rows "The hold key does nothing with no session", "The hold key down…", "The hold key up…", "A click away from a comment with text asks…", "Esc again keeps writing", "↩ on the discard question…", "A click away drops an empty comment", "Within 8 points of a label is on it…"; `comment-*` |
| Pasting a long comment keeps the top of the box on screen | `comment-very-long` |
| An arrow is edited and leaves a label that follows its element | rows "A finished shape opens its comment", "Esc in a shape's comment…", "Undo in draw mode", "A click away keeps a shape's comment…", "Esc in draw mode keeps the drawings"; `hud-drawing*`; flow 4 draws on the canvas |
| Shift-Return adds a line; Esc closes the preview | `comment-editing`; rows "↩ in the comment saves it", "Esc closes the preview" |
| Choosing a window can be cancelled with Esc | rows "Esc in the open picker goes back…", "Esc ends choosing"; `hud-source-picker-*` |
| The source picker chooses a window to record | flow 5 (a click on a window); rows "In recording mode it chooses the next clip's source", "A choice ends choosing", "Use window picker opens the picker"; `hud-source-picker-*`, `hud-recording-window` |
| The preview resizes, moves and snaps to the centre | rows "…within 40 pt of home snaps there", "The preview is never resized below 560 × 420", "The preview never grows past the room…"; `preview-*` |

## Not covered by an automatic test

Check these by hand when a change touches them (see `AGENTS.md`):

- Notes that follow elements in real Chrome, Safari, System Settings and the Simulator, read by
  Accessibility (the rows cover the rules; flow 4 covers another app's window).
- The arrow tip snapping to its element, and the comment box growing a line at a time without a
  flash.
- Key handling in text fields: Shift-Return and Option-Return, ⌘A, ⌘Z, ⌘V.
- A dropped place remembered per screen and forgotten at home; a preview size kept for the next one.
- The address field of Tilde's browser, and "Window closed" when a scoped window closes.
- The hand cursor over a label.
- An iPhone on a cable as a recording source (the VM has no device).

## Running

`scripts/ux.sh` (or `scripts/ux.sh <spec name>`) takes over the screen for about 2 minutes;
`swift test` skips these specs. Run them on the test Mac or, on a shared Mac, in the VM with
`scripts/ux-vm.sh`. The first run asks to give `TildeDriver` and `TildeUX` Accessibility,
once. The node flow needs `TILDE_UX_NODE` (default `vmself`: the VM's own ssh) in the ssh
config, with its own key in `authorized_keys`, a `~/.claude.json` file and a `~/.codex`
folder. Each flow prints `STEP` times to its log.
