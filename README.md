# Tilde

A macOS menu-bar app that lets any coding agent ask you for visual feedback.

The agent calls an MCP tool. Tilde opens annotate mode on your screen. You click
elements or drag regions on any app or web page, add a comment to each, and press
Send. The agent gets a markdown report plus one screenshot per annotation.

- Works with every MCP harness: Claude Code, Codex, Cursor, Gemini CLI, VS Code and others.
- Works with remote agents through an SSH reverse tunnel. Screenshots go back inline.
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
The menu-bar item has "Connect an Agent" entries that copy these snippets.

**Claude Code**

```sh
claude mcp add --scope user --transport http tilde http://127.0.0.1:7311/mcp
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.tilde]
url = "http://127.0.0.1:7311/mcp"
default_tools_approval_mode = "approve"
```

Without `default_tools_approval_mode`, Codex asks before each call, and `codex exec` refuses the call.

**Cursor, VS Code, others (HTTP)**

```json
{ "mcpServers": { "tilde": { "url": "http://127.0.0.1:7311/mcp" } } }
```

**Harnesses that only start stdio servers**

```json
{ "mcpServers": { "tilde": { "command": "/Applications/Tilde.app/Contents/MacOS/tilde-mcp" } } }
```

`tilde-mcp` forwards stdio to the HTTP endpoint and starts Tilde when it is not running.

**Remote agents** (the agent runs on a server, you annotate on your Mac)

```sh
ssh -R 7311:127.0.0.1:7311 your-server
```

Then configure the agent on the server with `http://127.0.0.1:7311/mcp`.

## Tools

| Tool | Inputs | Result |
|---|---|---|
| `start_annotation` | `message?`, `url?`, `wait_seconds = 45` | The feedback, or a `session_id` that is still in progress |
| `wait_for_annotation` | `session_id`, `wait_seconds = 45` | The feedback, "still annotating", or "cancelled" |

Send finishes the session. An open `wait_for_annotation` call returns at once. If
no call is open, the next call returns the stored result. Use a large
`wait_seconds` (up to 600) for harnesses with long tool timeouts.

`url` opens the page in Tilde's browser. Pages there give full DOM data: selector,
HTML, styles, React component names and, for React 18 dev builds, the source file.
The browser keeps cookies between launches, so you log in only once.

Only one session is on screen at a time. Further sessions queue.

## Annotate

Agents start a session with `start_annotation`. To start one yourself, press ⌃⌥A
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
| ⌃⌥P or Pause (HUD) | Lets you use your apps; markers stay. Press again to resume |
| Cancel (HUD or menu) | Closes the session without sending |

Tilde does not take focus from your app while you annotate.

**iOS Simulator (Xcode 27 Device Hub):** drag a region on the device screen. A click
gives only the whole device view. Device Hub exposes the iOS elements to Accessibility,
but it reports their frames without its zoom and pan, so Tilde cannot find the element
under the cursor.

## Output

The agent gets one text block and one PNG per annotation, in the same order.
For a session that you started, Tilde copies the markdown report to the clipboard.
The report gives the folder of the screenshots.
Every sent batch is also saved to `~/.tilde/inbox/<time>_<session>/` as
`feedback.md` plus `annotation-N.png`.

## Development

```sh
swift test           # MCP session contract and HTTP server
scripts/e2e.sh       # full flow in one process, no permissions needed
```

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
