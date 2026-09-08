# Evolve this Vibe Software with an AI

When a new need appears, give the source package (or installed folder) to a
trusted coding agent and use this prompt:

```text
Please evolve this Codex Vibe Software for the following need:

<describe what I want in ordinary language>

First read README.md, AGENTS.md, AI-INSTALLATION-GUIDE.md, the installed
AI-MAINTENANCE-GUIDE.md if present, launcher.settings.json if present, and
LOCAL-CHANGES.md if present. Inspect the current behavior and preserve useful
local changes. You may edit the local code and configuration needed for this
feature without asking me to make technical choices. Ask me only when a real
product choice, secret, external account action, download, or destructive
operation needs my decision.

Before replacing a working file, save a dated backup. Keep credentials out of
chat, source, logs, screenshots, and exported packages. Test in proportion to
the change: syntax plus the affected launcher path is normally enough; do not
turn an optional remote API test into a blocker. Record what changed, why, and
how to undo it in LOCAL-CHANGES.md. Update the relevant guide.

If this feature could help other users, also prepare a clean shareable patch
or source-package copy that contains no credentials, sessions, personal paths,
logs, databases, or machine-generated state. Show me the proposed share list;
do not upload or publish it until I explicitly approve.
```

The useful unit of sharing is not another person's whole configured computer.
It is a small source change, template, prompt improvement, or documented
compatibility rule that another agent can adapt to its own user.

