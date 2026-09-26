[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $installRoot 'launcher.settings.json'
$packageLaunchScript = Join-Path $installRoot 'Codex-PackageLaunch.ps1'
if (-not (Test-Path -LiteralPath $packageLaunchScript -PathType Leaf)) {
    throw "Codex package launch helper is missing: $packageLaunchScript"
}
. $packageLaunchScript

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
        }
        return
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Show-CodexMessage 'Codex is already open. Quit it completely before switching modes.'
        exit 2
    }

    $codexHome = Join-Path $env:USERPROFILE '.codex'
    $electronData = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'

    # Current Codex Store builds refuse to run without MSIX package identity,
    # so activate the app inside its package instead of starting ChatGPT.exe
    # as a plain file. The helper also establishes CODEX_HOME for the child.
    $null = Start-CodexDesktopInPackage `
        -CodexHome $codexHome `
        -ElectronData $electronData `
        -WrapperDirectory (Join-Path $installRoot 'runtime') `
        -WrapperName 'launch-chatgpt.cmd'
}
catch {
    Show-CodexMessage $_.Exception.Message 'Codex - ChatGPT launch error'
    exit 1
}
