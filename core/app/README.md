# Installed Codex Vibe Software

Open the `Codex` desktop shortcut and use the graphical launcher with ChatGPT,
DeepSeek, OpenAI Transfer, and Local Qwen3.6 entries. For diagnostics, run
`Start-Codex-Chooser.ps1 -ValidateOnly` with Windows PowerShell 5.1.

The top-level choices are ChatGPT, DeepSeek, OpenAI Transfer, and Local Qwen3.6.
The single
DeepSeek entry uses the official native profile. After Codex opens, its model
picker contains V4 Pro, V4 Flash, and V4 Flash Vision. OpenAI Transfer uses one
shared `auth.json` profile; switch between `OpenAI-transfer-Pro` and
`OpenAI-transfer` in the transfer-station web console for the same key.
Use the gear button in the top-right corner to save and select multiple
DeepSeek or Transfer keys. They are encrypted for the current Windows user.
Keys for the same provider reuse that provider's history and projects; restart
Codex after changing the active key.
The Transfer picker catalog currently includes `gpt-5.6-sol`, `gpt-5.6-luna`,
`gpt-5.6-terra`, `gpt-6-astra`, `gpt-6-sol`, and `gpt-6-luna`. The launcher
refreshes this list from the authenticated station `/v1/models` endpoint when
Transfer starts.

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

Local Qwen3.6 starts the installed Ollama service on `127.0.0.1:11434` when its
card is selected. It uses Codex's built-in `ollama` provider and an isolated
profile; the normal `%USERPROFILE%\.codex` profile is not changed. The tested
Ollama route supports structured tool calls and image input. The original
llama.cpp CUDA route remains available on `127.0.0.1:61991` as a fallback. See
`docs/LOCAL-QWEN36-INTEGRATION.md` for both paths and rollback checks.

The current local Ollama profile uses the full 262K context, one request slot,
Q8 KV cache, thinking, and no launcher-imposed output-token cap. It is the
maximum context configuration targeted on this RTX 5060 Laptop GPU. The
fallback llama.cpp profile independently retains its CUDA q8_0/Flash Attention
configuration.
The model picker exposes minimal, low, medium, high, xhigh, and max reasoning
effort; low remains the default.
An optional `ollama_web_search` MCP server can add approved web search and page
fetch without moving Qwen inference off the local GPU.

The detailed Local Qwen3.6 AI maintenance guide is installed in
docs\LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md. Read it for exact hashes,
resource tuning, troubleshooting, upgrade, rollback, and acceptance checks.

For maintenance, recovery, or a Codex update, read `AI-MAINTENANCE-GUIDE.md`
first. Never share or commit generated `auth.json`, `config.yml`, profile
state, sessions, databases, Electron data, logs, or backups.
