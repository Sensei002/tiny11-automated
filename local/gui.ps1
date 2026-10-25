<#
.SYNOPSIS
    Local GUI builder for every Tiny11 variant in this repository.

.DESCRIPTION
    A front-end for the same headless builders the CI runs. It collects the options
    the workflow form would collect, then runs prepare -> build -> export as one
    generated script and tails its output.

    Deliberately absent: SourceForge upload and Discord notifications. Both are
    workflow steps, not engine steps - the builders know nothing about either, so a
    local build simply does not include them.

    The GUI itself owns no build logic. Mapping a form onto builder parameters lives
    in local/lib.ps1, where tests can reach it without opening a window.

.PARAMETER Root
    Repository root. Defaults to the parent of this script's folder.

.PARAMETER Preset
    Variant id to preselect, e.g. 'core-gaming'. Deliberately not called -Variant:
    a type-constrained parameter of that name would collide with the
    `foreach ($variant in $profile.variants)` loops, coercing every variant object
    to a string.

.EXAMPLE
    .\local\gui.ps1
#>
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Preset = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

#---------[ Elevation ]---------#

# DISM mounting and offline servicing both need an elevated token, and there is no
# useful half-elevated mode: without it the build fails minutes in, after the ISO has
# already been downloaded. Ask for it up front instead.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Run this from a file so it can relaunch itself elevated."
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Root', $Root)
    if ($Preset) { $arguments += @('-Preset', $Preset) }

    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $shell -Verb RunAs -ArgumentList $arguments | Out-Null
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# A build runs 45-90 minutes of DISM work; letting the machine sleep halfway through
# leaves a half-serviced image behind.
Add-Type -Namespace Native -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction SilentlyContinue

$script:CanKeepAwake = $null -ne ('Native.Power' -as [type])

function Set-KeepAwake {
    param([bool]$On)
    if (-not $script:CanKeepAwake) { return }
    if ($On) {
        [Native.Power]::SetThreadExecutionState(0x80000001) | Out-Null
    } else {
        [Native.Power]::SetThreadExecutionState(0x80000000) | Out-Null
    }
}

$profile = Get-LocalBuildProfile -Path (Join-Path $Root 'config\local_build_profiles.json')
$workDir = Join-Path $env:LOCALAPPDATA 'tiny11-automated\work'
if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

#---------[ Window ]---------#

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Tiny11 Local Builder" Height="820" Width="1220" MinHeight="700" MinWidth="1040"
        WindowStartupLocation="CenterScreen" WindowStyle="None" Background="#0A0A0B"
        FontFamily="Segoe UI" UseLayoutRounding="True">

  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0"/>
  </shell:WindowChrome.WindowChrome>

  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#0A0A0B"/>
    <SolidColorBrush x:Key="Surface" Color="#0E0E10"/>
    <SolidColorBrush x:Key="Card" Color="#141417"/>
    <SolidColorBrush x:Key="Line" Color="#232328"/>
    <SolidColorBrush x:Key="Accent" Color="#E11D2E"/>
    <SolidColorBrush x:Key="AccentHover" Color="#FF2D3F"/>
    <SolidColorBrush x:Key="Ink" Color="#F2F2F4"/>
    <SolidColorBrush x:Key="Muted" Color="#8A8A93"/>
    <SolidColorBrush x:Key="Faint" Color="#5E5E66"/>

    <!-- Line heights are explicit so every line box is a whole number of pixels:
         under UseLayoutRounding a fractional box gets rounded, which makes row
         spacing jump between font sizes. -->
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="LineHeight" Value="30"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>

    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="18"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>

    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="LineHeight" Value="15"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="LineHeight" Value="18"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>

    <Style x:Key="FieldHelp" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="LineHeight" Value="16"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="26,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{StaticResource Accent}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Background" Value="#2A1116"/>
                <Setter Property="Foreground" Value="#7A5560"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnGhost" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Ink}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#3A3A40"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Width" Value="44"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1C1C21"/>
                <Setter Property="Foreground" Value="{StaticResource Ink}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="38" Height="20" CornerRadius="10" Background="#2A2A30" VerticalAlignment="Center">
                <Border x:Name="Knob" Width="16" Height="16" CornerRadius="8" Background="#8A8A93"
                        HorizontalAlignment="Left" Margin="2,0,0,0"/>
              </Border>
              <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
                <Setter TargetName="Knob" Property="Background" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TxtInput" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="ChoiceTemplate">
      <TextBlock Text="{Binding Label}" Foreground="{StaticResource Ink}" FontSize="12.5"
                 LineHeight="18" LineStackingStrategy="BlockLineHeight"/>
    </DataTemplate>

    <Style x:Key="ComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="B" Background="Transparent" CornerRadius="6" Margin="4,1">
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="B" Property="Background" Value="#2A1116"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ComboItem}"/>
      <!-- ItemTemplate, not DisplayMemberPath: with a custom ControlTemplate the
           selection box renders SelectionBoxItem, which only becomes readable when
           an ItemTemplate is what produces SelectionBoxItemTemplate. DisplayMemberPath
           leaves it as the raw object and the closed combo shows @{Label=...; Value=...}. -->
      <Setter Property="ItemTemplate" Value="{StaticResource ChoiceTemplate}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="B" Background="{StaticResource Card}" BorderBrush="{StaticResource Line}"
                            BorderThickness="1" CornerRadius="8">
                      <Path Data="M0,0 L4.5,4.5 L9,0" Stroke="#8A8A93" StrokeThickness="1.5"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="B" Property="BorderBrush" Value="#3A3A42"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="12,0,32,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Bottom" Focusable="False"
                     PopupAnimation="Fade" IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Background="#131316" BorderBrush="#2E2E34" BorderThickness="1" CornerRadius="8"
                        Margin="0,4,0,0" MinWidth="260" MaxHeight="300">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True" Margin="0,4"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#2E2E34" CornerRadius="4" Margin="1,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="46"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Grid x:Name="TitleBar" Grid.Row="0" Background="{StaticResource Surface}">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
        <Border Width="4" Height="18" Background="{StaticResource Accent}" CornerRadius="2"/>
        <TextBlock Text="TINY11" Foreground="{StaticResource Ink}" FontSize="13" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <TextBlock Text="LOCAL BUILDER" Foreground="{StaticResource Faint}" FontSize="11" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0">
        <Button x:Name="MinimiseButton" Style="{StaticResource TitleBtn}" Content="&#x2014;"/>
        <Button x:Name="CloseButton" Style="{StaticResource TitleBtn}" Content="&#x2715;"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="286"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="BUILD VARIANTS" Style="{StaticResource Section}" Margin="22,20,0,12"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,0,0,12">
            <StackPanel x:Name="VariantList" Margin="12,0"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="30,22,30,14">
          <TextBlock x:Name="VariantTitle" Style="{StaticResource H1}" Text=""/>
          <TextBlock x:Name="VariantDescription" Style="{StaticResource Body}" Margin="0,8,0,0" MaxWidth="820" HorizontalAlignment="Left"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="30,0,18,0">
          <StackPanel x:Name="SettingsHost" Margin="0,0,10,20"/>
        </ScrollViewer>

        <Border Grid.Row="2" x:Name="LogPanel" Background="#0B0B0D" BorderBrush="{StaticResource Line}"
                BorderThickness="1" CornerRadius="8" Margin="30,0,30,14" Height="172">
          <DockPanel>
            <Grid DockPanel.Dock="Top" Margin="14,10,10,0">
              <TextBlock Text="BUILD LOG" Style="{StaticResource Section}" Margin="0"/>
              <TextBlock x:Name="LogPathLabel" Foreground="{StaticResource Faint}" FontSize="10.5"
                         HorizontalAlignment="Right" TextTrimming="CharacterEllipsis" MaxWidth="380"/>
            </Grid>
            <TextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                     Foreground="#C9C9D2" FontFamily="Consolas" FontSize="11.5" Margin="10,6,4,8"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                     TextWrapping="NoWrap" AcceptsReturn="True"/>
          </DockPanel>
        </Border>

        <Border Grid.Row="3" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="30,14">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" VerticalAlignment="Center">
              <TextBlock x:Name="StatusText" Text="Ready" Foreground="{StaticResource Ink}" FontSize="12.5"/>
              <ProgressBar x:Name="Progress" Height="3" Margin="0,8,40,0" IsIndeterminate="True"
                           Visibility="Collapsed" Background="#1C1C21" BorderThickness="0">
                <ProgressBar.Foreground>
                  <SolidColorBrush Color="#E11D2E"/>
                </ProgressBar.Foreground>
              </ProgressBar>
            </StackPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="OpenFolderButton" Style="{StaticResource BtnGhost}" Content="Open folder" Margin="0,0,10,0" Visibility="Collapsed"/>
              <Button x:Name="CancelButton" Style="{StaticResource BtnGhost}" Content="Cancel" Margin="0,0,10,0" IsEnabled="False"/>
              <Button x:Name="BuildButton" Style="{StaticResource BtnPrimary}" Content="Build ISO"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$script:Window = $window

$controls = @{}
foreach ($name in 'TitleBar', 'MinimiseButton', 'CloseButton', 'VariantList', 'VariantTitle',
                  'VariantDescription', 'SettingsHost', 'LogBox', 'LogPathLabel', 'StatusText',
                  'Progress', 'BuildButton', 'CancelButton', 'OpenFolderButton', 'LogPanel') {
    $controls[$name] = $window.FindName($name)
}

$controls['TitleBar'].Add_MouseLeftButtonDown({ $script:Window.DragMove() })
$controls['MinimiseButton'].Add_Click({ $script:Window.WindowState = 'Minimized' })
$controls['CloseButton'].Add_Click({ if (-not $script:State.Building) { $script:Window.Close() } })

#---------[ State ]---------#

$script:State = @{
    Selected     = $null
    Fields       = @{}
    Groups       = @{}
    SourceDetail = @{}
    Building     = $false
    Process      = $null
    LogPath      = ''
    LogOffset    = 0
    Timer        = $null
    LastOutput   = ''
}

function Get-OptionalProperty {
    <#
    .SYNOPSIS
        Reads a property that the schema is allowed to omit.

    .DESCRIPTION
        Under Set-StrictMode, touching a property a PSCustomObject does not have
        throws. Only 'help' is optional in an input definition, but reading it
        directly would make the whole form fail to render for the inputs that leave
        it out.
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function New-Text {
    param([string]$Text, [string]$Style = 'Body', [double]$Top = 0)
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.Style = $window.Resources[$Style]
    $block.Margin = New-Object System.Windows.Thickness(0, $Top, 0, 0)
    return $block
}

function New-Combo {
    param([object[]]$Items, [string]$Selected)

    $combo = New-Object System.Windows.Controls.ComboBox
    $combo.Style = $window.Resources['Combo']
    $combo.ItemsSource = $Items
    $combo.SelectedValuePath = 'Value'
    if ($Selected) { $combo.SelectedValue = $Selected }
    if ($combo.SelectedIndex -lt 0 -and $Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    return $combo
}

function Get-ChoiceItems {
    param($Spec, $Profile)
    switch ($Spec.type) {
        'imageIndex'   { return @($Profile.imageIndexes | ForEach-Object { [pscustomobject]@{ Label = $_.label; Value = $_.value } }) }
        'language'     { return @($Profile.languages | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) }
        'ltscEdition'  { return @($Profile.ltscEditions | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) }
        default        { return @($Spec.options | ForEach-Object { [pscustomobject]@{ Label = $_.label; Value = $_.value } }) }
    }
}

function Get-FixedDrives {
    $drives = @()
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $drive.Root) { continue }
        $letter = $drive.Root.Substring(0, 1)
        if ($letter -notmatch '^[A-Za-z]$') { continue }
        $freeGb = 0
        try { $freeGb = [math]::Round($drive.Free / 1GB, 1) } catch { continue }
        $drives += [pscustomobject]@{
            Label = "$letter`:  -  $freeGb GB free"
            Value = $letter
            Free  = $freeGb
        }
    }
    return @($drives | Sort-Object Value)
}

function Add-Field {
    param($Element, [string]$Label, [string]$Help)
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 18)
    if ($Label) { $panel.Children.Add((New-Text -Text $Label -Style 'FieldLabel')) | Out-Null }
    $panel.Children.Add($Element) | Out-Null
    if ($Help) { $panel.Children.Add((New-Text -Text $Help -Style 'FieldHelp')) | Out-Null }
    return $panel
}

#---------[ Variant list ]---------#

function Show-Variant {
    param($Variant)

    $script:State.Selected = $Variant
    $script:State.Fields = @{}
    $script:State.Groups = @{}
    $script:State.SourceDetail = @{}

    $controls['VariantTitle'].Text = $Variant.label
    $controls['VariantDescription'].Text = $Variant.description

    Update-VariantCards

    $panelHost = $controls['SettingsHost']
    $panelHost.Children.Clear()

    # --- media source ---
    $panelHost.Children.Add((New-Text -Text 'WINDOWS MEDIA' -Style 'Section')) | Out-Null

    $allowed = @($profile.isoSources | ForEach-Object { $_.id })
    if ($Variant.PSObject.Properties['isoSources'] -and $Variant.isoSources) {
        $allowed = @($Variant.isoSources)
    }

    $sourceItems = @($profile.isoSources |
        Where-Object { $allowed -contains $_.id } |
        ForEach-Object { [pscustomobject]@{ Label = $_.label; Value = $_.id } })

    $sourceCombo = New-Combo -Items $sourceItems -Selected $profile.defaults.isoSource
    if (-not $sourceCombo.SelectedValue) { $sourceCombo.SelectedIndex = 0 }
    $script:State.Fields['isoSource'] = $sourceCombo
    $panelHost.Children.Add((Add-Field -Element $sourceCombo -Label 'ISO source')) | Out-Null

    $detailHost = New-Object System.Windows.Controls.StackPanel
    $detailHost.Margin = New-Object System.Windows.Thickness(0, -6, 0, 6)
    $panelHost.Children.Add($detailHost) | Out-Null
    $script:State.SourceDetail['Host'] = $detailHost

    $sourceCombo.Add_SelectionChanged({
        if ($script:State.Building) { return }
        Update-SourceDetail
    }.GetNewClosure())

    if ($Variant.PSObject.Properties['isoNote'] -and $Variant.isoNote) {
        $panelHost.Children.Add((New-Text -Text $Variant.isoNote -Style 'FieldHelp')) | Out-Null
        $panelHost.Children.Add((New-Object System.Windows.Controls.Border -Property @{ Height = 14 })) | Out-Null
    }

    # --- variant inputs ---
    $inputHeader = New-Text -Text 'BUILD OPTIONS' -Style 'Section'
    $inputHeader.Margin = New-Object System.Windows.Thickness(0, 12, 0, 10)
    $panelHost.Children.Add($inputHeader) | Out-Null

    foreach ($inputDef in $Variant.inputs) {
        $helpText = Get-OptionalProperty -Object $inputDef -Name 'help'
        switch ($inputDef.type) {
            'bool' {
                $check = New-Object System.Windows.Controls.CheckBox
                $check.Style = $window.Resources['Switch']
                $check.Content = $inputDef.label
                $check.IsChecked = [bool]$inputDef.default
                $script:State.Fields[$inputDef.key] = $check
                $panelHost.Children.Add((Add-Field -Element $check -Help $helpText)) | Out-Null
            }
            'group' {
                $header = New-Text -Text $inputDef.label.ToUpperInvariant() -Style 'Section'
                $header.Margin = New-Object System.Windows.Thickness(0, 8, 0, 10)
                $panelHost.Children.Add($header) | Out-Null

                $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
                $grid.Columns = 2
                $grid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)

                foreach ($group in $profile.gamingGroups) {
                    $check = New-Object System.Windows.Controls.CheckBox
                    $check.Style = $window.Resources['Switch']
                    $check.Content = $group.label
                    $check.IsChecked = [bool]$group.default
                    $check.Margin = New-Object System.Windows.Thickness(0, 0, 10, 14)
                    $check.ToolTip = $group.help
                    $script:State.Groups[$group.value] = $check
                    $grid.Children.Add($check) | Out-Null
                }
                $panelHost.Children.Add($grid) | Out-Null
                if ($helpText) { $panelHost.Children.Add((New-Text -Text $helpText -Style 'FieldHelp')) | Out-Null }
            }
            'text' {
                $box = New-Object System.Windows.Controls.TextBox
                $box.Style = $window.Resources['TxtInput']
                $box.Text = [string]$inputDef.default
                $script:State.Fields[$inputDef.key] = $box
                $panelHost.Children.Add((Add-Field -Element $box -Label $inputDef.label -Help $helpText)) | Out-Null
            }
            default {
                $combo = New-Combo -Items (Get-ChoiceItems -Spec $inputDef -Profile $profile) -Selected ([string]$inputDef.default)
                $script:State.Fields[$inputDef.key] = $combo
                $panelHost.Children.Add((Add-Field -Element $combo -Label $inputDef.label -Help $helpText)) | Out-Null
            }
        }
    }

    # --- update mode ---
    $updateHeader = New-Text -Text 'WINDOWS UPDATE' -Style 'Section'
    $updateHeader.Margin = New-Object System.Windows.Thickness(0, 14, 0, 10)
    $panelHost.Children.Add($updateHeader) | Out-Null

    $updateItems = @($profile.updateModes | ForEach-Object { [pscustomobject]@{ Label = $_.label; Value = $_.id } })
    $updateCombo = New-Combo -Items $updateItems -Selected $profile.defaults.updateMode
    $script:State.Fields['updateMode'] = $updateCombo
    $panelHost.Children.Add((Add-Field -Element $updateCombo -Label 'Cumulative update' -Help ($profile.updateModes | Where-Object { $_.id -eq $updateCombo.SelectedValue } | Select-Object -First 1).help)) | Out-Null

    $updateHelp = New-Object System.Windows.Controls.TextBlock
    $updateHelp.Style = $window.Resources['FieldHelp']
    $updateHelp.Margin = New-Object System.Windows.Thickness(0, -12, 0, 18)
    $updateHelp.TextWrapping = 'Wrap'
    $panelHost.Children.Add($updateHelp) | Out-Null
    $script:State.SourceDetail['UpdateHelp'] = $updateHelp
    Update-UpdateHelp
    $updateCombo.Add_SelectionChanged({ if (-not $script:State.Building) { Update-UpdateHelp } }.GetNewClosure())

    # --- output ---
    $outputHeader = New-Text -Text 'OUTPUT' -Style 'Section'
    $outputHeader.Margin = New-Object System.Windows.Thickness(0, 8, 0, 10)
    $panelHost.Children.Add($outputHeader) | Out-Null

    # Default to the roomiest fixed disk rather than whatever sorts first: the
    # scratch image alone is 25 GB, and C: is usually the smallest.
    $driveItems = Get-FixedDrives
    $defaultScratch = [string]$profile.defaults.scratchDrive
    if (-not $defaultScratch) {
        $roomiest = @($driveItems | Sort-Object -Property Free -Descending | Select-Object -First 1)
        if ($roomiest.Count -gt 0) { $defaultScratch = $roomiest[0].Value }
    }

    $scratchCombo = New-Combo -Items $driveItems -Selected $defaultScratch
    $script:State.Fields['scratchDrive'] = $scratchCombo
    $panelHost.Children.Add((Add-Field -Element $scratchCombo -Label 'Scratch drive' -Help 'Needs about 25 GB. The image is staged and mounted here, so pick a roomy disk.')) | Out-Null

    $outputRow = New-Object System.Windows.Controls.Grid
    $outputRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
    $colA = New-Object System.Windows.Controls.ColumnDefinition
    $colA.Width = New-Object System.Windows.GridLength(1, 'Star')
    $colB = New-Object System.Windows.Controls.ColumnDefinition
    $colB.Width = New-Object System.Windows.GridLength(0, 'Auto')
    $outputRow.ColumnDefinitions.Add($colA)
    $outputRow.ColumnDefinitions.Add($colB)

    $outputBox = New-Object System.Windows.Controls.TextBox
    $outputBox.Style = $window.Resources['TxtInput']
    $outputBox.Text = [Environment]::ExpandEnvironmentVariables([string]$profile.defaults.outputDir)
    $outputBox.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    [System.Windows.Controls.Grid]::SetColumn($outputBox, 0)
    $outputRow.Children.Add($outputBox) | Out-Null

    $browse = New-Object System.Windows.Controls.Button
    $browse.Style = $window.Resources['BtnGhost']
    $browse.Content = 'Browse'
    [System.Windows.Controls.Grid]::SetColumn($browse, 1)
    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Where should the finished ISO go?'
        if ($dialog.ShowDialog() -eq 'OK') { $script:State.Fields['outputDir'].Text = $dialog.SelectedPath }
    }.GetNewClosure())
    $outputRow.Children.Add($browse) | Out-Null

    $script:State.Fields['outputDir'] = $outputBox
    $panelHost.Children.Add((Add-Field -Element $outputRow -Label 'Save ISO to' -Help 'Checksums are written alongside. Cross-drive moves copy the whole file, so the same drive as the scratch disk is fastest.')) | Out-Null

    Update-SourceDetail
}

function Update-VariantCards {
    # Each child is itself the Border card; reading .Child here would style the
    # StackPanel inside it and leave the card looking untouched.
    $accent = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E11D2E')
    $idleLine = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#232328')
    $idleFill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#141417')
    $activeFill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1A0F12')

    foreach ($card in @($controls['VariantList'].Children)) {
        if ([string]$card.Tag -eq $script:State.Selected.id) {
            $card.Background = $activeFill
            $card.BorderBrush = $accent
        } else {
            $card.Background = $idleFill
            $card.BorderBrush = $idleLine
        }
    }
}

function Update-UpdateHelp {
    $combo = $script:State.Fields['updateMode']
    $label = $script:State.SourceDetail['UpdateHelp']
    if (-not $combo -or -not $label) { return }
    $mode = $profile.updateModes | Where-Object { $_.id -eq $combo.SelectedValue } | Select-Object -First 1
    if ($mode) { $label.Text = $mode.help }
}

function Update-SourceDetail {
    $panelHost = $script:State.SourceDetail['Host']
    if (-not $panelHost) { return }
    $panelHost.Children.Clear()
    $script:State.SourceDetail.Remove('IsoPath')
    $script:State.SourceDetail.Remove('MountedDrive')

    $source = $script:State.Fields['isoSource'].SelectedValue

    if ($source -eq 'file') {
        $row = New-Object System.Windows.Controls.Grid
        $colA = New-Object System.Windows.Controls.ColumnDefinition
        $colA.Width = New-Object System.Windows.GridLength(1, 'Star')
        $colB = New-Object System.Windows.Controls.ColumnDefinition
        $colB.Width = New-Object System.Windows.GridLength(0, 'Auto')
        $row.ColumnDefinitions.Add($colA)
        $row.ColumnDefinitions.Add($colB)

        $box = New-Object System.Windows.Controls.TextBox
        $box.Style = $window.Resources['TxtInput']
        $box.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        [System.Windows.Controls.Grid]::SetColumn($box, 0)
        $row.Children.Add($box) | Out-Null

        $browse = New-Object System.Windows.Controls.Button
        $browse.Style = $window.Resources['BtnGhost']
        $browse.Content = 'Choose ISO'
        [System.Windows.Controls.Grid]::SetColumn($browse, 1)
        $browse.Add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Windows ISO (*.iso)|*.iso|All files (*.*)|*.*'
            if ($dialog.ShowDialog() -eq 'OK') { $script:State.SourceDetail['IsoPath'].Text = $dialog.FileName }
        }.GetNewClosure())
        $row.Children.Add($browse) | Out-Null

        $script:State.SourceDetail['IsoPath'] = $box
        $panelHost.Children.Add((Add-Field -Element $row -Label 'ISO file')) | Out-Null
        return
    }

    if ($source -eq 'mounted') {
        $drives = @()
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $drive.Root) { continue }
            $letter = $drive.Root.Substring(0, 1)
            if (Test-Path -LiteralPath "${letter}:\sources") {
                $drives += [pscustomobject]@{ Label = "$letter`:  -  Windows media"; Value = $letter }
            }
        }

        if ($drives.Count -eq 0) {
            $panelHost.Children.Add((New-Text -Text 'No mounted Windows media found. Mount an ISO first, or choose another source.' -Style 'FieldHelp')) | Out-Null
            return
        }

        $combo = New-Combo -Items $drives -Selected $drives[0].Value
        $script:State.SourceDetail['MountedDrive'] = $combo
        $panelHost.Children.Add((Add-Field -Element $combo -Label 'Mounted drive')) | Out-Null
        return
    }

    $panelHost.Children.Add((New-Text -Text 'A fresh signed link is minted at build time. Expect roughly 5.8 GB.' -Style 'FieldHelp')) | Out-Null
}

#---------[ Building ]---------#

function Set-Busy {
    param([bool]$Busy)
    $script:State.Building = $Busy
    $controls['BuildButton'].IsEnabled = -not $Busy
    $controls['CancelButton'].IsEnabled = $Busy
    if ($Busy) {
        $controls['Progress'].Visibility = 'Visible'
    } else {
        $controls['Progress'].Visibility = 'Collapsed'
    }
}

function Read-LogChunk {
    if (-not $script:State.LogPath) { return '' }
    if (-not (Test-Path -LiteralPath $script:State.LogPath)) { return '' }

    try {
        $stream = [System.IO.File]::Open($script:State.LogPath, 'Open', 'Read', 'ReadWrite')
    } catch {
        return ''
    }

    try {
        if ($stream.Length -le $script:State.LogOffset) { return '' }
        $stream.Position = $script:State.LogOffset
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $script:State.LogOffset = $stream.Position
        return $text
    } finally {
        $stream.Dispose()
    }
}

function Update-Log {
    $chunk = Read-LogChunk
    if (-not $chunk) { return }
    $controls['LogBox'].AppendText($chunk)
    $controls['LogBox'].ScrollToEnd()
    $script:State.LastOutput += $chunk
}

function Complete-Build {
    $script:State.Timer.Stop()
    Update-Log

    $code = -1
    try { $code = $script:State.Process.ExitCode } catch { $code = -1 }

    Set-KeepAwake -On $false
    Set-Busy $false

    if ($code -eq 0) {
        $controls['StatusText'].Text = 'Build complete'
        $controls['OpenFolderButton'].Visibility = 'Visible'
        $controls['OpenFolderButton'].Tag = $script:State.Fields['outputDir'].Text
    } else {
        $controls['StatusText'].Text = "Build failed (exit $code) - see the log above"
        $controls['OpenFolderButton'].Visibility = 'Collapsed'
    }
}

function Start-Build {
    $variant = $script:State.Selected
    if (-not $variant) { return }

    $source = $script:State.Fields['isoSource'].SelectedValue
    $scratch = [string]$script:State.Fields['scratchDrive'].SelectedValue
    $outputDir = $script:State.Fields['outputDir'].Text
    $updateMode = [string]$script:State.Fields['updateMode'].SelectedValue

    if (-not $scratch) { [System.Windows.MessageBox]::Show('Pick a scratch drive.', 'Tiny11'); return }
    if ([string]::IsNullOrWhiteSpace($outputDir)) { [System.Windows.MessageBox]::Show('Pick an output folder.', 'Tiny11'); return }

    $free = 0
    try { $free = [math]::Round((Get-PSDrive -Name $scratch -ErrorAction Stop).Free / 1GB, 1) } catch { $free = 0 }
    if ($free -gt 0 -and $free -lt 25) {
        $answer = [System.Windows.MessageBox]::Show(
            "Drive ${scratch}: has only $free GB free. A build needs about 25 GB.`n`nContinue anyway?",
            'Not much room', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    $isoPath = ''
    $mountedDrive = ''
    if ($source -eq 'file') {
        $isoPath = $script:State.SourceDetail['IsoPath'].Text
        if ([string]::IsNullOrWhiteSpace($isoPath) -or -not (Test-Path -LiteralPath $isoPath)) {
            [System.Windows.MessageBox]::Show('Choose an ISO file that exists.', 'Tiny11'); return
        }
    } elseif ($source -eq 'mounted') {
        if (-not $script:State.SourceDetail.ContainsKey('MountedDrive')) {
            [System.Windows.MessageBox]::Show('No mounted Windows media found.', 'Tiny11'); return
        }
        $mountedDrive = [string]$script:State.SourceDetail['MountedDrive'].SelectedValue
    }

    # Gather every value the variant can map, then let lib decide which are used.
    $context = @{
        isoDrive             = ''
        image_index          = '1'
        scratchDrive         = $scratch
        skip_cleanup         = $false
        enable_dotnet35      = $false
        remove_defender      = $false
        account_setup        = 'auto-admin'
        hags                 = 'on'
        ltsc_edition         = ''
        gaming_groups        = @{}
        updateToLatest       = $false
        requireLatestUpdate  = $false
    }

    foreach ($key in $script:State.Fields.Keys) {
        if ($key -in 'isoSource', 'scratchDrive', 'outputDir', 'updateMode') { continue }
        $control = $script:State.Fields[$key]
        if ($control -is [System.Windows.Controls.CheckBox]) {
            $context[$key] = [bool]$control.IsChecked
        } elseif ($control -is [System.Windows.Controls.TextBox]) {
            $context[$key] = $control.Text
        } elseif ($control -is [System.Windows.Controls.ComboBox]) {
            $context[$key] = [string]$control.SelectedValue
        }
    }

    if ($script:State.Groups.Count -gt 0) {
        $groups = @{}
        foreach ($name in $script:State.Groups.Keys) {
            $groups[$name] = [bool]$script:State.Groups[$name].IsChecked
        }
        $context['gaming_groups'] = $groups
    }

    $flags = Get-UpdateModeFlags -Profile $profile -Mode $updateMode
    $context['updateToLatest'] = $flags.UpdateToLatest
    $context['requireLatestUpdate'] = $flags.RequireLatestUpdate

    if ($variant.PSObject.Properties['inputs'] -and (Get-VariantInput -Variant $variant -Key 'ltsc_edition')) {
        try {
            $context['image_index'] = Get-LtscIndexHint -Edition $context['ltsc_edition'] `
                -CatalogPath (Join-Path $Root 'scripts\ltsc-edition-catalog.ps1')
        } catch {
            [System.Windows.MessageBox]::Show("Could not resolve the LTSC edition: $($_.Exception.Message)", 'Tiny11')
            return
        }
    }

    try {
        $arguments = New-BuilderArguments -Variant $variant -Context $context
    } catch {
        [System.Windows.MessageBox]::Show("Could not assemble the build: $($_.Exception.Message)", 'Tiny11')
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $scriptPath = Join-Path $workDir "build-$($variant.id)-$stamp.ps1"
    $launcherPath = Join-Path $workDir "build-$($variant.id)-$stamp-params.ps1"
    $logPath = Join-Path $workDir "build-$($variant.id)-$stamp.log"

    $builderPath = Join-Path $Root ($variant.builder -replace '/', '\')
    $outputIsoPath = Join-Path (Split-Path -Parent $builderPath) $variant.outputIso

    $language = ''
    if ($context.ContainsKey('language')) { $language = [string]$context['language'] }

    $plan = @{
        RepoRoot            = $Root
        Source              = $source
        ScratchRoot         = "${scratch}:\"
        OutputDir           = $outputDir
        BuilderPath         = $builderPath
        BuiltIsoPath        = $outputIsoPath
        SourceIsoPath       = $isoPath
        UpdateMode          = $updateMode
        Language            = $language
        MountedDrive        = $mountedDrive
        LauncherPath        = $launcherPath
        Arguments           = $arguments
    }

    try {
        # Two files: the orchestrator, and the parameter splat it hands to a child
        # process. The builders exit the host, so they cannot run in-process.
        ConvertTo-LauncherScript -Variant $variant -Arguments $arguments `
            -BuilderPath $builderPath -ScriptPath $launcherPath | Out-Null
        ConvertTo-PipelineScript -Variant $variant -Plan $plan -ScriptPath $scriptPath | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Could not write the build script: $($_.Exception.Message)", 'Tiny11')
        return
    }

    $controls['LogBox'].Clear()
    $controls['LogPathLabel'].Text = Split-Path -Leaf $logPath
    $script:State.LogPath = $logPath
    $script:State.LogOffset = 0
    $script:State.LastOutput = ''

    Set-KeepAwake -On $true

    $pwsh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $proc = Start-Process $pwsh -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath
    ) -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" -NoNewWindow -PassThru

    $script:State.Process = $proc
    Set-Busy $true
    $controls['StatusText'].Text = "Building $($variant.label)..."
    $controls['OpenFolderButton'].Visibility = 'Collapsed'

    $script:State.Timer.Start()
}

#---------[ Wiring ]---------#

foreach ($variant in $profile.variants) {
    $card = New-Object System.Windows.Controls.Border
    # Tag carries the variant id: WPF's Name property rejects anything that is not a
    # valid identifier, and 'core-gaming' is not one.
    $card.Tag = $variant.id
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#141417')
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#232328')
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $card.Padding = New-Object System.Windows.Thickness(14, 12, 14, 12)
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $card.Cursor = 'Hand'

    $stack = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $variant.label
    $title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F2F2F4')
    $title.FontSize = 13
    $title.FontWeight = 'SemiBold'
    $title.TextWrapping = 'Wrap'
    $stack.Children.Add($title) | Out-Null

    $subtitle = New-Object System.Windows.Controls.TextBlock
    $subtitle.Text = $variant.subtitle
    $subtitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#8A8A93')
    $subtitle.FontSize = 11
    $subtitle.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
    $stack.Children.Add($subtitle) | Out-Null

    $card.Child = $stack
    $id = $variant.id
    $card.Add_MouseLeftButtonUp({ if (-not $script:State.Building) { Show-Variant (Get-BuildVariant -Profile $profile -Id $id) } }.GetNewClosure())
    $controls['VariantList'].Children.Add($card) | Out-Null
}

$controls['BuildButton'].Add_Click({ Start-Build })
$controls['CancelButton'].Add_Click({
    if (-not $script:State.Process) { return }
    $answer = [System.Windows.MessageBox]::Show(
        'Cancel the build? Any mounted image is left behind and the ISO is discarded.',
        'Cancel build', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    # Kill the tree, not just the orchestrator: the builder is its child, and
    # killing the parent alone would leave a DISM run going with no window to
    # cancel it from.
    try { & taskkill.exe /PID $script:State.Process.Id /T /F 2>&1 | Out-Null } catch { }
    $controls['StatusText'].Text = 'Cancelling...'
    $script:State.Timer.Stop()
    Set-Busy $false
    Set-KeepAwake -On $false
})
$controls['OpenFolderButton'].Add_Click({
    $target = [string]$controls['OpenFolderButton'].Tag
    if ($target -and (Test-Path -LiteralPath $target)) { Start-Process explorer.exe $target }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    Update-Log
    if ($script:State.Process -and $script:State.Process.HasExited) { Complete-Build }
})
$script:State.Timer = $timer

$initial = $profile.variants[0]
if ($Preset) {
    $wanted = $profile.variants | Where-Object { $_.id -eq $Preset } | Select-Object -First 1
    if ($wanted) { $initial = $wanted }
}
Show-Variant $initial

$window.Add_Loaded({ $window.Activate() })
[void]$window.ShowDialog()
