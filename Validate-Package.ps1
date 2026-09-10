[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hasher.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes) -replace '-', '')
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

$requiredFiles = @(
    'AGENTS.md',
    'START-HERE-FOR-AI.md',
    'README.md',
    'INSTALL-WITH-AI.md',
    'EVOLVE-WITH-AI.md',
    'AI-INSTALLATION-GUIDE.md',
    'Install.cmd',
    'Install-Codex-Provider-Launcher.ps1',
    'Validate-Package.ps1',
    'package-info.json',
    'payload\app\Start-Codex-Chooser.ps1',
    'payload\app\Start-Codex-ChatGPT.ps1',
    'payload\app\Start-Codex-DeepSeek.ps1',
    'payload\app\Start-Codex-OpenAI-Transfer.ps1',
    'payload\app\Stop-DeepSeek-Bridge.ps1',
    'payload\app\Install-Desktop-Shortcuts.ps1',
    'payload\app\maintenance\history\Repair-DeepSeek-History.ps1',
    'payload\app\maintenance\history\Repair-DeepSeek-HistoryMetadata.py',
    'payload\app\Codex.ico',
    'payload\app\moonbridge.exe',
    'payload\app\MOON-BRIDGE-LICENSE.txt',
    'payload\app\build-info.json',
    'payload\app\README.md',
    'payload\app\AI-MAINTENANCE-GUIDE.md',
    'payload\app\EVOLVE-WITH-AI.md',
    'payload\templates\native-config.template.toml',
    'payload\templates\transfer-shared-config.template.toml',
    'payload\templates\bridge-config.template.yml',
    'payload\templates\bridge-codex-config.template.toml',
    'payload\templates\transfer-pro-config.template.toml',
    'payload\templates\transfer-legacy-config.template.toml',
    'payload\catalogs\bridge-models_catalog.json',
    'payload\catalogs\native-models.json',
    'configuration\260909\README.md',
    'configuration\260909\native-config.example.toml'
)

$errors = New-Object System.Collections.Generic.List[string]
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $packageRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $errors.Add("Missing required file: $relativePath")
    }
}

# The validator is also run from a development checkout. Git metadata belongs
# to the repository, not to the distributable package content being checked.
$gitMetadataRoot = (Join-Path $packageRoot '.git').TrimEnd('\') + '\'
$packageFiles = @(
    Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.FullName.StartsWith(
                $gitMetadataRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
)
$packageDirectories = @(
    Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -Directory `
        -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.FullName.StartsWith(
                $gitMetadataRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
)

$forbiddenNames = @(
    'auth.json',
    'config.yml',
    'bridge.pid',
    'history.jsonl'
)
foreach ($name in $forbiddenNames) {
    foreach ($file in @($packageFiles | Where-Object { $_.Name -eq $name })) {
        $relative = $file.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Live or credential-bearing file is bundled: $relative")
    }
}

foreach ($directoryName in @(
    'electron-data',
    'sessions',
    'archived_sessions',
    'logs',
    'backups'
)) {
    foreach ($directory in @(
        $packageDirectories | Where-Object { $_.Name -eq $directoryName }
    )) {
        $relative = $directory.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Runtime directory is bundled: $relative")
    }
}

foreach ($file in $packageFiles) {
    if ($file.Extension -match '^\.(db|sqlite|sqlite3|log)$' -or
        $file.Name -match '\.sqlite-(shm|wal)$') {
        $relative = $file.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Runtime data file is bundled: $relative")
    }
}

$textExtensions = @(
    '.ps1', '.psm1', '.cmd', '.md', '.json', '.toml', '.yml', '.yaml',
    '.py', '.txt'
)
$secretPatterns = [ordered]@{
    'API-key-shaped value' = '(?i)\bsk-[A-Za-z0-9_-]{16,}\b'
    'Bearer token' = '(?i)Bearer\s+[A-Za-z0-9._~+/=-]{16,}'
    'JSON API key value' = '(?i)"OPENAI_API_KEY"\s*:\s*"(?!__|<)[^"\r\n]{8,}"'
    'TOML bearer value' = '(?i)experimental_bearer_token\s*=\s*"(?!__|<)[^"\r\n]{8,}"'
    'YAML API key value' = '(?i)^\s*api_key\s*:\s*"(?!__|<)[^"\r\n]{8,}"'
    'YAML auth token value' = '(?i)^\s*auth_token\s*:\s*"(?!__|<)[^"\r\n]{8,}"'
}

$secretMatches = 0
foreach ($file in $packageFiles) {
    if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) {
        continue
    }
    $content = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    foreach ($entry in $secretPatterns.GetEnumerator()) {
        if ([regex]::IsMatch($content, $entry.Value, 'Multiline')) {
            $relative = $file.FullName.Substring($packageRoot.Length).TrimStart('\')
            $errors.Add("$($entry.Key) found in package text: $relative")
            $secretMatches++
        }
    }
}

$parseErrorCount = 0
foreach ($scriptFile in @($packageFiles | Where-Object { $_.Extension -eq '.ps1' })) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        $relative = $scriptFile.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add(
            "PowerShell parse error in ${relative}: $($parseError.Message)"
        )
        $parseErrorCount++
    }
}

foreach ($jsonFile in @($packageFiles | Where-Object { $_.Extension -eq '.json' })) {
    try {
        $null = Get-Content -Raw -LiteralPath $jsonFile.FullName |
            ConvertFrom-Json
    }
    catch {
        $relative = $jsonFile.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Invalid JSON file: $relative")
    }
}

$nativeCatalogPath = Join-Path $packageRoot 'payload\catalogs\native-models.json'
if (Test-Path -LiteralPath $nativeCatalogPath -PathType Leaf) {
    try {
        $nativeCatalog = Get-Content -Raw -LiteralPath $nativeCatalogPath |
            ConvertFrom-Json
        $nativeSlugs = @(
            $nativeCatalog.models | ForEach-Object { [string]$_.slug }
        )
        foreach ($requiredNativeModel in @(
            'deepseek-v4-pro',
            'deepseek-v4-flash',
            'deepseek-v4-flash-vision-exp'
        )) {
            if ($nativeSlugs -notcontains $requiredNativeModel) {
                $errors.Add(
                    "Native DeepSeek catalog is missing $requiredNativeModel."
                )
            }
        }
        $visionModel = @(
            $nativeCatalog.models |
                Where-Object { $_.slug -eq 'deepseek-v4-flash-vision-exp' }
        )
        if (
            $visionModel.Count -eq 1 -and
            @($visionModel[0].input_modalities) -notcontains 'image'
        ) {
            $errors.Add(
                'Native DeepSeek vision model does not advertise image input.'
            )
        }
    }
    catch {
        $errors.Add('Could not inspect the native DeepSeek model catalog.')
    }
}

$chooserPath = Join-Path $packageRoot 'payload\app\Start-Codex-Chooser.ps1'
if (Test-Path -LiteralPath $chooserPath -PathType Leaf) {
    $chooserText = [IO.File]::ReadAllText($chooserPath, [Text.Encoding]::UTF8)
    foreach ($marker in @(
        'DeepSeekButton',
        'TransferButton',
        'shared profile',
        'Width="700"'
    )) {
        if ($chooserText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
            $errors.Add("Vibe launcher UI marker is missing: $marker")
        }
    }
}

$buildInfoPath = Join-Path $packageRoot 'payload\app\build-info.json'
$bridgeExePath = Join-Path $packageRoot 'payload\app\moonbridge.exe'
$sourceArchives = @(
    Get-ChildItem -LiteralPath (Join-Path $packageRoot 'third-party\source') `
        -File `
        -Filter '*.zip' `
        -ErrorAction SilentlyContinue
)
if (
    (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) -and
    (Test-Path -LiteralPath $bridgeExePath -PathType Leaf)
) {
    try {
        $buildInfo = Get-Content -Raw -LiteralPath $buildInfoPath |
            ConvertFrom-Json
        $actualExeHash = (Get-Sha256Hex `
            -Path $bridgeExePath).ToLowerInvariant()
        if ($actualExeHash -ne [string]$buildInfo.moonbridge_exe_sha256) {
            $errors.Add('moonbridge.exe does not match build-info.json.')
        }
        if ($sourceArchives.Count -ne 1) {
            $errors.Add('Expected exactly one pinned Moon Bridge source archive.')
        }
        else {
            $actualSourceHash = (Get-Sha256Hex `
                -Path $sourceArchives[0].FullName).ToLowerInvariant()
            if ($actualSourceHash -ne [string]$buildInfo.source_archive_sha256) {
                $errors.Add('Moon Bridge source archive does not match build-info.json.')
            }
        }
    }
    catch {
        $errors.Add('Could not verify Moon Bridge provenance hashes.')
    }
}

$templateChecks = [ordered]@{
    'payload\templates\bridge-config.template.yml' = @(
        '__LOCAL_BRIDGE_TOKEN_JSON__',
        '__DEEPSEEK_API_KEY_JSON__'
    )
    'payload\templates\bridge-codex-config.template.toml' = @(
        '__BRIDGE_CATALOG_PATH_JSON__'
    )
    'payload\templates\native-config.template.toml' = @(
        '__NATIVE_CATALOG_PATH_JSON__',
        '__DEEPSEEK_API_KEY_JSON__'
    )
    'payload\templates\transfer-shared-config.template.toml' = @(
        '__TRANSFER_MODEL_JSON__',
        '__TRANSFER_REASONING_JSON__'
    )
    'payload\templates\transfer-pro-config.template.toml' = @(
        '__TRANSFER_PRO_MODEL_JSON__',
        '__TRANSFER_PRO_REASONING_JSON__'
    )
    'payload\templates\transfer-legacy-config.template.toml' = @(
        '__TRANSFER_LEGACY_MODEL_JSON__',
        '__TRANSFER_LEGACY_REASONING_JSON__',
        '__TRANSFER_LEGACY_ACTOR_JSON__'
    )
}
foreach ($entry in $templateChecks.GetEnumerator()) {
    $templatePath = Join-Path $packageRoot $entry.Key
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        continue
    }
    $content = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    foreach ($placeholder in $entry.Value) {
        $count = [regex]::Matches(
            $content,
            [regex]::Escape($placeholder)
        ).Count
        if ($count -ne 1) {
            $errors.Add(
                "Template placeholder $placeholder occurs $count times in $($entry.Key)."
            )
        }
    }
}

if ($errors.Count -gt 0) {
    $message = "Package validation failed:`r`n - " + ($errors -join "`r`n - ")
    throw $message
}

if (-not $Quiet) {
    Write-Host 'Portable package validation passed.' -ForegroundColor Green
}

[ordered]@{
    Status = 'OK'
    PackageRoot = $packageRoot
    PowerShellFilesParsed = @(
        $packageFiles | Where-Object { $_.Extension -eq '.ps1' }
    ).Count
    JsonFilesParsed = @(
        $packageFiles | Where-Object { $_.Extension -eq '.json' }
    ).Count
    SecretPatternMatches = $secretMatches
    MoonBridgeBinaryVerified = $true
    MoonBridgeSourceVerified = $true
}
