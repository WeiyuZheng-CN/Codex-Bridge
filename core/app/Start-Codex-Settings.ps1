[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$settingsPath = Join-Path $InstallRoot 'launcher.settings.json'
$storeScriptPath = Join-Path $InstallRoot 'Codex-CredentialStore.ps1'

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Launcher settings are missing: $settingsPath"
}
if (-not (Test-Path -LiteralPath $storeScriptPath -PathType Leaf)) {
    throw "Credential store helper is missing: $storeScriptPath"
}

$launcherSettings = Get-Content -Raw -LiteralPath $settingsPath |
    ConvertFrom-Json
. $storeScriptPath

$storePath = Get-CodexCredentialStorePath `
    -LauncherSettings $launcherSettings `
    -InstallRoot $InstallRoot

function Get-ProfileRoot {
    param(
        [Parameter(Mandatory = $true)][string]$PropertyName
    )
    if (
        -not $launcherSettings.PSObject.Properties[$PropertyName] -or
        [string]::IsNullOrWhiteSpace([string]$launcherSettings.$PropertyName)
    ) {
        return $null
    }
    return [IO.Path]::GetFullPath([string]$launcherSettings.$PropertyName)
}

function Import-ExistingCredentialIfNeeded {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DeepSeek', 'Transfer')]
        [string]$Provider
    )

    if (@(Get-CodexCredentialSummaries -Path $storePath -Provider $Provider).Count -gt 0) {
        return
    }

    $value = $null
    $profileRoot = if ($Provider -eq 'DeepSeek') {
        Get-ProfileRoot -PropertyName 'deepseek_profile_root'
    }
    else {
        if ($launcherSettings.PSObject.Properties['transfer_shared_profile_root']) {
            Get-ProfileRoot -PropertyName 'transfer_shared_profile_root'
        }
        else {
            Get-ProfileRoot -PropertyName 'transfer_profile_root'
        }
    }
    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
        return
    }

    if ($Provider -eq 'DeepSeek') {
        $configPath = Join-Path $profileRoot 'codex-home\config.toml'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $content = Get-Content -Raw -LiteralPath $configPath
            $match = [regex]::Match(
                $content,
                '(?m)^experimental_bearer_token\s*=\s*"([^"]*)"\s*\r?$'
            )
            if ($match.Success) {
                $value = $match.Groups[1].Value
            }
        }
    }
    else {
        $authPath = Join-Path $profileRoot 'codex-home\auth.json'
        if (Test-Path -LiteralPath $authPath -PathType Leaf) {
            try {
                $auth = Get-Content -Raw -LiteralPath $authPath |
                    ConvertFrom-Json
                if ($auth.PSObject.Properties['OPENAI_API_KEY']) {
                    $value = [string]$auth.OPENAI_API_KEY
                }
            }
            catch {
                $value = $null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($value)) {
        Save-CodexCredential `
            -Path $storePath `
            -Provider $Provider `
            -Name ('Current ' + $Provider) `
            -Value $value | Out-Null
    }
}

Import-ExistingCredentialIfNeeded -Provider 'DeepSeek'
Import-ExistingCredentialIfNeeded -Provider 'Transfer'

if ($ValidateOnly) {
    [ordered]@{
        Status = 'OK'
        StorePath = $storePath
        DeepSeekKeys = @(Get-CodexCredentialSummaries -Path $storePath -Provider 'DeepSeek')
        TransferKeys = @(Get-CodexCredentialSummaries -Path $storePath -Provider 'Transfer')
    }
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Codex Settings"
    Width="640"
    Height="560"
    MinWidth="640"
    MinHeight="560"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    ShowInTaskbar="True"
    Background="#F5F4F0"
    FontFamily="Segoe UI"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="ActionButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="Background" Value="#FFFFFC"/>
            <Setter Property="BorderBrush" Value="#D8D5CD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#383631"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource ActionButtonStyle}">
            <Setter Property="Background" Value="#2E6F67"/>
            <Setter Property="BorderBrush" Value="#2E6F67"/>
            <Setter Property="Foreground" Value="White"/>
        </Style>
        <Style x:Key="DangerButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource ActionButtonStyle}">
            <Setter Property="Foreground" Value="#9A3F3F"/>
        </Style>
    </Window.Resources>

    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Codex Settings" FontSize="21" FontWeight="SemiBold" Foreground="#262522"/>

        <TabControl x:Name="ProviderTabs" Grid.Row="1" Margin="0,18,0,14">
            <TabItem Header="DeepSeek">
                <Grid Margin="16">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="DeepSeek API keys" FontSize="15" FontWeight="SemiBold" Foreground="#2E2D29"/>
                    <Grid Grid.Row="1" Margin="0,14,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Name" VerticalAlignment="Center" Foreground="#5A5750"/>
                        <TextBox x:Name="DeepSeekNameBox" Grid.Column="1" Height="30" Padding="8,5"/>
                    </Grid>
                    <Grid Grid.Row="2" Margin="0,8,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="API key" VerticalAlignment="Center" Foreground="#5A5750"/>
                        <PasswordBox x:Name="DeepSeekKeyBox" Grid.Column="1" Height="30" Padding="8,5"/>
                    </Grid>
                    <ListBox x:Name="DeepSeekList" Grid.Row="3" Margin="0,14,0,10" DisplayMemberPath="Display"/>
                    <StackPanel Grid.Row="4" Orientation="Horizontal">
                        <Button x:Name="DeepSeekNewButton" Content="New" Style="{StaticResource ActionButtonStyle}" Margin="0,0,8,0"/>
        <Button x:Name="DeepSeekSaveButton" Content="Save and use next start" Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="DeepSeekUseButton" Content="Use selected" Style="{StaticResource ActionButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="DeepSeekDeleteButton" Content="Delete" Style="{StaticResource DangerButtonStyle}"/>
                    </StackPanel>
                </Grid>
            </TabItem>
            <TabItem Header="OpenAI Transfer">
                <Grid Margin="16">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="OpenAI Transfer API keys" FontSize="15" FontWeight="SemiBold" Foreground="#2E2D29"/>
                    <Grid Grid.Row="1" Margin="0,14,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Name" VerticalAlignment="Center" Foreground="#5A5750"/>
                        <TextBox x:Name="TransferNameBox" Grid.Column="1" Height="30" Padding="8,5"/>
                    </Grid>
                    <Grid Grid.Row="2" Margin="0,8,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="API key" VerticalAlignment="Center" Foreground="#5A5750"/>
                        <PasswordBox x:Name="TransferKeyBox" Grid.Column="1" Height="30" Padding="8,5"/>
                    </Grid>
                    <ListBox x:Name="TransferList" Grid.Row="3" Margin="0,14,0,10" DisplayMemberPath="Display"/>
                    <StackPanel Grid.Row="4" Orientation="Horizontal">
                        <Button x:Name="TransferNewButton" Content="New" Style="{StaticResource ActionButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="TransferSaveButton" Content="Save and use next start" Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="TransferUseButton" Content="Use selected" Style="{StaticResource ActionButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="TransferDeleteButton" Content="Delete" Style="{StaticResource DangerButtonStyle}"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>

        <TextBlock x:Name="StatusText" Grid.Row="2" Text="Keys are encrypted for this Windows user. Keys in the same provider share its history and projects." Foreground="#6B6860" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <Button x:Name="CloseButton" Grid.Row="3" Content="Close" Width="86" Height="34" HorizontalAlignment="Right" Style="{StaticResource ActionButtonStyle}" IsDefault="True" IsCancel="True"/>
    </Grid>
</Window>
'@

$xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$statusText = $window.FindName('StatusText')
$closeButton = $window.FindName('CloseButton')
$closeButton.Add_Click({ $window.Close() }.GetNewClosure())

$controls = @{
    DeepSeek = @{
        List = $window.FindName('DeepSeekList')
        NameBox = $window.FindName('DeepSeekNameBox')
        KeyBox = $window.FindName('DeepSeekKeyBox')
        New = $window.FindName('DeepSeekNewButton')
        Save = $window.FindName('DeepSeekSaveButton')
        Use = $window.FindName('DeepSeekUseButton')
        Delete = $window.FindName('DeepSeekDeleteButton')
    }
    Transfer = @{
        List = $window.FindName('TransferList')
        NameBox = $window.FindName('TransferNameBox')
        KeyBox = $window.FindName('TransferKeyBox')
        New = $window.FindName('TransferNewButton')
        Save = $window.FindName('TransferSaveButton')
        Use = $window.FindName('TransferUseButton')
        Delete = $window.FindName('TransferDeleteButton')
    }
}

function Set-SettingsStatus {
    param([string]$Message, [bool]$Error = $false)
    $statusText.Text = $Message
    $statusText.Foreground = if ($Error) { '#9A3F3F' } else { '#6B6860' }
}

function Get-ListItem {
    param([string]$Provider)
    return $controls[$Provider].List.SelectedItem
}

function Clear-ProviderEditor {
    param([string]$Provider)
    $c = $controls[$Provider]
    $c.NameBox.Text = ''
    $c.KeyBox.Clear()
    $c.List.SelectedItem = $null
}

function Refresh-ProviderList {
    param([string]$Provider)
    $c = $controls[$Provider]
    $summaries = @(Get-CodexCredentialSummaries -Path $storePath -Provider $Provider)
    $items = @(
        $summaries | ForEach-Object {
            [pscustomobject]@{
                Id = $_.Id
                Name = $_.Name
                Display = if ($_.Active) {
                    $_.Name + '  (active)'
                }
                else {
                    $_.Name
                }
            }
        }
    )
    $c.List.ItemsSource = $null
    $c.List.ItemsSource = $items
}

function Save-ProviderKey {
    param([string]$Provider)
    $c = $controls[$Provider]
    $name = $c.NameBox.Text.Trim()
    $value = $c.KeyBox.Password
    $selected = Get-ListItem -Provider $Provider
    $id = if ($selected) { [string]$selected.Id } else { '' }
    try {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Enter a name for this key.'
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'Enter the API key.'
        }
        Save-CodexCredential `
            -Path $storePath `
            -Provider $Provider `
            -Name $name `
            -Value $value `
            -Id $id | Out-Null
        $c.KeyBox.Clear()
        Refresh-ProviderList -Provider $Provider
        Set-SettingsStatus -Message ($Provider + ' key saved. It will be used after Codex restarts.')
    }
    catch {
        Set-SettingsStatus -Message $_.Exception.Message -Error $true
    }
    finally {
        $value = $null
    }
}

function Use-ProviderKey {
    param([string]$Provider)
    $selected = Get-ListItem -Provider $Provider
    if (-not $selected) {
        Set-SettingsStatus -Message 'Select a saved key first.' -Error $true
        return
    }
    try {
        Set-CodexActiveCredential `
            -Path $storePath `
            -Provider $Provider `
            -Id ([string]$selected.Id)
        Refresh-ProviderList -Provider $Provider
        Set-SettingsStatus -Message ($Provider + ' active key changed. Restart Codex to use it.')
    }
    catch {
        Set-SettingsStatus -Message $_.Exception.Message -Error $true
    }
}

function Delete-ProviderKey {
    param([string]$Provider)
    $selected = Get-ListItem -Provider $Provider
    if (-not $selected) {
        Set-SettingsStatus -Message 'Select a saved key first.' -Error $true
        return
    }
    $choice = [System.Windows.MessageBox]::Show(
        ('Delete the saved key "' + [string]$selected.Name + '"?'),
        'Delete saved key',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }
    try {
        Remove-CodexCredential `
            -Path $storePath `
            -Provider $Provider `
            -Id ([string]$selected.Id)
        Refresh-ProviderList -Provider $Provider
        Clear-ProviderEditor -Provider $Provider
        Set-SettingsStatus -Message ($Provider + ' key deleted.')
    }
    catch {
        Set-SettingsStatus -Message $_.Exception.Message -Error $true
    }
}

foreach ($provider in @('DeepSeek', 'Transfer')) {
    $c = $controls[$provider]
    $providerName = $provider
    Refresh-ProviderList -Provider $provider
    $c.New.Add_Click({
        Clear-ProviderEditor -Provider $providerName
    }.GetNewClosure())
    $c.Save.Add_Click({
        Save-ProviderKey -Provider $providerName
    }.GetNewClosure())
    $c.Use.Add_Click({
        Use-ProviderKey -Provider $providerName
    }.GetNewClosure())
    $c.Delete.Add_Click({
        Delete-ProviderKey -Provider $providerName
    }.GetNewClosure())
    foreach ($button in @($c.New, $c.Save, $c.Use, $c.Delete)) {
        $button.Tag = $provider
    }
    $c.List.Add_SelectionChanged({
        param($sender, $eventArgs)
        $item = $sender.SelectedItem
        if ($item) {
            $controls[$providerName].NameBox.Text = [string]$item.Name
            $controls[$providerName].KeyBox.Clear()
        }
    }.GetNewClosure())
    $c.List.Tag = $provider
}

$window.Add_ContentRendered({
    $window.Activate()
}.GetNewClosure())

$window.ShowDialog() | Out-Null
