[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $scriptRoot 'ollama-server.pid.json'

if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    Write-Output 'No Ollama server owned by the Local Qwen launcher was recorded.'
    exit 0
}

$record = Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json
$process = Get-CimInstance Win32_Process `
    -Filter "ProcessId = $($record.process_id)" `
    -ErrorAction SilentlyContinue
if (
    $process -and
    $process.Name -eq 'ollama.exe' -and
    $process.CommandLine -match '(?i)ollama\.exe.*\bserve\b' -and
    [IO.Path]::GetFullPath($process.ExecutablePath) -eq [IO.Path]::GetFullPath([string]$record.executable)
) {
    Stop-Process -Id ([int]$record.process_id) -Force
    Write-Output "Stopped owned Ollama server PID $($record.process_id)."
}
else {
    Write-Output 'Recorded Ollama process is no longer the same owned server; it was not stopped.'
}

$ollamaDirectory = Split-Path -Parent ([IO.Path]::GetFullPath([string]$record.executable))
$children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -eq 'llama-server.exe' -and
        $_.ParentProcessId -eq [int]$record.process_id -and
        $_.ExecutablePath -and
        ([IO.Path]::GetFullPath([string]$_.ExecutablePath)).StartsWith(
            $ollamaDirectory,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
foreach ($child in @($children)) {
    Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
    Write-Output "Stopped owned Ollama runner PID $($child.ProcessId)."
}

Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
