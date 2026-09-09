# AI agent working instructions

This repository is an AI-maintained software seed. Optimize for a successful,
understandable local installation, not for making every target computer match
the package author's machine.

## Working style

1. Read `START-HERE-FOR-AI.md` and `AI-INSTALLATION-GUIDE.md` completely.
2. Inspect first, then act. Do reversible, in-scope work without repeatedly
   asking for permission.
3. Ask for the modes the user wants. Do not collect credentials for modes they
   will not use.
4. Use package checks as diagnostics. A missing core file or syntax error is a
   real problem; a stale recorded hash after an intentional edit is not.
5. Make the smallest local adaptation that explains the observed difference.
   Back up the affected file and write a short `LOCAL-CHANGES.md` entry.
6. Leave the user with the graphical launcher, a concise result, and a clear
   boundary between local validation and a real provider request.

## Modes and inputs

| Installer mode | UI choice | Private input |
|---|---|---|
| `ChatGPT` | ChatGPT | Existing Codex login; no new key |
| `DeepSeek` | DeepSeek V4 Pro | DeepSeek API key |
| `NativeFlash` | DeepSeek V4 Flash | DeepSeek API key |
| `TransferPro` | OpenAI-transfer-Pro | Pro key |
| `TransferLegacy` | OpenAI-transfer | Legacy key and, when required, actor value |

`ChatGPT` is included automatically. A DeepSeek key can serve both DeepSeek
modes, but they remain different routes. Transfer Pro and Legacy never share a
credential merely because their current endpoint is the same.

Prefer private one-line files outside the extracted package. Pass file paths
to the installer; never read or print their contents. If files do not exist,
run the installer visibly so the user can type into its hidden prompts.

For current Transfer station information, direct the user to
<https://ai-pixel.online/keys> and ask them to click **使用密匙**. Use the
sanitized references under `configuration/260902` to understand the expected
shapes. Keep the page output private and never request it in chat.

## Typical commands

First inspect without writing:

```powershell
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes ChatGPT,TransferPro `
  -TransferProKeyFile "<private-file-path>" `
  -ValidateOnly -NonInteractive
```

Then install the requested modes:

```powershell
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes ChatGPT,TransferPro `
  -TransferProKeyFile "<private-file-path>" `
  -NonInteractive
```

Use Windows PowerShell 5.1. Supply `-CodexExecutablePath` when automatic
detection cannot see the installed `ChatGPT.exe`. `-Modes all` requests the
complete setup. `-TransferLegacyWithoutActor` is only appropriate after the
current station configuration confirms that the legacy actor header is not
needed. `-SkipPackageValidation` is for an inspected, intentional local
adaptation, not for ignoring an unknown failure.

## Boundaries

- Never put secrets, `auth.json`, generated `config.yml`, sessions, databases,
  logs, Electron data, or profile backups in the portable package.
- Do not silently modify `%USERPROFILE%\.codex`; ChatGPT uses it as-is.
- Preserve a recoverable copy before replacing working user configuration.
- Do not stop the Codex process that contains the current installation task.
- Ask before destructive cleanup, external account changes, downloads from an
  unverified source, publication, or transmission to another person.

Everything else inside the requested local installation is adaptation work the
agent may perform and explain.
