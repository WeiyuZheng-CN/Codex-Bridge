[CmdletBinding()]
param(
    [ValidateSet('deepseek-v4-pro', 'deepseek-v4-flash')]
    [string]$Model = 'deepseek-v4-pro',
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeExe = Join-Path $installRoot 'moonbridge.exe'
$configPath = Join-Path $installRoot 'config.yml'
$codexHome = Join-Path $installRoot 'codex-home'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$electronData = Join-Path $installRoot 'electron-data'
$authPath = Join-Path $codexHome 'auth.json'
$historyDirectory = Join-Path $installRoot 'maintenance\history'
$historyRepair = Join-Path $historyDirectory 'Repair-DeepSeek-History.ps1'
$metadataRepair = Join-Path $historyDirectory 'Repair-DeepSeek-HistoryMetadata.py'
$logDirectory = Join-Path $installRoot 'logs'
$pidPath = Join-Path $installRoot 'bridge.pid'
$bridgeProcess = $null
$settingsPath = Join-Path $installRoot 'launcher.settings.json'

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
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsPath |
                ConvertFrom-Json
            if ($settings.PSObject.Properties['codex_executable']) {
                $configured = [string]$settings.codex_executable
                if (Test-Path -LiteralPath $configured -PathType Leaf) {
                    return [IO.Path]::GetFullPath($configured)
                }
            }
        }
        catch {
            # Fall through to dynamic discovery.
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

function Test-Bridge {
    param([hashtable]$Headers)

    try {
        $null = Invoke-RestMethod `
            -UseBasicParsing `
            -Uri 'http://127.0.0.1:38440/v1/models' `
            -Headers $Headers `
            -TimeoutSec 2
        return $true
    }
    catch {
        return $false
    }
}

function Get-LocalBridgeToken {
    try {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
    }
    catch {
        throw 'The local bridge authentication file is not valid JSON.'
    }

    $localToken = ''
    if ($auth.PSObject.Properties['OPENAI_API_KEY']) {
        $localToken = [string]$auth.OPENAI_API_KEY
    }
    elseif ($auth.PSObject.Properties['openai_api_key']) {
        $localToken = [string]$auth.openai_api_key
    }
    if ([string]::IsNullOrWhiteSpace($localToken)) {
        throw 'The local bridge authentication token is missing.'
    }
    return $localToken
}

function Set-SelectedModel {
    param([string]$SelectedModel)

    $content = [IO.File]::ReadAllText(
        $codexConfigPath,
        [Text.Encoding]::UTF8
    )
    $pattern = '(?m)^model\s*=\s*"[^"]*"\s*\r?$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one top-level model setting in $codexConfigPath."
    }

    $replacement = 'model = "' + $SelectedModel + '"'
    $updated = [regex]::Replace($content, $pattern, $replacement, 1)
    $effortPattern = '(?m)^model_reasoning_effort\s*=\s*"[^"]*"\s*\r?$'
    $effortMatches = [regex]::Matches($updated, $effortPattern)
    if ($effortMatches.Count -ne 1) {
        throw "Expected exactly one reasoning-effort setting in $codexConfigPath."
    }
    $updated = [regex]::Replace(
        $updated,
        $effortPattern,
        'model_reasoning_effort = "high"',
        1
    )
    if ($updated -ceq $content) {
        return
    }

    $backupDirectory = Join-Path $installRoot (
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
        $historyLogPath = Join-Path $logDirectory 'history-repair.log'
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
        $bridgeExe,
        $configPath,
        $authPath,
        $codexConfigPath,
        $historyRepair,
        $metadataRepair
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required setup file is missing: $requiredPath"
        }
    }

    if ($ValidateOnly) {
        $modelLine = [regex]::Match(
            [IO.File]::ReadAllText($codexConfigPath, [Text.Encoding]::UTF8),
            '(?m)^model\s*=\s*"([^"]*)"\s*\r?$'
        )
        if (-not $modelLine.Success) {
            throw 'The DeepSeek model setting could not be read.'
        }
        $effortLine = [regex]::Match(
            [IO.File]::ReadAllText($codexConfigPath, [Text.Encoding]::UTF8),
            '(?m)^model_reasoning_effort\s*=\s*"([^"]*)"\s*\r?$'
        )
        if (-not $effortLine.Success) {
            throw 'The DeepSeek reasoning-effort setting could not be read.'
        }
        $null = Get-LocalBridgeToken
        [ordered]@{
            Status = 'OK'
            RequestedModel = $Model
            CurrentModel = $modelLine.Groups[1].Value
            CurrentReasoningEffort = $effortLine.Groups[1].Value
            LocalAuthPresent = $true
            HistoryRepair = $historyRepair
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit Codex completely, then open the shortcut again to switch models.'
        exit 2
    }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $electronData | Out-Null

    Set-SelectedModel -SelectedModel $Model
    Invoke-HistoryRepair

    $localToken = Get-LocalBridgeToken
    $headers = @{ Authorization = "Bearer $localToken" }

    if (-not (Test-Bridge -Headers $headers)) {
        $quotedConfigPath = '"' + $configPath.Replace('"', '\"') + '"'
        $bridgeProcess = Start-Process `
            -FilePath $bridgeExe `
            -ArgumentList @('-config', $quotedConfigPath) `
            -WorkingDirectory $installRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $logDirectory 'moonbridge.stdout.log') `
            -RedirectStandardError (Join-Path $logDirectory 'moonbridge.stderr.log') `
            -PassThru
        [IO.File]::WriteAllText($pidPath, [string]$bridgeProcess.Id)

        $ready = $false
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            Start-Sleep -Milliseconds 250
            if ($bridgeProcess.HasExited) {
                break
            }
            if (Test-Bridge -Headers $headers) {
                $ready = $true
                break
            }
        }
        if (-not $ready) {
            if ($bridgeProcess -and -not $bridgeProcess.HasExited) {
                Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $pidPath) {
                $recordedPid = (Get-Content -Raw -LiteralPath $pidPath).Trim()
                if ($recordedPid -eq [string]$bridgeProcess.Id) {
                    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
                }
            }
            throw 'The local DeepSeek bridge did not become ready. See the logs folder for details.'
        }
    }

    $appExe = Resolve-CodexDesktopExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] =
        $electronData
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $appProcess) {
        throw 'Codex did not start.'
    }

    $appProcess.WaitForExit()
    Invoke-HistoryRepair
}
catch {
    Show-CodexMessage $_.Exception.Message 'Codex - DeepSeek setup error'
    exit 1
}
