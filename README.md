# Tilde

A macOS menu-bar app that lets any coding agent ask you for visual feedback.

The agent calls an MCP tool. Tilde opens annotate mode on your screen. You click
elements or drag regions on any app or web page, add a comment to each, and press
Send. The agent gets a markdown report plus one screenshot per annotation.

- Works with every MCP harness: Claude Code, Codex, Cursor, Gemini CLI, VS Code and others.
- Works with remote agents through an SSH tunnel to a private socket. Screenshots go back inline.
- No paste step. The result goes back on the agent's own tool call.

## Install

```sh
./scripts/build-app.sh
cp -R build/Tilde.app /Applications/
open /Applications/Tilde.app
```

Requirements: macOS 14 or later, Swift 6 (Xcode or Command Line Tools).

Then, in System Settings > Privacy & Security, turn on Tilde for:

| Permission | What it enables | Without it |
|---|---|---|
| Screen Recording | Screenshots of any app | Screenshots only for pages in Tilde's browser |
| Accessibility | Element data in native apps | The window under the cursor only |

The build is signed ad hoc with a designated requirement on the bundle identifier
(`dev.tilde.app`), so the permissions stay after a rebuild. If a switch is on but
Tilde's menu says "not allowed", the entry belongs to an older signature: remove
Tilde with **−** and add `/Applications/Tilde.app` again.

macOS also asks from time to time to confirm direct screen capture ("Tilde is
requesting to bypass the system private window picker"). Tilde triggers this check
at launch, so it does not interrupt an annotation. Click **Allow**.

## Connect an agent

Tilde serves MCP at `http://127.0.0.1:7311/mcp` (set `TILDE_PORT` to change it).

Choose **Agents** in the menu-bar menu, or open **Settings** (⌘,) → **Agents**. It lists the known agent
apps that are on your Mac, each with its own icon and a status dot: green installed, red
error (for example a config that is not valid JSON), grey not installed. Each app has
Install and Uninstall, and Details with its config file and skill. **Install Everywhere**
sets up all of them. After a change, a short note at the top of the screen says what
happened; its Details button opens this page. The **Claude** row sets up Claude Code.
Cursor, VS Code and Windsurf share an editor base, but each one's agent reads its own MCP
file, so each has its own row. Tilde adds its MCP server entry and a `tilde` skill
(`/tilde`, or "annotate with Tilde"), and changes nothing else in each file. Then restart
the app.

| App | MCP config | Entry | Skill folder |
|---|---|---|---|
| Claude Code | `~/.claude.json` | `mcpServers.tilde`: `type: http`, `url` | `~/.claude/skills` |
| Codex | `~/.codex/config.toml` | `[mcp_servers.tilde]`: `url`, `default_tools_approval_mode = "approve"` | `~/.agents/skills` |
| Cursor | `~/.cursor/mcp.json` | `mcpServers.tilde`: `url` | `~/.agents/skills` |
| VS Code | `~/Library/Application Support/Code/User/mcp.json` | `servers.tilde`: `type: http`, `url` | `~/.agents/skills` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers.tilde`: `httpUrl` | `~/.agents/skills` |
| Windsurf (Devin) | `~/.config/devin/mcp_config.json` | `mcpServers.tilde`: `serverUrl` | `~/.agents/skills` |

Tilde writes through symbolic links, so a skills folder that links into a dotfiles
repository gets the skill in that repository.

The same installer runs from the command line:

```sh
/Applications/Tilde.app/Contents/MacOS/tilde-mcp install                 # list apps and status
/Applications/Tilde.app/Contents/MacOS/tilde-mcp install --all --dry-run
/Applications/Tilde.app/Contents/MacOS/tilde-mcp install codex cursor --uninstall
/Applications/Tilde.app/Contents/MacOS/tilde-mcp install claude      # claude-code and claude-desktop
```

Options: `--all`, `--uninstall`, `--dry-run`, and `--home <dir>`, which
uses another home folder and finds only apps inside it.

Tilde answers only calls that carry its token (`~/.tilde/local-token`, which only you can
read) as an `Authorization: Bearer` header. Install writes the header into each entry.

**Copy** in the **Copy setup** row on the same page copies these snippets, for agents that
are not listed. Each is the entry that Install writes, with your token in place of `<token>`:

**Claude Code**

```sh
claude mcp add --scope user --transport http tilde http://127.0.0.1:7311/mcp --header "Authorization: Bearer <token>"
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.tilde]
url = "http://127.0.0.1:7311/mcp"
http_headers = { Authorization = "Bearer <token>" }
default_tools_approval_mode = "approve"
```

Without `default_tools_approval_mode`, Codex asks before each call, and `codex exec` refuses the call.

**Cursor, others (HTTP)**

```json
{
  "mcpServers": {
    "tilde": {
      "url": "http://127.0.0.1:7311/mcp",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
```

**Harnesses that only start stdio servers**

```json
{
  "mcpServers": {
    "tilde": {
      "command": "/Applications/Tilde.app/Contents/MacOS/tilde-mcp",
      "args": []
    }
  }
}
```

`tilde-mcp` forwards stdio to the HTTP endpoint with the token, which it reads itself, and
starts Tilde when it is not running.

**Remote agents** (the agent runs on a server, you annotate on your Mac)

Settings → Agents → Remote machines lists the hosts of your ssh config and connections. Install
on one sets up its agent apps as on this Mac, and links it while Tilde runs: an ssh tunnel
from a private socket on the server (`~/.tilde/tilde.sock`, only your user can open it) to
Tilde. The agents there start `~/.tilde/bin/tproxy`, a small pipe to that socket, as a stdio
MCP server; it rides out a dropped link, so a running agent keeps Tilde. Tilde.app holds `tproxy` for each server system (macOS or Linux, arm64 or x86-64)
and copies the server's one there again whenever it changed. A server of another type is linked by a port that other users there
can reach, with a token, and Settings shows it as not protected. A server that an older Tilde
linked by a port moves to the socket with one Install for all its apps.

## Tools

| Tool | Inputs | Result |
|---|---|---|
| `start_annotation` | `url?`, `context = "window"`, `wait_seconds = 45` | The feedback, or a `session_id` that is still in progress |
| `wait_for_annotation` | `session_id`, `wait_seconds = 45` | The feedback, "still annotating", or "cancelled" |

### Skill and resources

The `tilde` skill is the user-facing command: type `/tilde` (or ask the agent to "annotate
with Tilde") in any app that loads Agent Skills. Settings → Agents writes it. The same text is
the MCP server's instructions, so agents without skills get it too. It lives only in
`Sources/TildeSkill/Skill.swift`.

- Resources `tilde://feedback/latest` and one per recent batch hold sent feedback, for
  example after a session that you started yourself. In Claude Code, type `@tilde:` to attach one. They carry the
  report as text and the screenshots as PNG blobs; the report gives the inbox folder, so an
  agent can also open the PNG files.
- While a tool call waits for you, Tilde streams progress such as "Tilde is open on the
  user's screen: 2 notes so far" to clients that ask for progress.

Send finishes the session. An open `wait_for_annotation` call returns at once. If
no call is open, the next call returns the stored result. Use a large
`wait_seconds` (up to 600) for harnesses with long tool timeouts.

`url` opens the page in Tilde's browser. Pages there give full DOM data: selector,
HTML, styles, React component names and, for React 18 dev builds, the source file.
The browser keeps cookies between launches, so you log in only once.

Only one session is on screen at a time. Further sessions queue.

When an agent's session opened a page in Tilde's browser, Send or Cancel closes the browser
and brings the agent's app (the one in front when the session started) back to the front.

## Annotate

Agents start a session with `start_annotation`. To start one yourself, tap ⌃ twice
or choose Start Annotation in the menu-bar menu. Use this to send feedback to any
agent by paste, or to try Tilde without an agent.

| Action | Result |
|---|---|
| Hover | Highlights the element under the cursor |
| Click | Annotates that element |
| Drag | Annotates a screen region (screenshot, no element data) |
| ↩ | Adds the comment |
| ⌘↩ | Adds the comment and sends everything |
| Esc | Closes the comment box |
| Click a marker | Edits or deletes that annotation |
| Space on a marker, or a thumbnail in the list | Opens the preview. ← and → show the other annotations; Esc or a click outside closes it |
| Record button (HUD) | Goes to recording mode and lets you choose a screen, window or phone to record; click the source name under the title to choose again before Record. Click the button again to go back to annotating. |
| Open Browser (menu) | Opens Tilde's browser and limits annotating to it; starts paused so you can browse first |
| Open in Tilde's browser (under the HUD) | Shows once a session after your first click on a page in Chrome, Safari, Arc, Edge or Brave, and stays until you use it or dismiss it with ×. Opens that page in Tilde's browser, where you pick exact page elements and send their HTML and styles. Your notes stay |
| Pause (HUD), or Esc with no box open | Lets you use your apps; markers stay. Annotate in the HUD, or ⌃ twice, goes on |
| Clear all (HUD trash) | Deletes all annotations and keeps the session; asks first |
| Cancel (HUD X or menu) | Closes the session without sending; the HUD asks first when there are annotations |
| Drag the HUD pill | Moves the HUD on that screen. An outline shows the home position; the pill snaps there when close. Settings → General → HUD position → Reset also puts it back |

While Tilde has the keyboard (where Esc works: its overlay, HUD or browser, never while you
type), single keys press the HUD's buttons, under the same rules. Each button's tooltip
shows its key, and Settings → Shortcuts changes them.

| Key | Result |
|---|---|
| A | Back to annotating from recording mode |
| R | Into or out of recording mode, as the record toggle |
| D | Starts drawing, as Draw |
| Space | Pauses or resumes; in recording mode records, pauses or resumes the clip. On a marker, Space opens its preview instead |
| A, R, O, P (while drawing) | Arrow, rectangle, circle, freehand. A and R pick their tools and stay in drawing |
| 1–6 (while drawing) | The colours, in the drawing bar's order |

While drawing, only the drawing keys work; D and Space do nothing. Done or Esc ends drawing.

Tilde does not take focus from your app while you annotate. It is the app in front only
while you write a comment, so that a dictation app pastes into the comment box.

**iOS Simulator (Xcode 27 Device Hub):** drag a region on the device screen. A click
gives only the whole device view. Device Hub exposes the iOS elements to Accessibility,
but it reports their frames without its zoom and pan, so Tilde cannot find the element
under the cursor.

## Output

The agent gets one text block and, per annotation, a close-up PNG and a context PNG,
in that order. The context PNG shows the window the element belongs to (without the
windows in front of it), or for a region the window that holds it or the screen area
around it, with the target outlined. `context: "none"` turns context PNGs off.
For a session that you started, Tilde copies the markdown report to the clipboard.
The report gives the folder of the screenshots.
Every sent batch is also saved to `~/.tilde/inbox/<time>_<session>/` as
`feedback.md` plus `annotation-N.png` and `annotation-N-context.png`.

## Development

```sh
scripts/check.sh      # before every commit: the next two, about 30 s, no screen
swift test            # unit and behaviour tests (about 10 s)
scripts/ui-check.sh   # the UI contract: a picture of each state, a row for each rule
scripts/ux-vm.sh      # the UX specs: the built app with real input, in a VM
scripts/e2e.sh        # full flow in one process with synthesized events
```

### Testing

| Layer | Covers | Run |
|---|---|---|
| `TildeCoreTests` | MCP session contract, HTTP server, node socket, the `tilde-mcp` stdio bridge, report path compaction | `swift test --filter TildeCoreTests` |
| `TildeInstallerTests` | Install, merge, idempotency, uninstall, Codex TOML and linked skills folders, in a temporary home | `swift test --filter TildeInstallerTests` |
| `TildeUITests` | What the controller does with no window on screen: the session flow, confirm flows, keys, saved sessions, note tracking rules, node links, the recorder, the Copy setup snippets | `swift test --filter TildeUITests` |
| UI contract, `Tests/Contract` | A picture of each state of the HUD, the list, the comment box, the preview, tooltips, the overlay, the browser toolbar and Settings; a row for each rule (state plus event gives state) | `scripts/ui-check.sh` |
| UX specs, `Tests/TildeUXTests` | A few flows that only the built app with real input and real apps can prove; they take over the screen | `scripts/ux-vm.sh` in the VM, `scripts/ux.sh` on this Mac |
| `scripts/e2e.sh` | The whole flow with synthesized events: hover, click, comment, preview, region, send, inbox, agent result, capture shapes | `scripts/e2e.sh` |

`scripts/check.sh` runs `swift test` and `scripts/ui-check.sh`; neither uses the screen, the
mouse or the keyboard.

The UI contract draws each state offscreen at 2× and compares it with its picture in
`Tests/Contract/pictures/macos-<version>/`. Text rendering changes between macOS versions,
so the pictures belong to one macOS and SDK (`recorded-on.txt`): on that setup every pixel
must be the same, on a close one a channel may differ by 2 in at most 0.1 % of the pixels,
and on another macOS no picture is compared. A picture that differs is written to
`.build/ui-check/<name>.png`. After an intended design change, look at it, then record it,
only on the macOS the pictures are for:

```sh
scripts/ui-check.sh --record <name>
```

Then look at the changed PNGs in `git diff` before you commit them. `Tests/Contract/README.md`
and `Tests/TildeUXTests/README.md` say how to add a state, a row or a flow.

`scripts/e2e.sh` runs the real MCP server, browser, overlay, HUD and comment box.
It drives them with synthesized AppKit events, acts as the agent, and writes
rendered screens plus the agent's result to `build/e2e/`. With `--external`, it
waits on port 7312 for a real agent:

```sh
scripts/e2e.sh --external &
codex exec -c 'mcp_servers.tilde.url="http://127.0.0.1:7312/mcp"' \
  -c 'mcp_servers.tilde.default_tools_approval_mode="approve"' \
  "Ask me for visual feedback on http://127.0.0.1:7313/ with tilde and summarize it."
```

The harness cannot see window-server behavior (click-through, other apps' windows,
permissions). For that, `scripts/build-driver.sh` builds `TildeDriver.app`, which
posts real input and takes screenshots over `http://127.0.0.1:7320` (see the header
of `Sources/tilde-driver/main.swift`). It needs its own Accessibility and Screen
Recording permissions. Tilde logs session steps under the `dev.tilde.app` subsystem:

```sh
log show --last 10m --predicate 'subsystem == "dev.tilde.app"'
```
