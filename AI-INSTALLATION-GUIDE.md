# Codex Vibe Software architecture and adaptation guide

## Purpose

The package is a software seed for Windows 10/11 x64. It combines a stable
launcher core with enough explanation for an AI agent to install and evolve it
on computers the original author has never seen. It intentionally does not
encode every environment or future provider revision.

The three-entry WPF chooser remains the human-facing launcher. The AI
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
```

`launcher.settings.json`, generated on the target computer, records the Codex
executable, profile roots, and `enabled_modes`. Unselected cards stay visible
and are dimmed. This makes later growth discoverable without pretending that a
missing credential is already configured.

Default destinations are:

```text
%LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge\   launcher application
<Documents>\Codex\deepseek-native-test\         native DeepSeek profile
<Documents>\Codex\ai-pixel-relay\               shared Transfer profile
<Documents>\Codex\ai-pixel-relay\legacy-transfer\  old compatibility profile, if retained
<Documents>\Codex\Codex-Launcher                friendly app link
```

The agent may choose different safe paths. The normal `%USERPROFILE%\.codex`
profile is used only by the ChatGPT launcher and is not rewritten.

## Mode-aware installation

The installer accepts:

```text
-Modes ChatGPT,DeepSeek,Transfer
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
| `-TransferProModel` / `-TransferModel` | Current station model name for the shared profile. The old Pro name remains accepted. |
| `-TransferProReasoningEffort` | Current reasoning default for the shared profile. |
| `-TransferProKeyFile` / `-TransferLegacyKeyFile` | Compatibility aliases for `-TransferKeyFile`; use one key file. |
| `-TransferLegacyWithoutActor` | Retained for old scripts; the shared auth.json profile does not add an actor header. |
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
`configuration\260909` and
<https://api-docs.deepseek.com/guides/vision>.

Moon Bridge and its source remain in the package as historical compatibility
resources, but the primary DeepSeek launcher does not start the bridge.

## Current Transfer baseline

The official station documentation is the source of truth:

- API overview: <https://docs.ai-pixel.online/docs/api>
- Responses API: <https://docs.ai-pixel.online/docs/api/responses>
- Models: <https://docs.ai-pixel.online/docs/api/models>
- Client configuration: <https://docs.ai-pixel.online/docs/normal-client-setup>
- Account-mode routing: <https://docs.ai-pixel.online/docs/normal-account-mode>

The sanitized historical references are stored under `configuration\260902`.
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
runtime data, obvious credential-shaped values, and Moon Bridge provenance.
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

- templates under `payload\templates` for a new provider revision;
- model catalogs under `payload\catalogs`;
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
