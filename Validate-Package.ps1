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
    'payload\app\Start-Codex-Native-Flash.ps1',
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
    'payload\templates\bridge-config.template.yml',
    'payload\templates\bridge-codex-config.template.toml',
    'payload\templates\native-config.template.toml',
    'payload\templates\transfer-pro-config.template.toml',
    'payload\templates\transfer-legacy-config.template.toml',
    'payload\catalogs\bridge-models_catalog.json',
    'payload\catalogs\native-models.json'
)

$errors = New-Object System.Collections.Generic.List[string]
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $packageRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $errors.Add("Missing required file: $relativePath")
    }
}

$forbiddenNames = @(
    'auth.json',
    'config.yml',
    'bridge.pid',
    'history.jsonl'
)
foreach ($name in $forbiddenNames) {
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot `
        -Recurse `
        -Force `
        -File `
        -Filter $name `
        -ErrorAction SilentlyContinue) {
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
    foreach ($directory in Get-ChildItem -LiteralPath $packageRoot `
        -Recurse `
        -Force `
        -Directory `
        -Filter $directoryName `
        -ErrorAction SilentlyContinue) {
        $relative = $directory.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Runtime directory is bundled: $relative")
    }
}

foreach ($file in Get-ChildItem -LiteralPath $packageRoot `
    -Recurse `
    -Force `
    -File `
    -ErrorAction SilentlyContinue) {
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
foreach ($file in Get-ChildItem -LiteralPath $packageRoot `
    -Recurse `
    -Force `
    -File `
    -ErrorAction SilentlyContinue) {
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
foreach ($scriptFile in Get-ChildItem -LiteralPath $packageRoot `
    -Recurse `
    -Force `
    -File `
    -Filter '*.ps1') {
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

foreach ($jsonFile in Get-ChildItem -LiteralPath $packageRoot `
    -Recurse `
    -Force `
    -File `
    -Filter '*.json') {
    try {
        $null = Get-Content -Raw -LiteralPath $jsonFile.FullName |
            ConvertFrom-Json
    }
    catch {
        $relative = $jsonFile.FullName.Substring($packageRoot.Length).TrimStart('\')
        $errors.Add("Invalid JSON file: $relative")
    }
}

$chooserPath = Join-Path $packageRoot 'payload\app\Start-Codex-Chooser.ps1'
if (Test-Path -LiteralPath $chooserPath -PathType Leaf) {
    $chooserText = [IO.File]::ReadAllText($chooserPath, [Text.Encoding]::UTF8)
    foreach ($marker in @(
        'function Select-OpenAITransferMode',
        'TransferProButton',
        'TransferLegacyButton',
        'Width="500"'
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
        Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter '*.ps1'
    ).Count
    JsonFilesParsed = @(
        Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter '*.json'
    ).Count
    SecretPatternMatches = $secretMatches
    MoonBridgeBinaryVerified = $true
    MoonBridgeSourceVerified = $true
}
