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
$contextLength = 131072
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

if ($ValidateOnly) {
    $version = Get-OllamaVersion
    $tags = Get-OllamaTags
    $names = if ($tags) { @($tags.models | ForEach-Object { [string]$_.name }) } else { @() }
    [ordered]@{
        Status = if ($ollama) { 'OK' } else { 'ERROR' }
        Ollama = $ollama
        Version = if ($version) { [string]$version.version } else { $null }
        Endpoint = $endpoint
        Model = $model
        SourceModel = $sourceModel
        SourceModelInstalled = ($names -contains $sourceModel -or $names -contains ($sourceModel + ':latest'))
        ModelAliasInstalled = ($names -contains $model -or $names -contains ($model + ':latest'))
        ContextLength = $contextLength
        ServerHealthy = [bool](Test-OllamaReady)
        Logs = $logDir
    }
    return
}

if (Test-OllamaReady) {
    Write-Output 'Ollama server is already running and the Local Qwen model is available.'
    Write-Output "Endpoint: $endpoint"
    Write-Output "Model: $model"
    exit 0
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$previous = Get-OllamaVersion
if (-not $previous) {
    $oldHost = $env:OLLAMA_HOST
    $oldContext = $env:OLLAMA_CONTEXT_LENGTH
    $oldParallel = $env:OLLAMA_NUM_PARALLEL
    $oldFlash = $env:OLLAMA_FLASH_ATTENTION
    $oldKeepAlive = $env:OLLAMA_KEEP_ALIVE
    $oldNoCloud = $env:OLLAMA_NO_CLOUD
    try {
        $env:OLLAMA_HOST = '127.0.0.1:11434'
        $env:OLLAMA_CONTEXT_LENGTH = [string]$contextLength
        $env:OLLAMA_NUM_PARALLEL = '1'
        $env:OLLAMA_FLASH_ATTENTION = '0'
        $env:OLLAMA_KEEP_ALIVE = '30m'
        $env:OLLAMA_NO_CLOUD = '1'
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

Write-Output 'Ollama Local Qwen server is ready.'
Write-Output "Endpoint: $endpoint"
Write-Output "Model: $model"
Write-Output "Context environment: $contextLength tokens"
Write-Output "GPU/runtime logs: $logDir"
