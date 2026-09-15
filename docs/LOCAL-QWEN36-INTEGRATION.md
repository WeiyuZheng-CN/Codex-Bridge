# Local Qwen3.6 integration guide

This document describes the local Codex route added for the verified
Qwen3.6 35B-A3B Q4_K_M installation on the RTX 5060 Laptop GPU.

For the complete AI-facing maintenance contract, including exact hashes,
resource tuning, troubleshooting, upgrade, rollback, privacy, and acceptance
checks, read LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md in this directory.

This public source document contains the integration design only. The GGUF
weight file and the llama.cpp/CUDA runtime are deliberately not bundled.
Prepare them from the official sources in README.md in a target-specific
directory, then replace the path placeholders below. Do not put those assets
inside the Git source tree.

## What is installed

The local route has three separate ownership boundaries:

```text
Codex chooser
    |
    +-- Local Qwen3.6 card
            |
            +-- isolated Codex profile
            |     Documents\Codex\local-qwen36-codex\codex-home
            |
            +-- loopback Responses API
                  http://127.0.0.1:61991/v1
                  |
                  +-- llama-server.exe, llama.cpp b10964 CUDA 13.3
                  +-- Qwen3.6 35B-A3B Q4_K_M model
```

The normal `%USERPROFILE%\.codex` profile is not used by this card and is not
rewritten. No API key or OpenAI login is required. The server binds to
`127.0.0.1` only.

The stable runtime root is:

```text
<Documents>\Codex\local-qwen36
```

Its subdirectories are `model`, `runtime`, and `launcher`. The model file is:

```text
model\qwen3.6-35b-a3b-coding-q4_k_m.gguf
```

## Integrity baseline

The model is expected to be exactly 21,718,480,960 bytes with SHA-256:

```text
D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC
```

Check it before diagnosing runtime failures:

```powershell
$model = '<Documents>\Codex\local-qwen36\model\qwen3.6-35b-a3b-coding-q4_k_m.gguf'
$item = Get-Item -LiteralPath $model
$hash = Get-FileHash -LiteralPath $model -Algorithm SHA256
"bytes=$($item.Length)"
"sha256=$($hash.Hash)"
```

The expected runtime is upstream llama.cpp b10964, Windows x64, CUDA 13.3.
Its device check must show:

```text
CUDA0: NVIDIA GeForce RTX 5060 Laptop GPU
```

## GPU strategy

The model is larger than the laptop's 8 GB VRAM. The working launcher uses:

```text
--device CUDA0
--cpu-moe
--gpu-layers 99
--flash-attn on
--no-mmproj
--ctx-size 262144
--parallel 1
--reasoning on
--reasoning-effort low
--reasoning-budget 512
--reasoning-format deepseek
--cache-type-k q8_0
--cache-type-v q8_0
--load-mode none
```

The Codex model catalog exposes the complete local reasoning scale:
minimal, low, medium, high, xhigh, and max. The profile default remains low.
These are request-time reasoning controls and do not change the quantized
model weights. Higher levels may use more tokens and take longer.

`--cpu-moe` keeps the large MoE expert weights in system RAM while eligible
shared/attention layers and the quantized KV cache use CUDA. “GPU mode”
therefore means hybrid GPU/CPU execution, not that the whole 20.2 GiB model
is resident in VRAM.

The full 262,144-token context was tested successfully. The q8 KV cache uses
about 7.1 GiB of the 8.15 GiB VRAM on this machine. A short coding request
completed at about 24.7 tokens/s in the dedicated 262K test; the final
stable-root test completed at about 34.0 tokens/s. Larger prompt batches can
improve prompt ingestion, but may reduce interactive decode speed.

Repeated 384-token decode samples averaged about 31 tokens/s. The server uses
most of the available VRAM at maximum context, so leave other GPU-heavy work
closed while using this profile.

The final installed launcher uses `--batch-size 512` and `--ubatch-size 256`.
A measured comparison showed that this pair greatly improves long-prompt
ingestion, while repeated 384-token decode samples remained about 31 tokens/s.
If interactive latency or VRAM pressure becomes a problem, step down to
`256/128`, then `128/64`.

The launcher also uses `--load-mode none`. On this machine it improved the
measured 384-token decode rate to about 35 tokens/s at 262K context, but it
uses almost all available system RAM because model tensors are loaded eagerly.
Keep a few gigabytes free for Windows and the coding workspace; switch back
to the default mmap mode if the system begins paging.

The built-in verification script checks both the legacy completion endpoint and
the Responses API used by the Codex profile.

## Daily use

1. Quit Codex completely if it is open.
2. Open the `Codex` shortcut or run the installed chooser.
3. Select `Local Qwen3.6`.
4. The provider launcher starts the local server if it is not already healthy,
   then opens Codex with the isolated profile.

The server can also be started directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  '<Documents>\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1'
```

Stop only the server owned by this package:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  '<Documents>\Codex\local-qwen36\launcher\Stop-Qwen36-GPU-Coding.ps1'
```

The launcher logs are under `local-qwen36\launcher\logs`. They contain runtime
diagnostics; keep them private when sharing a bug report.

## Profile contract

The generated local profile must contain the equivalent of:

```toml
model = "qwen3.6-35b-a3b-coding"
model_provider = "local_qwen36"
model_reasoning_effort = "low"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
model_context_window = 262144

[model_providers.local_qwen36]
name = "Local Qwen3.6"
base_url = "http://127.0.0.1:61991/v1"
wire_api = "responses"
requires_openai_auth = false
```

Do not add an API key to this profile. If a future Codex build asks for
OpenAI authentication despite this setting, capture the exact error, preserve
the profile backup, and test the CLI/profile contract separately before making
another change.

## Checks after an update

Run these checks in order:

```powershell
$root = '<Documents>\Codex\local-qwen36'
Push-Location (Join-Path $root 'runtime')
.\llama-server.exe --list-devices
Pop-Location

Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:61991/health'
Invoke-RestMethod -Uri 'http://127.0.0.1:61991/v1/models' |
  ConvertTo-Json -Depth 10

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  (Join-Path $root 'launcher\Test-Qwen36-GPU.ps1')
```

Then validate the installed chooser:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  '%LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge\Start-Codex-Chooser.ps1' `
  -ValidateOnly
```

Expected local results include `Status = OK`, the model alias, the loopback
base URL, and `RequiresOpenAIAuth = false`. A `SKIPPED` result for an unrelated
provider is normal.

## Safe upgrade and rollback

Never replace the live runtime while `llama-server.exe` is running.

1. Record the current model hash, runtime version, launcher arguments, health
   result, and a short coding response.
2. Download or extract a candidate runtime into a new versioned directory.
3. Test it on a second port with the same model and conservative flags.
4. Promote it only after CUDA discovery, health, response, and memory checks
   pass.
5. Keep the previous runtime directory until the new one has survived normal
   use.

The promotion made for this installation was a copy-and-hash-verify operation;
the original Ollama blob remains available as a fallback. The prior launcher
package is also retained in its installer backup directory. To roll back the
Codex integration, restore the timestamped backup of
`Start-Codex-Chooser.ps1`, remove the Local Qwen profile entry from
`launcher.settings.json`, and leave the model/runtime root untouched.

## Resource troubleshooting

If the port is busy, inspect the owner before stopping anything:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 61991
$ownerPid = (Get-NetTCPConnection -State Listen -LocalPort 61991).OwningProcess
Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" |
  Select-Object ProcessId,Name,CommandLine
```

Only a command line that clearly points to
`Documents\Codex\local-qwen36\runtime\llama-server.exe` belongs to this
route. Otherwise choose a separate tested port and update the profile and
launcher together.

If CUDA is missing, run `--list-devices` first. If `CUDA0` is absent, inspect
the NVIDIA driver and the CUDA DLLs before changing the model or quantization.
If memory pressure appears, lower context, batch, and GPU layers one at a time;
keep `--cpu-moe` enabled until a replacement strategy is validated.

## Sharing boundary

Safe-to-share materials are the sanitized launcher source, this guide, the
non-secret checksums, and anonymized test results. Do not share the model
profile's Electron data, Codex databases, logs, backups, sessions, or any
future credential-bearing file.
