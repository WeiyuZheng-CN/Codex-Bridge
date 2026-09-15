[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'
$powerShellExe = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)

$launcherSettings = $null
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
        $launcherSettings = Get-Content -Raw -LiteralPath $settingsPath |
            ConvertFrom-Json
    }
    catch {
        throw 'launcher.settings.json is not valid JSON.'
    }
}

function Get-DocumentsPath {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) {
        $documents = Join-Path $env:USERPROFILE 'Documents'
    }
    return $documents
}

function Get-SettingPath {
    param(
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$DefaultPath
    )
    if (
        $launcherSettings -and
        $launcherSettings.PSObject.Properties[$PropertyName] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$launcherSettings.$PropertyName
        )
    ) {
        return [IO.Path]::GetFullPath([string]$launcherSettings.$PropertyName)
    }
    return [IO.Path]::GetFullPath($DefaultPath)
}

$documentsPath = Get-DocumentsPath
$localQwenRoot = Get-SettingPath `
    -PropertyName 'local_qwen36_root' `
    -DefaultPath (Join-Path $documentsPath 'Codex\local-qwen36')
$profileRoot = Get-SettingPath `
    -PropertyName 'local_qwen36_profile_root' `
    -DefaultPath (Join-Path $documentsPath 'Codex\local-qwen36-codex')
$codexHome = Join-Path $profileRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$electronData = Join-Path $profileRoot 'electron-data'
$serverLauncher = Join-Path $localQwenRoot 'launcher\Start-Qwen36-GPU-Coding.ps1'
$serverExecutable = Join-Path $localQwenRoot 'runtime\llama-server.exe'
$modelPath = Join-Path $localQwenRoot 'model\qwen3.6-35b-a3b-coding-q4_k_m.gguf'
$port = 61991
$endpoint = "http://127.0.0.1:$port"
$expectedModelBytes = [int64]21718480960
$expectedContextWindow = 262144

function Show-CodexMessage {
    param(
        [string]$Message,
        [string]$Title = 'Codex - Local Qwen3.6'
    )
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Message, $Title) | Out-Null
    }
    catch {
        Write-Host "$Title`n$Message"
    }
}

function Resolve-CodexDesktopExecutable {
    if (
        $launcherSettings -and
        $launcherSettings.PSObject.Properties['codex_executable']
    ) {
        $configured = [string]$launcherSettings.codex_executable
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [IO.Path]::GetFullPath($configured)
        }
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommand -and $codexCommand.Source) {
        $searchDirectory = Split-Path -Parent $codexCommand.Source
        for ($level = 0; $level -lt 5 -and $searchDirectory; $level++) {
            $candidate = Join-Path $searchDirectory 'ChatGPT.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
            $parentDirectory = Split-Path -Parent $searchDirectory
            if ($parentDirectory -eq $searchDirectory) { break }
            $searchDirectory = $parentDirectory
        }
    }

    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Codex\ChatGPT.exe'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\ChatGPT.exe'),
        (Join-Path $env:ProgramFiles 'Codex\ChatGPT.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw 'The installed Codex desktop executable could not be located.'
}

function Assert-LocalQwenRuntime {
    foreach ($requiredPath in @(
        $serverLauncher,
        $serverExecutable,
        $modelPath
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Local Qwen3.6 runtime file is missing: $requiredPath"
        }
    }
    $modelItem = Get-Item -LiteralPath $modelPath
    if ($modelItem.Length -ne $expectedModelBytes) {
        throw (
            "Local Qwen3.6 model size is $($modelItem.Length) bytes; " +
            "expected $expectedModelBytes bytes."
        )
    }
}

function Read-LocalProfileConfiguration {
    if (-not (Test-Path -LiteralPath $codexConfigPath -PathType Leaf)) {
        throw "Local Qwen3.6 Codex profile is missing: $codexConfigPath"
    }
    $content = [IO.File]::ReadAllText($codexConfigPath, [Text.Encoding]::UTF8)
    $values = [ordered]@{}
    foreach ($name in @('model', 'model_provider', 'model_reasoning_effort')) {
        $match = [regex]::Match(
            $content,
            '(?m)^' + [regex]::Escape($name) +
                '\s*=\s*"([^"]*)"\s*\r?$'
        )
        if (-not $match.Success) {
            throw "The Local Qwen3.6 profile is missing $name."
        }
        $values[$name] = $match.Groups[1].Value
    }
    $contextLine = [regex]::Match(
        $content,
        '(?m)^model_context_window\s*=\s*(\d+)\s*\r?$'
    )
    if (-not $contextLine.Success -or [int]$contextLine.Groups[1].Value -ne $expectedContextWindow) {
        throw "The Local Qwen3.6 profile must use a 262144-token context window."
    }
    $provider = [regex]::Match(
        $content,
        '(?ms)\[model_providers\.local_qwen36\](.*?)(?=\r?\n\[|\z)'
    )
    if (-not $provider.Success) {
        throw 'The Local Qwen3.6 provider block is missing.'
    }
    $catalogLine = [regex]::Match(
        $content,
        '(?m)^model_catalog_json\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (-not $catalogLine.Success -or
        -not (Test-Path -LiteralPath $catalogLine.Groups[1].Value -PathType Leaf)) {
        throw 'The Local Qwen3.6 model catalog is missing.'
    }
    try {
        $catalog = Get-Content -Raw -LiteralPath $catalogLine.Groups[1].Value |
            ConvertFrom-Json
        $catalogModel = @(
            $catalog.models |
                Where-Object { $_.slug -eq 'qwen3.6-35b-a3b-coding' }
        )
        $requiredLevels = @(
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max'
        )
        if ($catalogModel.Count -ne 1) {
            throw 'the catalog must contain exactly one Local Qwen3.6 model'
        }
        $actualLevels = @(
            $catalogModel[0].supported_reasoning_levels |
                ForEach-Object { [string]$_.effort }
        )
        foreach ($level in $requiredLevels) {
            if ($actualLevels -notcontains $level) {
                throw "the catalog is missing reasoning level $level"
            }
        }
    }
    catch {
        throw "The Local Qwen3.6 model catalog is invalid: $($_.Exception.Message)"
    }
    $providerText = $provider.Groups[1].Value
    $baseUrl = [regex]::Match(
        $providerText,
        '(?m)^base_url\s*=\s*"([^"]*)"\s*\r?$'
    )
    $wireApi = [regex]::Match(
        $providerText,
        '(?m)^wire_api\s*=\s*"([^"]*)"\s*\r?$'
    )
    $requiresAuth = [regex]::Match(
        $providerText,
        '(?m)^requires_openai_auth\s*=\s*(true|false)\s*\r?$'
    )
    if (-not $baseUrl.Success -or $baseUrl.Groups[1].Value -ne $endpoint + '/v1') {
        throw "The Local Qwen3.6 profile must use base_url = `"$endpoint/v1`"."
    }
    if (-not $wireApi.Success -or $wireApi.Groups[1].Value -ne 'responses') {
        throw 'The Local Qwen3.6 profile must use wire_api = "responses".'
    }
    if (-not $requiresAuth.Success -or $requiresAuth.Groups[1].Value -ne 'false') {
        throw 'The Local Qwen3.6 profile must disable OpenAI authentication.'
    }
    if ($values.model_provider -ne 'local_qwen36') {
        throw 'The Local Qwen3.6 profile has an unexpected model_provider.'
    }
    return [ordered]@{
        Model = $values.model
        Provider = $values.model_provider
        ReasoningEffort = $values.model_reasoning_effort
        ReasoningLevels = @($actualLevels)
        BaseUrl = $baseUrl.Groups[1].Value
        WireApi = $wireApi.Groups[1].Value
        RequiresOpenAIAuth = $requiresAuth.Groups[1].Value
        ContextWindow = [int]$contextLine.Groups[1].Value
        CatalogPath = $catalogLine.Groups[1].Value
    }
}

function Get-LocalServerListener {
    return Get-NetTCPConnection -State Listen -LocalPort $port `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Assert-LocalServerOwnership {
    param([Parameter(Mandatory = $true)]$Listener)
    $owner = Get-CimInstance Win32_Process `
        -Filter "ProcessId = $($Listener.OwningProcess)" `
        -ErrorAction SilentlyContinue
    if (
        -not $owner -or
        $owner.Name -ne 'llama-server.exe' -or
        $owner.CommandLine -notlike "*$localQwenRoot*llama-server.exe*"
    ) {
        throw (
            "Port $port is occupied by an unrelated process. " +
            'Stop it manually or choose another local model port.'
        )
    }
    return $owner
}

function Test-LocalServerHealth {
    try {
        $health = Invoke-WebRequest -Uri "$endpoint/health" `
            -TimeoutSec 3 -UseBasicParsing
        return ($health.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Start-LocalQwenServer {
    $listener = Get-LocalServerListener
    if ($listener) {
        $null = Assert-LocalServerOwnership -Listener $listener
        if (Test-LocalServerHealth) {
            return $listener.OwningProcess
        }
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        ('"' + $serverLauncher + '"')
    )
    $wrapper = Start-Process -FilePath $powerShellExe `
        -ArgumentList $arguments `
        -WorkingDirectory $localQwenRoot `
        -WindowStyle Hidden `
        -PassThru
    for ($index = 0; $index -lt 180; $index++) {
        Start-Sleep -Seconds 1
        if (Test-LocalServerHealth) {
            $readyListener = Get-LocalServerListener
            if ($readyListener) {
                $null = Assert-LocalServerOwnership -Listener $readyListener
                return $readyListener.OwningProcess
            }
        }
        if ($wrapper.HasExited -and $index -gt 5) {
            # The wrapper normally exits after spawning llama-server. Continue
            # waiting while the child finishes loading the 20 GB model.
        }
    }
    throw (
        'Timed out waiting for the Local Qwen3.6 server. Inspect ' +
        (Join-Path $localQwenRoot 'launcher\logs') + '.'
    )
}

try {
    Assert-LocalQwenRuntime
    $profile = Read-LocalProfileConfiguration
    if ($ValidateOnly) {
        [ordered]@{
            Status = 'OK'
            Model = $profile.Model
            Provider = $profile.Provider
            BaseUrl = $profile.BaseUrl
            WireApi = $profile.WireApi
            RequiresOpenAIAuth = $profile.RequiresOpenAIAuth
            ReasoningEffort = $profile.ReasoningEffort
            ReasoningLevels = @($profile.ReasoningLevels)
            ContextWindow = $profile.ContextWindow
            LocalQwenRoot = $localQwenRoot
            ModelPath = $modelPath
            ModelBytes = $expectedModelBytes
            Runtime = $serverExecutable
            ProfileRoot = $profileRoot
            CodexHome = $codexHome
            ElectronData = $electronData
            ServerHealthy = (Test-LocalServerHealth)
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely before switching modes.'
        exit 2
    }

    $serverPid = Start-LocalQwenServer
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null
    $appExe = Resolve-CodexDesktopExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $electronData
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $appProcess) { throw 'Codex did not start.' }
    Write-Verbose "Local Qwen3.6 server PID: $serverPid"
    $appProcess.WaitForExit()
}
catch {
    Show-CodexMessage $_.Exception.Message
    exit 1
}
