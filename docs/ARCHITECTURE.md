# Codex Vibe Software architecture and adaptation guide

## Purpose

The package is a software seed for Windows 10/11 x64. It combines a stable
launcher core with enough explanation for an AI agent to install and evolve it
on computers the original author has never seen. It intentionally does not
encode every environment or future provider revision.

The four-entry WPF chooser remains the human-facing launcher. The AI
conversation is the installer, repair assistant, and development interface.

## Architecture

The chooser dispatches provider launchers in separate PowerShell processes:

```text
Start-Codex-Chooser.ps1
  ChatGPT             -> normal user Codex profile
  DeepSeek             -> one native profile -> DeepSeek Responses API
    Codex model picker -> V4 Pro / V4 Flash / V4 Flash Vision
  OpenAI Transfer     -> one shared auth.json profile -> station Responses API
    Pro / Legacy       -> selected by the transfer-station web console
  Local Qwen3.6       -> Ollama Responses API -> isolated profile
                         llama.cpp CUDA server remains fallback
```

`launcher.settings.json`, generated on the target computer, records the Codex
executable, profile roots, credential-store path, and `enabled_modes`. Unselected cards stay visible
and are dimmed. This makes later growth discoverable without pretending that a
missing credential is already configured.

The Codex desktop app is a Microsoft Store/MSIX package, and current builds
refuse to run when `ChatGPT.exe` is started as a plain file: the process gets no
package identity and the app aborts with "the process has no package identity"
(Windows error 15700). Every provider launcher therefore activates the app
inside its package with `Invoke-CommandInDesktopPackage`, through the shared
`core\app\Codex-PackageLaunch.ps1` helper. Package activation does not carry the
calling process's environment into the app, so the profile paths are set inside
a generated `.cmd` wrapper that runs in the packaged child; setting `CODEX_HOME`
in the launcher process alone is not sufficient. The package is always resolved
dynamically with `Get-AppxPackage`, so a Store update cannot break the path.

Default destinations are:

```text
%LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge\   launcher application
<Documents>\Codex\deepseek-native-test\         native DeepSeek profile
<Documents>\Codex\ai-pixel-relay\               shared Transfer profile
<Documents>\Codex\ai-pixel-relay\legacy-transfer\  old compatibility profile, if retained
<Documents>\Codex\local-qwen36\                 verified model + CUDA runtime
<Documents>\Codex\local-qwen36-codex\          local Codex profile
<Documents>\Codex\codex-vibe-settings\        encrypted key store
<Documents>\Codex\Codex-Launcher                friendly app link
```

The agent may choose different safe paths. The normal `%USERPROFILE%\.codex`
profile is used only by the ChatGPT launcher and is not rewritten.

The chooser's settings gear opens a local key manager for DeepSeek and OpenAI
Transfer. Each saved key has a user-chosen name and an active selection. Key
values are stored with Windows DPAPI for the current Windows user. Switching a
key updates only the provider's authentication field; the provider's existing
`CODEX_HOME` and Electron data directories remain unchanged, so that provider's
dialog history and projects are shared across its saved keys. The change takes
effect the next time that provider is launched; the settings window never
terminates an existing Codex process.

Local Qwen3.6 local inference is credential-free. Its primary isolated profile uses Codex's
built-in Ollama provider and the local Responses API at
`http://127.0.0.1:11434/v1`. The Q4_K_M model is about 22 GiB and is managed by
Ollama outside the portable launcher package. The verified llama.cpp profile
at `http://127.0.0.1:61991/v1` remains available as a fallback.
The current model digest is
`D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC`.
The tested Ollama profile uses the full `262144`-token model context, one
parallel sequence, and a Q8 KV cache. It supports tools, thinking, and image
input. The fallback runtime independently uses the full `262144`-token context,
CUDA `q8_0` KV cache, and Flash Attention; the MoE experts remain in system RAM.
The Ollama catalog exposes minimal, low, medium, high, xhigh, and max reasoning,
with max as the default. The launcher adds no fixed output-token cap.
Optional web search is a separate MCP server named `ollama_web_search`; it uses
the external Ollama API only for search/fetch, while the Qwen model remains on
the local Ollama runner.
The model weights and CUDA runtime are external assets and are deliberately
not bundled in this public source package. The target machine must stage them
outside the repository before selecting Local Qwen3.6.

## Mode-aware installation

The installer accepts:

```text
-Modes ChatGPT,DeepSeek,Transfer,LocalQwen36
```

Use `-Modes all` for everything. If `-Modes` is omitted in non-interactive
automation, supplied credential-file paths are used to infer a useful subset;
with no credentials it installs ChatGPT only. In an attended run, the installer
asks which modes to install. ChatGPT is always included as the base route.
For compatibility, old names such as `NativeFlash` and
`deepseek-v4-flash` are accepted as aliases for the single `DeepSeek` mode.

Examples:

```powershell
# Shared Transfer profile (plus ChatGPT)
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes Transfer `
  -TransferKeyFile "D:\Private\transfer.txt" `
  -NonInteractive

# Native DeepSeek with all three models (plus ChatGPT)
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes DeepSeek `
  -DeepSeekKeyFile "D:\Private\deepseek.txt" `
  -NonInteractive
```

Those paths are examples, not required locations. Without key-file arguments,
omit `-NonInteractive` and let the user enter secrets locally.

Other useful parameters are:

| Parameter | Meaning |
|---|---|
| `-TransferKeyFile` | One current station key for the shared Transfer profile. |
| `-CodexExecutablePath` | Full path to `ChatGPT.exe` when discovery fails. |
| `-InstallRoot` / `-ProfilesRoot` | Machine-specific destinations. |
| `-NoDesktopShortcut` / `-NoFriendlyLink` | Skip optional shell integration. |
| `-TransferModel` | Current station model name for the shared profile. |
| `-TransferReasoningEffort` | Current reasoning default for the shared profile. |
| `-LocalQwenRoot` / `-LocalQwenProfileRoot` | Stable local model/runtime and isolated profile destinations. |
| `-TransferKeyFile` | The single shared Transfer key file. Old Pro/Legacy names remain aliases. |
| `-ValidateOnly` | Inspect package, paths, selected modes, and supplied key files without installing. |
| `-SkipPackageValidation` | Continue after an agent has inspected a warning caused by a deliberate local adaptation. |

## Credentials

Required inputs depend on the selected modes. The native DeepSeek profile uses
one DeepSeek key for Pro, Flash, and Flash Vision. The shared Transfer profile
uses one station key in `auth.json`; the station web console decides whether
that key currently routes through Pro or Legacy. An actor-authorization value
is only relevant to an older API Key Mode compatibility profile.

Pass paths to private one-line files outside the extracted package, or let the
user type into local secure prompts. Never place secret values on command lines
or in AI chat. Generated local credential/configuration files receive private
ACLs where Windows permits it.

## Current DeepSeek native baseline

The 260909 reference and official Vision guide use the native DeepSeek API at
`https://api.deepseek.com`. The generated Codex profile uses the Responses API
and one model catalog containing:

- `deepseek-v4-pro`;
- `deepseek-v4-flash`;
- `deepseek-v4-flash-vision-exp`.

There is no second DeepSeek dialog. The user starts DeepSeek once and selects
the desired model in Codex. The vision model accepts JPEG, PNG, GIF, and WebP
images through Responses API `input_image` parts. See
`references\deepseek\260909` and
<https://api-docs.deepseek.com/guides/vision>.

Moon Bridge and its source are not part of the active package. Historical
files are retained under archive/legacy-moon-bridge; older Git releases and
that archive remain available for one-time recovery work.

## Current Transfer baseline

The official station documentation is the source of truth:

- API overview: <https://docs.ai-pixel.online/docs/api>
- Responses API: <https://docs.ai-pixel.online/docs/api/responses>
- Models: <https://docs.ai-pixel.online/docs/api/models>
- Client configuration: <https://docs.ai-pixel.online/docs/normal-client-setup>
- Account-mode routing: <https://docs.ai-pixel.online/docs/normal-account-mode>

Historical Transfer compatibility is summarized in
`docs\LEGACY-COMPATIBILITY.md`.
For the current key, direct the user to <https://ai-pixel.online/keys> and ask
them to click **使用密匙**. The resulting configuration or credentials must
remain in a private file outside the repository, or be entered through the
local hidden prompt. The agent should use only the private file path and must
not ask the user to paste page contents into chat.

The two screenshots supplied for the current Pro/Legacy key both show the
same `auth.json mode` shape:

```toml
model_provider = "OpenAI"
base_url = "https://ai-pixel.online"
wire_api = "responses"
requires_openai_auth = true
```

That is why new installations use one shared Transfer profile and one
`auth.json`. The web console's Pro/Legacy setting is expected to change server
side routing for the same key. The selected model must still be available to
that key; check `/v1/models` or the model list returned by **使用密匙**.

The current Transfer catalog includes:

- `gpt-5.6-sol`
- `gpt-5.6-luna`
- `gpt-5.6-terra`
- `gpt-6-astra`
- `gpt-6-sol`
- `gpt-6-luna`

The currently tested Transfer entries `gpt-5.6-sol`, `gpt-5.6-luna`,
`gpt-5.6-terra`, `gpt-6-sol`, `gpt-6-luna`, and `gpt-6-astra` advertise both
text and image input. The capability flag was confirmed with minimal real
image requests on September 23, 2026; a future station revision should be
retested before changing the catalog.

When the Transfer launcher starts, it performs a read-only authenticated
`GET /v1/models` and refreshes the shared `models.json` catalog. It keeps a
dated catalog backup and preserves the packaged catalog if the station is
temporarily unavailable. This updates the Codex picker without sending a chat
request.

The older 260902 API Key Mode remains a compatibility reference:

```toml
requires_openai_auth = false
env_key = "SUB2API_API_KEY"
http_headers = { "x-openai-actor-authorization" = "<local secret>" }
```

If a future popup returns this older shape, or adds a different required
header, do not force it into the shared profile. Keep the old compatibility
profile, save a dated backup, and let the agent adapt the smallest local block.
The endpoint and auth shape must be inferred from the current popup, not from a
model name or the 260902 date alone.

## Validation philosophy

`Validate-Package.ps1` checks missing core files, syntax, JSON, accidental
runtime data, and obvious credential-shaped values.
It is a fast diagnostic, not a trust ceremony. After inspecting a warning that
was caused by an intentional local adaptation, the agent can rerun the
installer with `-SkipPackageValidation` and rely on the focused installed-path
check.

After installation, run:

```powershell
& "<InstallRoot>\Start-Codex-Chooser.ps1" -ValidateOnly
```

`OK` means the installed local route is structurally ready. `SKIPPED` means the
mode was not selected. Neither result proves that a paid API key, quota,
account, or remote station is currently available. Test a real provider only
when the user wants an attended network test.

## Adaptation and extension points

An agent may modify:

- templates under `core\templates` for a new provider revision;
- model catalogs under `core\catalogs`;
- provider launchers for changed environment handling;
- the WPF chooser while preserving a concise, non-technical experience;
- the installer for a target computer's path, permission, or app-discovery
  behavior;
- maintenance helpers or a new mode requested by the user.

Before replacing a working local file, save a dated backup. Record local work
in `LOCAL-CHANGES.md` with date, need, files, behavior, check performed, and
rollback path. A small change should receive a small check: parse the edited
PowerShell and exercise the affected `-ValidateOnly` or preview path.

When sharing a useful extension, export source/templates/docs only. Exclude
`auth.json`, generated `config.yml`, API keys, actor values, sessions,
databases, logs, Electron data, PID files, caches, backups, and personal paths.

## Repair heuristics

- Codex not found: locate the installed `ChatGPT.exe` and pass its path.
- "ChatGPT failed to start" with "the process has no package identity": a Store
  update changed the launch contract, or something started `ChatGPT.exe`
  directly. Launch through `Start-Codex-*` (package activation) rather than the
  raw executable, and re-check `core\app\Codex-PackageLaunch.ps1`.
- A card is dimmed: the mode is not in `enabled_modes`; ask for its credential
  and configure it rather than calling the UI broken.
- Transfer 409: inspect the station/account connection state before changing
  the launcher; a web-console connection step may be required.
- Provider settings changed: compare the current **使用密匙** output with the
  official station docs. Keep one shared profile only when both modes return
  the same auth shape; otherwise retain a separate compatibility profile.
- A preflight hash/check changed after an intentional edit: inspect the diff,
  then continue; do not undo a useful feature merely to satisfy an old hash.
- Codex is already open: finish the current task and quit it before switching
  provider profiles. Never terminate the process hosting the agent task.

The goal is a working, understandable local system that can keep evolving—not
a frozen copy of the author's computer.
