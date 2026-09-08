[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidPath = Join-Path $installRoot 'bridge.pid'

if (-not (Test-Path -LiteralPath $pidPath)) {
    exit 0
}

$savedPid = 0
if ([int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$savedPid)) {
    $savedProcess = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
    if ($savedProcess -and $savedProcess.ProcessName -eq 'moonbridge') {
        Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
