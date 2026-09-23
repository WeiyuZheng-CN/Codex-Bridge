# Codex Vibe Software: installed maintenance guide

This is an AI-maintained local installation. Read `launcher.settings.json` and
`install-manifest.json` before changing it. They describe the physical app
path, profile roots, selected modes, and package version, but contain no keys.

## Current architecture

```text
Codex desktop shortcut
  -> Start-Codex-Chooser.ps1
     -> ChatGPT profile
     -> DeepSeek -> native DeepSeek Responses API
          -> Codex model picker: V4 Pro / V4 Flash / V4 Flash Vision
      -> OpenAI Transfer -> shared auth.json profile -> station API
           -> Pro/Legacy selected in the station web console
     -> Local Qwen3.6 -> Ollama Responses API -> isolated profile
                         llama.cpp CUDA remains fallback
```

The main chooser has one DeepSeek card. The native DeepSeek profile exposes
`deepseek-v4-pro`, `deepseek-v4-flash`, and
`deepseek-v4-flash-vision-exp` through the same provider entrance. The vision
model accepts JPEG, PNG, GIF, and WebP images as Responses API `input_image`
parts. The former Moon Bridge route is not included in the current application.
Its old source and binary are kept outside the repository package as a local
archive when recovery is needed.

The current public reference is `references\deepseek\260909`. An old
`NativeFlash` installer argument may still appear in a user's history, but it
maps to this same native DeepSeek entry; it must not create a second card or a
second model-selection dialog.

Provider profiles and Electron data are isolated. ChatGPT uses the normal
Codex profile as-is. The shared Transfer profile uses one station key in
`auth.json`; the web console chooses Pro or Legacy routing for that key. The
historical 260902 API Key Mode profile may remain in the user's existing
profile for rollback when a station still requires an environment key or actor
header.
The settings gear manages multiple keys for DeepSeek and Transfer. Keys are
stored with Windows DPAPI for the current user. A provider keeps the same
`CODEX_HOME` and Electron data when its active key changes, so history and
projects remain shared; the change takes effect after Codex is restarted.
The Transfer model catalog includes the current `gpt-5.6-*` models plus
`gpt-6-astra`, `gpt-6-sol`, and `gpt-6-luna`. The launcher refreshes it from
the authenticated `/v1/models` endpoint at startup and never sends a chat
request for model discovery.

Local Qwen3.6 is credential-free and is kept outside the portable app directory.
Its Ollama profile is
`%USERPROFILE%\Documents\Codex\local-qwen36-ollama-codex` and uses Codex's
built-in `ollama` provider at `http://127.0.0.1:11434/v1`. The verified
llama.cpp profile remains at `%USERPROFILE%\Documents\Codex\local-qwen36-codex`
and `http://127.0.0.1:61991/v1` as fallback. Read
`docs\LOCAL-QWEN36-INTEGRATION.md` for both paths and rollback procedure.

The current Ollama defaults are `262144` context tokens, one request slot,
Q8 KV cache, Flash Attention enabled, max reasoning, and no launcher-imposed
output-token cap. The full context was tested on the RTX 5060 Laptop GPU; it
uses most of the available VRAM and should not be combined with another heavy
GPU workload. The independent llama.cpp fallback keeps CUDA `q8_0`, Flash
Attention, low reasoning, and its tested 512-token budget. The Local Qwen3.6
model catalog exposes minimal, low, medium, high, xhigh, and max reasoning;
higher levels may use more tokens and take longer.
The server also uses the bundled Codex-compatible Jinja template to normalize
Codex system/developer message order before Qwen inference.
Optional web search uses the installed `ollama_web_search` MCP server and the
private Ollama API-key file outside this package. Keep `OLLAMA_NO_CLOUD=1` so
model inference stays local; only approved MCP search/fetch calls use the hosted
Ollama web API.
The external local-qwen36 launcher must contain
qwen3.6-codex-compatible.jinja and pass it with chat-template-file.

For current station behavior, read:

- <https://docs.ai-pixel.online/docs/api>
- <https://docs.ai-pixel.online/docs/api/responses>
- <https://docs.ai-pixel.online/docs/api/models>
- <https://docs.ai-pixel.online/docs/normal-client-setup>
- <https://docs.ai-pixel.online/docs/normal-account-mode>

When a key or generated configuration is needed, have the user open
<https://ai-pixel.online/keys> and click **使用密匙**. Keep the result private.

Legacy files are intentionally not copied into the installed core. If an old
Moon Bridge history needs repair, use the archived files from the source
package's legacy archive or an older Git release, without copying user state
into this package.

The detailed Local Qwen3.6 maintenance handoff is installed under
docs\LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md. Read it before changing the
model, runtime, context, memory settings, or local profile.

## Agent maintenance rule

The agent may adapt this installation to a new Codex build, provider revision,
model, endpoint, authentication shape, path, or user-requested feature. Before
replacing a working file:

1. inspect the real behavior and current profile;
2. save a dated copy of the affected file;
3. make the smallest understandable change;
4. record it in `LOCAL-CHANGES.md` with reason and rollback path;
5. parse edited PowerShell and run the affected `-ValidateOnly` or UI preview.

Do not require every unrelated mode or remote API to pass before accepting a
local change. `SKIPPED` means a mode is not configured. A local `OK` result is
not proof of remote key, quota, account, or station availability.

If the station changes its generated configuration, compare the current
**使用密匙** output with the shared profile. Keep one profile when both web
modes use the same `auth.json` shape; retain or restore `legacy-transfer` when
API Key Mode or an actor header is required.

## Boundaries

- Never expose or copy values from `auth.json`, generated `config.yml`, or
  secret-bearing profile settings into chat, logs, screenshots, source, or a
  shareable archive.
- Do not silently rewrite `%USERPROFILE%\.codex`.
- Ask before deleting personal state, changing an external account, installing
  untrusted software, or publishing files.
- Do not terminate the Codex process hosting the current agent task.
- Do not recursively delete through the friendly `Codex-Launcher` junction.

When a useful feature should be shared, export only sanitized source,
templates, prompts, and documentation—not the configured installation.
