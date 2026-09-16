# AI agent working instructions

This repository is an AI-maintained software seed. Optimize for a successful,
understandable local installation, not for making every target computer match
the package author's machine.

## Working style

1. Read `START-HERE-FOR-AI.md` and `docs/ARCHITECTURE.md` completely.
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
| `DeepSeek` | V4 Pro, V4 Flash, or V4 Flash Vision; select inside Codex | DeepSeek API key |
| `Transfer` | OpenAI Transfer; switch Pro/Legacy at the station website | One current station key |
| `LocalQwen36` | Local Qwen3.6 35B-A3B Q4_K_M through Ollama, with llama.cpp CUDA fallback | Installed Ollama/model; no key |

`ChatGPT` is included automatically. One DeepSeek key serves the native profile
and its Pro, Flash, and Flash Vision model choices. The current station's
`auth.json mode` supplies the same local shape for the Pro and Legacy choices;
the web console performs the server-side switch for the same key. The old
`TransferPro` and `TransferLegacy` names remain accepted as installer aliases.

`LocalQwen36` is credential-free. It requires Ollama with the verified
`qwen3.6:35b-a3b-coding` model and creates the isolated
`Documents\Codex\local-qwen36-ollama-codex` profile. It never rewrites the
normal `%USERPROFILE%\.codex` profile. The primary tested context is 131072
tokens with tools, thinking, and image input; the separately staged
`Documents\Codex\local-qwen36` llama.cpp CUDA route remains the 262144-token
fallback.

Prefer private one-line files outside the extracted package. Pass file paths
to the installer; never read or print their contents. If files do not exist,
run the installer visibly so the user can type into its hidden prompts.

For current Transfer station information, direct the user to
<https://ai-pixel.online/keys> and ask them to click **使用密匙**. Use the
official references below and `references/deepseek/260909` for the current
DeepSeek shape. Historical Transfer compatibility is summarized in
`docs/LEGACY-COMPATIBILITY.md`; it is not part of the current package. Keep
the page output private and never request it in chat.

Official references:

- <https://docs.ai-pixel.online/docs/api>
- <https://docs.ai-pixel.online/docs/api/responses>
- <https://docs.ai-pixel.online/docs/api/models>
- <https://docs.ai-pixel.online/docs/normal-client-setup>
- <https://docs.ai-pixel.online/docs/normal-account-mode>

## Typical commands

First inspect without writing:

```powershell
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes ChatGPT,Transfer `
  -TransferKeyFile "<private-file-path>" `
  -ValidateOnly -NonInteractive
```

Then install the requested modes:

```powershell
& .\Install-Codex-Provider-Launcher.ps1 `
  -Modes ChatGPT,Transfer `
  -TransferKeyFile "<private-file-path>" `
  -NonInteractive
```

Use Windows PowerShell 5.1. Supply `-CodexExecutablePath` when automatic
detection cannot see the installed `ChatGPT.exe`. `-Modes all` requests the
complete setup. Old Pro/Legacy key parameter names remain aliases for the
single `-TransferKeyFile`. `-SkipPackageValidation` is for an inspected,
intentional local adaptation, not for ignoring an unknown failure.

## Boundaries

- Never put secrets, `auth.json`, generated `config.yml`, sessions, databases,
  logs, Electron data, or profile backups in the portable package.
- Do not silently modify `%USERPROFILE%\.codex`; ChatGPT uses it as-is.
- Preserve a recoverable copy before replacing working user configuration.
- Do not stop the Codex process that contains the current installation task.
- Ask before destructive cleanup, external account changes, downloads from an
  unverified source, publication, or transmission to another person.
- If the current **使用密匙** popup returns an API Key Mode or extra actor
  header, keep it as a compatibility profile instead of silently forcing the
  shared `auth.json` shape.

Everything else inside the requested local installation is adaptation work the
agent may perform and explain.

The DeepSeek UI is intentionally one entry. Its native profile exposes Pro,
Flash, and Flash Vision in Codex after startup; do not add a DeepSeek second
layer or revive the old native-Flash card as the primary path.
