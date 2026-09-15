[CmdletBinding()]
param(
    [string]$DesktopPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
}
else {
    $desktop = [IO.Path]::GetFullPath($DesktopPath)
}
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw 'The Desktop folder could not be resolved.'
}
New-Item -ItemType Directory -Force -Path $desktop | Out-Null

$powerShellExe = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)
$iconPath = Join-Path $installRoot 'Codex.ico'
$chooserScript = Join-Path $installRoot 'Start-Codex-Chooser.ps1'

foreach ($requiredPath in @($iconPath, $chooserScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required shortcut file is missing: $requiredPath"
    }
}

$shell = New-Object -ComObject WScript.Shell
$shortcutNames = @(
    'Codex.lnk',
    'Codex - ChatGPT.lnk',
    'Codex - DeepSeek.lnk'
)

# Apply the proper Codex icon to the two legacy provider shortcuts before
# archiving them. This preserves a clean, recoverable copy of the old layout.
foreach ($name in @('Codex - ChatGPT.lnk', 'Codex - DeepSeek.lnk')) {
    $legacyPath = Join-Path $desktop $name
    if (Test-Path -LiteralPath $legacyPath) {
        $legacyShortcut = $shell.CreateShortcut($legacyPath)
        $legacyShortcut.IconLocation = "$iconPath,0"
        $legacyShortcut.Save()
    }
}

$existingShortcuts = @(
    $shortcutNames |
        ForEach-Object { Join-Path $desktop $_ } |
        Where-Object { Test-Path -LiteralPath $_ }
)

$backupDirectory = $null
if ($existingShortcuts.Count -gt 0) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupDirectory = Join-Path $installRoot "backups\desktop-shortcuts\$stamp"
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null

    foreach ($shortcutPath in $existingShortcuts) {
        $backupPath = Join-Path $backupDirectory (Split-Path -Leaf $shortcutPath)
        if ((Split-Path -Leaf $shortcutPath) -eq 'Codex.lnk') {
            Copy-Item -LiteralPath $shortcutPath -Destination $backupPath
        }
        else {
            Move-Item -LiteralPath $shortcutPath -Destination $backupPath
        }
    }
}

$unifiedPath = Join-Path $desktop 'Codex.lnk'
$shortcut = $shell.CreateShortcut($unifiedPath)
$shortcut.TargetPath = $powerShellExe
$shortcut.Arguments =
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$chooserScript`""
$shortcut.WorkingDirectory = $installRoot
$shortcut.IconLocation = "$iconPath,0"
$shortcut.Description = 'Choose ChatGPT, DeepSeek, or OpenAI Transfer, then open Codex'
$shortcut.Save()

[ordered]@{
    UnifiedShortcut = $unifiedPath
    Icon = $iconPath
    BackupDirectory = $backupDirectory
    LegacyShortcutsRemovedFromDesktop = $true
}
