# AI Maintenance Guidebook

## Qwen3.6 35B-A3B Coding Model on Windows + RTX 5060 Laptop GPU

Guidebook version: 1.1
Baseline date: 2026-09-15
Maintainer audience: a future AI agent, automation process, or human operator

This is the detailed operational handoff for the Local Qwen3.6 route. Read it
completely before changing the model, runtime, launcher, Codex profile, port,
or memory settings. It records the difference between confirmed tests and
unresolved questions; a future AI must not turn a structural check into an
end-to-end claim.

## Distribution boundary

This public source copy describes the validated reference installation. It
does not contain the Qwen3.6 GGUF weight file, the CUDA/llama.cpp runtime,
local profile state, logs, or caches. Those assets are obtained separately
from official sources and staged outside the Git source tree.

The path placeholders below are intentionally portable. A maintainer must
resolve them on the target computer before running commands:

```text
<Documents>\Codex\local-qwen36
```

Use these current paths for all new maintenance work:

```text
Model:    <Documents>\Codex\local-qwen36\model\qwen3.6-35b-a3b-coding-q4_k_m.gguf
Runtime:  <Documents>\Codex\local-qwen36\runtime
Launcher: <Documents>\Codex\local-qwen36\launcher
Profile:  <Documents>\Codex\local-qwen36-codex\codex-home
API:      http://127.0.0.1:61991/v1
```

The reference model file is `21,718,480,960` bytes with SHA-256
`D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC`.
The original Ollama blob is retained separately as a fallback. Sections below
that mention the former workspace path describe the acquisition baseline only;
the stable-root paths above take precedence.

This is the operational source of truth for the working local coding-model
installation in this workspace. It describes what is confirmed, what may be
changed safely, what must remain invariant, and how to prove that a change did
not break the installation.

The original acquisition workspace was:

```text
<AcquisitionWorkspace>
```

The original acquisition package directory was:

```text
<AcquisitionWorkspace>\outputs\Qwen3.6-35B-A3B
```

The current user-facing launcher directory is the stable path at the top of
this guide: `<Documents>\Codex\local-qwen36\launcher`.

The original model source was stored in Ollama's model store. The verified
stable copy now used by the launcher is under the relocated root described
above; the Ollama blob remains as a fallback:

```text
%USERPROFILE%\.ollama\models\blobs\sha256-d372de8e934898a59e6ccfabc3368474711384d8f1fd4d22d87a3f0a45400cdc
```

Do not overwrite either verified copy in place. A new model must be staged,
hashed, and tested separately before promotion.

---

## 1. Executive status

### Current result

GPU inference is working through the standalone upstream llama.cpp runtime.
The model is not being run through Ollama's bundled llama-server because that
runner fails on this machine during CUDA initialization.

The working architecture is hybrid:

- CUDA runs the model's shared/attention layers on the RTX 5060.
- `--cpu-moe` keeps the large Mixture-of-Experts expert weights in system RAM.
- The model therefore does not need to fit entirely inside 8 GB of VRAM.

### Verified evidence

- GPU device discovery: `CUDA0: NVIDIA GeForce RTX 5060 Laptop GPU`
- GPU memory: `7127 MiB / 8151 MiB` observed during the 262K q8-KV test
- GPU server health: HTTP `200`
- Packaged coding response: valid Python `square(x)` implementation
- Stable-root packaged test speed: approximately `34.00 tokens/s`
- 262K GPU q8-KV test speed: approximately `24.73 tokens/s`
- Model layer byte count: `21,718,480,960`
- Model layer SHA-256: `D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC`

### Known limitation

The installed Ollama 0.34.0 runner detects the GPU but fails for this model
with CUDA out-of-memory/shared-object/Flash-Attention errors. This is a
runtime compatibility problem, not evidence that the model file is corrupt.
Use the packaged upstream llama.cpp launcher for GPU inference.

---

## 2. Immutable baseline

Before changing anything, record the current baseline. A maintainer must not
silently replace any of these components.

### Hardware and operating system

| Item | Verified baseline |
|---|---|
| Operating system | Windows 11 Home Chinese Edition, build 26200 |
| CPU | Intel Core Ultra 9 285H |
| CPU topology | 16 physical cores / 16 logical processors reported |
| System RAM | 31.5 GB |
| GPU | NVIDIA GeForce RTX 5060 Laptop GPU |
| VRAM | 8,151 MiB reported by `nvidia-smi` |
| NVIDIA driver | 610.74 |
| CUDA capability reported by Ollama | compute 12.0 |

Hardware facts can drift after a driver or Windows update. Recheck them with:

```powershell
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader
Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
Get-CimInstance Win32_ComputerSystem | Select-Object @{Name="RAM_GB";Expression={[math]::Round($_.TotalPhysicalMemory/1GB,1)}}
```

### Model baseline

| Item | Value |
|---|---|
| Registry name | `qwen3.6:35b-a3b-coding` |
| Model family | Qwen3.6 35B-A3B MoE |
| Parameters | 35.5B total |
| Quantization | Q4_K_M |
| Model training context | 262,144 tokens |
| Launcher context | 262,144 tokens |
| Model layer size | 21,718,480,960 bytes |
| Model layer digest | `D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC` |
| Model metadata license | Apache License 2.0 as reported by `ollama show` |

The launcher uses the full 262,144-token model context. The q8 KV cache and
Flash Attention combination was tested on this RTX 5060; it uses most of the
available VRAM, so leave headroom for other GPU applications.

Verify the model blob:

```powershell
$model = "%USERPROFILE%\.ollama\models\blobs\sha256-d372de8e934898a59e6ccfabc3368474711384d8f1fd4d22d87a3f0a45400cdc"
$item = Get-Item -LiteralPath $model
Get-FileHash -Algorithm SHA256 -LiteralPath $model
"bytes=$($item.Length)"
```

The expected output is the byte count and digest above. A matching file size
alone is not sufficient.

### Runtime baseline

The working runtime is the official upstream llama.cpp b10964 Windows x64
CUDA 13.3 build, relocated to:

```text
<Documents>\Codex\local-qwen36\runtime
```

The two downloaded official archives and their verified hashes are recorded in
[CHECKSUMS.txt](CHECKSUMS.txt):

- `llama-b10964-bin-win-cuda-13.3-x64.zip`
- `cudart-llama-bin-win-cuda-13.3-x64.zip`

Runtime discovery must report:

```text
CUDA0: NVIDIA GeForce RTX 5060 Laptop GPU
```

Check it without starting a server:

```powershell
$runtime = "<Documents>\Codex\local-qwen36\runtime"
Push-Location $runtime
.\llama-server.exe --list-devices
Pop-Location
```

If it reports `Available devices: (none)`, do not claim GPU support. Diagnose
the CUDA DLL path, driver, executable architecture, and process environment.

---

## 3. Architecture and ownership

```text
User / IDE / PowerShell client
          |
          v
127.0.0.1:61991  (OpenAI-compatible llama.cpp server)
          |
          +--> llama-server.exe from upstream b10964 CUDA 13.3 runtime
          |       |
          |       +--> CUDA0: RTX 5060 shared/attention layers
          |       +--> CPU: MoE expert weights (--cpu-moe)
          |       +--> 262K context / q8 KV cache / one parallel sequence
          |
          +--> verified Qwen3.6 Q4_K_M model copy in local-qwen36\model
```

### Component ownership

| Component | Owner/source | Safe maintenance rule |
|---|---|---|
| Model weights | Official Ollama registry | Never overwrite without rechecking digest |
| GPU runtime | Official llama.cpp release b10964 | Stage a new version beside the current one |
| Launcher scripts | This package | Edit only after preserving a working copy |
| Ollama app | Ollama 0.34.0 | It may remain installed for model storage; do not use its failing runner for this model |
| CUDA driver | NVIDIA/Windows system | Do not alter during a model test unless explicitly requested |
| Test artifacts | `local-qwen36\launcher` | Keep verification outputs; remove only known temporary fragments |

### Why the model is hybrid

The model file is roughly 22 GB while the GPU has 8 GB VRAM. A full-GPU load
is impossible. Qwen3.6 is an MoE model: only some parameters are active per
token, but the stored expert weights are still large. `--cpu-moe` places those
experts in RAM and leaves the smaller shared execution path on CUDA.

Do not interpret “GPU mode” as “the entire model is in VRAM.” The correct
success criterion is:

1. `--list-devices` detects CUDA0.
2. The server starts with `--device CUDA0` and `--cpu-moe`.
3. `nvidia-smi` shows model memory/use during a request.
4. The request returns a correct response.

---

## 4. Daily operation

### Start

Double-click:

[Start-Qwen36-GPU-Coding.cmd](Start-Qwen36-GPU-Coding.cmd)

Or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1"
```

The server binds only to loopback:

```text
http://127.0.0.1:61991
```

The advertised model alias is:

```text
qwen3.6-35b-a3b-coding
```

The launcher is idempotent. If the owned server is already healthy, it reports
the existing PID. If the owned process is stale, it replaces it. If another
unrelated process owns port 61991, it stops and asks for a different port
instead of killing that process.

Use a different port for a second instance:

```powershell
$env:QWEN36_PORT = "61992"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1"
```

### Health check

```powershell
Invoke-WebRequest -Uri "http://127.0.0.1:61991/health" -UseBasicParsing
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader
```

Expected health content:

```json
{"status":"ok"}
```

### Model listing

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:61991/v1/models" | ConvertTo-Json -Depth 10
```

The model ID should include:

```text
qwen3.6-35b-a3b-coding
```

### Built-in test

Double-click:

[Test-Qwen36-GPU.cmd](Test-Qwen36-GPU.cmd)

Or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Test-Qwen36-GPU.ps1"
```

The test checks health, submits a Responses request with enough output budget
for the configured reasoning allowance, requires a non-empty final answer
message with basic code structure, submits a legacy completion
request, records NVIDIA telemetry, and writes:

- `gpu-verification.txt`
- `gpu-verification.json`

### Ask the model

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Ask-Qwen36-GPU.ps1" -Prompt "Review this Python function for correctness and improve it: ..." -MaxTokens 512
```

Optional flags:

- `-Think`: preserve the model's reasoning output.
- `-OutputFile answer.txt`: save the answer beside the launcher package.

### Stop

Double-click:

[Stop-Qwen36-GPU-Coding.cmd](Stop-Qwen36-GPU-Coding.cmd)

Or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Stop-Qwen36-GPU-Coding.ps1"
```

The stop script only stops a process whose command line contains the packaged
llama.cpp runtime marker. It must not stop unrelated Ollama, NI, Python, or
other `llama-server` processes.

---

## 5. API contract

The server exposes an OpenAI-compatible API on loopback.

### Minimal PowerShell completion request

```powershell
$body = @{
    prompt = "<|im_start|>user`nWrite a Python function square(x).<|im_end|>`n<|im_start|>assistant`n<think>`n`n</think>`n"
    n_predict = 128
    temperature = 0.2
    stream = $false
    stop = @("<|im_end|>")
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Uri "http://127.0.0.1:61991/completion" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body `
  -TimeoutSec 900
```

### OpenAI-compatible chat request

```powershell
$body = @{
    model = "qwen3.6-35b-a3b-coding"
    messages = @(
        @{ role = "user"; content = "Explain this Python exception: ..." }
    )
    stream = $false
    max_tokens = 256
    temperature = 0.2
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Uri "http://127.0.0.1:61991/v1/chat/completions" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body `
  -TimeoutSec 900
```

For a coding editor, configure:

```text
Base URL: http://127.0.0.1:61991/v1
Model: qwen3.6-35b-a3b-coding
API key: not required for loopback use
```

Do not bind the service to `0.0.0.0` without adding authentication and a
firewall rule. The current launcher intentionally binds to `127.0.0.1` only.

---

## 6. Configuration invariants

These settings are part of the known-good solution.

| Setting | Current value | Reason |
|---|---:|---|
| `--device` | `CUDA0` | Selects the RTX 5060 explicitly |
| `--cpu-moe` | enabled | Keeps expert weights in 31.5 GB system RAM |
| `--gpu-layers` | `99` | Lets llama.cpp place all eligible non-expert layers on CUDA |
| `--flash-attn` | `on` | Required by the tested quantized KV path and improves long-context attention |
| `--no-mmproj` | enabled | This is a text coding setup; frees VRAM and avoids unnecessary vision initialization |
| `--ctx-size` | `262144` | Uses the model's full supported context |
| `--parallel` | `1` | Prevents concurrent requests from multiplying memory use |
| `--batch-size` | `512` | Faster long-prompt ingestion; validated on this machine |
| `--ubatch-size` | `256` | Faster prompt processing; reduce if VRAM pressure appears |
| `--cache-type-k` / `--cache-type-v` | `q8_0` | Compresses the long-context KV cache so it fits the 8 GB GPU |
| `--reasoning` / `--reasoning-effort` / `--reasoning-budget` | `on` / `low` / `512` | Keeps reasoning useful without consuming the whole response budget |
| `--load-mode` | `none` | Eagerly keeps CPU-side MoE tensors resident; measured faster on this 32 GB machine |
| `--threads` | `16` | Matches the reported CPU topology |
| `--threads-batch` | `16` | Keeps prompt processing consistent |
| bind address | `127.0.0.1` | Local-only security boundary |
| port | `61991` | Stable local API endpoint |

Do not change several resource variables at once. Change one setting, run the
acceptance test, record VRAM/RAM/speed, and only then keep the change.

---

## 7. Safe tuning order

### If VRAM out-of-memory occurs

Apply changes in this order:

1. Stop competing GPU applications and check `nvidia-smi`.
2. Reduce `--ctx-size` from `262144` to `131072`.
3. Reduce `--batch-size` from `512` to `256`.
4. Reduce `--ubatch-size` from `256` to `128`.
5. Replace `--gpu-layers 99` with `--gpu-layers 8` or `--gpu-layers 4`.
6. Keep `--cpu-moe` enabled.
7. If RAM becomes tight, change `--load-mode none` to `mmap` before reducing
   the context. Keep q8 KV with Flash Attention enabled; switching to f16 KV
   or disabling Flash Attention changes the memory requirements and must be
   retested.

After every change, check:

```powershell
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader
Invoke-WebRequest -Uri "http://127.0.0.1:61991/health" -UseBasicParsing
```

### If generation is slow

The expected tradeoff is CPU/RAM bandwidth versus GPU memory. Try, one at a
time:

- Increase `--gpu-layers` only if VRAM has a safe margin.
- Increase `--ubatch-size` only for prompt-heavy workloads.
- Keep generation context modest.
- Stop background applications that consume CPU or RAM.
- Keep Flash Attention on for the tested q8 KV configuration.
- `--load-mode none` is the speed default. Use mmap mode when other programs
  need more system RAM.

Do not judge speed from model loading. Measure tokens per second during a
completed request.

### If the GPU is not detected

Run:

```powershell
$runtime = "<Documents>\Codex\local-qwen36\runtime"
Push-Location $runtime
.\llama-server.exe --list-devices
Pop-Location
nvidia-smi
```

Interpretation:

- `CUDA0` appears: runtime can see the GPU; continue to model loading checks.
- `Available devices: (none)`: inspect CUDA DLL presence, executable/runtime
  pairing, NVIDIA driver, and process environment.
- `nvidia-smi` fails: fix the driver/system before touching the model.

### If the server port is busy

```powershell
Get-NetTCPConnection -State Listen -LocalPort 61991
$pid = 12345  # replace with the PID reported by the first command
Get-CimInstance Win32_Process -Filter "ProcessId = $pid" | Select-Object CommandLine
```

Only stop the process if its command line clearly identifies this package.
Otherwise set a new port for this session:

```powershell
$env:QWEN36_PORT = "61992"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1"
```

### If the model is reported missing or invalid

Do not redownload immediately. Check:

```powershell
$model = "<Documents>\Codex\local-qwen36\model\qwen3.6-35b-a3b-coding-q4_k_m.gguf"
Get-Item -LiteralPath $model | Select-Object Length,Attributes,LastWriteTime
Get-FileHash -Algorithm SHA256 -LiteralPath $model
```

Expected size and SHA-256 are in [CHECKSUMS.txt](CHECKSUMS.txt). A failed
download must remain untrusted until both match.

---

## 8. Upgrade protocol

An AI maintainer must use a staged upgrade. Never replace the working runtime
in place while the server is running.

### Step A: capture the baseline

Record:

- current runtime directory and release identifier;
- model size and SHA-256;
- `nvidia-smi` output;
- `llama-server --list-devices` output;
- health result;
- a short coding response and tokens/second;
- current launcher arguments.

### Step B: obtain official artifacts

Prefer the upstream llama.cpp GitHub release. For each archive:

1. Resolve the release tag and asset name.
2. Download to a new versioned directory.
3. Check the publisher/API SHA-256.
4. Extract to a new runtime directory.
5. Do not alter the current runtime.

The current tested release is b10964. A newer release should not be assumed
better until the same CUDA and coding tests pass.

### Step C: test on a second port

Start the candidate runtime on a port such as 61992 with the same model and
conservative flags. Verify:

- CUDA0 discovery;
- health 200;
- model load;
- one coding response;
- NVIDIA memory use;
- no CUDA/Flash-Attention errors;
- speed and output quality.

### Step D: promote or roll back

Promote only after the candidate passes. Promotion means changing the runtime
path in the launcher, not copying files over a running process. If any test
fails, stop the candidate and restore the previous runtime path.

The model blob should not be re-quantized or replaced as part of a runtime-only
upgrade.

---

## 9. Model upgrade protocol

Model upgrades are separate from runtime upgrades.

### Required checks

For a new model or quantization:

1. Confirm the exact upstream repository/tag and license.
2. Confirm architecture compatibility with the current llama.cpp build.
3. Check expected file size before downloading.
4. Download to a staging path with resume support.
5. Verify SHA-256 after completion.
6. Preserve the current model until the candidate passes.
7. Test with the same prompt and resource settings.
8. Record quality, speed, VRAM, RAM, and failure behavior.

### Quantization guidance

- Q4_K_M is the current quality/size choice and is about 22 GB here.
- IQ4_XS/Q4XS variants are smaller but are not the current installed model.
- A smaller model may be faster and easier to run entirely on GPU.
- A larger model should not be downloaded merely because it has a larger total
  parameter count; available RAM/VRAM and actual latency matter.

Do not delete the current verified model until the user explicitly wants the
old model removed and the new one is independently validated.

---

## 10. Security and data boundaries

- The server binds to `127.0.0.1` only.
- No API key is configured because access is local-only.
- Do not change the bind address to `0.0.0.0` without authentication and a
  firewall rule.
- Do not put secrets, API keys, passwords, private source code, or personal
  documents into persistent test files.
- Review `logs\` before sharing them; prompts or errors may reveal local paths.
- Keep the model and runtime licenses with any redistributed package.
- The launch scripts do not require internet access after the model/runtime
  artifacts are present.

---

## 11. AI maintainer contract

Any future AI taking maintenance responsibility must follow this contract.

### Before acting

1. Read this guidebook completely.
2. Inspect the current process, port, GPU telemetry, runtime version, and model
   hash.
3. Distinguish confirmed observations from assumptions.
4. Check whether the user requested a runtime change, model change, or only a
   diagnosis.
5. Preserve existing user changes and output artifacts.

### During changes

1. Make one material change at a time.
2. Use versioned staging directories for downloads.
3. Never use a broad recursive delete.
4. Never overwrite the verified model blob in place.
5. Never kill an unrelated process based only on a port number.
6. Keep the server local-only unless the user explicitly authorizes a network
   service and security configuration.

### Before claiming success

All of the following are required:

- the runtime detects `CUDA0`;
- the model hash still matches;
- the server health endpoint returns 200;
- a real coding request returns text;
- NVIDIA telemetry shows GPU memory/use during the request;
- the output is saved or otherwise inspectable;
- any limitation is stated explicitly.

Do not call a model “GPU-accelerated” based on package names, device detection
alone, or a successful process startup. Require an actual inference request.

---

## 12. Recovery checklist

Use this short sequence when the setup stops working:

```powershell
# 1. Check hardware and competing GPU use
nvidia-smi

# 2. Check the model blob
$model = "%USERPROFILE%\.ollama\models\blobs\sha256-d372de8e934898a59e6ccfabc3368474711384d8f1fd4d22d87a3f0a45400cdc"
(Get-Item -LiteralPath $model).Length
Get-FileHash -Algorithm SHA256 -LiteralPath $model

# 3. Check the standalone runtime
$runtime = "<Documents>\Codex\local-qwen36\runtime"
Push-Location $runtime
.\llama-server.exe --list-devices
Pop-Location

# 4. Start the known-good launcher
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Start-Qwen36-GPU-Coding.ps1"

# 5. Test the real API
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Test-Qwen36-GPU.ps1"
```

If step 2 fails, stop and repair/restore the model before changing runtime
settings. If step 3 fails, repair the runtime/driver path. If step 4 fails,
inspect the package logs and port ownership. If step 5 fails while steps 2–4
pass, inspect the request format and server logs before changing GPU settings.

---

## 13. Current change history

### 2026-09-15

- Installed and verified official `qwen3.6:35b-a3b-coding` Q4_K_M.
- Detected that Ollama 0.34.0's bundled runner failed on the RTX 5060 during
  CUDA/Flash-Attention initialization.
- Downloaded and hash-verified official llama.cpp b10964 Windows CUDA 13.3
  binaries and CUDA runtime DLLs.
- Created the hybrid `CUDA0 + --cpu-moe` launcher.
- Verified health 200, NVIDIA memory use, and real coding output.
- Added a stable API alias and PowerShell request helper.
- Removed failed Q4XS/partial-download troubleshooting fragments after the
  verified Q4_K_M path was working.
- Tuned the stable launcher to the full 262144-token context with GPU q8 KV,
  Flash Attention, eager model loading, and 512/256 prompt batching. The full
  context and coding request passed on the RTX 5060.

### Future entries

Every future maintainer should append:

```text
YYYY-MM-DD — maintainer/action — reason — files changed — hashes — test result — rollback information
```

Never rewrite old entries to make a failed experiment look successful.

---

## 14. Quick reference

| Need | Action |
|---|---|
| Start | `Start-Qwen36-GPU-Coding.cmd` |
| Test | `Test-Qwen36-GPU.cmd` |
| Ask | `Ask-Qwen36-GPU.ps1 -Prompt "..."` |
| Stop | `Stop-Qwen36-GPU-Coding.cmd` |
| API | `http://127.0.0.1:61991` |
| Model alias | `qwen3.6-35b-a3b-coding` |
| GPU check | `llama-server.exe --list-devices` |
| Integrity check | [CHECKSUMS.txt](CHECKSUMS.txt) |
| Fix explanation | [GPU-FIX-REPORT.md](GPU-FIX-REPORT.md) |
| Verification output | [gpu-verification.txt](gpu-verification.txt) |

The known-good state is: official Q4_K_M model, verified digest, upstream
llama.cpp CUDA 13.3 runtime, CUDA0 detected, CPU MoE offload, GPU q8 KV,
Flash Attention on, full 262144-token context, local-only API, and a successful
real coding request.

---

## 15. Definitive AI handoff supplement

This supplement is intentionally explicit because the guide is copied to
several locations. The stable root is the live authority, the source package
is the authority for future installer behavior, and the acquisition output is
an evidence copy. If they disagree, compare hashes and timestamps before
choosing a file.

### 15.1 Exact path and ownership map

| Location | Purpose | Rule |
|---|---|---|
| <SourceRoot> | Source starter | Edit source docs and scripts here; preserve unrelated user changes |
| <Documents>\Codex\local-qwen36 | Live model and runtime root | Do not replace live files while the server is running |
| <Documents>\Codex\local-qwen36\model\qwen3.6-35b-a3b-coding-q4_k_m.gguf | Live GGUF | Verify length and SHA-256 before diagnosing anything |
| <Documents>\Codex\local-qwen36\runtime | Live llama.cpp CUDA runtime | Upgrade by side-by-side staging |
| <Documents>\Codex\local-qwen36\launcher | Live start, stop, test scripts and logs | Back up each script before editing |
| <Documents>\Codex\local-qwen36-codex\codex-home | Isolated Codex home | Contains Local Qwen profile state only |
| <Documents>\Codex\local-qwen36-codex\electron-data | Isolated desktop state | Private; never package or share |
| %LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge | Installed four-card chooser | Validate after source-to-installed changes |
| <AcquisitionWorkspace>\outputs\Qwen3.6-35B-A3B | Delivery and evidence output | Sanitized artifacts; not the live server |
| %USERPROFILE%\.ollama\models\blobs\sha256-d372de8e934898a59e6ccfabc3368474711384d8f1fd4d22d87a3f0a45400cdc | Retained Ollama fallback | Do not overwrite; hash before fallback use |
| %USERPROFILE%\.codex | Normal Codex profile | Local Qwen must never rewrite it |

Existing recoverable archives:

~~~text
<Documents>\Codex\_archive\local-qwen36-integration-preinstall-20260915-040910
<Documents>\Codex\_archive\local-qwen36-tuning-pre-20260915-130649
<Documents>\Codex\_archive\local-qwen36-batch-pre-20260915-161533
~~~

The installer can also create an installed-app sibling named
Codex-DeepSeek-Bridge.backup-<timestamp> and profile backups under
<profile-root>\backups\portable-installer\<timestamp>. Inspect the exact path
reported by the installer instead of guessing a backup name.

The sanitized guide must be present at:

~~~text
<SourceRoot>\docs\LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md
<AcquisitionWorkspace>\outputs\Qwen3.6-35B-A3B\AI-MAINTENANCE-GUIDEBOOK.md
<Documents>\Codex\local-qwen36\launcher\AI-MAINTENANCE-GUIDEBOOK.md
%LOCALAPPDATA%\Programs\Codex-DeepSeek-Bridge\docs\LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md
~~~

### 15.2 Integrity and hardware gates

Run this before every repair, tuning experiment, or upgrade:

~~~powershell
$root = "<Documents>\Codex\local-qwen36"
$model = Join-Path $root "model\qwen3.6-35b-a3b-coding-q4_k_m.gguf"
$item = Get-Item -LiteralPath $model
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $model
"model_bytes=$($item.Length)"
"model_sha256=$($hash.Hash.ToUpperInvariant())"
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader
Push-Location (Join-Path $root "runtime")
try { .\llama-server.exe --version; .\llama-server.exe --list-devices }
finally { Pop-Location }
~~~

Required model values:

~~~text
model_bytes=21718480960
model_sha256=D372DE8E934898A59E6CCFABC3368474711384D8F1FD4D22D87A3F0A45400CDC
~~~

Required device output includes:

~~~text
CUDA0: NVIDIA GeForce RTX 5060 Laptop GPU
~~~

The API may report an internal GGUF payload size different from the Windows
file length. That is not a corruption signal. Use the Windows length and
SHA-256 as the integrity gate.

### 15.3 Exact launch contract

The current stable launcher is configured with:

~~~text
--host 127.0.0.1
--port 61991
--offline
--no-webui
--no-mmproj
--ctx-size 262144
--parallel 1
--device CUDA0
--cpu-moe
--gpu-layers 99
--flash-attn on
--reasoning on
--reasoning-effort low
--reasoning-budget 512
--reasoning-format deepseek
--chat-template-file qwen3.6-codex-compatible.jinja
--batch-size 512
--ubatch-size 256
--cache-type-k q8_0
--cache-type-v q8_0
--load-mode none
--threads 16
--threads-batch 16
~~~

The important interpretations are:

* CPU MoE is intentional. The model is hybrid GPU/CPU inference, not full
  model residency in VRAM.
* q8 KV plus Flash Attention is the tested long-context memory compromise.
* parallel one prevents a second sequence from multiplying KV memory.
* load mode none is the measured speed default but is aggressive with 31.5 GB
  system RAM. Mmap is the fallback when Windows begins paging.
* no-mmproj is intentional because this is a text coding route.
* the compatible Jinja template is required for Codex's multi-system-message
  request format; without it the native template can return HTTP 500 before
  inference starts.

At maximum context, observed GPU use was about 6.8 to 7.1 GiB of 8.15 GiB.
Observed generation samples were about 31 to 35 tokens per second, with
variation from prompt length, warm state, thermal state, and background work.
Do not turn one short sample into a performance guarantee.

### 15.4 Context policy: maximum versus 128K balance

The model supports 262144 tokens and the current profile advertises that
maximum. This is useful for large repositories, but it consumes most of the
GPU memory and nearly all system memory with the current q8 and eager-load
settings.

The user's earlier 128K choice is a sensible interactive compromise. In
binary units, 128K is 131072:

The Codex catalog exposes minimal, low, medium, high, xhigh, and max. The
isolated profile defaults to low. The launcher keeps low effort and a
512-token reasoning budget by default; Codex may request another catalog level
per conversation. Max is selectable, but its latency and token use should be
measured for the workload.

* 262144 gives maximum repository and history capacity.
* 131072 usually gives better memory headroom and interactive behavior.
* 65536 or 32768 are recovery settings for heavy background workloads.

When changing context, update and test the server ctx-size, the isolated
profile model_context_window, the catalog context values, and the recorded
launcher settings metadata together. Never advertise more than the model's
training context. A client value larger than the server value can cause
truncation or confusing errors.

### 15.5 Codex profile and catalog contract

The isolated profile is:

~~~text
<Documents>\Codex\local-qwen36-codex\codex-home\config.toml
~~~

Its required semantic content is:

~~~toml
model = "qwen3.6-35b-a3b-coding"
model_provider = "local_qwen36"
model_reasoning_effort = "low"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
model_context_window = 262144
model_catalog_json = "<Documents>/Codex/local-qwen36-codex/codex-home/models.json"

[model_providers.local_qwen36]
name = "Local Qwen3.6"
base_url = "http://127.0.0.1:61991/v1"
wire_api = "responses"
requires_openai_auth = false
~~~

The catalog is:

~~~text
<Documents>\Codex\local-qwen36-codex\codex-home\models.json
~~~

It must contain the exact model slug and must not advertise a context above
262144. The chooser card and the model catalog are different layers; do not
add another chooser card just to expose a model setting.

The Local Qwen launcher sets:

~~~text
CODEX_HOME=<Documents>\Codex\local-qwen36-codex\codex-home
CODEX_ELECTRON_USER_DATA_PATH=<Documents>\Codex\local-qwen36-codex\electron-data
~~~

If Codex asks for OpenAI authentication, inspect the exact profile, endpoint,
wire API, catalog path, and environment first. Do not add a secret to this
credential-free provider, and do not copy the normal Codex profile into it.

### 15.6 API and acceptance tests

Health and model discovery:

~~~powershell
$endpoint = "http://127.0.0.1:61991"
Invoke-WebRequest -UseBasicParsing -Uri "$endpoint/health" -TimeoutSec 10
Invoke-RestMethod -Uri "$endpoint/v1/models" -TimeoutSec 30 | ConvertTo-Json -Depth 15
~~~

The model list must contain qwen3.6-35b-a3b-coding. Then test the exact
Responses wire used by Codex:

~~~powershell
$body = @{ model = "qwen3.6-35b-a3b-coding"; instructions = "Return concise, runnable code."; input = "Write one short Python function add_one(x) that returns x + 1."; max_output_tokens = 1024; stream = $false; store = $false } | ConvertTo-Json -Depth 10
$result = Invoke-RestMethod -Uri "http://127.0.0.1:61991/v1/responses" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 900
"status=$($result.status)"
$result | ConvertTo-Json -Depth 20
~~~

Pass requires status completed, a message item with non-empty output_text, and
basic code structure in that final answer. A very small output budget can be
consumed entirely by the configured reasoning allowance and produce a
completed response with no final message; that is a failed coding acceptance
test. Also run the packaged test:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<Documents>\Codex\local-qwen36\launcher\Test-Qwen36-GPU.ps1"
~~~

That test covers health, Responses, legacy completion, timing, and NVIDIA
telemetry. Health alone is not an inference test. Device discovery alone is
not a GPU-inference test. Raw API success is not automatically a complete
Codex GUI or CLI success.

### 15.7 Troubleshooting rules

#### VRAM out of memory

Record nvidia-smi, then change one setting at a time in this order:

1. Close competing GPU applications.
2. Reduce context from 262144 to 131072.
3. Reduce batch and ubatch from 512/256 to 256/128, then 128/64.
4. Reduce GPU layers from 99 to 8, then 4.
5. Keep CPU MoE, q8 KV, and Flash Attention while isolating the cause.

Restart and run Responses plus completion tests after every change.

#### RAM exhaustion or paging

Load mode none keeps CPU-side model tensors resident and can consume most of
the 31.5 GB RAM. If Windows starts paging, close applications, keep parallel
at one, switch to load mode mmap, and retest. Do not disable the pagefile.

#### CUDA missing

If nvidia-smi works but list-devices does not show CUDA0, inspect the matching
CUDA DLL set and executable architecture. Do not mix DLLs from an unrelated
installation. If nvidia-smi fails, repair the driver before touching the
model.

#### Port conflict

Inspect the owner before stopping anything:

~~~powershell
$listeners = Get-NetTCPConnection -State Listen -LocalPort 61991 -ErrorAction SilentlyContinue
foreach ($listener in $listeners) {
    Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" | Select-Object ProcessId,Name,ExecutablePath,CommandLine
}
~~~

Only a command line pointing to the stable local-qwen36 runtime belongs to
this route. Changing QWEN36_PORT alone is incomplete: the server launcher,
Codex profile, chooser settings, and tests must agree on the new port.

#### Reasoning-only output or visible think tags

The direct helper's default prompt closes an empty think block; its Think
switch intentionally leaves reasoning visible. Check that Codex uses the
Responses wire API, that the caller did not inject an unfinished think block,
and that the final-answer field is displayed instead of a reasoning field.
Compare one helper request with Think and one without it before changing the
production launcher. A staged reasoning-off or lower-budget test is allowed,
but do not change production behavior for one malformed prompt.

#### Codex remains connecting or returns a server error

Check the Qwen stderr log. The old embedded peg-native template can report
Jinja Exception: System message must be at the beginning when Codex sends
multiple system or developer messages in its Responses request. This happens
before token generation, so GPU utilization may remain low.

The known-good launcher must pass
qwen3.6-codex-compatible.jinja with chat-template-file. Confirm the server
command line contains that option and that the template file exists beside the
launcher. The current llama.cpp build may also report that Responses tool
types such as namespace, web_search, or custom were skipped. That is a
separate tool-compatibility limitation; first confirm that a plain Responses
request returns a final answer.

If the old server is healthy but lacks the compatible template argument, the
Local Qwen launcher should restart only that owned server. Do not kill an
unrelated process that happens to use another port.

#### Codex authentication or wrong-profile failure

Check the isolated config.toml, models.json, installed launcher.settings.json,
and CODEX_HOME. Required values are the exact local slug, the /v1 URL,
Responses wire API, and requires_openai_auth false. Close all Codex processes
before relaunching. Do not repair this by copying the normal profile.

#### CLI stalls while raw API passes

Record the Codex version, isolated home, command line, stdout, stderr, and
whether the server received an HTTP request. If no request arrived, inspect
client profile discovery or Electron/CLI isolation; GPU tuning cannot fix a
client that never reached the server. The previous CLI smoke test remains
inconclusive until it produces direct request and output evidence.

### 15.8 Upgrade and rollback contract

For a runtime upgrade:

1. Record version, command line, model hash, health, API output, telemetry,
   and a coding answer.
2. Extract the candidate into a new versioned directory.
3. Verify its archive checksum and device discovery.
4. Test it on a second port with the same model.
5. Promote only after health, model listing, Responses, completion, memory,
   and quality checks pass.
6. Keep the previous runtime until normal use is confirmed.

For a model upgrade:

1. Verify upstream name, architecture, license, file length, and SHA-256.
2. Stage it beside the current model.
3. Test it with the same prompts and resource settings.
4. Keep the current Q4_K_M until the candidate is accepted.

For a Codex integration rollback:

1. Close Codex.
2. Back up the current installed chooser and settings.
3. Restore matching files from the dated archives in section 15.1 or from
   the installer's profile backup.
4. Leave the verified model and runtime untouched if only the UI or profile
   failed.
5. Run installed chooser ValidateOnly and the API tests.

Never use a destructive reset or broad recursive delete as rollback. Keep a
failed candidate and its logs inspectable.

### 15.9 Security and sharing boundary

The service is bound to 127.0.0.1 only. Do not change it to 0.0.0.0, add a
firewall exception, or forward the port without an explicit authentication
and network-security design.

Safe to share after review: this guide, sanitized launcher source, non-secret
checksums, anonymized timings, and redacted errors. Do not share auth.json,
generated credential-bearing configuration, Codex databases, Electron data,
sessions, profile backups, raw logs with prompts, or private source code.

The PaddleOCR artifacts in the acquisition workspace are separate. This guide
does not certify an OCR installation, and a future AI must not delete or
replace them while maintaining Qwen3.6.

### 15.10 Final AI acceptance checklist

- [ ] Model length is 21718480960 bytes and SHA-256 matches the baseline.
- [ ] Runtime version is known and list-devices shows CUDA0.
- [ ] Server uses CUDA0 plus CPU MoE, or the deviation is documented.
- [ ] Health returns HTTP 200.
- [ ] Model listing contains the exact alias.
- [ ] Responses returns status completed with non-empty output.
- [ ] Legacy completion returns valid coding output.
- [ ] NVIDIA telemetry shows GPU memory or activity during a request.
- [ ] RAM remains usable and sustained paging is absent.
- [ ] Installed chooser ValidateOnly returns Local Qwen OK.
- [ ] Profile URL, wire API, model slug, context, and auth flag are correct.
- [ ] Four high-level chooser cards remain intact.
- [ ] Normal %USERPROFILE%\.codex was not rewritten.
- [ ] A dated backup exists for each changed working file.
- [ ] No secrets, databases, sessions, or private prompts are in the package.
- [ ] Any unresolved CLI or GUI limitation is reported explicitly.

### 15.11 Maintenance record format

Append one record after each material change:

~~~text
YYYY-MM-DD HH:MM
Maintainer:
Request and classification:
Before: runtime / model hash / context / KV / layers / CPU MoE / load mode / batch
Change:
Evidence: device / health / models / Responses / completion / VRAM / RAM / speed
Files changed:
Backup path:
Result:
Rollback:
Remaining uncertainty:
~~~

Never rewrite a failed experiment into a successful history entry.

### 15.12 Latest regression evidence

The packaged test was rerun after the guide and test hardening on 2026-09-15.
It passed with health HTTP 200, Responses status completed, a final answer
message of 46 characters, valid Python completion output, and NVIDIA telemetry
showing the RTX 5060 at 6882 MiB of 8151 MiB and 65 degrees Celsius. The short
completion sample measured 34.27 tokens per second in that run.

The packaged Responses diagnostic requests 1024 output tokens because the live
server permits up to 512 reasoning tokens. A smaller request can legitimately
finish with only a reasoning item and no final answer. The test now rejects
that false-positive state.

A final rerun after the documentation synchronization also passed with a
non-empty final Responses answer, valid legacy coding output, 31.55 tokens per
second, and NVIDIA telemetry of 7485 MiB used out of 8151 MiB at 69 degrees
Celsius. The difference from the earlier 34.27 tokens per second sample is
normal benchmark variation; compare runs only under the same thermal and
workload conditions.

On 2026-09-16, a production Responses regression carrying separate
system/developer messages plus function and web-search tool descriptions
completed successfully with a final answer of `2`. The server log contained
no Jinja ordering exception; the remaining tool-type skip warning is recorded
as a known llama.cpp adapter limitation. The packaged test then returned valid
Python, 35.91 tokens per second, and 6971 MiB of 8151 MiB GPU memory used.
