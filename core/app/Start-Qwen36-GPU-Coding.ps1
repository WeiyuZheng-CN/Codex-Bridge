$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtime = (Resolve-Path (Join-Path $scriptRoot "..\runtime")).Path
$server = Join-Path $runtime "llama-server.exe"
$model = Join-Path $scriptRoot "..\model\qwen3.6-35b-a3b-coding-q4_k_m.gguf"
$chatTemplate = Join-Path $scriptRoot "qwen3.6-codex-compatible.jinja"
$port = if ($env:QWEN36_PORT) { [int]$env:QWEN36_PORT } else { 61991 }
$expectedBytes = [int64]21718480960

foreach ($requiredPath in @($server, $model, $chatTemplate)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Local Qwen3.6 file is missing: $requiredPath"
    }
}

$modelItem = Get-Item -LiteralPath $model
if ($modelItem.Length -ne $expectedBytes) {
    throw "Model size is $($modelItem.Length) bytes; expected $expectedBytes bytes."
}

$listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($listener) {
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($owner -and $owner.Name -eq "llama-server.exe" -and $owner.CommandLine -like "*local-qwen36*llama-server.exe*") {
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 -UseBasicParsing
            if ($health.StatusCode -eq 200) {
                Write-Output "Qwen3.6 GPU server is already running."
                Write-Output "Endpoint: http://127.0.0.1:$port"
                Write-Output "PID: $($listener.OwningProcess)"
                exit 0
            }
        }
        catch {}
        Write-Output "Replacing stale Qwen3.6 server PID $($listener.OwningProcess)."
        Stop-Process -Id $listener.OwningProcess -Force
        Start-Sleep -Seconds 2
    }
    else {
        throw "Port $port is already occupied by an unrelated process."
    }
}

$logDir = Join-Path $scriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdout = Join-Path $logDir "qwen36-gpu.stdout.log"
$stderr = Join-Path $logDir "qwen36-gpu.stderr.log"

$arguments = @(
    "--model", $model,
    "--alias", "qwen3.6-35b-a3b-coding",
    "--host", "127.0.0.1",
    "--port", "$port",
    "--offline",
    "--no-webui",
    "--no-mmproj",
    "--ctx-size", "262144",
    "--parallel", "1",
    "--device", "CUDA0",
    "--cpu-moe",
    "--gpu-layers", "99",
    "--flash-attn", "on",
    "--reasoning", "on",
    "--reasoning-effort", "low",
    "--reasoning-budget", "512",
    "--reasoning-format", "deepseek",
    "--batch-size", "512",
    "--ubatch-size", "256",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0",
    "--load-mode", "none",
    "--threads", "16",
    "--threads-batch", "16",
    "--chat-template-file", $chatTemplate,
    "--no-warmup",
    "--no-context-shift",
    "--log-verbosity", "3",
    "--no-log-prefix",
    "--no-log-timestamps"
)

$process = Start-Process -FilePath $server -ArgumentList $arguments -WorkingDirectory $runtime -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$ready = $false
for ($index = 0; $index -lt 120; $index++) {
    Start-Sleep -Seconds 1
    if ($process.HasExited) {
        $tail = if (Test-Path -LiteralPath $stderr) {
            (Get-Content -LiteralPath $stderr | Select-Object -Last 20) -join [Environment]::NewLine
        }
        else {
            ""
        }
        throw ("llama-server exited with code $($process.ExitCode)." + [Environment]::NewLine + $tail)
    }
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 -UseBasicParsing
        if ($health.StatusCode -eq 200) {
            $ready = $true
            break
        }
    }
    catch {}
}
if (-not $ready) {
    throw "Timed out waiting for Qwen3.6 GPU server. Logs: $stdout and $stderr"
}

Write-Output "Qwen3.6 35B-A3B Q4_K_M GPU server is ready."
Write-Output "Endpoint: http://127.0.0.1:$port"
Write-Output "PID: $($process.Id)"
Write-Output "GPU mode: CUDA0 + CPU MoE experts + GPU q8 KV + Flash Attention on"
Write-Output "Context: 262144 tokens; reasoning: low with 512-token budget"
Write-Output "Chat template: Codex-compatible system/developer normalization"
Write-Output "Prompt batching: 512 logical / 256 physical"
Write-Output "Logs: $logDir"
