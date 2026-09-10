[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$PreviewOnly,
    [switch]$PreviewInteractive,
    [string]$PreviewImagePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$chatGPTScript = Join-Path $installRoot 'Start-Codex-ChatGPT.ps1'
$deepSeekScript = Join-Path $installRoot 'Start-Codex-DeepSeek.ps1'
$openaiTransferScript = Join-Path $installRoot 'Start-Codex-OpenAI-Transfer.ps1'
$settingsPath = Join-Path $installRoot 'launcher.settings.json'
$historyDirectory = Join-Path $installRoot 'maintenance\history'
$historyRepair = Join-Path $historyDirectory 'Repair-DeepSeek-History.ps1'
$metadataRepair = Join-Path $historyDirectory 'Repair-DeepSeek-HistoryMetadata.py'
$iconPath = Join-Path $installRoot 'Codex.ico'
$pidPath = Join-Path $installRoot 'bridge.pid'
$logDirectory = Join-Path $installRoot 'logs'
$errorLogPath = Join-Path $logDirectory 'chooser-error.log'
$dispatchLogPath = Join-Path $logDirectory 'chooser-dispatch.log'
$powerShellExe = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)

function Get-ModeAvailability {
    # The portable package has no settings file yet, so preview/package checks
    # present the complete UI. An installed copy records only the modes the
    # user selected; absent modes stay visible but cannot be launched.
    $available = [ordered]@{
        ChatGPT = $true
        DeepSeek = $true
        Transfer = $true
    }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $available
    }
    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath |
            ConvertFrom-Json
        if ($settings.PSObject.Properties['enabled_modes']) {
            foreach ($name in @($available.Keys)) {
                $available[$name] = $false
            }
            foreach ($mode in @($settings.enabled_modes)) {
                switch ([string]$mode) {
                    'ChatGPT' { $available.ChatGPT = $true }
                    'DeepSeek' { $available.DeepSeek = $true }
                    # Old installations used a second native Flash flag. All
                    # current DeepSeek models use the single native entry.
                    'NativeFlash' { $available.DeepSeek = $true }
                    'DeepSeekVision' { $available.DeepSeek = $true }
                    'Transfer' { $available.Transfer = $true }
                    # Older manifests recorded two Transfer modes. Treat either
                    # one as the single shared entrance during migration.
                    'TransferPro' { $available.Transfer = $true }
                    'TransferLegacy' { $available.Transfer = $true }
                }
            }
        }
        return $available
    }
    catch {
        Write-ChooserErrorLog ('Could not read launcher settings: ' + $_.Exception.Message)
        return $available
    }
}

function New-UnavailableValidationResult {
    param([Parameter(Mandatory = $true)][string]$Mode)
    return [ordered]@{
        Status = 'SKIPPED'
        Mode = $Mode
        Reason = 'Mode is not installed yet; the AI installation agent can add it later.'
    }
}

function ConvertTo-SafeChooserLogText {
    param(
        [string]$Message,
        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return ''
    }

    $safe = [regex]::Replace(
        $Message,
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

function Write-ChooserLog {
    param(
        [string]$Path,
        [string]$Message
    )

    try {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $encoding = New-Object System.Text.UTF8Encoding($false)
        if (
            (Test-Path -LiteralPath $Path) -and
            (Get-Item -LiteralPath $Path).Length -ge 1MB
        ) {
            [IO.File]::Copy($Path, "$Path.previous", $true)
            [IO.File]::WriteAllText($Path, '', $encoding)
        }
        $line = '{0:u} {1}' -f (
            Get-Date
        ), (ConvertTo-SafeChooserLogText -Message $Message)
        [IO.File]::AppendAllText(
            $Path,
            $line + [Environment]::NewLine,
            $encoding
        )
    }
    catch {
        # Logging must never mask the original action or failure.
    }
}

function Write-ChooserErrorLog {
    param(
        [string]$Message
    )
    Write-ChooserLog -Path $errorLogPath -Message $Message
}

function Show-ChooserError {
    param(
        [string]$Message
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            'Codex launcher error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Host "Codex launcher error: $Message" -ForegroundColor Red
    }
}

function Write-ChooserDispatchLog {
    param(
        [string]$Message
    )
    Write-ChooserLog -Path $dispatchLogPath -Message $Message
}

function Start-ProviderScriptOutOfProcess {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    # Provider scripts call $appProcess.WaitForExit() and must run as their own
    # process. In-process dispatch (& $script) blocks the WPF dispatcher and can
    # fail silently inside the hidden chooser context. `Start-Process` spawns a
    # fresh hidden PowerShell that behaves exactly like the verified manual
    # launcher path.
    $quotedScriptPath = '"' + $ScriptPath.Replace('"', '\"') + '"'
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        $quotedScriptPath
    )
    foreach ($item in $Arguments) {
        $argumentList += $item
    }
    Write-ChooserDispatchLog ('Starting: ' + $ScriptPath + ' ' + ($Arguments -join ' '))
    try {
        $providerProcess = Start-Process -FilePath $powerShellExe `
            -ArgumentList $argumentList `
            -WorkingDirectory $installRoot `
            -WindowStyle Hidden `
            -PassThru
        if (-not $providerProcess) {
            throw 'The provider launcher process was not created.'
        }
        Write-ChooserDispatchLog (
            'Provider launcher started. Pid=' + $providerProcess.Id
        )
        Start-Sleep -Milliseconds 150
        if ($providerProcess.HasExited -and $providerProcess.ExitCode -ne 0) {
            throw (
                'The provider launcher exited immediately with code ' +
                $providerProcess.ExitCode + '.'
            )
        }
    }
    catch {
        Write-ChooserDispatchLog ('Provider dispatch FAILED: ' + $_.Exception.Message)
        throw
    }
}

function Test-DeepSeekBridgeProcess {
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return $false
    }

    $savedPid = 0
    if (-not [int]::TryParse(
        (Get-Content -Raw -LiteralPath $pidPath).Trim(),
        [ref]$savedPid
    )) {
        return $false
    }

    $savedProcess = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
    return [bool](
        $savedProcess -and
        $savedProcess.ProcessName -eq 'moonbridge'
    )
}

function Show-AlreadyRunningMessage {
    [System.Windows.MessageBox]::Show(
        "Codex is already running.`r`n`r`nQuit Codex completely, then open the Codex shortcut again to choose a mode.",
        'Codex is already open',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Get-WpfCompatibleIcon {
    param(
        [string]$IconFilePath
    )
    # WPF's BitmapImage cannot reliably decode .ico files. Convert through
    # System.Drawing.Icon to an Imaging BitmapSource instead.
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $icon = New-Object System.Drawing.Icon -ArgumentList $IconFilePath
    try {
        $stream = New-Object System.IO.MemoryStream
        try {
            $icon.Save($stream)
            $stream.Position = 0
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )
            return $decoder.Frames[0]
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $icon.Dispose()
    }
}

foreach ($requiredPath in @(
    $chatGPTScript,
    $deepSeekScript,
    $openaiTransferScript,
    $historyRepair,
    $metadataRepair,
    $iconPath,
    $powerShellExe
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required launcher file is missing: $requiredPath"
    }
}

Add-Type -AssemblyName System.Drawing

if ($ValidateOnly) {
    $validationIcon = New-Object System.Drawing.Icon -ArgumentList $iconPath
    $validationIcon.Dispose()
    $availability = Get-ModeAvailability
    $installed = Test-Path -LiteralPath $settingsPath -PathType Leaf
    if ($installed -and $availability.ChatGPT) {
        $chatGPT = & $chatGPTScript -ValidateOnly
    }
    else {
        $chatGPT = New-UnavailableValidationResult -Mode 'ChatGPT'
    }
    if ($installed -and $availability.DeepSeek) {
        $deepSeek = & $deepSeekScript -ValidateOnly
    }
    else {
        $deepSeek = New-UnavailableValidationResult -Mode 'DeepSeek'
    }
    if ($installed -and $availability.Transfer) {
        # Shared profiles ignore the compatibility mode value. For an older
        # split-profile installation, choose the profile that was enabled if
        # only the legacy flag was recorded.
        $validationTransferMode = 'OpenAI-transfer-Pro'
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsPath |
                ConvertFrom-Json
            $hasSharedRoot = [bool](
                $settings.PSObject.Properties['transfer_shared_profile_root'] -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$settings.transfer_shared_profile_root
                )
            )
            if (
                -not $hasSharedRoot -and
                $settings.PSObject.Properties['enabled_modes'] -and
                @($settings.enabled_modes | ForEach-Object { [string]$_ }) -contains 'TransferLegacy' -and
                @($settings.enabled_modes | ForEach-Object { [string]$_ }) -notcontains 'TransferPro'
            ) {
                $validationTransferMode = 'OpenAI-transfer'
            }
        }
        catch {
            # The launcher performs the authoritative profile validation.
        }
        $transfer = & $openaiTransferScript `
            -TransferMode $validationTransferMode `
            -ValidateOnly
    }
    else {
        $transfer = New-UnavailableValidationResult -Mode 'Transfer'
    }

    [ordered]@{
        Status = $(if ($installed) { 'OK' } else { 'PACKAGE_READY' })
        Installed = $installed
        EnabledModes = @($availability.Keys | Where-Object { $availability[$_] })
        Choices = @(
            'ChatGPT',
            'DeepSeek (V4 Pro + V4 Flash + Vision)',
            'OpenAI Transfer'
        )
        TransferModes = @('OpenAI-transfer-Pro / OpenAI-transfer (server-side switch)')
        ChatGPTValidation = $chatGPT
        DeepSeekValidation = $deepSeek
        TransferValidation = $transfer
        # Retain field names used by older maintenance scripts.
        TransferProValidation = $transfer
        TransferLegacyValidation = $transfer
        Icon = $iconPath
        BridgeRunning = (Test-DeepSeekBridgeProcess)
    }
    return
}

# Keep headless validation independent from WPF initialization. Some Windows
# PowerShell hosts can wait indefinitely when PresentationFramework is loaded
# before a non-interactive validation call. The graphical UI is loaded only
# for the interactive/preview paths below.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

try {
    $xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:sys="clr-namespace:System;assembly=mscorlib"
    Title="Start Codex"
    Width="700"
    MinWidth="700"
    MaxWidth="700"
    SizeToContent="Height"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    ShowInTaskbar="True"
    Background="#F5F4F0"
    FontFamily="Segoe UI"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="ModeButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="Background" Value="#FFFFFC"/>
            <Setter Property="BorderBrush" Value="#DEDCD5"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="CardBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="16"
                                SnapsToDevicePixels="True">
                            <ContentPresenter
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CardBorder" Property="Background" Value="#FBFAF7"/>
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="#C9C6BC"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CardBorder" Property="Background" Value="#F1EEE8"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="#AAA69C"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="CardBorder" Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CancelButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="Background" Value="#FFFFFC"/>
            <Setter Property="BorderBrush" Value="#D8D5CD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="18,0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#383631"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="CancelBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CancelBorder" Property="Background" Value="#F4F2ED"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CancelBorder" Property="Background" Value="#EAE7E0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="28,18,28,18">
        <Grid.RowDefinitions>
            <RowDefinition Height="54"/>
            <RowDefinition Height="1"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="168"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="36"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="42" Height="42" CornerRadius="13" Background="#FFFFFC" BorderBrush="#DDDAD2" BorderThickness="1">
                <Canvas Width="42" Height="42">
                    <Line X1="21" Y1="5" X2="21" Y2="16" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="21" Y1="26" X2="21" Y2="37" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="5" Y1="21" X2="16" Y2="21" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="26" Y1="21" X2="37" Y2="21" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="9" Y1="9" X2="17" Y2="17" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="25" Y1="25" X2="33" Y2="33" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="33" Y1="9" X2="25" Y2="17" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Line X1="17" Y1="25" X2="9" Y2="33" Stroke="#302F2B" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                </Canvas>
            </Border>
            <TextBlock Text="Start Codex" Margin="14,0,0,0" VerticalAlignment="Center" FontSize="20" FontWeight="SemiBold" Foreground="#262522"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#DDDAD2"/>

        <Grid Grid.Row="3">
            <Grid.RowDefinitions>
                <RowDefinition Height="78"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="78"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Button x:Name="ChatGPTButton" Grid.Row="0" Grid.Column="0" Margin="0,0,6,6" Style="{StaticResource ModeButtonStyle}" AutomationProperties.Name="ChatGPT">
                <Grid Margin="16,0,12,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="38"/><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions>
                    <Border Width="38" Height="38" CornerRadius="12" Background="#F0F0ED" VerticalAlignment="Center">
                        <TextBlock Text="O" Foreground="#34332F" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Grid.Column="1" Text="ChatGPT" Margin="16,0,0,0" VerticalAlignment="Center" Foreground="#2E2D29" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock Grid.Column="2" Text="&#x203A;" VerticalAlignment="Center" HorizontalAlignment="Right" Foreground="#9F9B92" FontSize="24" FontWeight="Light"/>
                </Grid>
            </Button>

            <Button x:Name="DeepSeekButton" Grid.Row="0" Grid.Column="1" Margin="6,0,0,6" Style="{StaticResource ModeButtonStyle}" AutomationProperties.Name="DeepSeek">
                <Grid Margin="16,0,12,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="38"/><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions>
                    <Border Width="38" Height="38" CornerRadius="12" Background="#F8ECE7" VerticalAlignment="Center">
                        <TextBlock Text="D" Foreground="#BF5B41" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Grid.Column="1" Text="DeepSeek" Margin="16,0,0,0" VerticalAlignment="Center" Foreground="#2E2D29" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock Grid.Column="2" Text="&#x203A;" VerticalAlignment="Center" HorizontalAlignment="Right" Foreground="#9F9B92" FontSize="24" FontWeight="Light"/>
                </Grid>
            </Button>

            <Button x:Name="TransferButton" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,6,0,0" Style="{StaticResource ModeButtonStyle}" AutomationProperties.Name="OpenAI Transfer">
                <Grid Margin="16,0,12,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="38"/><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions>
                    <Border Width="38" Height="38" CornerRadius="12" Background="#EAF3F1" VerticalAlignment="Center">
                        <TextBlock Text="T" Foreground="#2A7E71" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Grid.Column="1" Text="OpenAI Transfer" Margin="16,0,0,0" VerticalAlignment="Center" Foreground="#2E2D29" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock Grid.Column="2" Text="&#x203A;" VerticalAlignment="Center" HorizontalAlignment="Right" Foreground="#9F9B92" FontSize="24" FontWeight="Light"/>
                </Grid>
            </Button>
        </Grid>

        <Button x:Name="CancelButton" Grid.Row="5" Width="84" Height="36" HorizontalAlignment="Right" Content="Cancel" Style="{StaticResource CancelButtonStyle}" IsCancel="True" AutomationProperties.Name="Cancel"/>
    </Grid>
</Window>
'@

    $xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)

    try {
        $window.Icon = Get-WpfCompatibleIcon -IconFilePath $iconPath
    }
    catch {
        # An icon failure must not prevent the chooser from opening.
        Write-ChooserErrorLog ('Icon load warning: ' + $_.Exception.Message)
        $window.Icon = $null
    }

    $chatGPTButton = $window.FindName('ChatGPTButton')
    $deepSeekButton = $window.FindName('DeepSeekButton')
    $transferButton = $window.FindName('TransferButton')
    $cancelButton = $window.FindName('CancelButton')
    $availability = Get-ModeAvailability
    $chatGPTButton.IsEnabled = [bool]$availability.ChatGPT
    $deepSeekButton.IsEnabled = [bool]$availability.DeepSeek
    $transferButton.IsEnabled = [bool]$availability.Transfer

    # A hashtable carries the selection across the WPF event-handler closure
    # boundary. Mutating a script-scope hashtable is reliable; rebinding a plain
    # script variable from inside a GetNewClosure event handler can silently not
    # propagate, which previously made every provider choice exit without
    # launching anything.
    $script:chooserState = @{ Provider = $null }
    $chatGPTButton.Add_Click({
        $script:chooserState.Provider = 'chatgpt'
        Write-ChooserDispatchLog ('Button clicked: chatgpt')
        $window.DialogResult = $true
    }.GetNewClosure())
    $deepSeekButton.Add_Click({
        $script:chooserState.Provider = 'deepseek'
        Write-ChooserDispatchLog ('Button clicked: deepseek native profile')
        $window.DialogResult = $true
    }.GetNewClosure())
    $transferButton.Add_Click({
        $script:chooserState.Provider = 'openai-transfer'
        Write-ChooserDispatchLog 'Button clicked: openai-transfer shared profile'
        $window.DialogResult = $true
    }.GetNewClosure())

    $window.Add_PreviewKeyDown({
        param($sender, $eventArgs)

        $target = $null
        switch ($eventArgs.Key) {
            ([System.Windows.Input.Key]::Left) {
                if ($deepSeekButton.IsKeyboardFocusWithin) { $target = $chatGPTButton }
            }
            ([System.Windows.Input.Key]::Right) {
                if ($chatGPTButton.IsKeyboardFocusWithin) { $target = $deepSeekButton }
            }
            ([System.Windows.Input.Key]::Up) {
                if ($transferButton.IsKeyboardFocusWithin) { $target = $chatGPTButton }
            }
            ([System.Windows.Input.Key]::Down) {
                if ($chatGPTButton.IsKeyboardFocusWithin -or $deepSeekButton.IsKeyboardFocusWithin) {
                    $target = $transferButton
                }
            }
        }

        if ($target) {
            $target.Focus() | Out-Null
            $eventArgs.Handled = $true
        }
    }.GetNewClosure())

    $window.Add_ContentRendered({
        foreach ($button in @(
            $chatGPTButton,
            $deepSeekButton,
            $transferButton
        )) {
            if ($button.IsEnabled) {
                $button.Focus() | Out-Null
                break
            }
        }
    }.GetNewClosure())

    function Save-WpfPreview {
        param([string]$Path)

        $window.UpdateLayout()
        $width = [int][Math]::Ceiling($window.ActualWidth)
        $height = [int][Math]::Ceiling(
            $window.Content.ActualHeight +
            $window.Content.Margin.Top +
            $window.Content.Margin.Bottom
        )
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            $width,
            $height,
            96,
            96,
            [System.Windows.Media.PixelFormats]::Pbgra32
        )
        $bitmap.Render($window)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create)
        try {
            $encoder.Save($stream)
        }
        finally {
            $stream.Dispose()
        }
    }

    if ($PreviewOnly) {
        if ([string]::IsNullOrWhiteSpace($PreviewImagePath)) {
            $PreviewImagePath = Join-Path ([IO.Path]::GetTempPath()) 'codex-launcher-wpf-preview.png'
        }
        $previewDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($PreviewImagePath))
        if (-not (Test-Path -LiteralPath $previewDirectory)) {
            New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null
        }
        $window.Show()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{},
            [System.Windows.Threading.DispatcherPriority]::Render
        )
        Save-WpfPreview -Path ([IO.Path]::GetFullPath($PreviewImagePath))
        $window.Close()
        Write-Output ([IO.Path]::GetFullPath($PreviewImagePath))
        return
    }

    if ($PreviewInteractive) {
        $window.ShowDialog() | Out-Null
        return
    }

    $dialogResult = $window.ShowDialog()
    $effectiveProvider = [string]$script:chooserState.Provider
    Write-ChooserDispatchLog ('ShowDialog returned. DialogResult=' + $dialogResult + ' Provider="' + $effectiveProvider + '"')

    if ($dialogResult -ne $true -or [string]::IsNullOrWhiteSpace($effectiveProvider)) {
        Write-ChooserDispatchLog 'Exiting without launch (dialog cancelled or provider empty).'
        exit 0
    }

    if (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Write-ChooserDispatchLog 'Exiting: Codex is already open.'
        Show-AlreadyRunningMessage
        exit 2
    }

    switch ($effectiveProvider) {
        'chatgpt' {
            Write-ChooserDispatchLog 'Dispatching ChatGPT'
            Start-ProviderScriptOutOfProcess -ScriptPath $chatGPTScript
        }
        'deepseek' {
            Write-ChooserDispatchLog 'Dispatching DeepSeek native profile'
            Start-ProviderScriptOutOfProcess -ScriptPath $deepSeekScript
        }
        'openai-transfer' {
            Write-ChooserDispatchLog 'Dispatching OpenAI Transfer shared profile'
            Start-ProviderScriptOutOfProcess -ScriptPath $openaiTransferScript
        }
        default {
            throw "Unknown Codex provider choice: $effectiveProvider"
        }
    }
}
catch {
    $errorMessage = $_.Exception.ToString()
    Write-ChooserErrorLog $errorMessage
    Show-ChooserError $_.Exception.Message
    exit 1
}
