[CmdletBinding()]
param(
    [ValidateSet(
        'deepseek-v4-pro',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp'
    )]
    [string]$Model = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'
$historyRepair = Join-Path $installRoot (
    'maintenance\history\Repair-DeepSeek-History.ps1'
)
$logDirectory = Join-Path $installRoot 'logs'
$pidPath = Join-Path $installRoot 'bridge.pid'

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

function Get-DeepSeekProfileRoot {
    if (
        $launcherSettings -and
        $launcherSettings.PSObject.Properties['deepseek_profile_root'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$launcherSettings.deepseek_profile_root
        )
    ) {
        return [IO.Path]::GetFullPath(
            [string]$launcherSettings.deepseek_profile_root
        )
    }

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = Join-Path $env:USERPROFILE 'Documents'
    }
    return Join-Path (Join-Path $documentsPath 'Codex') 'deepseek-native-test'
}

$deepSeekRoot = Get-DeepSeekProfileRoot
$codexHome = Join-Path $deepSeekRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$modelCatalogPath = Join-Path $codexHome 'models.json'
$electronData = Join-Path $deepSeekRoot 'electron-data'

function Show-CodexMessage {
    param(
        [string]$Message,
        [string]$Title = 'Codex - DeepSeek'
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
    if ($codexCommand) {
        $resourcesDirectory = Split-Path -Parent $codexCommand.Source
        $appDirectory = Split-Path -Parent $resourcesDirectory
        $candidate = Join-Path $appDirectory 'ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' `
        -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'The installed Codex desktop executable could not be located.'
}

function Stop-LegacyMoonBridgeIfRecorded {
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        return
    }

    $savedPid = 0
    if ([int]::TryParse(
        (Get-Content -Raw -LiteralPath $pidPath).Trim(),
        [ref]$savedPid
    )) {
        $savedProcess = Get-Process -Id $savedPid `
            -ErrorAction SilentlyContinue
        if ($savedProcess -and $savedProcess.ProcessName -eq 'moonbridge') {
            Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Get-DeepSeekProfileState {
    if (-not (Test-Path -LiteralPath $codexConfigPath -PathType Leaf)) {
        throw "DeepSeek native config is missing: $codexConfigPath"
    }
    if (-not (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf)) {
        throw "DeepSeek model catalog is missing: $modelCatalogPath"
    }

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
            throw "The DeepSeek native profile is missing $name."
        }
        $settings[$name] = $match.Groups[1].Value
    }

    if ($settings.model_provider -ne 'deepseek') {
        throw 'The DeepSeek profile must use model_provider = "deepseek".'
    }
    $baseUri = $null
    if (
        -not [Uri]::TryCreate(
            $settings.base_url,
            [UriKind]::Absolute,
            [ref]$baseUri
        ) -or
        $baseUri.Scheme -notin @('http', 'https')
    ) {
        throw 'The DeepSeek native profile has an invalid base_url.'
    }
    if ($settings.wire_api -ne 'responses') {
        throw 'The DeepSeek native profile must use wire_api = "responses".'
    }
    if ([string]::IsNullOrWhiteSpace($settings.experimental_bearer_token)) {
        throw 'The DeepSeek native authentication token is missing.'
    }

    try {
        $catalog = Get-Content -Raw -LiteralPath $modelCatalogPath |
            ConvertFrom-Json
    }
    catch {
        throw 'The DeepSeek native model catalog is not valid JSON.'
    }
    if (-not $catalog.PSObject.Properties['models']) {
        throw 'The DeepSeek native model catalog has no models list.'
    }
    $modelSlugs = @($catalog.models | ForEach-Object { [string]$_.slug })
    foreach ($requiredModel in @(
        'deepseek-v4-pro',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp'
    )) {
        if ($modelSlugs -notcontains $requiredModel) {
            throw "The DeepSeek model catalog does not expose $requiredModel."
        }
    }

    return [ordered]@{
        Model = $settings.model
        Provider = $settings.model_provider
        BaseUrl = $baseUri.AbsoluteUri.TrimEnd('/')
        WireApi = $settings.wire_api
        ReasoningEffort = $settings.model_reasoning_effort
        Models = @($modelSlugs)
    }
}

function Set-SelectedModel {
    param([string]$SelectedModel)

    if ([string]::IsNullOrWhiteSpace($SelectedModel)) {
        return
    }
    $content = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )
    $pattern = '(?m)^model\s*=\s*"[^"]*"\s*\r?$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one top-level model setting in $codexConfigPath."
    }
    $updated = [regex]::Replace(
        $content,
        $pattern,
        'model = "' + $SelectedModel + '"',
        1
    )
    if ($updated -ceq $content) {
        return
    }

    $backupDirectory = Join-Path $deepSeekRoot (
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
    if (-not (Test-Path -LiteralPath $historyRepair -PathType Leaf)) {
        return
    }
    try {
        & $historyRepair -CodexHome $codexHome -Quiet
    }
    catch {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $safeMessage = [regex]::Replace(
            [string]$_.Exception.Message,
            '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}',
            '$1<redacted>'
        )
        $safeMessage = [regex]::Replace(
            $safeMessage,
            '[\r\n]+',
            ' '
        ).Trim()
        if ($safeMessage.Length -gt 1000) {
            $safeMessage = $safeMessage.Substring(0, 1000) + '...'
        }
        [IO.File]::AppendAllText(
            (Join-Path $logDirectory 'history-repair-native.log'),
            ('{0:u} History repair warning: {1}' -f (Get-Date), $safeMessage) +
                [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
}

try {
    $requiredPaths = @(
        $codexConfigPath,
        $modelCatalogPath,
        $historyRepair
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required DeepSeek native file is missing: $requiredPath"
        }
    }

    $profile = Get-DeepSeekProfileState
    if ($ValidateOnly) {
        [ordered]@{
            Status = 'OK'
            RequestedModel = $(
                if ($Model) { $Model } else { '(preserve configured model)' }
            )
            CurrentModel = $profile.Model
            CurrentProvider = $profile.Provider
            CurrentBaseUrl = $profile.BaseUrl
            CurrentWireApi = $profile.WireApi
            CurrentReasoningEffort = $profile.ReasoningEffort
            Models = $profile.Models
            DeepSeekProfileRoot = $deepSeekRoot
            CodexHome = $codexHome
            ElectronData = $electronData
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely before switching modes.'
        exit 2
    }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null
    Stop-LegacyMoonBridgeIfRecorded
    Set-SelectedModel -SelectedModel $Model
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
    Show-CodexMessage $_.Exception.Message 'Codex - DeepSeek launch error'
    exit 1
}
