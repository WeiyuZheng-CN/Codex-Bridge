# Local Qwen3.6 Ollama Implementation Handoff

## Result

Local Qwen3.6 now uses Ollama as the primary backend in the installed chooser.
The existing llama.cpp CUDA route remains a separate fallback.

Primary profile:

```text
Documents\Codex\local-qwen36-ollama-codex\codex-home
model = qwen3.6-35b-a3b-coding
model_provider = ollama
base endpoint = http://127.0.0.1:11434/v1
context = 262144
default reasoning = max
launcher output cap = none
```

Fallback profile:

```text
Documents\Codex\local-qwen36-codex\codex-home
model_provider = local_qwen36
base endpoint = http://127.0.0.1:61991/v1
context = 262144
llama.cpp CUDA + compatible Jinja template
```

The normal `%USERPROFILE%\.codex` profile was not modified.

## Evidence

Ollama 0.34.0 was verified with the installed Qwen3.6 Q4_K_M model and a
local alias `qwen3.6-35b-a3b-coding` created with `ollama cp` from
`qwen3.6:35b-a3b-coding`. The alias shares the same Ollama digest and does not
duplicate the weights.

Direct Ollama tests passed:

- native `/api/chat` returned a structured `tool_calls` item;
- `/v1/responses` returned a structured `function_call` with JSON arguments;
- `function_call_output` continuation completed;
- `/v1/responses` accepted `input_image` and returned an image description;
- mixed system/developer/function/custom/namespace/web-search input completed.

Codex CLI tests passed with `--oss --local-provider ollama`:

- ordinary text response;
- real `command_execution` reading a local workspace file;
- final answer after the file read;
- local image attachment with `--image` and a correct description.

The default Codex `read-only` sandbox rejected PowerShell in the isolated test
workspace. The product keeps the existing `workspace-write`/elevated policy;
the completed file-loop test used an isolated workspace with the explicit
dangerous bypass flag only for validation.

## New source files

```text
core/app/Start-Qwen36-Ollama.ps1
core/app/Stop-Qwen36-Ollama.ps1
core/app/Test-Qwen36-Ollama.ps1
core/app/Start-Codex-Local-Qwen36-Ollama.ps1
core/catalogs/local-qwen36-ollama-models.json
core/templates/local-qwen36-ollama-config.template.toml
```

The Ollama launcher binds to loopback, starts `ollama serve` with one parallel
request, a 262144-token context, and Q8 KV cache, verifies the source model,
creates the hyphenated alias when needed, and records an owned PID. It persists
the Ollama settings for future starts and warms the model before checking
`/api/ps`. If an external Ollama process is already serving the alias with a
smaller context, it reports that service as stale and refuses to continue
silently. The stop script only stops the recorded Ollama process and its child
runner.

## Installed deployment

The official installer could not atomically move the existing installed app
while the current Codex process was open. A clean staging installation was
created and the changed scripts, chooser, settings, and documentation were
copied into the installed app with a backup first.

Backup:

```text
Documents\Codex\_archive\codex-bridge-ollama-pre-20260916-124604
```

Installed chooser validation returned `Status = OK` with all four modes:
ChatGPT, DeepSeek, Transfer, and LocalQwen36. The Ollama profile validation
returned `Backend = ollama`, `ContextWindow = 262144`, and `ImageInput = true`.
The llama.cpp fallback validation still returned its 61991 endpoint and
262144-token context.

The live fallback was restored after tests and returned HTTP 200 on
`http://127.0.0.1:61991/health`. Ollama is stopped when idle; the Local Qwen
launcher starts it on demand.

## Verification commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "Documents\Codex\local-qwen36\launcher\Start-Qwen36-Ollama.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "Documents\Codex\local-qwen36\launcher\Test-Qwen36-Ollama.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "Documents\Codex\local-qwen36\launcher\Stop-Qwen36-Ollama.ps1"
```

Fallback:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "Documents\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1"
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:61991/health
```

## Remaining attended test

After completely quitting all Codex windows, select Local Qwen3.6 in the
installed chooser and verify one ordinary prompt, one text-file request, and
one attached PNG/JPG. If the desktop test fails, restore the chooser and
settings from the backup and use the llama.cpp fallback. Do not delete either
model copy.

## Validation

The source package passed after the implementation:

```text
Portable package validation: OK
PowerShell parse errors: 0
Secret pattern matches: 0
```

Do not commit Ollama blobs, GGUF weights, runtime binaries, logs, profile
databases, Electron data, sessions, or private prompts.
