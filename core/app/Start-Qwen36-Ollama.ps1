[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$localQwenRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$ollamaCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
)
$ollama = $null
foreach ($candidate in $ollamaCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $ollama = [IO.Path]::GetFullPath($candidate)
        break
    }
}
if (-not $ollama) {
    $command = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        $ollama = [IO.Path]::GetFullPath($command.Source)
    }
}

$endpoint = 'http://127.0.0.1:11434'
$sourceModel = 'qwen3.6:35b-a3b-coding'
$model = 'qwen3.6-35b-a3b-coding'
$logDir = Join-Path $scriptRoot 'logs'
$stdout = Join-Path $logDir 'qwen36-ollama.stdout.log'
$stderr = Join-Path $logDir 'qwen36-ollama.stderr.log'
$pidFile = Join-Path $scriptRoot 'ollama-server.pid.json'
$environmentBackupPath = Join-Path $scriptRoot 'ollama-user-environment-backup.json'
$contextLength = 262144
$ollamaEnvironment = [ordered]@{
    OLLAMA_CONTEXT_LENGTH = [string]$contextLength
    OLLAMA_NUM_PARALLEL = '1'
    OLLAMA_FLASH_ATTENTION = '1'
    OLLAMA_KV_CACHE_TYPE = 'q8_0'
    OLLAMA_KEEP_ALIVE = '30m'
    OLLAMA_NO_CLOUD = '1'
}
$process = $null

function Get-OllamaVersion {
    try {
        return Invoke-RestMethod -Uri "$endpoint/api/version" -TimeoutSec 5
    }
    catch {
        return $null
    }
}

function Get-OllamaTags {
    try {
        return Invoke-RestMethod -Uri "$endpoint/api/tags" -TimeoutSec 15
    }
    catch {
        return $null
    }
}

function Test-OllamaReady {
    $version = Get-OllamaVersion
    $tags = Get-OllamaTags
    if (-not $version -or -not $tags) {
        return $false
    }
    $names = @($tags.models | ForEach-Object { [string]$_.name })
    return ($names -contains $model -or $names -contains ($model + ':latest'))
}

function Set-OllamaEnvironmentDefaults {
    if (-not (Test-Path -LiteralPath $environmentBackupPath -PathType Leaf)) {
        $backup = [ordered]@{}
        foreach ($name in $ollamaEnvironment.Keys) {
            $backup[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
        }
        $backup | ConvertTo-Json | Set-Content -LiteralPath $environmentBackupPath -Encoding UTF8
    }
    foreach ($name in $ollamaEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$ollamaEnvironment[$name], 'User')
        Set-Item -Path ("Env:{0}" -f $name) -Value ([string]$ollamaEnvironment[$name])
    }
}

function Get-OllamaRunningModel {
    try {
        $running = Invoke-RestMethod -Uri "$endpoint/api/ps" -TimeoutSec 15
    }
    catch {
        return $null
    }
    $matches = @(
        $running.models |
            Where-Object {
                [string]$_.name -eq $model -or
                [string]$_.name -eq ($model + ':latest') -or
                [string]$_.name -eq $sourceModel -or
                [string]$_.name -eq ($sourceModel + ':latest')
            }
    )
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Warm-OllamaModel {
    $body = @{
        model = $model
        prompt = 'Reply with OK.'
        stream = $false
        keep_alive = '30m'
        think = $false
        options = @{
            num_predict = 1
            temperature = 0
        }
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$endpoint/api/generate" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 900 | Out-Null
}

function Wait-OllamaModelContext {
    param([int]$TimeoutSeconds = 900)
    for ($index = 0; $index -lt $TimeoutSeconds; $index++) {
        $runningModel = Get-OllamaRunningModel
        if ($runningModel) {
            $value = 0
            if ([int]::TryParse([string]$runningModel.context_length, [ref]$value)) {
                return $value
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Get-OllamaContextError {
    param([int]$ActualContext)
    return (
        "Ollama is already running the Local Qwen model with a $ActualContext-token " +
        "context, below the requested $contextLength. The launcher has saved the " +
        "persistent user settings, but an existing Ollama service must be fully " +
        "quit and restarted before the new context can take effect. Close Ollama " +
        "from its tray menu, then run this launcher again."
    )
}

function Get-OllamaContextStatus {
    $runningModel = Get-OllamaRunningModel
    if (-not $runningModel) {
        return [ordered]@{
            ActiveContextLength = $null
            ContextVerified = $false
            ContextError = $null
        }
    }
    $actual = 0
    if (-not [int]::TryParse([string]$runningModel.context_length, [ref]$actual)) {
        return [ordered]@{
            ActiveContextLength = $null
            ContextVerified = $false
            ContextError = 'Ollama reported a loaded model without a readable context_length.'
        }
    }
    return [ordered]@{
        ActiveContextLength = $actual
        ContextVerified = ($actual -ge $contextLength)
        ContextError = if ($actual -lt $contextLength) { Get-OllamaContextError -ActualContext $actual } else { $null }
    }
}

function Ensure-OllamaModelAlias {
    $tags = Get-OllamaTags
    if (-not $tags) {
        return $false
    }
    $names = @($tags.models | ForEach-Object { [string]$_.name })
    if ($names -contains $model -or $names -contains ($model + ':latest')) {
        return $true
    }
    if ($names -notcontains $sourceModel -and $names -notcontains ($sourceModel + ':latest')) {
        return $false
    }
    & $ollama cp $sourceModel $model 2>&1 | Out-Null
    return (Test-OllamaReady)
}

function Write-OllamaPidFile {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    [ordered]@{
        process_id = $ProcessId
        executable = $ollama
        endpoint = $endpoint
        started_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding UTF8
}

if (-not $ollama) {
    throw 'Ollama was not found. Install Ollama or add ollama.exe to PATH.'
}

Set-OllamaEnvironmentDefaults

if ($ValidateOnly) {
    $version = Get-OllamaVersion
    $tags = Get-OllamaTags
    $names = if ($tags) { @($tags.models | ForEach-Object { [string]$_.name }) } else { @() }
    $contextStatus = Get-OllamaContextStatus
    [ordered]@{
        Status = if ($ollama -and (Test-OllamaReady) -and $contextStatus.ContextVerified) { 'OK' } else { 'ERROR' }
        Ollama = $ollama
        Version = if ($version) { [string]$version.version } else { $null }
        Endpoint = $endpoint
        Model = $model
        SourceModel = $sourceModel
        SourceModelInstalled = ($names -contains $sourceModel -or $names -contains ($sourceModel + ':latest'))
        ModelAliasInstalled = ($names -contains $model -or $names -contains ($model + ':latest'))
        RequestedContextLength = $contextLength
        ActiveContextLength = $contextStatus.ActiveContextLength
        ContextVerified = $contextStatus.ContextVerified
        ContextError = $contextStatus.ContextError
        Environment = $ollamaEnvironment
        ServerHealthy = [bool](Test-OllamaReady)
        Logs = $logDir
    }
    return
}

if (Test-OllamaReady) {
    $contextStatus = Get-OllamaContextStatus
    if (-not $contextStatus.ActiveContextLength) {
        Warm-OllamaModel
        $contextStatus = [ordered]@{
            ActiveContextLength = Wait-OllamaModelContext
            ContextVerified = $false
            ContextError = $null
        }
        $contextStatus.ContextVerified = ($contextStatus.ActiveContextLength -ge $contextLength)
        if (-not $contextStatus.ContextVerified -and $contextStatus.ActiveContextLength) {
            $contextStatus.ContextError = Get-OllamaContextError -ActualContext $contextStatus.ActiveContextLength
        }
    }
    if (-not $contextStatus.ContextVerified) {
        if ($contextStatus.ContextError) { throw $contextStatus.ContextError }
        throw "Ollama did not expose a verified $contextLength-token context after loading '$model'."
    }
    Write-Output 'Ollama server is already running with the requested Local Qwen context.'
    Write-Output "Endpoint: $endpoint"
    Write-Output "Model: $model"
    Write-Output "Active context: $($contextStatus.ActiveContextLength) tokens"
    exit 0
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$previous = Get-OllamaVersion
if (-not $previous) {
    $oldHost = $env:OLLAMA_HOST
    $oldContext = $env:OLLAMA_CONTEXT_LENGTH
    $oldParallel = $env:OLLAMA_NUM_PARALLEL
    $oldFlash = $env:OLLAMA_FLASH_ATTENTION
    $oldKvCache = $env:OLLAMA_KV_CACHE_TYPE
    $oldKeepAlive = $env:OLLAMA_KEEP_ALIVE
    $oldNoCloud = $env:OLLAMA_NO_CLOUD
    try {
        $env:OLLAMA_HOST = '127.0.0.1:11434'
        foreach ($name in $ollamaEnvironment.Keys) {
            Set-Item -Path ("Env:{0}" -f $name) -Value ([string]$ollamaEnvironment[$name])
        }
        $process = Start-Process -FilePath $ollama `
            -ArgumentList @('serve') `
            -WorkingDirectory $localQwenRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -PassThru
    }
    finally {
        $env:OLLAMA_HOST = $oldHost
        $env:OLLAMA_CONTEXT_LENGTH = $oldContext
        $env:OLLAMA_NUM_PARALLEL = $oldParallel
        $env:OLLAMA_FLASH_ATTENTION = $oldFlash
        $env:OLLAMA_KV_CACHE_TYPE = $oldKvCache
        $env:OLLAMA_KEEP_ALIVE = $oldKeepAlive
        $env:OLLAMA_NO_CLOUD = $oldNoCloud
    }
    Write-OllamaPidFile -ProcessId $process.Id
}

$ready = $false
for ($index = 0; $index -lt 120; $index++) {
    Start-Sleep -Seconds 1
    if (Ensure-OllamaModelAlias) {
        $ready = $true
        break
    }
    if ($process -and $process.HasExited) {
        $tail = if (Test-Path -LiteralPath $stderr) {
            (Get-Content -LiteralPath $stderr | Select-Object -Last 30) -join [Environment]::NewLine
        }
        else { '' }
        throw "Ollama server exited with code $($process.ExitCode).$([Environment]::NewLine)$tail"
    }
}
if (-not $ready) {
    $tags = Get-OllamaTags
    $names = if ($tags) { @($tags.models | ForEach-Object { [string]$_.name }) } else { @() }
    if ($names -notcontains $sourceModel -and $names -notcontains ($sourceModel + ':latest')) {
        throw "Ollama is ready, but model '$sourceModel' is not installed. Install it first; no model was downloaded by this launcher."
    }
    throw "Timed out creating the Ollama model alias '$model'. Logs: $stdout and $stderr"
}

Warm-OllamaModel
$activeContext = Wait-OllamaModelContext
if (-not $activeContext -or $activeContext -lt $contextLength) {
    if ($activeContext) { throw (Get-OllamaContextError -ActualContext $activeContext) }
    throw "Ollama loaded '$model' but did not report the requested $contextLength-token context."
}

Write-Output 'Ollama Local Qwen server is ready.'
Write-Output "Endpoint: $endpoint"
Write-Output "Model: $model"
Write-Output "Active context: $activeContext tokens"
Write-Output 'Thinking: enabled; Codex may select minimal, low, medium, high, xhigh, or max.'
Write-Output 'Output token cap: none at the Ollama model default; request-level caps remain client-controlled.'
Write-Output "GPU/runtime logs: $logDir"
