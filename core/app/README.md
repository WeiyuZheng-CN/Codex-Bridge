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

Local Qwen3.6 starts the verified upstream llama.cpp b10964 CUDA runtime on
`127.0.0.1:61991` when its card is selected. It uses an isolated Codex profile
with `requires_openai_auth = false`; the normal `%USERPROFILE%\.codex` profile
is not changed. See `docs/LOCAL-QWEN36-INTEGRATION.md` in the source package
for the model digest, 262K context/GPU-q8 settings, rollback path, and
troubleshooting checks.

The current local profile uses the full 262K context, GPU `q8_0` KV cache,
Flash Attention, and low reasoning with a 512-token budget. It is the maximum
context configuration tested on this RTX 5060 Laptop GPU.
The model picker exposes minimal, low, medium, high, xhigh, and max reasoning
effort; low remains the default.

The detailed Local Qwen3.6 AI maintenance guide is installed in
docs\LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md. Read it for exact hashes,
resource tuning, troubleshooting, upgrade, rollback, and acceptance checks.

For maintenance, recovery, or a Codex update, read `AI-MAINTENANCE-GUIDE.md`
first. Never share or commit generated `auth.json`, `config.yml`, profile
state, sessions, databases, Electron data, logs, or backups.
