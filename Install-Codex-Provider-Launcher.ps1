[CmdletBinding()]
param(
    [string[]]$Modes = @(),
    [string]$DeepSeekKeyFile = '',
    [Alias('OpenAITransferKeyFile')]
    [string]$TransferKeyFile = '',
    [string]$TransferProKeyFile = '',
    [string]$TransferLegacyKeyFile = '',
    [string]$TransferLegacyActorFile = '',
    [string]$CodexExecutablePath = '',
    [string]$InstallRoot = '',
    [string]$ProfilesRoot = '',
    [string]$DesktopPath = '',
    [Alias('TransferModel')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$TransferProModel = 'gpt-5.6-luna',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$TransferLegacyModel = 'gpt-5.6-terra',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$TransferProReasoningEffort = 'medium',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$TransferLegacyReasoningEffort = 'medium',
    [switch]$NoDesktopShortcut,
    [switch]$NoFriendlyLink,
    [switch]$TransferLegacyWithoutActor,
    [switch]$SkipPackageValidation,
    [switch]$NonInteractive,
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $packageRoot 'payload'
$payloadApp = Join-Path $payloadRoot 'app'
$templateRoot = Join-Path $payloadRoot 'templates'
$catalogRoot = Join-Path $payloadRoot 'catalogs'
$validatorPath = Join-Path $packageRoot 'Validate-Package.ps1'
$packageInfoPath = Join-Path $packageRoot 'package-info.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$installStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

function Write-InstallStep {
    param([string]$Message)
    Write-Host ("  " + $Message) -ForegroundColor Cyan
}

function Resolve-InstallModes {
    param([string[]]$RequestedModes)

    $validModes = @(
        'ChatGPT',
        'DeepSeek',
        'Transfer'
    )
    $aliases = @{
        'chatgpt' = 'ChatGPT'
        'deepseek' = 'DeepSeek'
        'deepseekpro' = 'DeepSeek'
        'deepseek-v4-pro' = 'DeepSeek'
        # Old installers exposed Flash separately. Keep the old names as
        # compatibility aliases for the single native DeepSeek entrance.
        'native' = 'DeepSeek'
        'nativeflash' = 'DeepSeek'
        'deepseek-v4-flash' = 'DeepSeek'
        'deepseek-v4-flash-vision-exp' = 'DeepSeek'
        'deepseekvision' = 'DeepSeek'
        # The station now routes Pro/Legacy on the server for the same key.
        # Keep the old names as aliases so existing AI installation prompts
        # continue to work, while new installs create one local Transfer mode.
        'transfer' = 'Transfer'
        'transferpro' = 'Transfer'
        'openai-transfer-pro' = 'Transfer'
        'transferlegacy' = 'Transfer'
        'openai-transfer' = 'Transfer'
        'all' = 'all'
    }

    $requested = @($RequestedModes | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($requested.Count -gt 0) {
        $tokens = New-Object System.Collections.Generic.List[string]
        foreach ($item in $requested) {
            foreach ($token in ([string]$item -split '[,; ]+')) {
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    $tokens.Add($token.Trim())
                }
            }
        }
        $normalized = New-Object System.Collections.Generic.List[string]
        foreach ($token in $tokens) {
            $key = $token.ToLowerInvariant()
            if (-not $aliases.ContainsKey($key)) {
                throw (
                    "Unknown installation mode '$token'. Use: " +
                    ($validModes -join ', ')
                )
            }
            $mapped = $aliases[$key]
            if ($mapped -eq 'all') {
                return $validModes
            }
            if (-not $normalized.Contains($mapped)) {
                $normalized.Add($mapped)
            }
        }
        if (-not $normalized.Contains('ChatGPT')) {
            $normalized.Insert(0, 'ChatGPT')
        }
        return @($normalized)
    }

    # When an agent supplies only credential paths, infer the smallest useful
    # installation. This keeps a later extension cheap while avoiding prompts
    # for modes the user never asked for.
    $inferred = New-Object System.Collections.Generic.List[string]
    if ($DeepSeekKeyFile) {
        $inferred.Add('DeepSeek')
    }
    if ($TransferKeyFile -or $TransferProKeyFile -or
        $TransferLegacyKeyFile -or $TransferLegacyActorFile) {
        $inferred.Add('Transfer')
    }
    if ($inferred.Count -gt 0) {
        $withChatGPT = New-Object System.Collections.Generic.List[string]
        $withChatGPT.Add('ChatGPT')
        foreach ($mode in $inferred) {
            if (-not $withChatGPT.Contains($mode)) {
                $withChatGPT.Add($mode)
            }
        }
        return @($withChatGPT)
    }

    if ($NonInteractive) {
        # A no-credential, non-interactive install still gives the user a
        # working ChatGPT launcher. The agent can add provider modes later.
        return @('ChatGPT')
    }

    Write-Host ''
    Write-Host 'Choose the modes to install.' -ForegroundColor White
    Write-Host 'Press Enter for all modes, or type names separated by commas:'
    Write-Host 'ChatGPT, DeepSeek, Transfer'
    $answer = Read-Host 'Modes'
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $validModes
    }
    return Resolve-InstallModes -RequestedModes @($answer)
}

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($expanded -eq '~') {
        $expanded = $env:USERPROFILE
    }
    elseif ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $candidatePath = (ConvertTo-NormalizedPath $Candidate).TrimEnd(
        [char[]]@('\', '/')
    )
    $parentPath = (ConvertTo-NormalizedPath $Parent).TrimEnd(
        [char[]]@('\', '/')
    )
    if ($candidatePath.Equals(
        $parentPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return $true
    }
    $prefix = $parentPath + [IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-SafeDirectoryTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $fullPath = ConvertTo-NormalizedPath $Path
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -eq $pathRoot.TrimEnd('\')) {
        throw "$Label cannot be a drive root: $fullPath"
    }
    if ($fullPath.TrimEnd('\') -eq $env:USERPROFILE.TrimEnd('\')) {
        throw "$Label cannot be the user profile root."
    }
    return $fullPath
}

function Resolve-CodexDesktopExecutable {
    param([string]$RequestedPath = '')

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $requested = ConvertTo-NormalizedPath $RequestedPath
        if (-not (Test-Path -LiteralPath $requested -PathType Leaf)) {
            throw "The supplied Codex executable was not found: $requested"
        }
        if ((Split-Path -Leaf $requested) -ne 'ChatGPT.exe') {
            throw 'CodexExecutablePath must point to the installed ChatGPT.exe.'
        }
        return $requested
    }

    $runningProcesses = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    foreach ($runningProcess in $runningProcesses) {
        try {
            $runningPath = [string]$runningProcess.Path
            if ($runningPath -and (Test-Path -LiteralPath $runningPath -PathType Leaf)) {
                return [IO.Path]::GetFullPath($runningPath)
            }
        }
        catch {
            # Process paths may be hidden from a non-elevated agent.
        }
    }

    try {
        $runningCim = Get-CimInstance Win32_Process `
            -Filter "Name = 'ChatGPT.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath } |
            Select-Object -First 1
        if ($runningCim -and (Test-Path -LiteralPath $runningCim.ExecutablePath -PathType Leaf)) {
            return [IO.Path]::GetFullPath([string]$runningCim.ExecutablePath)
        }
    }
    catch {
        # CIM process inspection is optional.
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommand -and $codexCommand.Source) {
        $searchDirectory = Split-Path -Parent $codexCommand.Source
        for ($level = 0; $level -lt 5 -and $searchDirectory; $level++) {
            $candidate = Join-Path $searchDirectory 'ChatGPT.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
            $parentDirectory = Split-Path -Parent $searchDirectory
            if ($parentDirectory -eq $searchDirectory) {
                break
            }
            $searchDirectory = $parentDirectory
        }
    }

    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Codex\ChatGPT.exe'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\ChatGPT.exe'),
        (Join-Path $env:ProgramFiles 'Codex\ChatGPT.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        $package = Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Codex*' } |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $windowsAppsRoot = Join-Path $env:ProgramFiles 'WindowsApps'
    foreach ($appDirectory in @(
        Get-ChildItem -LiteralPath $windowsAppsRoot `
            -Directory `
            -Filter 'OpenAI.Codex_*' `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )) {
        $candidate = Join-Path $appDirectory.FullName 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw (
        'Codex for Windows was not found. Install Codex first, open it once, ' +
        'and then run this installer again.'
    )
}

function ConvertFrom-SecureValue {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecureValue
    )
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Assert-SecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 8) {
        throw "$Label is empty or too short."
    }
    if ($Value -match '\s') {
        throw "$Label contains whitespace. The key file must contain one key only."
    }
    if ($Value -match '^(__.*__|<.*>|your[-_ ]?key)') {
        throw "$Label looks like a placeholder rather than a real key."
    }
}

function Get-SecretFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $fullPath = ConvertTo-NormalizedPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label file was not found: $fullPath"
    }
    if (Test-PathInside -Candidate $fullPath -Parent $packageRoot) {
        throw (
            "$Label file is inside the portable package. Move it to a private " +
            'folder outside this package before installing.'
        )
    }
    $value = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8).Trim()
    Assert-SecretValue -Value $value -Label $Label
    return $value
}

function Get-RequiredSecret {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return Get-SecretFromFile -Path $Path -Label $Label
    }
    if ($NonInteractive) {
        throw "$Label file is required in non-interactive mode."
    }

    $secureValue = Read-Host -Prompt $Prompt -AsSecureString
    $value = ConvertFrom-SecureValue -SecureValue $secureValue
    Assert-SecretValue -Value $value -Label $Label
    return $value
}

function Resolve-TransferKeyPath {
    $candidates = @(
        [pscustomobject]@{ Name = 'TransferKeyFile'; Path = $TransferKeyFile },
        [pscustomobject]@{ Name = 'TransferProKeyFile'; Path = $TransferProKeyFile },
        [pscustomobject]@{ Name = 'TransferLegacyKeyFile'; Path = $TransferLegacyKeyFile }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) }

    if (@($candidates).Count -eq 0) {
        return ''
    }

    $normalized = @{}
    foreach ($candidate in $candidates) {
        $fullPath = ConvertTo-NormalizedPath ([string]$candidate.Path)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "$($candidate.Name) was not found: $fullPath"
        }
        $key = $fullPath.ToLowerInvariant()
        if (-not $normalized.ContainsKey($key)) {
            $normalized[$key] = New-Object System.Collections.Generic.List[string]
        }
        $normalized[$key].Add([string]$candidate.Name)
    }

    if ($normalized.Count -gt 1) {
        throw (
            'Use one Transfer key file for the shared profile. Supplied files ' +
            'resolve to different paths: ' +
            (($normalized.Values | ForEach-Object { $_ -join ', ' }) -join '; ')
        )
    }
    $firstKey = @($normalized.Keys)[0]
    return [string]$firstKey
}

function ConvertTo-JsonString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Expand-PackageTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $content = [IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8)
    foreach ($placeholder in $Values.Keys) {
        $count = [regex]::Matches(
            $content,
            [regex]::Escape([string]$placeholder)
        ).Count
        if ($count -ne 1) {
            throw (
                "Template placeholder $placeholder occurred $count times in " +
                "$TemplatePath; expected exactly once."
            )
        }
        $content = $content.Replace(
            [string]$placeholder,
            [string]$Values[$placeholder]
        )
    }
    if ($content -match '__[A-Z0-9_]+__') {
        throw "An unresolved placeholder remains in $TemplatePath."
    }
    return $content
}

function Install-TextFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupName
    )

    $targetDirectory = Split-Path -Parent $TargetPath
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    $temporaryPath = Join-Path $targetDirectory (
        '.' + (Split-Path -Leaf $TargetPath) + '.install-' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    Write-Utf8Text -Path $temporaryPath -Content $Content

    $backupPath = $null
    $wasNew = -not (Test-Path -LiteralPath $TargetPath)
    try {
        if ($wasNew) {
            Move-Item -LiteralPath $temporaryPath -Destination $TargetPath
        }
        else {
            New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
            $backupPath = Join-Path $BackupRoot $BackupName
            [IO.File]::Replace(
                $temporaryPath,
                $TargetPath,
                $backupPath,
                $true
            )
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return [pscustomobject]@{
        TargetPath = $TargetPath
        BackupPath = $backupPath
        WasNew = $wasNew
    }
}

function Protect-SensitiveFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        Write-Warning "Could not restrict permissions for $Path (icacls missing)."
        return
    }
    try {
        # Codex agents can execute as a temporary sandbox identity while the
        # desktop profile still belongs to $env:USERNAME. Grant the profile
        # user explicitly; granting only the process identity can lock the
        # real user out after installation.
        $targetAccount = New-Object Security.Principal.NTAccount(
            $env:USERDOMAIN,
            $env:USERNAME
        )
        $targetSid = $targetAccount.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        $processSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $grantUser = '*' + $targetSid + ':(F)'
        $grantProcess = '*' + $processSid + ':(F)'
        $grantSystem = '*S-1-5-18:(F)'
        $grantAdmins = '*S-1-5-32-544:(F)'
        $grantRules = @($grantUser, $grantSystem, $grantAdmins)
        if ($processSid -ne $targetSid) {
            $grantRules += $grantProcess
        }
        $icaclsArguments = @($Path, '/inheritance:r', '/grant:r') +
            $grantRules
        & $icacls @icaclsArguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not fully restrict permissions for $Path."
        }
    }
    catch {
        Write-Warning "Could not restrict permissions for $Path."
    }
}

function Restore-ProfileChanges {
    param([System.Collections.IList]$Changes)

    for ($index = $Changes.Count - 1; $index -ge 0; $index--) {
        $change = $Changes[$index]
        if ($change.BackupPath -and (Test-Path -LiteralPath $change.BackupPath)) {
            if (Test-Path -LiteralPath $change.TargetPath) {
                Remove-Item -LiteralPath $change.TargetPath -Force
            }
            Move-Item -LiteralPath $change.BackupPath `
                -Destination $change.TargetPath
        }
        elseif ($change.WasNew -and (Test-Path -LiteralPath $change.TargetPath)) {
            Remove-Item -LiteralPath $change.TargetPath -Force
        }
    }
}

function Install-FriendlyJunction {
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $backupPath = $null
    if (Test-Path -LiteralPath $LinkPath) {
        $item = Get-Item -Force -LiteralPath $LinkPath
        $sameTarget = $false
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            foreach ($target in @($item.Target)) {
                if ($target) {
                    try {
                        $sameTarget = (
                            (ConvertTo-NormalizedPath $target) -eq
                            (ConvertTo-NormalizedPath $TargetPath)
                        )
                    }
                    catch {
                        $sameTarget = $false
                    }
                    if ($sameTarget) { break }
                }
            }
        }
        if ($sameTarget) {
            return [pscustomobject]@{
                LinkPath = $LinkPath
                BackupPath = $null
                Reused = $true
            }
        }

        $archiveRoot = Join-Path $ProfilesRoot (
            '_archive\portable-installer-' + $installStamp
        )
        New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
        $backupPath = Join-Path $archiveRoot (Split-Path -Leaf $LinkPath)
        Move-Item -LiteralPath $LinkPath -Destination $backupPath
    }

    $null = New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath
    return [pscustomobject]@{
        LinkPath = $LinkPath
        BackupPath = $backupPath
        Reused = $false
    }
}

foreach ($requiredPath in @(
    $payloadApp,
    $templateRoot,
    $catalogRoot,
    $validatorPath,
    $packageInfoPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Portable package component is missing: $requiredPath"
    }
}

Write-Host ''
Write-Host 'Codex Provider Launcher' -ForegroundColor White
Write-InstallStep 'Checking the package and the Codex installation...'
if (-not $SkipPackageValidation) {
    $null = & $validatorPath -Quiet
}
else {
    Write-Warning 'Package preflight skipped after local agent inspection.'
}
$selectedModes = @(Resolve-InstallModes -RequestedModes $Modes)
Write-InstallStep ('Modes: ' + ($selectedModes -join ', '))
$resolvedCodexExecutable = Resolve-CodexDesktopExecutable `
    -RequestedPath $CodexExecutablePath

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA (
        'Programs\Codex-DeepSeek-Bridge'
    )
}
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) {
    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = Join-Path $env:USERPROFILE 'Documents'
    }
    $ProfilesRoot = Join-Path $documentsPath 'Codex'
}
if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
    $DesktopPath = [Environment]::GetFolderPath('Desktop')
}

$InstallRoot = Assert-SafeDirectoryTarget `
    -Path $InstallRoot `
    -Label 'InstallRoot'
$ProfilesRoot = Assert-SafeDirectoryTarget `
    -Path $ProfilesRoot `
    -Label 'ProfilesRoot'
if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
    $DesktopPath = Assert-SafeDirectoryTarget `
        -Path $DesktopPath `
        -Label 'DesktopPath'
}

if (
    (Test-PathInside -Candidate $InstallRoot -Parent $packageRoot) -or
    (Test-PathInside -Candidate $packageRoot -Parent $InstallRoot)
) {
    throw 'InstallRoot must be separate from the extracted portable package.'
}
if (Test-PathInside -Candidate $ProfilesRoot -Parent $packageRoot) {
    throw 'ProfilesRoot must be outside the extracted portable package.'
}

$transferRoot = Join-Path $ProfilesRoot 'ai-pixel-relay'
$transferLegacyRoot = Join-Path $transferRoot 'legacy-transfer'
$deepSeekRoot = Join-Path $ProfilesRoot 'deepseek-native-test'
$deepSeekCatalogPath = Join-Path $deepSeekRoot 'codex-home\models.json'
$friendlyLinkPath = Join-Path $ProfilesRoot 'Codex-Launcher'

if ($ValidateOnly) {
    if ($DeepSeekKeyFile) {
        $checkedDeepSeek = Get-SecretFromFile `
            -Path $DeepSeekKeyFile `
            -Label 'DeepSeek API key'
        $checkedDeepSeek = $null
    }
    $resolvedTransferKeyFile = Resolve-TransferKeyPath
    if ($resolvedTransferKeyFile) {
        $checkedTransfer = Get-SecretFromFile `
            -Path $resolvedTransferKeyFile `
            -Label 'OpenAI Transfer key'
        $checkedTransfer = $null
    }
    [ordered]@{
        Status = 'OK'
        Package = $packageRoot
        Modes = @($selectedModes)
        CodexExecutable = $resolvedCodexExecutable
        InstallRoot = $InstallRoot
        ProfilesRoot = $ProfilesRoot
        DeepSeekProfileRoot = $deepSeekRoot
        CredentialFilesChecked = [bool](
            $DeepSeekKeyFile -or
            $TransferKeyFile -or
            $TransferProKeyFile -or
            $TransferLegacyKeyFile -or
            $TransferLegacyActorFile
        )
        WritesPerformed = $false
    }
    return
}

$targetPidPath = Join-Path $InstallRoot 'bridge.pid'
if (Test-Path -LiteralPath $targetPidPath) {
    $savedPid = 0
    if ([int]::TryParse(
        ([IO.File]::ReadAllText($targetPidPath).Trim()),
        [ref]$savedPid
    )) {
        $savedProcess = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
        if ($savedProcess -and $savedProcess.ProcessName -eq 'moonbridge') {
            throw (
                'The existing local bridge is running. Quit provider-mode ' +
                'Codex and run Stop-DeepSeek-Bridge.ps1 before upgrading.'
            )
        }
    }
}

${needsDeepSeek} = $selectedModes -contains 'DeepSeek'
${needsTransfer} = $selectedModes -contains 'Transfer'

# Keep all secret-bearing variables initialized so a failed adaptation can
# still cleanly release them in the finally block below.
$deepSeekKey = ''
$transferKey = ''
$deepSeekKeyJson = ''
$transferModelJson = ''
$transferReasoningJson = ''
$nativeConfig = ''
$transferConfig = ''
$transferAuth = ''
$resolvedTransferKeyFile = ''

Write-InstallStep 'Reading only the credentials needed by the selected modes...'
if (${needsDeepSeek}) {
    $deepSeekKey = Get-RequiredSecret `
        -Path $DeepSeekKeyFile `
        -Label 'DeepSeek API key' `
        -Prompt 'Enter the DeepSeek API key'
}
if (${needsTransfer}) {
    $resolvedTransferKeyFile = Resolve-TransferKeyPath
    $transferKey = Get-RequiredSecret `
        -Path $resolvedTransferKeyFile `
        -Label 'OpenAI Transfer key' `
        -Prompt 'Enter the OpenAI Transfer key'
}
$deepSeekKeyJson = ConvertTo-JsonString $deepSeekKey
$transferModelJson = ConvertTo-JsonString $TransferProModel
$transferReasoningJson = ConvertTo-JsonString $TransferProReasoningEffort

if (${needsDeepSeek}) {
    $nativeConfig = Expand-PackageTemplate `
        -TemplatePath (Join-Path $templateRoot 'native-config.template.toml') `
        -Values @{
            '__NATIVE_CATALOG_PATH_JSON__' = (
                ConvertTo-JsonString $deepSeekCatalogPath
            )
            '__DEEPSEEK_API_KEY_JSON__' = $deepSeekKeyJson
        }
}
if (${needsTransfer}) {
    $transferConfig = Expand-PackageTemplate `
        -TemplatePath (Join-Path $templateRoot 'transfer-shared-config.template.toml') `
        -Values @{
            '__TRANSFER_MODEL_JSON__' = $transferModelJson
            '__TRANSFER_REASONING_JSON__' = $transferReasoningJson
        }
    $transferAuth = [ordered]@{
        OPENAI_API_KEY = $transferKey
    } | ConvertTo-Json
}

$launcherSettings = [ordered]@{
    schema_version = 5
    enabled_modes = @($selectedModes)
    codex_executable = $resolvedCodexExecutable
    deepseek_profile_root = $deepSeekRoot
    deepseek_transport = 'native'
    deepseek_models = @(
        'deepseek-v4-pro',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp'
    )
    transfer_profile_root = $transferRoot
    transfer_shared_profile_root = $transferRoot
    transfer_profile_strategy = 'shared-auth-json'
} | ConvertTo-Json -Depth 5

$installParent = Split-Path -Parent $InstallRoot
New-Item -ItemType Directory -Force -Path $installParent | Out-Null
New-Item -ItemType Directory -Force -Path $ProfilesRoot | Out-Null

$stageRoot = Join-Path $installParent (
    '.' + (Split-Path -Leaf $InstallRoot) + '.install-' +
    [Guid]::NewGuid().ToString('N')
)
$installBackupPath = $null
$newInstallActivated = $false
$profileChanges = New-Object System.Collections.ArrayList

try {
    Write-InstallStep 'Preparing a clean local installation...'
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $payloadApp) {
        Copy-Item -LiteralPath $item.FullName `
            -Destination $stageRoot `
            -Recurse `
            -Force
    }

    Write-Utf8Text `
        -Path (Join-Path $stageRoot 'launcher.settings.json') `
        -Content $launcherSettings

    if (Test-Path -LiteralPath $InstallRoot) {
        $existingInstall = Get-Item -Force -LiteralPath $InstallRoot
        if ($existingInstall.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'InstallRoot is a link. Choose the physical installation path.'
        }
        $installBackupPath = Join-Path $installParent (
            (Split-Path -Leaf $InstallRoot) + '.backup-' + $installStamp
        )
        if (Test-Path -LiteralPath $installBackupPath) {
            $installBackupPath += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        }
        Move-Item -LiteralPath $InstallRoot -Destination $installBackupPath
    }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $InstallRoot
        $newInstallActivated = $true
        $stageRoot = $null
    }
    catch {
        if (
            $installBackupPath -and
            (Test-Path -LiteralPath $installBackupPath) -and
            -not (Test-Path -LiteralPath $InstallRoot)
        ) {
            Move-Item -LiteralPath $installBackupPath -Destination $InstallRoot
            $installBackupPath = $null
        }
        throw
    }

    Write-InstallStep 'Creating the isolated DeepSeek and Transfer profiles...'
    $transferBackupRoot = Join-Path $transferRoot (
        'backups\portable-installer\' + $installStamp
    )

    if (${needsDeepSeek}) {
        $deepSeekBackupRoot = Join-Path $deepSeekRoot (
            'backups\portable-installer\' + $installStamp
        )
        $change = Install-TextFileAtomically `
            -TargetPath (Join-Path $deepSeekRoot 'codex-home\config.toml') `
            -Content $nativeConfig `
            -BackupRoot $deepSeekBackupRoot `
            -BackupName 'config.toml'
        $null = $profileChanges.Add($change)

        $nativeCatalog = [IO.File]::ReadAllText(
            (Join-Path $catalogRoot 'native-models.json'),
            [Text.Encoding]::UTF8
        )
        $change = Install-TextFileAtomically `
            -TargetPath $deepSeekCatalogPath `
            -Content $nativeCatalog `
            -BackupRoot $deepSeekBackupRoot `
            -BackupName 'models.json'
        $null = $profileChanges.Add($change)
    }

    if (${needsTransfer}) {
        $change = Install-TextFileAtomically `
            -TargetPath (Join-Path $transferRoot 'codex-home\config.toml') `
            -Content $transferConfig `
            -BackupRoot $transferBackupRoot `
            -BackupName 'config.toml'
        $null = $profileChanges.Add($change)

        $change = Install-TextFileAtomically `
            -TargetPath (Join-Path $transferRoot 'codex-home\auth.json') `
            -Content $transferAuth `
            -BackupRoot $transferBackupRoot `
            -BackupName 'auth.json'
        $null = $profileChanges.Add($change)
    }

    Write-InstallStep 'Running the installed launcher checks...'
    $chooserValidation = & (Join-Path $InstallRoot 'Start-Codex-Chooser.ps1') `
        -ValidateOnly
    if (-not $chooserValidation) {
        throw 'The installed launcher did not return a validation result.'
    }

    foreach ($sensitivePath in @(
        (Join-Path $deepSeekRoot 'codex-home\config.toml'),
        $deepSeekCatalogPath,
        (Join-Path $transferRoot 'codex-home\config.toml'),
        (Join-Path $transferRoot 'codex-home\auth.json'),
        (Join-Path $transferLegacyRoot 'codex-home\config.toml'),
        (Join-Path $transferLegacyRoot 'codex-home\auth.json')
    )) {
        Protect-SensitiveFile -Path $sensitivePath
    }
    foreach ($changeRecord in $profileChanges) {
        if ($changeRecord.BackupPath) {
            Protect-SensitiveFile -Path $changeRecord.BackupPath
        }
    }
}
catch {
    $originalError = $_
    try {
        Restore-ProfileChanges -Changes $profileChanges
    }
    catch {
        Write-Warning 'A profile rollback step failed; inspect the installer backups.'
    }

    if ($newInstallActivated -and (Test-Path -LiteralPath $InstallRoot)) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
    if (
        $installBackupPath -and
        (Test-Path -LiteralPath $installBackupPath) -and
        -not (Test-Path -LiteralPath $InstallRoot)
    ) {
        Move-Item -LiteralPath $installBackupPath -Destination $InstallRoot
    }
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    throw $originalError
}
finally {
    $deepSeekKey = $null
    $transferKey = $null
    $deepSeekKeyJson = $null
    $transferModelJson = $null
    $transferReasoningJson = $null
    $nativeConfig = $null
    $transferConfig = $null
    $transferAuth = $null
}

$friendlyResult = $null
$shortcutResult = $null
$postInstallWarnings = @()

if (-not $NoFriendlyLink) {
    try {
        Write-InstallStep 'Creating the friendly Codex-Launcher folder link...'
        $friendlyResult = Install-FriendlyJunction `
            -LinkPath $friendlyLinkPath `
            -TargetPath $InstallRoot
    }
    catch {
        $postInstallWarnings += (
            'The friendly folder link was not created: ' + $_.Exception.Message
        )
    }
}

if (-not $NoDesktopShortcut) {
    try {
        Write-InstallStep 'Creating the unified Codex desktop shortcut...'
        $shortcutArguments = @{}
        if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
            $shortcutArguments.DesktopPath = $DesktopPath
        }
        $shortcutResult = & (Join-Path $InstallRoot 'Install-Desktop-Shortcuts.ps1') `
            @shortcutArguments
    }
    catch {
        $postInstallWarnings += (
            'The desktop shortcut was not created: ' + $_.Exception.Message
        )
    }
}

$packageInfo = Get-Content -Raw -LiteralPath $packageInfoPath |
    ConvertFrom-Json
$manifest = [ordered]@{
    schema_version = 1
    package_name = [string]$packageInfo.name
    package_version = [string]$packageInfo.version
    installed_utc = [DateTime]::UtcNow.ToString('o')
    enabled_modes = @($selectedModes)
    codex_executable_at_install = $resolvedCodexExecutable
    install_root = $InstallRoot
    profiles_root = $ProfilesRoot
    deepseek_profile_root = $deepSeekRoot
    deepseek_transport = 'native'
    deepseek_models = @(
        'deepseek-v4-pro',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp'
    )
    transfer_profile_root = $transferRoot
    transfer_shared_profile_root = $transferRoot
    transfer_profile_strategy = 'shared-auth-json'
    transfer_reference = '260902'
    friendly_link = $(if ($NoFriendlyLink) { $null } else { $friendlyLinkPath })
    desktop_shortcut = $(
        if ($NoDesktopShortcut -or [string]::IsNullOrWhiteSpace($DesktopPath)) {
            $null
        }
        else {
            Join-Path $DesktopPath 'Codex.lnk'
        }
    )
    prior_install_backup = $installBackupPath
    credentials_bundled = $false
}
Write-Utf8Text `
    -Path (Join-Path $InstallRoot 'install-manifest.json') `
    -Content ($manifest | ConvertTo-Json -Depth 5)

Write-Host ''
Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host 'Quit Codex before using the shortcut to choose another mode.'
foreach ($warningText in $postInstallWarnings) {
    Write-Warning $warningText
}

[ordered]@{
    Status = 'OK'
    EnabledModes = @($selectedModes)
    InstallRoot = $InstallRoot
    ProfilesRoot = $ProfilesRoot
    DesktopShortcutCreated = [bool]$shortcutResult
    FriendlyLinkCreated = [bool]$friendlyResult
    PreviousInstallBackup = $installBackupPath
    Warnings = $postInstallWarnings
    CredentialsBundled = $false
}
