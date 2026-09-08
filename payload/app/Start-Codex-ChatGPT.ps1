[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidPath = Join-Path $installRoot 'bridge.pid'
$settingsPath = Join-Path $installRoot 'launcher.settings.json'

function Show-CodexMessage {
    param(
        [string]$Message,
        [string]$Title = 'Codex - ChatGPT'
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

try {
    $appExe = Resolve-CodexDesktopExecutable
    if ($ValidateOnly) {
        [ordered]@{
            Status = 'OK'
            AppExecutable = $appExe
            CodexHome = (Join-Path $env:USERPROFILE '.codex')
            ElectronData = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex')
            BridgePidFile = $pidPath
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit it completely before switching modes.'
        exit 2
    }

    if (Test-Path -LiteralPath $pidPath) {
        $savedPid = 0
        if ([int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$savedPid)) {
            $savedProcess = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($savedProcess -and $savedProcess.ProcessName -eq 'moonbridge') {
                Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $appExe
    $startInfo.WorkingDirectory = Split-Path -Parent $appExe
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = Join-Path $env:USERPROFILE '.codex'
    $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] =
        Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    $appProcess = [System.Diagnostics.Process]::Start($startInfo)

    if (-not $appProcess) {
        throw 'Codex did not start.'
    }
}
catch {
    Show-CodexMessage $_.Exception.Message 'Codex - ChatGPT launch error'
    exit 1
}
