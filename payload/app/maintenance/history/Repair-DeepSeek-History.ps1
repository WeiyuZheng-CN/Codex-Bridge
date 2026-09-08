[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome = '',
    [switch]$ValidateOnly,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Join-Path $installRoot 'codex-home'
}
$codexExe = Join-Path $CodexHome '.sandbox-bin\codex.exe'
$metadataRepair = Join-Path $PSScriptRoot 'Repair-DeepSeek-HistoryMetadata.py'
$sessionRoots = @(
    (Join-Path $CodexHome 'sessions'),
    (Join-Path $CodexHome 'archived_sessions')
)

function Get-ModelLabel {
    param([string]$Model)

    switch ($Model) {
        'deepseek-v4-flash' { return 'DeepSeek V4 Flash' }
        'deepseek-v4-pro' { return 'DeepSeek V4 Pro' }
        'moonbridge' { return 'DeepSeek V4 Pro' }
        default { return 'DeepSeek' }
    }
}

function Compress-TitleText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $candidate = $Text
    $requestMarker = [regex]::Match(
        $candidate,
        '(?is)##\s+My request for Codex:\s*(.*)$'
    )
    if ($requestMarker.Success) {
        $candidate = $requestMarker.Groups[1].Value
    }

    $candidate = [regex]::Replace(
        $candidate,
        '(?is)<(?:recommended_plugins|environment_context|in-app-browser-context)\b.*?</(?:recommended_plugins|environment_context|in-app-browser-context)>',
        ' '
    )
    $candidate = [regex]::Replace(
        $candidate,
        '(?im)^\s*#\s*Files mentioned by the user:\s*$',
        ' '
    )
    $candidate = [regex]::Replace($candidate, '\s+', ' ').Trim()

    if ($candidate -match '^[-#]*\s*$') {
        return ''
    }
    return $candidate
}

function Limit-Title {
    param(
        [string]$Text,
        [int]$MaximumLength = 92
    )

    if ($Text.Length -le $MaximumLength) {
        return $Text
    }

    $short = $Text.Substring(0, $MaximumLength - 3).TrimEnd()
    $lastSpace = $short.LastIndexOf(' ')
    if ($lastSpace -ge 48) {
        $short = $short.Substring(0, $lastSpace)
    }
    return "$short..."
}

function Get-RolloutCandidate {
    param([string]$Path)

    $reader = New-Object System.IO.StreamReader(
        $Path,
        [System.Text.Encoding]::UTF8,
        $true
    )
    try {
        $metadata = $null
        $model = ''
        $userMessage = ''

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ($record.type -eq 'session_meta') {
                $metadata = $record.payload
                continue
            }

            if (
                $record.type -eq 'turn_context' -and
                $record.payload.PSObject.Properties['model']
            ) {
                $model = [string]$record.payload.model
                continue
            }

            if (
                $record.type -eq 'event_msg' -and
                $record.payload.type -eq 'user_message'
            ) {
                $userMessage = [string]$record.payload.message
                break
            }
        }

        if (-not $metadata) {
            return $null
        }
        if ([string]$metadata.model_provider -ne 'moonbridge') {
            return $null
        }
        if ([string]$metadata.source -notin @('vscode', 'appServer')) {
            return $null
        }
        if ([string]::IsNullOrWhiteSpace([string]$metadata.id)) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($model)) {
            $model = 'deepseek-v4-pro'
        }
        $label = Get-ModelLabel -Model $model
        $summary = Compress-TitleText -Text $userMessage
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $workspaceName = Split-Path -Leaf ([string]$metadata.cwd)
            if ([string]::IsNullOrWhiteSpace($workspaceName)) {
                $workspaceName = 'coding task'
            }
            $timestamp = ''
            if (
                $metadata.PSObject.Properties['timestamp'] -and
                -not [string]::IsNullOrWhiteSpace([string]$metadata.timestamp)
            ) {
                try {
                    $parsed = [DateTimeOffset]::Parse(
                        [string]$metadata.timestamp
                    )
                    $timestamp = $parsed.ToLocalTime().ToString(
                        'yyyy-MM-dd HH:mm'
                    )
                }
                catch {
                    $timestamp = ''
                }
            }
            if ($timestamp) {
                $summary = "$workspaceName ($timestamp)"
            }
            else {
                $summary = $workspaceName
            }
        }

        return [pscustomobject]@{
            Id = [string]$metadata.id
            Path = $Path
            Title = Limit-Title -Text "${label}: $summary"
            Archived = $Path.StartsWith(
                (Join-Path $CodexHome 'archived_sessions'),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Get-AllCandidates {
    $files = @()
    foreach ($root in $sessionRoots) {
        if (Test-Path -LiteralPath $root) {
            $files += Get-ChildItem `
                -LiteralPath $root `
                -Filter 'rollout-*.jsonl' `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue
        }
    }

    $byId = @{}
    foreach ($file in $files) {
        $candidate = Get-RolloutCandidate -Path $file.FullName
        if ($candidate) {
            $byId[$candidate.Id] = $candidate
        }
    }
    return @($byId.Values)
}

function Resolve-PythonExecutable {
    $knownPython = Join-Path $env:LOCALAPPDATA (
        'Python\pythoncore-3.14-64\python.exe'
    )
    if (Test-Path -LiteralPath $knownPython) {
        return $knownPython
    }

    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pythonCommand -and (Test-Path -LiteralPath $pythonCommand.Source)) {
        return $pythonCommand.Source
    }
    throw 'Python is required for the narrow SQLite history-metadata repair.'
}

function Start-AppServer {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $codexExe
    $startInfo.Arguments = 'app-server --listen stdio://'
    $startInfo.WorkingDirectory = $CodexHome
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome

    $server = New-Object System.Diagnostics.Process
    $server.StartInfo = $startInfo
    $null = $server.Start()
    return $server
}

function ConvertTo-SafeProcessError {
    param(
        [string]$Text,
        [int]$MaximumLength = 1000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return '(no diagnostic text)'
    }
    $safe = [regex]::Replace(
        $Text,
        '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}',
        '$1<redacted>'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\bsk-[A-Za-z0-9_-]{12,}',
        '<redacted-api-key>'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)((?:api[_-]?key|auth[_-]?token)\s*[:=]\s*["'']?)[^\s,"'']{8,}',
        '$1<redacted>'
    )
    $safe = [regex]::Replace($safe, '[\r\n]+', ' ').Trim()
    if ($safe.Length -gt $MaximumLength) {
        return $safe.Substring(0, $MaximumLength) + '... [truncated]'
    }
    return $safe
}

function Send-AppServerMessage {
    param(
        [System.Diagnostics.Process]$Server,
        [hashtable]$Message
    )

    $json = $Message | ConvertTo-Json -Depth 20 -Compress
    $Server.StandardInput.WriteLine($json)
    $Server.StandardInput.Flush()
}

function Read-AppServerResponse {
    param(
        [System.Diagnostics.Process]$Server,
        [int]$Id,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $readTask = $Server.StandardOutput.ReadLineAsync()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $readTask.Wait(250)) {
            if ($Server.HasExited) {
                $stderr = $Server.StandardError.ReadToEnd()
                $safeError = ConvertTo-SafeProcessError -Text $stderr
                throw "Codex app-server exited with code $($Server.ExitCode). $safeError"
            }
            continue
        }

        $line = $readTask.Result
        if ($null -eq $line) {
            $stderr = $Server.StandardError.ReadToEnd()
            $safeError = ConvertTo-SafeProcessError -Text $stderr
            throw "Codex app-server closed its output stream. $safeError"
        }
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try {
                $message = $line | ConvertFrom-Json
            }
            catch {
                throw (
                    "Codex app-server returned invalid JSON while waiting " +
                    "for request $Id (response length: $($line.Length))."
                )
            }
            if ($message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
                if ($message.PSObject.Properties['error']) {
                    throw "App-server request $Id failed: $($message.error | ConvertTo-Json -Compress -Depth 10)"
                }
                return $message
            }
        }
        $readTask = $Server.StandardOutput.ReadLineAsync()
    }
    throw "Timed out waiting for app-server response $Id."
}

function Stop-AppServer {
    param([System.Diagnostics.Process]$Server)

    try {
        $Server.StandardInput.Close()
    }
    catch {
    }
    if (-not $Server.WaitForExit(3000)) {
        $Server.Kill()
        $Server.WaitForExit()
    }
    $Server.Dispose()
}

function Initialize-AppServer {
    param(
        [System.Diagnostics.Process]$Server,
        [int]$Id
    )

    Send-AppServerMessage -Server $Server -Message @{
        id = $Id
        method = 'initialize'
        params = @{
            clientInfo = @{
                name = 'deepseek-history-repair'
                version = '1.1.0'
            }
        }
    }
    $null = Read-AppServerResponse -Server $Server -Id $Id
    Send-AppServerMessage -Server $Server -Message @{ method = 'initialized' }
}

function Request-ThreadList {
    param(
        [System.Diagnostics.Process]$Server,
        [int]$Id,
        [bool]$Archived
    )

    Send-AppServerMessage -Server $Server -Message @{
        id = $Id
        method = 'thread/list'
        params = @{
            archived = $Archived
            limit = 100
            modelProviders = @('moonbridge')
            sourceKinds = @(
                'cli'
                'vscode'
                'exec'
                'appServer'
                'subAgent'
                'subAgentReview'
                'subAgentCompact'
                'subAgentThreadSpawn'
                'subAgentOther'
                'unknown'
            )
            useStateDbOnly = $true
        }
    }
    return Read-AppServerResponse -Server $Server -Id $Id
}

foreach ($requiredPath in @($codexExe, $metadataRepair)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "History repair dependency not found: $requiredPath"
    }
}

$candidates = @(Get-AllCandidates)
if ($ValidateOnly) {
    $python = Resolve-PythonExecutable
    [ordered]@{
        Status = 'OK'
        CodexHome = $CodexHome
        RolloutCandidates = $candidates.Count
        Python = $python
        MetadataRepair = $metadataRepair
    }
    return
}

$server = $null
$repaired = @()
try {
    $server = Start-AppServer
    Initialize-AppServer -Server $server -Id 1

    $visibleIds = @{}
    foreach ($response in @(
        (Request-ThreadList -Server $server -Id 2 -Archived $false),
        (Request-ThreadList -Server $server -Id 3 -Archived $true)
    )) {
        foreach ($thread in @($response.result.data)) {
            $visibleIds[[string]$thread.id] = $true
        }
    }

    $requestId = 100
    $readRequestId = 20
    foreach ($candidate in $candidates) {
        if ($candidate.Archived) {
            continue
        }
        if ($visibleIds.ContainsKey($candidate.Id)) {
            continue
        }

        Send-AppServerMessage -Server $server -Message @{
            id = $readRequestId
            method = 'thread/read'
            params = @{
                threadId = $candidate.Id
                includeTurns = $false
            }
        }
        $threadRead = Read-AppServerResponse `
            -Server $server `
            -Id $readRequestId
        $readRequestId++
        if (
            $threadRead.result.thread -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$threadRead.result.thread.name
            )
        ) {
            continue
        }

        if (-not $PSCmdlet.ShouldProcess(
            $candidate.Id,
            "Set task title to '$($candidate.Title)'"
        )) {
            continue
        }

        Send-AppServerMessage -Server $server -Message @{
            id = $requestId
            method = 'thread/name/set'
            params = @{
                threadId = $candidate.Id
                name = $candidate.Title
            }
        }
        $null = Read-AppServerResponse -Server $server -Id $requestId
        $repaired += $candidate
        $requestId++
    }

    Stop-AppServer -Server $server
    $server = $null

    $python = Resolve-PythonExecutable
    $applyMetadata = $PSCmdlet.ShouldProcess(
        (Join-Path $CodexHome 'state_5.sqlite'),
        'Repair blank DeepSeek task-list metadata'
    )
    if ($applyMetadata) {
        $metadataOutput = & $python $metadataRepair `
            --codex-home $CodexHome `
            --apply
    }
    else {
        $metadataOutput = & $python $metadataRepair `
            --codex-home $CodexHome
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Metadata repair failed with exit code $LASTEXITCODE."
    }
    $metadataResult = $metadataOutput | ConvertFrom-Json
    if ($metadataResult.status -ne 'ok') {
        throw 'Metadata repair did not return an OK status.'
    }

    if (-not $applyMetadata) {
        if (-not $Quiet) {
            [ordered]@{
                Status = 'DRY_RUN'
                RolloutCandidates = $candidates.Count
                Repaired = $repaired.Count
                MetadataCandidates = [int]$metadataResult.candidate_count
                MetadataIntegrity = [string]$metadataResult.integrity
            }
        }
        return
    }

    $server = Start-AppServer
    Initialize-AppServer -Server $server -Id 800
    $verifiedIds = @{}
    foreach ($response in @(
        (Request-ThreadList -Server $server -Id 900 -Archived $false),
        (Request-ThreadList -Server $server -Id 901 -Archived $true)
    )) {
        foreach ($thread in @($response.result.data)) {
            $verifiedIds[[string]$thread.id] = $true
        }
    }
    foreach ($candidate in $candidates) {
        if (-not $verifiedIds.ContainsKey($candidate.Id)) {
            throw "Task $($candidate.Id) is still absent from the state-backed task list."
        }
    }

    if (-not $Quiet) {
        [ordered]@{
            Status = 'OK'
            RolloutCandidates = $candidates.Count
            Repaired = $repaired.Count
            RepairedTasks = @(
                $repaired | ForEach-Object {
                    [ordered]@{
                        Id = $_.Id
                        Title = $_.Title
                    }
                }
            )
            MetadataCandidates = [int]$metadataResult.candidate_count
            MetadataIntegrity = [string]$metadataResult.integrity
            Verified = $true
        }
    }
}
finally {
    if ($server) {
        Stop-AppServer -Server $server
    }
}
