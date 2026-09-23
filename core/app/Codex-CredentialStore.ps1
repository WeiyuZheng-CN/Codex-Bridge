Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CodexCredentialStorePath {
    param(
        [object]$LauncherSettings,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    if (
        $LauncherSettings -and
        $LauncherSettings.PSObject.Properties['credential_store_path'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$LauncherSettings.credential_store_path
        )
    ) {
        return [IO.Path]::GetFullPath(
            [string]$LauncherSettings.credential_store_path
        )
    }

    $profileRoot = $null
    foreach ($name in @(
        'transfer_shared_profile_root',
        'transfer_profile_root',
        'deepseek_profile_root'
    )) {
        if (
            $LauncherSettings -and
            $LauncherSettings.PSObject.Properties[$name] -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$LauncherSettings.$name
            )
        ) {
            $profileRoot = Split-Path -Parent (
                [IO.Path]::GetFullPath([string]$LauncherSettings.$name)
            )
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
        $profileRoot = Split-Path -Parent ([IO.Path]::GetFullPath($InstallRoot))
    }
    return Join-Path $profileRoot 'codex-vibe-settings\credentials.dpapi.json'
}

function New-CodexCredentialStoreObject {
    return [pscustomobject]@{
        schema_version = 1
        active = [pscustomobject]@{
            DeepSeek = $null
            Transfer = $null
        }
        entries = @()
    }
}

function Read-CodexCredentialStore {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-CodexCredentialStoreObject
    }

    try {
        $store = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "The credential store is not valid JSON: $Path"
    }

    if (-not $store.PSObject.Properties['entries']) {
        throw "The credential store has no entries list: $Path"
    }
    if (-not $store.PSObject.Properties['active']) {
        $store | Add-Member -MemberType NoteProperty -Name active `
            -Value ([pscustomobject]@{ DeepSeek = $null; Transfer = $null })
    }
    foreach ($provider in @('DeepSeek', 'Transfer')) {
        if (-not $store.active.PSObject.Properties[$provider]) {
            $store.active | Add-Member -MemberType NoteProperty `
                -Name $provider -Value $null
        }
    }
    return $store
}

function Set-CodexPrivateFileAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        return
    }
    try {
        $account = New-Object Security.Principal.NTAccount(
            $env:USERDOMAIN,
            $env:USERNAME
        )
        $sid = $account.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        & $icacls $Path '/inheritance:r' '/grant:r' `
            ('*' + $sid + ':(F)') `
            '*S-1-5-18:(F)' `
            '*S-1-5-32-544:(F)' | Out-Null
    }
    catch {
        # DPAPI still protects the values when ACL hardening is unavailable.
    }
}

function Write-CodexCredentialStore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Store
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $content = $Store | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $temporaryPath = Join-Path $directory (
        '.credentials-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $replacementBackup = Join-Path $directory (
        '.credentials-replace-' + [Guid]::NewGuid().ToString('N') + '.bak'
    )
    [IO.File]::WriteAllText($temporaryPath, $content, $encoding)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace(
                $temporaryPath,
                $Path,
                $replacementBackup,
                $true
            )
            if (Test-Path -LiteralPath $replacementBackup) {
                Remove-Item -LiteralPath $replacementBackup -Force
            }
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $replacementBackup) {
            Remove-Item -LiteralPath $replacementBackup -Force
        }
    }
    Set-CodexPrivateFileAcl -Path $Path
}

function Protect-CodexSecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    try {
        return ConvertFrom-SecureString -SecureString $secure
    }
    finally {
        $secure.Dispose()
    }
}

function Unprotect-CodexSecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$EncryptedValue
    )

    $secure = ConvertTo-SecureString -String $EncryptedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secure.Dispose()
    }
}

function Assert-CodexCredentialProvider {
    param([Parameter(Mandatory = $true)][string]$Provider)
    if ($Provider -notin @('DeepSeek', 'Transfer')) {
        throw "Unsupported credential provider: $Provider"
    }
}

function Assert-CodexCredentialValue {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 8) {
        throw 'The API key is empty or too short.'
    }
    if ($Value -match '\s') {
        throw 'The API key must not contain whitespace.'
    }
}

function Get-CodexCredentialSummaries {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider
    )

    Assert-CodexCredentialProvider -Provider $Provider
    $store = Read-CodexCredentialStore -Path $Path
    $activeId = [string]$store.active.$Provider
    return @(
        @($store.entries) |
            Where-Object { [string]$_.provider -eq $Provider } |
            ForEach-Object {
                [pscustomobject]@{
                    Id = [string]$_.id
                    Name = [string]$_.name
                    Provider = [string]$_.provider
                    Active = ([string]$_.id -eq $activeId)
                    UpdatedUtc = [string]$_.updated_utc
                }
            } |
            Sort-Object Name, Id
    )
}

function Save-CodexCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Id = ''
    )

    Assert-CodexCredentialProvider -Provider $Provider
    Assert-CodexCredentialValue -Value $Value
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'A key name is required.'
    }

    $store = Read-CodexCredentialStore -Path $Path
    $now = [DateTime]::UtcNow.ToString('o')
    $existing = @(
        @($store.entries) |
            Where-Object {
                ([string]$_.provider -eq $Provider) -and
                (
                    ([string]$_.id -eq $Id -and -not [string]::IsNullOrWhiteSpace($Id)) -or
                    ([string]$_.name -eq $Name -and [string]::IsNullOrWhiteSpace($Id))
                )
            } |
            Select-Object -First 1
    )
    $entryId = if ($existing) { [string]$existing.id } else {
        [Guid]::NewGuid().ToString('N')
    }
    $encrypted = Protect-CodexSecretValue -Value $Value
    if ($existing) {
        $existing.name = $Name
        $existing.encrypted_value = $encrypted
        $existing.updated_utc = $now
    }
    else {
        $newEntry = [pscustomobject]@{
            id = $entryId
            provider = $Provider
            name = $Name
            encrypted_value = $encrypted
            created_utc = $now
            updated_utc = $now
        }
        $store.entries = @($store.entries) + $newEntry
    }
    $store.active.$Provider = $entryId
    Write-CodexCredentialStore -Path $Path -Store $store
    return $entryId
}

function Set-CodexActiveCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Id
    )

    Assert-CodexCredentialProvider -Provider $Provider
    $store = Read-CodexCredentialStore -Path $Path
    $entry = @(
        @($store.entries) |
            Where-Object {
                [string]$_.provider -eq $Provider -and
                [string]$_.id -eq $Id
            } |
            Select-Object -First 1
    )
    if (-not $entry) {
        throw "Credential entry was not found: $Id"
    }
    $store.active.$Provider = $Id
    Write-CodexCredentialStore -Path $Path -Store $store
}

function Remove-CodexCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Id
    )

    Assert-CodexCredentialProvider -Provider $Provider
    $store = Read-CodexCredentialStore -Path $Path
    $remaining = @(
        @($store.entries) |
            Where-Object {
                -not (
                    [string]$_.provider -eq $Provider -and
                    [string]$_.id -eq $Id
                )
            }
    )
    if ($remaining.Count -eq @($store.entries).Count) {
        throw "Credential entry was not found: $Id"
    }
    $store.entries = $remaining
    if ([string]$store.active.$Provider -eq $Id) {
        $replacement = @(
            $remaining |
                Where-Object { [string]$_.provider -eq $Provider } |
                Select-Object -First 1
        )
        $store.active.$Provider = if ($replacement) {
            [string]$replacement.id
        }
        else {
            $null
        }
    }
    Write-CodexCredentialStore -Path $Path -Store $store
}

function Get-CodexActiveCredentialValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider
    )

    Assert-CodexCredentialProvider -Provider $Provider
    $store = Read-CodexCredentialStore -Path $Path
    $activeId = [string]$store.active.$Provider
    if ([string]::IsNullOrWhiteSpace($activeId)) {
        return $null
    }
    $entry = @(
        @($store.entries) |
            Where-Object {
                [string]$_.provider -eq $Provider -and
                [string]$_.id -eq $activeId
            } |
            Select-Object -First 1
    )
    if (-not $entry) {
        return $null
    }
    return Unprotect-CodexSecretValue -EncryptedValue (
        [string]$entry.encrypted_value
    )
}

function Get-CodexActiveCredentialId {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider
    )
    Assert-CodexCredentialProvider -Provider $Provider
    $store = Read-CodexCredentialStore -Path $Path
    return [string]$store.active.$Provider
}

function Write-CodexTextAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = Join-Path $directory (
        '.' + (Split-Path -Leaf $Path) + '.switch-' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $replacementBackup = Join-Path $directory (
        '.' + (Split-Path -Leaf $Path) + '.replace-' +
        [Guid]::NewGuid().ToString('N') + '.bak'
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace(
                $temporaryPath,
                $Path,
                $replacementBackup,
                $true
            )
            if (Test-Path -LiteralPath $replacementBackup) {
                Remove-Item -LiteralPath $replacementBackup -Force
            }
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $replacementBackup) {
            Remove-Item -LiteralPath $replacementBackup -Force
        }
    }
    Set-CodexPrivateFileAcl -Path $Path
}

function Sync-CodexActiveCredential {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DeepSeek', 'Transfer')]
        [string]$Provider,
        [object]$LauncherSettings,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $storePath = Get-CodexCredentialStorePath `
        -LauncherSettings $LauncherSettings `
        -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
        return $false
    }
    $value = Get-CodexActiveCredentialValue `
        -Path $storePath `
        -Provider $Provider
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    if ($Provider -eq 'DeepSeek') {
        $content = [IO.File]::ReadAllText($TargetPath, [Text.Encoding]::UTF8)
        $pattern = '(?m)^experimental_bearer_token\s*=\s*"[^"]*"\s*\r?$'
        if (-not [regex]::IsMatch($content, $pattern)) {
            throw 'The DeepSeek config has no experimental_bearer_token setting.'
        }
        $replacement = 'experimental_bearer_token = ' +
            (ConvertTo-Json -InputObject $value -Compress)
        $updated = [regex]::Replace($content, $pattern, $replacement, 1)
        if ($updated -cne $content) {
            Write-CodexTextAtomically -Path $TargetPath -Content $updated
        }
    }
    else {
        $auth = Get-Content -Raw -LiteralPath $TargetPath | ConvertFrom-Json
        if (-not $auth.PSObject.Properties['OPENAI_API_KEY']) {
            $auth | Add-Member -MemberType NoteProperty `
                -Name OPENAI_API_KEY -Value $value
        }
        else {
            $auth.OPENAI_API_KEY = $value
        }
        Write-CodexTextAtomically `
            -Path $TargetPath `
            -Content ($auth | ConvertTo-Json -Depth 5)
    }
    return $true
}
