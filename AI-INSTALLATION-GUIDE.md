# Codex Vibe Software architecture and adaptation guide

## Purpose

The package is a software seed for Windows 10/11 x64. It combines a stable
launcher core with enough explanation for an AI agent to install and evolve it
on computers the original author has never seen. It intentionally does not
encode every environment or future provider revision.

The four-card WPF chooser remains the human-facing launcher. The AI
conversation is the installer, repair assistant, and development interface.

## Architecture

The chooser dispatches provider launchers in separate PowerShell processes:

```text
Start-Codex-Chooser.ps1
  ChatGPT             -> normal user Codex profile
  DeepSeek V4 Pro     -> local Moon Bridge -> DeepSeek Anthropic API
  DeepSeek V4 Flash   -> isolated profile -> DeepSeek Responses API
  OpenAI Transfer     -> second selector
    OpenAI-transfer-Pro -> isolated Pro profile
    OpenAI-transfer     -> isolated Legacy profile
```

`launcher.settings.json`, generated on the target computer, records the Codex
executable, profile roots, and `enabled_modes`. Unselected cards stay visible
and are dimmed. This makes later growth discoverable without pretending that a
missing credential is already configured.

Default destinations are:

```text
%LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge\   launcher application
<Documents>\Codex\deepseek-native-test\         native Flash profile
<Documents>\Codex\ai-pixel-relay\               Transfer Pro profile
<Documents>\Codex\ai-pixel-relay\legacy-transfer\  Transfer Legacy profile
<Documents>\Codex\Codex-Launcher                friendly app link
```

The agent may choose different safe paths. The normal `%USERPROFILE%\.codex`
profile is used only by the ChatGPT launcher and is not rewritten.

## Mode-aware installation

The installer accepts:

```text
-Modes ChatGPT,DeepSeek,NativeFlash,TransferPro,TransferLegacy
```

Use `-Modes all` for everything. If `-Modes` is omitted in non-interactive
automation, supplied credential-file paths are used to infer a useful subset;
with no credentials it installs ChatGPT only. In an attended run, the installer
asks which modes to install. ChatGPT is always included as the base route.

Examples:

```powershell
# Pro transfer only (plus ChatGPT)
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes TransferPro `
  -TransferProKeyFile "D:\Private\transfer-pro.txt" `
  -NonInteractive

# Both DeepSeek routes (plus ChatGPT)
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes DeepSeek,NativeFlash `
  -DeepSeekKeyFile "D:\Private\deepseek.txt" `
  -NonInteractive
```

Those paths are examples, not required locations. Without key-file arguments,
omit `-NonInteractive` and let the user enter secrets locally.

Other useful parameters are:

| Parameter | Meaning |
|---|---|
| `-CodexExecutablePath` | Full path to `ChatGPT.exe` when discovery fails. |
| `-InstallRoot` / `-ProfilesRoot` | Machine-specific destinations. |
| `-NoDesktopShortcut` / `-NoFriendlyLink` | Skip optional shell integration. |
| `-TransferProModel` / `-TransferLegacyModel` | Current station model names. |
| `-TransferProReasoningEffort` / `-TransferLegacyReasoningEffort` | Current reasoning defaults. |
| `-TransferLegacyWithoutActor` | Omit the actor header only when the station confirms it is unnecessary. |
| `-ValidateOnly` | Inspect package, paths, selected modes, and supplied key files without installing. |
| `-SkipPackageValidation` | Continue after an agent has inspected a warning caused by a deliberate local adaptation. |

## Credentials

Required inputs depend on the selected modes. DeepSeek Pro and native Flash can
use the same DeepSeek key. Transfer Pro and Transfer Legacy receive distinct
keys. Legacy may additionally need an actor-authorization value.

Pass paths to private one-line files outside the extracted package, or let the
user type into local secure prompts. Never place secret values on command lines
or in AI chat. Generated local credential/configuration files receive private
ACLs where Windows permits it.

## Current Transfer baseline

The included templates currently share:

```toml
base_url = "https://ai-pixel.online"
wire_api = "responses"
```

Pro currently uses `requires_openai_auth = true` with its own `auth.json`.
Legacy currently uses 260902 API Key Mode:

```toml
requires_openai_auth = false
env_key = "SUB2API_API_KEY"
http_headers = { "x-openai-actor-authorization" = "<local secret>" }
```

These are defaults, not eternal truths. If the station changes, the agent may
adapt a working copy after comparing the newest provider information. Preserve
the separation of Pro and Legacy credentials and profiles. The Transfer
launcher accepts any valid HTTP(S) station URL found in the local profile so a
legitimate endpoint adaptation does not require rewriting its validator.

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
- Provider settings changed: compare the current profile and station docs,
  adapt the smallest block, and keep Pro/Legacy isolated.
- A preflight hash/check changed after an intentional edit: inspect the diff,
  then continue; do not undo a useful feature merely to satisfy an old hash.
- Codex is already open: finish the current task and quit it before switching
  provider profiles. Never terminate the process hosting the agent task.

The goal is a working, understandable local system that can keep evolving—not
a frozen copy of the author's computer.
