Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Current Codex Store/MSIX builds refuse to run when their executable is started
# as a plain file: the process gets no package identity and the app aborts with
# "the process has no package identity" (Windows error 15700). The executable
# must be activated inside the package context instead.
#
# Setting CODEX_HOME in the calling process is also not enough, because package
# activation does not carry this process's environment into the app. The profile
# paths therefore have to be established in a small wrapper that runs inside the
# package context, which is what this helper generates.

function Get-CodexDesktopPackage {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'The installed Codex desktop package (OpenAI.Codex) could not be located.'
    }
    return $package
}

function Resolve-CodexDesktopApplication {
    $package = Get-CodexDesktopPackage
    $appId = 'App'
    $appExe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
        throw "ChatGPT.exe was not found in the installed Codex package: $appExe"
    }
    return [ordered]@{
        Package = $package
        PackageFamilyName = $package.PackageFamilyName
        AppId = $appId
        Application = [IO.Path]::GetFullPath($appExe)
    }
}

function Write-CodexLaunchWrapper {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    # Keep the wrapper free of non-ASCII so it survives any console code page.
    # The profile paths arrive as command-line arguments from the package
    # activation call instead of being embedded here.
    $lines = @(
        '@echo off'
        'set "CODEX_HOME=%~1"'
        'set "CODEX_ELECTRON_USER_DATA_PATH=%~2"'
        'start "" /b "%~3"'
        ''
    )
    $content = ($lines -join "`r`n")
    $encoding = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($Path, $content, $encoding)
}

function Start-CodexDesktopInPackage {
    param(
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$ElectronData,
        [Parameter(Mandatory = $true)][string]$WrapperDirectory,
        [string]$WrapperName = 'launch-codex-profile.cmd'
    )

    $launchCommand = Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue
    if (-not $launchCommand) {
        throw 'Invoke-CommandInDesktopPackage is unavailable. The Appx PowerShell module is required to start Codex with package identity.'
    }

    $resolved = Resolve-CodexDesktopApplication
    $codexHomePath = [IO.Path]::GetFullPath($CodexHome)
    $electronDataPath = [IO.Path]::GetFullPath($ElectronData)

    $wrapperPath = Join-Path ([IO.Path]::GetFullPath($WrapperDirectory)) $WrapperName
    Write-CodexLaunchWrapper -Path $wrapperPath

    # A batch file whose path is quoted needs the doubled-quote form so that
    # cmd.exe also accepts wrapper directories containing spaces.
    $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $arguments = '/d /c ""' + $wrapperPath + '" "' + $codexHomePath +
        '" "' + $electronDataPath + '" "' + $resolved.Application + '""'

    Invoke-CommandInDesktopPackage `
        -PackageFamilyName $resolved.PackageFamilyName `
        -AppId $resolved.AppId `
        -Command $commandInterpreter `
        -Args $arguments `
        -PreventBreakaway | Out-Null

    return [ordered]@{
        PackageFullName = $resolved.Package.PackageFullName
        PackageFamilyName = $resolved.PackageFamilyName
        AppId = $resolved.AppId
        Application = $resolved.Application
        Wrapper = $wrapperPath
        CodexHome = $codexHomePath
        ElectronData = $electronDataPath
    }
}
