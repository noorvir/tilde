/// The `tilde` Agent Skill, written as `<skills folder>/tilde/SKILL.md` by the installer.
/// This is the only copy of its text: the MCP server also sends the body as its instructions.
public let tildeSkill = """
---
name: tilde
description: Get visual feedback from the user with Tilde. Use for /tilde and "annotate with Tilde".
---

\(tildeSkillBody)
"""

/// The skill without its front matter.
public let tildeSkillBody = """
# Tilde

1. First action: call `start_annotation` from the `tilde` MCP server. Do not read files, run commands or explain first.
2. Pass `url` only if the user gave one or it is already known in this conversation, such as a dev server you started. Never search for one.
3. While the result says that the user is still annotating, call `wait_for_annotation` with the `session_id` and `wait_seconds` 600. Write nothing between calls.
4. When the feedback arrives, quote each annotation briefly (target and comment), then act on it. If a comment is a question or is unclear, answer or ask first.
5. If the user cancelled, stop. If the `tilde` tools are missing, say in one line that the user must open Tilde.

Each annotation has a close-up (primary) and a context image (secondary); look at the context image only if the close-up is not enough. Feedback the user sent earlier is in the resource `tilde://feedback/latest`.

"""
