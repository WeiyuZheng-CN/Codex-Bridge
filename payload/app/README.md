# Installed Codex Vibe Software

Open the `Codex` desktop shortcut, or run `Start-Codex-Chooser.cmd`, and use
the four-card graphical launcher.

The top-level choices are ChatGPT, DeepSeek V4 Pro, DeepSeek V4 Flash, and
OpenAI Transfer. OpenAI Transfer opens a concise second dialog with
`OpenAI-transfer-Pro` and `OpenAI-transfer`.

Cards for modes not selected during installation remain visible but are
dimmed. Give the original package and `AI-MAINTENANCE-GUIDE.md` to an AI agent
when you want to configure another mode or evolve the launcher.

Quit Codex completely before switching modes. Each provider has its own
profile and machine-local configuration. The launcher reads those paths from
`launcher.settings.json`; it does not assume a username or drive.

For maintenance, recovery, or a Codex update, read `AI-MAINTENANCE-GUIDE.md`
first. Never share or commit generated `auth.json`, `config.yml`, profile
state, sessions, databases, Electron data, logs, or backups.
