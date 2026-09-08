[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'

if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "Launcher settings are missing: $settingsPath"
}
try {
    $launcherSettings = Get-Content -Raw -LiteralPath $settingsPath |
        ConvertFrom-Json
}
catch {
    throw 'launcher.settings.json is not valid JSON.'
}
if (
    -not $launcherSettings.PSObject.Properties['native_profile_root'] -or
    [string]::IsNullOrWhiteSpace(
        [string]$launcherSettings.native_profile_root
    )
) {
    throw 'launcher.settings.json is missing native_profile_root.'
}

# Native DeepSeek profile: talks directly to https://api.deepseek.com/responses.
# No Moon Bridge, no localhost proxy, no translation layer.
$nativeRoot = [IO.Path]::GetFullPath(
    [string]$launcherSettings.native_profile_root
)
$codexHome = Join-Path $nativeRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$modelCatalogPath = Join-Path $codexHome 'models.json'
$electronData = Join-Path $nativeRoot 'electron-data'
$pidPath = Join-Path $installRoot 'bridge.pid'
$historyRepair = Join-Path $installRoot (
    'maintenance\history\Repair-DeepSeek-History.ps1'
)
$logDirectory = Join-Path $installRoot 'logs'

function Show-CodexMessage {
    param(
        [string]$Message,
        [string]$Title = 'Codex - DeepSeek V4 Flash'
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
    if ($launcherSettings.PSObject.Properties['codex_executable']) {
        $configured = [string]$launcherSettings.codex_executable
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [IO.Path]::GetFullPath($configured)
        }
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommand) {
        $resourcesDirectory = Split-Path -Parent $codexCommand.Source
        $appDirectory = Split-Path -Parent $resourcesDirectory
        $candidate = Join-Path $appDirectory 'ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'The installed Codex desktop executable could not be located.'
}

function Stop-DeepSeekBridgeIfRunning {
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return
    }

    $savedPid = 0
    if ([int]::TryParse(
        (Get-Content -Raw -LiteralPath $pidPath).Trim(),
        [ref]$savedPid
    )) {
        $savedProcess = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
        if ($savedProcess -and $savedProcess.ProcessName -eq 'moonbridge') {
            Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Get-NativeProfileState {
    $content = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )

    $settings = @{}
    foreach ($name in @(
        'model',
        'model_provider',
        'base_url',
        'wire_api',
        'model_reasoning_effort',
        'experimental_bearer_token'
    )) {
        $match = [regex]::Match(
            $content,
            '(?m)^' + [regex]::Escape($name) +
                '\s*=\s*"([^"]*)"\s*\r?$'
        )
        if (-not $match.Success) {
            throw "The native DeepSeek profile is missing $name."
        }
        $settings[$name] = $match.Groups[1].Value
    }

    if ($settings.model_provider -ne 'deepseek') {
        throw 'The native DeepSeek profile must use model_provider = "deepseek".'
    }
    if ($settings.base_url -ne 'https://api.deepseek.com/') {
        throw 'The native DeepSeek profile has an unexpected base_url.'
    }
    if ($settings.wire_api -ne 'responses') {
        throw 'The native DeepSeek profile must use wire_api = "responses".'
    }
    if ([string]::IsNullOrWhiteSpace($settings.experimental_bearer_token)) {
        throw 'The native DeepSeek authentication token is missing.'
    }
    try {
        $null = Get-Content -Raw -LiteralPath $modelCatalogPath |
            ConvertFrom-Json
    }
    catch {
        throw 'The native DeepSeek model catalog is not valid JSON.'
    }

    return [ordered]@{
        Model = $settings.model
        Provider = $settings.model_provider
        BaseUrl = $settings.base_url
        WireApi = $settings.wire_api
        ReasoningEffort = $settings.model_reasoning_effort
        AuthPresent = $true
        CatalogValid = $true
    }
}

function Set-NativeFlashModel {
    $content = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )

    $providerLine = [regex]::Match(
        $content,
        '(?m)^model_provider\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (
        -not $providerLine.Success -or
        $providerLine.Groups[1].Value -ne 'deepseek'
    ) {
        throw 'The native DeepSeek profile must use model_provider = "deepseek".'
    }

    $pattern = '(?m)^model\s*=\s*"[^"]*"\s*\r?$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one top-level model setting in $codexConfigPath."
    }

    $updated = [regex]::Replace(
        $content,
        $pattern,
        'model = "deepseek-v4-flash"',
        1
    )
    if ($updated -ceq $content) {
        return
    }

    $backupDirectory = Join-Path $nativeRoot (
        'backups\model-switch\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    )
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
    $backupPath = Join-Path $backupDirectory 'config.toml'
    $temporaryPath = Join-Path $codexHome (
        'config.toml.switch-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $updated, $utf8NoBom)
    try {
        [IO.File]::Replace(
            $temporaryPath,
            $codexConfigPath,
            $backupPath,
            $true
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-HistoryRepair {
    try {
        & $historyRepair -CodexHome $codexHome -Quiet
    }
    catch {
        $safeMessage = [regex]::Replace(
            [string]$_.Exception.Message,
            '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}',
            '$1<redacted>'
        )
        $safeMessage = [regex]::Replace(
            $safeMessage,
            '(?i)\bsk-[A-Za-z0-9_-]{12,}',
            '<redacted-api-key>'
        )
        $safeMessage = [regex]::Replace(
            $safeMessage,
            '(?i)((?:api[_-]?key|auth[_-]?token)\s*[:=]\s*["'']?)[^\s,"'']{8,}',
            '$1<redacted>'
        )
        $safeMessage = [regex]::Replace(
            $safeMessage,
            '[\r\n]+',
            ' '
        ).Trim()
        if ($safeMessage.Length -gt 1000) {
            $safeMessage = $safeMessage.Substring(0, 1000) +
                '... [truncated]'
        }
        $message = '{0:u} History repair warning: {1}' -f (
            Get-Date
        ), $safeMessage
        $historyLogPath = Join-Path $logDirectory (
            'history-repair-native-flash.log'
        )
        $encoding = New-Object System.Text.UTF8Encoding($false)
        if (
            (Test-Path -LiteralPath $historyLogPath) -and
            (Get-Item -LiteralPath $historyLogPath).Length -ge 256KB
        ) {
            [IO.File]::Copy(
                $historyLogPath,
                "$historyLogPath.previous",
                $true
            )
            [IO.File]::WriteAllText($historyLogPath, '', $encoding)
        }
        [IO.File]::AppendAllText(
            $historyLogPath,
            $message + [Environment]::NewLine,
            $encoding
        )
    }
}

try {
    foreach ($requiredPath in @(
        $codexConfigPath,
        $modelCatalogPath,
        $historyRepair
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required native DeepSeek file is missing: $requiredPath"
        }
    }

    if ($ValidateOnly) {
        $profile = Get-NativeProfileState
        [ordered]@{
            Status = 'OK'
            RequestedModel = 'deepseek-v4-flash'
            CurrentModel = $profile.Model
            CurrentProvider = $profile.Provider
            CurrentBaseUrl = $profile.BaseUrl
            CurrentWireApi = $profile.WireApi
            CurrentReasoningEffort = $profile.ReasoningEffort
            AuthPresent = $profile.AuthPresent
            CatalogValid = $profile.CatalogValid
            NativeCodexHome = $codexHome
            ElectronData = $electronData
            BridgePidFile = $pidPath
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely, then open the shortcut again to switch models.'
        exit 2
    }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null

    $null = Get-NativeProfileState
    Stop-DeepSeekBridgeIfRunning
    Set-NativeFlashModel
    Invoke-HistoryRepair

    $appExe = Resolve-CodexDesktopExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $electronData
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $appProcess) {
        throw 'Codex did not start.'
    }

    $appProcess.WaitForExit()
    Invoke-HistoryRepair
}
catch {
    Show-CodexMessage $_.Exception.Message 'Codex - DeepSeek V4 Flash launch error'
    exit 1
}
