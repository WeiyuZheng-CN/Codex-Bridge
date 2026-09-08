[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [ValidateSet('OpenAI-transfer', 'OpenAI-transfer-Pro')]
    [string]$TransferMode = 'OpenAI-transfer-Pro',
    [ValidateScript({
        [string]::IsNullOrWhiteSpace($_) -or
        $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    })]
    [string]$Model = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Launcher settings are missing: $settingsPath"
}
try {
    $launcherSettings = Get-Content -Raw -LiteralPath $settingsPath |
        ConvertFrom-Json
}
catch {
    throw 'launcher.settings.json is not valid JSON.'
}
$legacyActorOptional = [bool](
    $launcherSettings.PSObject.Properties['transfer_legacy_actor_optional'] -and
    $launcherSettings.transfer_legacy_actor_optional
)

function Get-ConfiguredProfileRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingName
    )

    if (
        -not $launcherSettings.PSObject.Properties[$SettingName] -or
        [string]::IsNullOrWhiteSpace([string]$launcherSettings.$SettingName)
    ) {
        throw "launcher.settings.json is missing $SettingName."
    }
    return [IO.Path]::GetFullPath([string]$launcherSettings.$SettingName)
}

# Both transfer modes use the station's newest 260902 transport settings.
# They remain separate Codex profiles because their credentials and histories
# belong to different station modes. No Moon Bridge, localhost proxy, or
# translation layer is used.
if ($TransferMode -eq 'OpenAI-transfer') {
    $profileRoot = Get-ConfiguredProfileRoot `
        -SettingName 'transfer_legacy_profile_root'
}
else {
    if ($launcherSettings.PSObject.Properties['transfer_pro_profile_root']) {
        $profileRoot = Get-ConfiguredProfileRoot `
            -SettingName 'transfer_pro_profile_root'
    }
    else {
        # Keep compatibility with the first AI-installed package schema.
        $profileRoot = Get-ConfiguredProfileRoot `
            -SettingName 'transfer_profile_root'
    }
}
$profileAuthMode = if ($TransferMode -eq 'OpenAI-transfer') {
    'environment-key'
}
else {
    'auth.json'
}
$codexHome = Join-Path $profileRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$authPath = Join-Path $codexHome 'auth.json'
$electronData = Join-Path $profileRoot 'electron-data'
$pidPath = Join-Path $installRoot 'bridge.pid'
$logDirectory = Join-Path $profileRoot 'logs'

function Show-CodexMessage {
    param(
        [string]$Message,
        [string]$Title = 'Codex - OpenAI Transfer'
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

function Get-TransferAuthenticationKey {
    try {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
    }
    catch {
        throw 'The OpenAI Transfer authentication file is not valid JSON.'
    }
    if (
        -not $auth.PSObject.Properties['OPENAI_API_KEY'] -or
        [string]::IsNullOrWhiteSpace([string]$auth.OPENAI_API_KEY)
    ) {
        throw 'The OpenAI Transfer authentication key is missing.'
    }
    return [string]$auth.OPENAI_API_KEY
}

function Assert-TransferAuthentication {
    [void](Get-TransferAuthenticationKey)
}

function Read-TransferProfileConfiguration {
    $configText = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )

    $providerLine = [regex]::Match(
        $configText,
        '(?m)^model_provider\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (
        -not $providerLine.Success -or
        $providerLine.Groups[1].Value -ne 'OpenAI'
    ) {
        throw ('The ' + $TransferMode + ' profile must use model_provider = "OpenAI".')
    }

    $baseUrlLine = [regex]::Match(
        $configText,
        '(?m)^base_url\s*=\s*"([^"]*)"\s*\r?$'
    )
    $parsedBaseUrl = $null
    if (
        -not $baseUrlLine.Success -or
        -not [Uri]::TryCreate(
            $baseUrlLine.Groups[1].Value,
            [UriKind]::Absolute,
            [ref]$parsedBaseUrl
        ) -or
        $parsedBaseUrl.Scheme -notin @('http', 'https')
    ) {
        throw "The $TransferMode profile needs a valid station base_url."
    }

    $wireApiLine = [regex]::Match(
        $configText,
        '(?m)^wire_api\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (
        -not $wireApiLine.Success -or
        $wireApiLine.Groups[1].Value -ne 'responses'
    ) {
        throw ('The ' + $TransferMode + ' profile must use wire_api = "responses".')
    }

    $requiresAuthLine = [regex]::Match(
        $configText,
        '(?m)^requires_openai_auth\s*=\s*(true|false)\s*\r?$'
    )
    if (
        -not $requiresAuthLine.Success -or
        (
            ($profileAuthMode -eq 'auth.json' -and $requiresAuthLine.Groups[1].Value -ne 'true') -or
            ($profileAuthMode -eq 'environment-key' -and $requiresAuthLine.Groups[1].Value -ne 'false')
        )
    ) {
        throw "The $TransferMode profile has an unexpected authentication mode."
    }

    $envKeyLine = [regex]::Match(
        $configText,
        '(?m)^env_key\s*=\s*"([^"]*)"\s*\r?$'
    )
    $actorHeaderLine = [regex]::Match(
        $configText,
        '(?m)^http_headers\s*=\s*\{\s*"([^"]+)"\s*=\s*"[^"]*"\s*\}\s*\r?$'
    )
    if ($profileAuthMode -eq 'environment-key') {
        if (-not $envKeyLine.Success) {
            throw 'The legacy OpenAI-transfer profile needs an env_key.'
        }
        if (-not $legacyActorOptional -and -not $actorHeaderLine.Success) {
            throw 'The current legacy OpenAI-transfer profile needs its actor header.'
        }
    }

    [ordered]@{
        Provider = $providerLine.Groups[1].Value
        BaseUrl = $parsedBaseUrl.AbsoluteUri.TrimEnd('/')
        WireApi = $wireApiLine.Groups[1].Value
        RequiresOpenAIAuth = $requiresAuthLine.Groups[1].Value
        AuthMode = $profileAuthMode
        EnvironmentKey = if ($envKeyLine.Success) { $envKeyLine.Groups[1].Value } else { '' }
        ActorHeader = if ($actorHeaderLine.Success) { $actorHeaderLine.Groups[1].Value } else { '' }
    }
}

function Set-TransferModel {
    param(
        [string]$RequestedModel
    )

    # No explicit model override: leave the profile model untouched so the
    # user's configured default (or in-app picker choice) is preserved.
    if ([string]::IsNullOrWhiteSpace($RequestedModel)) {
        return
    }

    $content = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )

    [void](Read-TransferProfileConfiguration)

    $pattern = '(?m)^model\s*=\s*"[^"]*"\s*\r?$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one top-level model setting in $codexConfigPath."
    }

    $updated = [regex]::Replace(
        $content,
        $pattern,
        'model = "' + $RequestedModel + '"',
        1
    )
    if ($updated -ceq $content) {
        return
    }

    $backupDirectory = Join-Path $profileRoot (
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

try {
    foreach ($requiredPath in @(
        $codexConfigPath,
        $authPath
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required OpenAI Transfer file is missing: $requiredPath"
        }
    }

    if ($ValidateOnly) {
        $profileSettings = Read-TransferProfileConfiguration
        $configText = [IO.File]::ReadAllText(
            $codexConfigPath,
            [Text.Encoding]::UTF8
        )
        $modelLine = [regex]::Match(
            $configText,
            '(?m)^model\s*=\s*"([^"]*)"\s*\r?$'
        )
        if (-not $modelLine.Success) {
            throw 'The OpenAI Transfer model setting could not be read.'
        }
        Assert-TransferAuthentication
        $effortLine = [regex]::Match(
            $configText,
            '(?m)^model_reasoning_effort\s*=\s*"([^"]*)"\s*\r?$'
        )
        $currentEffort = ''
        if ($effortLine.Success) {
            $currentEffort = $effortLine.Groups[1].Value
        }
        [ordered]@{
            Status = 'OK'
            TransferMode = $TransferMode
            ModelOverride = $(if ($Model) { $Model } else { '(preserve configured model)' })
            CurrentModel = $modelLine.Groups[1].Value
            CurrentProvider = $profileSettings.Provider
            CurrentBaseUrl = $profileSettings.BaseUrl
            CurrentWireApi = $profileSettings.WireApi
            RequiresOpenAIAuth = $profileSettings.RequiresOpenAIAuth
            AuthenticationMode = $profileSettings.AuthMode
            CurrentReasoningEffort = $currentEffort
            ProfileRoot = $profileRoot
            TransferCodexHome = $codexHome
            ElectronData = $electronData
            AuthFilePresent = (Test-Path -LiteralPath $authPath)
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

    Stop-DeepSeekBridgeIfRunning
    $profileSettings = Read-TransferProfileConfiguration
    Set-TransferModel -RequestedModel $Model

    $transferKey = Get-TransferAuthenticationKey

    $appExe = Resolve-CodexDesktopExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $electronData
    if ($profileSettings.AuthMode -eq 'environment-key') {
        $startInfo.EnvironmentVariables[$profileSettings.EnvironmentKey] = $transferKey
    }
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $appProcess) {
        throw 'Codex did not start.'
    }

    $appProcess.WaitForExit()
}
catch {
    Show-CodexMessage $_.Exception.Message 'Codex - OpenAI Transfer launch error'
    exit 1
}
