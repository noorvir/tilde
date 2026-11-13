<p align="center">
<img src="docs/icon.png" width="128" alt="Tilde icon">
</p>

<h1 align="center">Tilde</h1>

<p align="center">Show your coding agent what you mean, right on the screen.</p>

## About

Tilde is a macOS menu bar app. You point at things on the screen, write a note, draw or sketch a wireframe, and Tilde sends it to your coding agent.

- **Annotate.** Pick an element in any app and write a note about it. Pages in Tilde's built-in browser also give the DOM and React data of the element.
- **Draw.** Draw arrows, rectangles, ellipses and free lines over the screen, in six colours.
- **Wireframe.** Sketch the skeletons of components over the screen, with labels, and send them as one note.
- **Record.** Record a display, a window, or an iPhone on a cable, to a video.
- **Remote machines.** Link a machine over ssh, so that its agents can use Tilde on your Mac.
- **History.** Open earlier sessions again from the menu.

## How it works with agents

Tilde runs a local MCP server on `127.0.0.1`. Each request needs a local token.

From the **Agents** menu, Tilde adds its MCP server and its `tilde` skill to these apps: Claude Code, Codex, Cursor, VS Code, Gemini CLI and Windsurf (Devin). For other apps, Settings shows the entry to copy. `tilde-mcp` is the stdio bridge for apps that start MCP servers as processes. It also starts Tilde when Tilde is not open.

The agent uses these MCP tools:

- `start_annotation` opens Tilde, optionally on a web page in its browser, and returns your feedback.
- `wait_for_annotation` waits while you still annotate.
- `get_report` reads a sent report again by its id.

The feedback is a Markdown report with your notes. Each note has a close-up picture and a picture of the window around it, with the target outlined. Tilde also keeps each report, its pictures and its videos in `~/.tilde/inbox/`, and gives the latest report as the MCP resource `tilde://feedback/latest`.

## Install

Tilde needs macOS 14 or later. It asks for the Screen Recording and Accessibility permissions.

**Download.** Get the DMG from [GitHub Releases](../../releases) and move Tilde to Applications. Tilde then updates itself with Sparkle.

**Build from source.** You need Swift 6 (Xcode or the Command Line Tools) and Go.

```sh
scripts/install-app.sh
```

This builds `Tilde.app`, installs it in `/Applications` and opens it.
