[CmdletBinding()]
param(
    [string]$EnvironmentRoot = '',
    [string]$PythonPath = '',
    [switch]$Upgrade
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$localQwenRoot = Split-Path -Parent $scriptRoot
if ([string]::IsNullOrWhiteSpace($EnvironmentRoot)) {
    $EnvironmentRoot = Join-Path $localQwenRoot 'web-search-env'
}
$EnvironmentRoot = [IO.Path]::GetFullPath($EnvironmentRoot)

function Resolve-Python {
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $candidate = [IO.Path]::GetFullPath($PreferredPath)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Python executable was not found: $candidate"
        }
        return $candidate
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:ProgramFiles 'Python311\python.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return [IO.Path]::GetFullPath($command.Source)
    }
    throw 'Python 3.11 or newer was not found.'
}

$python = Resolve-Python -PreferredPath $PythonPath
$venvPython = Join-Path $EnvironmentRoot 'Scripts\python.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EnvironmentRoot) | Out-Null

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    & $python -m venv $EnvironmentRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Python could not create the web-search environment (exit $LASTEXITCODE)."
    }
}

$packages = @('mcp==1.26.0', 'ollama==0.6.2')
$pipArguments = @('-m', 'pip', 'install')
if ($Upgrade) { $pipArguments += '--upgrade' }
$pipArguments += $packages
& $venvPython @pipArguments
if ($LASTEXITCODE -ne 0) {
    throw "Python could not install the Ollama web-search dependencies (exit $LASTEXITCODE)."
}

$probe = & $venvPython -c 'import mcp, ollama; print("mcp=" + getattr(mcp, "__version__", "installed")); print("ollama=" + getattr(ollama, "__version__", "installed"))'
if ($LASTEXITCODE -ne 0) {
    throw 'The Ollama web-search Python imports did not pass.'
}

[ordered]@{
    Status = 'OK'
    Python = $python
    Environment = $EnvironmentRoot
    PythonExecutable = $venvPython
    Packages = $packages
    Probe = @($probe)
    McpScript = (Join-Path $scriptRoot 'ollama-web-search-mcp.py')
} | ConvertTo-Json -Depth 5
