# Installed Codex Vibe Software

Open the `Codex` desktop shortcut, or run `Start-Codex-Chooser.cmd`, and use
the graphical launcher with ChatGPT, DeepSeek, and OpenAI Transfer entries.

The top-level choices are ChatGPT, DeepSeek, and OpenAI Transfer. The single
DeepSeek entry uses the official native profile. After Codex opens, its model
picker contains V4 Pro, V4 Flash, and V4 Flash Vision. OpenAI Transfer uses one
shared `auth.json` profile; switch between `OpenAI-transfer-Pro` and
`OpenAI-transfer` in the transfer-station web console for the same key.

Cards for modes not selected during installation remain visible but are
dimmed. Give the original package and `AI-MAINTENANCE-GUIDE.md` to an AI agent
when you want to configure another mode or evolve the launcher.

Quit Codex completely before switching providers. Each provider has its own
profile and machine-local configuration. The launcher reads those paths from
`launcher.settings.json`; it does not assume a username or drive.

If the current **使用密匙** popup returns API Key Mode or an extra actor
header, an AI agent may retain the old compatibility profile and adapt it
locally. Current station references are documented at:
<https://docs.ai-pixel.online/docs/api>.

For maintenance, recovery, or a Codex update, read `AI-MAINTENANCE-GUIDE.md`
first. Never share or commit generated `auth.json`, `config.yml`, profile
state, sessions, databases, Electron data, logs, or backups.
