[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcherSettings = $null
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $launcherSettings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
}

function Get-DocumentsPath {
    $path = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $env:USERPROFILE 'Documents'
    }
    return $path
}

function Get-SettingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Default
    )
    if ($launcherSettings -and $launcherSettings.PSObject.Properties[$Name]) {
        $value = [string]$launcherSettings.$Name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [IO.Path]::GetFullPath($value)
        }
    }
    return [IO.Path]::GetFullPath($Default)
}

$documentsPath = Get-DocumentsPath
$localQwenRoot = Get-SettingPath -Name 'local_qwen36_root' `
    -Default (Join-Path $documentsPath 'Codex\local-qwen36')
$profileRoot = Get-SettingPath -Name 'local_qwen36_ollama_profile_root' `
    -Default (Join-Path $documentsPath 'Codex\local-qwen36-ollama-codex')
$codexHome = Join-Path $profileRoot 'codex-home'
$electronData = Join-Path $profileRoot 'electron-data'
$serverLauncher = Join-Path $localQwenRoot 'launcher\Start-Qwen36-Ollama.ps1'
$catalogPath = Join-Path $codexHome 'models.json'
$configPath = Join-Path $codexHome 'config.toml'
$endpoint = 'http://127.0.0.1:11434'
$model = 'qwen3.6-35b-a3b-coding'
$contextWindow = 131072

function Show-CodexMessage {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Message, 'Codex - Local Qwen3.6') | Out-Null
    }
    catch {
        Write-Host "Codex - Local Qwen3.6`n$Message"
    }
}

function Resolve-CodexExecutable {
    if ($launcherSettings -and $launcherSettings.PSObject.Properties['codex_executable']) {
        $configured = [string]$launcherSettings.codex_executable
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [IO.Path]::GetFullPath($configured)
        }
    }
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) {
        $package = Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Codex*' } |
            Sort-Object Version -Descending | Select-Object -First 1
    }
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Codex for Windows was not found.'
}

function Read-ProfileValues {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Ollama Codex profile is missing: $configPath"
    }
    $content = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
    $values = [ordered]@{}
    foreach ($name in @('model', 'model_provider', 'model_reasoning_effort')) {
        $match = [regex]::Match($content, '(?m)^' + [regex]::Escape($name) + '\s*=\s*"([^"]*)"\s*\r?$')
        if (-not $match.Success) { throw "Ollama profile is missing $name." }
        $values[$name] = $match.Groups[1].Value
    }
    $context = [regex]::Match($content, '(?m)^model_context_window\s*=\s*(\d+)\s*\r?$')
    if (-not $context.Success -or [int]$context.Groups[1].Value -ne $contextWindow) {
        throw "Ollama profile must use a $contextWindow-token context window."
    }
    $catalog = [regex]::Match($content, '(?m)^model_catalog_json\s*=\s*"([^"]*)"\s*\r?$')
    if (-not $catalog.Success -or -not (Test-Path -LiteralPath $catalog.Groups[1].Value -PathType Leaf)) {
        throw 'Ollama profile model catalog is missing.'
    }
    $catalogObject = Get-Content -Raw -LiteralPath $catalog.Groups[1].Value | ConvertFrom-Json
    $entry = @($catalogObject.models | Where-Object { $_.slug -eq $model })
    if ($entry.Count -ne 1) { throw 'Ollama catalog must contain exactly one Local Qwen model.' }
    if (@($entry[0].input_modalities) -notcontains 'image') {
        throw 'Ollama catalog must advertise image input after image validation.'
    }
    if ($values.model -ne $model -or $values.model_provider -ne 'ollama') {
        throw 'Ollama profile has an unexpected model or provider.'
    }
    return [ordered]@{
        Model = $values.model
        Provider = $values.model_provider
        ReasoningEffort = $values.model_reasoning_effort
        ContextWindow = [int]$context.Groups[1].Value
        CatalogPath = $catalog.Groups[1].Value
    }
}

function Test-OllamaHealth {
    try {
        $version = Invoke-RestMethod -Uri "$endpoint/api/version" -TimeoutSec 5
        $tags = Invoke-RestMethod -Uri "$endpoint/api/tags" -TimeoutSec 15
        $names = @($tags.models | ForEach-Object { [string]$_.name })
        return [bool]($version -and ($names -contains $model -or $names -contains ($model + ':latest')))
    }
    catch { return $false }
}

function Start-Ollama {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $serverLauncher + '"'))
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $arguments `
        -WorkingDirectory $localQwenRoot -WindowStyle Hidden -PassThru
    for ($index = 0; $index -lt 150; $index++) {
        Start-Sleep -Seconds 1
        if (Test-OllamaHealth) { return }
        if ($process.HasExited -and $index -gt 10) {
            throw "Ollama launcher exited with code $($process.ExitCode)."
        }
    }
    throw 'Timed out waiting for the Ollama Local Qwen server.'
}

try {
    foreach ($required in @($serverLauncher, $configPath, $catalogPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Ollama Local Qwen asset is missing: $required"
        }
    }
    $profile = Read-ProfileValues
    if ($ValidateOnly) {
        [ordered]@{
            Status = 'OK'
            Backend = 'ollama'
            Model = $profile.Model
            Provider = $profile.Provider
            Endpoint = $endpoint
            ContextWindow = $profile.ContextWindow
            ProfileRoot = $profileRoot
            CodexHome = $codexHome
            LocalQwenRoot = $localQwenRoot
            ServerHealthy = (Test-OllamaHealth)
            ImageInput = $true
            FallbackLauncher = (Join-Path $installRoot 'Start-Codex-Local-Qwen36.ps1')
        }
        return
    }
    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely before switching modes.'
        exit 2
    }
    if (-not (Test-OllamaHealth)) { Start-Ollama }
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null
    $appExe = Resolve-CodexExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $electronData
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $appProcess) { throw 'Codex did not start.' }
    $appProcess.WaitForExit()
}
catch {
    Show-CodexMessage $_.Exception.Message
    exit 1
}
