/// Tilde's Agent Skill, `<skills folder>/<name>/SKILL.md`. `checksum` is the value of Tilde's
/// mark on the file. Its text is the same for every app, since apps share skills folders.
/// The body is the only copy of the instructions: the MCP server also sends it, and Gemini
/// CLI's command holds it.
public func tildeSkill(name: String, checksum: String) -> String {
    """
    ---
    name: \(name)
    description: Get visual feedback from the user with Tilde. Use when the user starts this skill or asks to annotate with Tilde.
    disable-model-invocation: true
    metadata:
      tilde-checksum: \(checksum)
    ---

    \(tildeSkillBody)
    """
}

/// Gemini CLI's custom command, `<commands folder>/<name>.toml`: Gemini starts skills only
/// through the model, so the command holds the instructions itself. The body has no `\`,
/// `{{args}}`, `@{` or `!{`, which the string or Gemini would read.
public func tildeCommandTOML(checksum: String) -> String {
    """
    # Written by Tilde. tilde-checksum: \(checksum)
    description = "Get visual feedback from the user with Tilde."
    prompt = \"\"\"
    \(tildeSkillBody)\"\"\"

    """
}

/// The skill without its front matter.
public let tildeSkillBody = """
# Tilde

1. First action: call `start_annotation` from the `tilde` MCP server. Do not read files, run commands or explain first.
2. Pass `url` only if the user gave one or it is already known in this conversation, such as a dev server you started. Never search for one.
3. While the result says that the user is still annotating, call `wait_for_annotation` with the `session_id` and `wait_seconds` 600. Write nothing between calls.
4. When the feedback arrives, quote each annotation briefly (target and comment), then act on it. If a comment is a question or is unclear, answer or ask first.
5. If the user cancelled, stop. If the `tilde` tools are missing or cannot be reached, say in one line that the user must open Tilde on their Mac.

Each annotation has a close-up (primary) and a context image (secondary); look at the context image only if the close-up is not enough. Feedback the user sent earlier is in the resource `tilde://feedback/latest`.

"""
