[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$RefreshModels,
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
$credentialStoreScript = Join-Path $installRoot 'Codex-CredentialStore.ps1'
if (Test-Path -LiteralPath $credentialStoreScript -PathType Leaf) {
    . $credentialStoreScript
}

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
$profileSetting = if (
    $launcherSettings.PSObject.Properties['transfer_shared_profile_root'] -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$launcherSettings.transfer_shared_profile_root
    )
) {
    [string]$launcherSettings.transfer_shared_profile_root
}
elseif (
    $launcherSettings.PSObject.Properties['transfer_profile_root'] -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$launcherSettings.transfer_profile_root
    )
) {
    [string]$launcherSettings.transfer_profile_root
}
else {
    throw 'launcher.settings.json is missing the shared Transfer profile root.'
}
$profileRoot = [IO.Path]::GetFullPath($profileSetting)
$codexHome = Join-Path $profileRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$authPath = Join-Path $codexHome 'auth.json'
$modelCatalogPath = Join-Path $codexHome 'models.json'
$electronData = Join-Path $profileRoot 'electron-data'
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
        throw 'The OpenAI Transfer profile must use model_provider = "OpenAI".'
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
        throw 'The OpenAI Transfer profile needs a valid station base_url.'
    }

    $wireApiLine = [regex]::Match(
        $configText,
        '(?m)^wire_api\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (
        -not $wireApiLine.Success -or
        $wireApiLine.Groups[1].Value -ne 'responses'
    ) {
        throw 'The OpenAI Transfer profile must use wire_api = "responses".'
    }

    $requiresAuthLine = [regex]::Match(
        $configText,
        '(?m)^requires_openai_auth\s*=\s*(true|false)\s*\r?$'
    )
    if (
        -not $requiresAuthLine.Success -or
        $requiresAuthLine.Groups[1].Value -ne 'true'
    ) {
        throw 'The OpenAI Transfer profile must use auth.json authentication.'
    }

    $catalogLine = [regex]::Match(
        $configText,
        '(?m)^model_catalog_json\s*=\s*"([^"]*)"\s*\r?$'
    )
    if (
        -not $catalogLine.Success -or
        [IO.Path]::GetFullPath($catalogLine.Groups[1].Value) -ne
            [IO.Path]::GetFullPath($modelCatalogPath) -or
        -not (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf)
    ) {
        throw 'The OpenAI Transfer profile model catalog is missing or points to the wrong file.'
    }

    [ordered]@{
        Provider = $providerLine.Groups[1].Value
        BaseUrl = $parsedBaseUrl.AbsoluteUri.TrimEnd('/')
        WireApi = $wireApiLine.Groups[1].Value
        RequiresOpenAIAuth = $requiresAuthLine.Groups[1].Value
        AuthMode = 'auth.json'
        ProfileStrategy = 'shared-auth-json'
        CatalogPath = $modelCatalogPath
    }
}

function Get-TransferModelsEndpoint {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $normalized = $BaseUrl.TrimEnd('/')
    if ($normalized -match '/v1$') {
        return $normalized + '/models'
    }
    return $normalized + '/v1/models'
}

function ConvertTo-TransferModelDisplayName {
    param([Parameter(Mandatory = $true)][string]$Slug)

    $parts = @($Slug -split '-')
    if ($parts.Count -lt 3 -or $parts[0] -ne 'gpt') {
        return $Slug
    }
    $tail = @(
        $parts[2..($parts.Count - 1)] |
            ForEach-Object {
                if ($_.Length -eq 0) {
                    ''
                }
                else {
                    $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
                }
            }
    ) -join ' '
    return 'GPT-' + $parts[1] + ' ' + $tail
}

function New-GenericTransferModelEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [int]$Priority = 10
    )

    $imageCapable = $Slug -in @(
        'gpt-5.6-sol',
        'gpt-5.6-luna',
        'gpt-5.6-terra',
        'gpt-6-sol',
        'gpt-6-luna',
        'gpt-6-astra'
    )
    [ordered]@{
        slug = $Slug
        display_name = ConvertTo-TransferModelDisplayName -Slug $Slug
        description = 'OpenAI-compatible Transfer coding model.'
        default_reasoning_level = 'high'
        supported_reasoning_levels = @(
            [ordered]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' }
            [ordered]@{ effort = 'medium'; description = 'Balanced reasoning' }
            [ordered]@{ effort = 'high'; description = 'Deep reasoning for complex work' }
            [ordered]@{ effort = 'xhigh'; description = 'Extra deep reasoning' }
            [ordered]@{ effort = 'max'; description = 'Maximum reasoning depth' }
            [ordered]@{ effort = 'ultra'; description = 'Highest available reasoning depth' }
        )
        shell_type = 'shell_command'
        visibility = 'list'
        supported_in_api = $true
        priority = $Priority
        additional_speed_tiers = @()
        availability_nux = $null
        upgrade = $null
        base_instructions = 'You are an OpenAI-compatible coding model connected through the Transfer station. Inspect the workspace, follow its instructions, and collaborate until the user''s goal is handled.'
        supports_reasoning_summaries = $true
        default_reasoning_summary = 'none'
        support_verbosity = $true
        default_verbosity = 'low'
        apply_patch_tool_type = 'freeform'
        web_search_tool_type = 'text'
        truncation_policy = [ordered]@{ mode = 'tokens'; limit = 10000 }
        supports_parallel_tool_calls = $true
        supports_image_detail_original = $imageCapable
        effective_context_window_percent = 95
        experimental_supported_tools = @()
        input_modalities = if ($imageCapable) {
            @('text', 'image')
        }
        else {
            @('text')
        }
        supports_search_tool = $false
        context_window = 1000000
        max_context_window = 1000000
        reasoning_summary_format = 'experimental'
        minimal_client_version = '0.154.0'
        multi_agent_version = 'v2'
        use_responses_lite = $false
        include_skills_usage_instructions = $true
    }
}

function Sync-TransferModelCatalog {
    param([switch]$Strict)

    try {
        $profile = Read-TransferProfileConfiguration
        $key = Get-TransferAuthenticationKey
        $headers = @{ Authorization = 'Bearer ' + $key }
        $response = Invoke-RestMethod `
            -Uri (Get-TransferModelsEndpoint -BaseUrl $profile.BaseUrl) `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 45
        $remoteIds = @()
        foreach ($item in @($response.data)) {
            $id = [string]$item.id
            if (
                $id -match '^gpt-' -and
                $id -notmatch '^gpt-image'
            ) {
                $remoteIds += $id
            }
        }
        $remoteIds = @($remoteIds | Sort-Object -Unique)
        if ($remoteIds.Count -eq 0) {
            throw 'The Transfer models endpoint returned no GPT text models.'
        }

        $existingBySlug = @{}
        if (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf) {
            $existing = Get-Content -Raw -LiteralPath $modelCatalogPath |
                ConvertFrom-Json
            foreach ($entry in @($existing.models)) {
                $existingBySlug[[string]$entry.slug] = $entry
            }
        }

        $models = @()
        $priority = 0
        foreach ($slug in $remoteIds) {
            if ($existingBySlug.ContainsKey($slug)) {
                $entry = $existingBySlug[$slug]
                $imageCapable = $slug -in @(
                    'gpt-5.6-sol',
                    'gpt-5.6-luna',
                    'gpt-5.6-terra',
                    'gpt-6-sol',
                    'gpt-6-luna',
                    'gpt-6-astra'
                )
                # Keep every retained entry schema-valid. Older catalogs stored
                # a bare "text" string here, and Codex rejects the whole catalog
                # because input_modalities must be a sequence.
                $entry.input_modalities = if ($imageCapable) {
                    @('text', 'image')
                }
                else {
                    @('text')
                }
                $entry.supports_image_detail_original = $imageCapable
                $models += $entry
            }
            else {
                $models += New-GenericTransferModelEntry -Slug $slug -Priority $priority
            }
            $priority++
        }
        $catalogObject = [ordered]@{ models = $models }
        $updatedText = $catalogObject | ConvertTo-Json -Depth 20
        # Windows PowerShell 5.1 ConvertTo-Json collapses a single-element array
        # into a scalar, so input_modalities = @('text') would be written as
        # "text" and Codex would reject the catalog ("expected a sequence").
        # Force the field back to a JSON sequence in the serialized text.
        $updatedText = [regex]::Replace(
            $updatedText,
            '("input_modalities"\s*:\s*)"([^"]*)"',
            '$1[ "$2" ]'
        )
        $oldText = ''
        if (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf) {
            $oldText = [IO.File]::ReadAllText($modelCatalogPath, [Text.Encoding]::UTF8)
        }
        if ($oldText.Trim() -eq $updatedText.Trim()) {
            return [ordered]@{
                Status = 'UNCHANGED'
                ModelCount = $remoteIds.Count
                Models = $remoteIds
                CatalogPath = $modelCatalogPath
            }
        }

        $backupDirectory = Join-Path $profileRoot (
            'backups\model-catalog\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        )
        $backupPath = Join-Path $backupDirectory 'models.json'
        New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
        $temporaryPath = Join-Path $codexHome (
            'models.json.refresh-' + [Guid]::NewGuid().ToString('N') + '.tmp'
        )
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, $updatedText, $utf8NoBom)
        try {
            if (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf) {
                [IO.File]::Replace($temporaryPath, $modelCatalogPath, $backupPath, $true)
            }
            else {
                Move-Item -LiteralPath $temporaryPath -Destination $modelCatalogPath
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        return [ordered]@{
            Status = 'UPDATED'
            ModelCount = $remoteIds.Count
            Models = $remoteIds
            CatalogPath = $modelCatalogPath
            BackupPath = $backupPath
        }
    }
    catch {
        if ($Strict) { throw }
        return [ordered]@{
            Status = 'REMOTE_UNAVAILABLE'
            ModelCount = 0
            Models = @()
            CatalogPath = $modelCatalogPath
            Error = $_.Exception.Message
        }
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

    if (-not $ValidateOnly) {
        Sync-CodexActiveCredential `
            -Provider 'Transfer' `
            -LauncherSettings $launcherSettings `
            -InstallRoot $installRoot `
            -TargetPath $authPath | Out-Null
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
            TransferMode = 'shared (web-selected Pro/Legacy)'
            ModelOverride = $(if ($Model) { $Model } else { '(preserve configured model)' })
            CurrentModel = $modelLine.Groups[1].Value
            CurrentProvider = $profileSettings.Provider
            CurrentBaseUrl = $profileSettings.BaseUrl
            CurrentWireApi = $profileSettings.WireApi
            RequiresOpenAIAuth = $profileSettings.RequiresOpenAIAuth
            AuthenticationMode = $profileSettings.AuthMode
            ProfileStrategy = $profileSettings.ProfileStrategy
            ModelCatalogPath = $profileSettings.CatalogPath
            ServerSideModeSwitch = $true
            CurrentReasoningEffort = $currentEffort
            ProfileRoot = $profileRoot
            TransferCodexHome = $codexHome
            ElectronData = $electronData
            AuthFilePresent = (Test-Path -LiteralPath $authPath)
        }
        return
    }

    if ($RefreshModels) {
        Sync-TransferModelCatalog -Strict | ConvertTo-Json -Depth 8
        return
    }

    $catalogSync = Sync-TransferModelCatalog

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely, then open the shortcut again to switch models.'
        exit 2
    }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null

    $profileSettings = Read-TransferProfileConfiguration
    Set-TransferModel -RequestedModel $Model

    Assert-TransferAuthentication

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
}
catch {
    if ($RefreshModels) {
        Write-Error $_.Exception.ToString()
        exit 1
    }
    Show-CodexMessage $_.Exception.Message 'Codex - OpenAI Transfer launch error'
    exit 1
}
