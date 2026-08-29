# AgentContinuity-Ui.ps1 — 편의성 UI (Windows / WPF).
# 검증된 launcher 스크립트를 자식 pwsh 로 실행하는 얇은 껍데기다: 모든 안전
# 규칙(사전 검사, lease, secret scan, fail-closed)은 launcher/core 가 그대로
# 수행하고, UI 는 상태 표시·버튼·로그·예외 안내만 담당한다 (plan §3).
#
# 실행: pwsh -ExecutionPolicy Bypass -File ui\AgentContinuity-Ui.ps1
# (가상/보조 기기는 AGENT_CONTINUITY_HOME 을 설정한 창에서 실행하면 그대로 상속)

param([string] $ProjectName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AcRoot = Split-Path -Parent $PSScriptRoot
foreach ($m in @('Common', 'Lease', 'Transaction')) {
    Import-Module (Join-Path $script:AcRoot "core/$m.psm1") -Force -DisableNameChecking
}

if (-not $IsWindows) {
    Write-Host (Get-AcText 'ui.windowsOnly')
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Expand-AcXamlText {
    # XAML 안의 %key% 자리를 현재 언어의 리소스 문자열(XML 이스케이프 적용)로
    # 치환한다. 라벨을 코드가 아닌 리소스에서 가져오기 위한 전처리다 (D3 i18n).
    param([Parameter(Mandatory)][string] $Xaml)
    [regex]::Replace($Xaml, '%([a-zA-Z][a-zA-Z0-9.]*)%', {
        param($m)
        [System.Security.SecurityElement]::Escape((Get-AcText $m.Groups[1].Value))
    })
}

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Agent Continuity" Width="760" Height="660" MinWidth="620" MinHeight="520"
        WindowStartupLocation="CenterScreen" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="%ui.main.targetProject%" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <Button x:Name="BtnRefresh" Content="%ui.main.refresh%" DockPanel.Dock="Right" Padding="10,4" Margin="8,0,0,0"/>
      <ComboBox x:Name="CmbProject" VerticalAlignment="Center"/>
    </DockPanel>

    <Border Grid.Row="1" BorderBrush="#CCCCCC" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,8" Background="#F7F7F7">
      <TextBlock x:Name="TxtStatus" TextWrapping="Wrap" FontFamily="Consolas" Text="%ui.main.loading%"/>
    </Border>

    <Border Grid.Row="2" x:Name="Banner" CornerRadius="4" Padding="10,6" Margin="0,0,0,8" Background="#EEEEEE">
      <TextBlock x:Name="TxtBanner" Text="%ui.main.ready%" FontWeight="Bold"/>
    </Border>

    <TextBox Grid.Row="3" x:Name="TxtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             TextWrapping="NoWrap" Background="#1E1E1E" Foreground="#DDDDDD"/>

    <UniformGrid Grid.Row="4" Rows="3" Columns="3" Margin="0,10,0,0">
      <Button x:Name="BtnStart" Content="%ui.btn.start%" Height="40" Margin="0,0,6,6" FontWeight="Bold"/>
      <Button x:Name="BtnFinish" Content="%ui.btn.finish%" Height="40" Margin="0,0,6,6" FontWeight="Bold"/>
      <Button x:Name="BtnRecover" Content="%ui.btn.recover%" Height="40" Margin="0,0,0,6"/>
      <Button x:Name="BtnAddProject" Content="%ui.btn.addProject%" Height="40" Margin="0,0,6,6"/>
      <Button x:Name="BtnMoveWorktree" Content="%ui.btn.moveWorktree%" Height="40" Margin="0,0,6,6"/>
      <Button x:Name="BtnEditProfile" Content="%ui.btn.editProfile%" Height="40" Margin="0,0,0,6"/>
      <Button x:Name="BtnTray" Content="%ui.btn.tray%" Height="40"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$recoverXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%ui.recover.title%" Width="520" Height="300" WindowStartupLocation="CenterOwner" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="%ui.recover.action%" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="CmbAction"/>
    </DockPanel>
    <DockPanel Grid.Row="1" Margin="0,0,0,8">
      <TextBlock Text="%ui.recover.backupFile%" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <Button x:Name="BtnBrowse" Content="%ui.btn.browse%" DockPanel.Dock="Right" Padding="10,2" Margin="8,0,0,0"/>
      <TextBox x:Name="TxtBackup"/>
    </DockPanel>
    <CheckBox Grid.Row="2" x:Name="ChkForce" Content="%ui.recover.forceLabel%" Margin="0,0,0,8"/>
    <TextBlock Grid.Row="3" TextWrapping="Wrap" Foreground="#666666"
               Text="%ui.recover.help%"/>
    <UniformGrid Grid.Row="4" Columns="2">
      <Button x:Name="BtnRun" Content="%ui.btn.run%" Height="34" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnClose" Content="%ui.btn.close%" Height="34"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$projectXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%ui.project.title%" Width="560" Height="420" WindowStartupLocation="CenterOwner" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="130"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="%ui.project.machine%" VerticalAlignment="Center"/>
    <TextBox x:Name="TxtMachine" Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,2"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="%ui.project.vault%" VerticalAlignment="Center"/>
    <TextBox x:Name="TxtVault" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,2"/>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="%ui.project.name%" VerticalAlignment="Center"/>
    <TextBox x:Name="TxtName" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,2"/>
    <TextBlock Grid.Row="3" Grid.Column="0" Text="%ui.project.remote%" VerticalAlignment="Center"/>
    <TextBox x:Name="TxtRemote" Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,2"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Text="%ui.project.agent%" VerticalAlignment="Center"/>
    <ComboBox x:Name="CmbAgent" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,2"/>
    <TextBlock Grid.Row="5" Grid.Column="0" Text="%ui.project.path%" VerticalAlignment="Center"/>
    <TextBox x:Name="TxtPath" Grid.Row="5" Grid.Column="1" Margin="0,2"/>
    <Button x:Name="BtnPickPath" Grid.Row="5" Grid.Column="2" Content="%ui.btn.browse%" Padding="10,2" Margin="6,2,0,2"/>
    <TextBlock Grid.Row="6" Grid.ColumnSpan="3" TextWrapping="Wrap" Foreground="#666666" Margin="0,8"
               Text="%ui.project.pathHelp%"/>
    <UniformGrid Grid.Row="7" Grid.ColumnSpan="3" Columns="2">
      <Button x:Name="BtnOk" Content="%ui.btn.register%" Height="34" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnCancel" Content="%ui.btn.cancel%" Height="34"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$profileXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%ui.profile.title%" Width="560" Height="520" WindowStartupLocation="CenterOwner" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="%ui.profile.allowedLabel%" Margin="0,0,0,4"/>
    <TextBox Grid.Row="1" x:Name="TxtAllowed" AcceptsReturn="True" FontFamily="Consolas"
             VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,0,0,8"/>
    <TextBlock Grid.Row="2" Text="%ui.profile.excludedLabel%" Margin="0,0,0,4"/>
    <TextBox Grid.Row="3" x:Name="TxtExcluded" AcceptsReturn="True" FontFamily="Consolas"
             VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,0,0,8"/>
    <CheckBox Grid.Row="4" x:Name="ChkTrackedOnly" Content="%ui.profile.trackedOnlyLabel%" Margin="0,0,0,8"/>
    <DockPanel Grid.Row="5" Margin="0,0,0,8">
      <TextBlock Text="%ui.profile.maxBytesLabel%" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="TxtMaxBytes" FontFamily="Consolas"/>
    </DockPanel>
    <TextBlock Grid.Row="6" TextWrapping="Wrap" Foreground="#666666" Margin="0,0,0,8"
               Text="%ui.profile.help%"/>
    <UniformGrid Grid.Row="7" Columns="2">
      <Button x:Name="BtnSave" Content="%ui.btn.save%" Height="34" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnCancel" Content="%ui.btn.cancel%" Height="34"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse((Expand-AcXamlText $xaml))
foreach ($name in @('CmbProject', 'BtnRefresh', 'TxtStatus', 'Banner', 'TxtBanner', 'TxtLog', 'BtnStart', 'BtnFinish', 'BtnRecover', 'BtnAddProject', 'BtnMoveWorktree', 'BtnEditProfile', 'BtnTray')) {
    Set-Variable -Name $name -Value $window.FindName($name)
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Set-Banner {
    param([ValidateSet('green', 'red', 'yellow', 'gray')] [string] $Color, [string] $Text)
    $bg = switch ($Color) { 'green' { '#DFF6DD' } 'red' { '#FDE7E9' } 'yellow' { '#FFF4CE' } default { '#EEEEEE' } }
    $Banner.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($bg)
    $TxtBanner.Text = $Text
}

function Get-SelectedProject {
    $config = Get-AcConfig
    if (-not $config) { return $null }
    $config.projects | Where-Object { $_.name -eq [string]$CmbProject.SelectedItem }
}

function Get-ProjectStatusLine {
    # 한 프로젝트의 한 줄 요약: 병렬로 여러 worktree 를 감시하는 뷰의 행.
    param([Parameter(Mandatory)] $Project)
    try {
        $leaseInfo = Get-AcLease -ProjectId $Project.projectId
        $leaseText = Get-AcText 'ui.status.idle'
        if ($leaseInfo.Lease -and $leaseInfo.Lease.state -eq 'active') {
            $expired = if (Test-AcLeaseExpired -Lease $leaseInfo.Lease) { Get-AcText 'ui.status.expiredSuffix' } else { '' }
            $leaseText = Get-AcText 'ui.status.working' @($leaseInfo.Lease.machineId, $expired)
        }
        $keeper = if (Test-AcKeeperAlive -ProjectId $Project.projectId) { '●' } else { '○' }
        $lastTx = Get-AcLastTransaction -ProjectId $Project.projectId
        $gen = if ($lastTx.Record) { "gen=$($lastTx.Record.generation)" } else { Get-AcText 'ui.status.initial' }
        $sessionMark = if ([bool]$Project.allowSessionSnapshot) { Get-AcText 'ui.status.sessionSync' @($Project.agent) } else { '' }
        return "[$($Project.name)] $leaseText · keeper $keeper · $gen$sessionMark"
    } catch {
        return (Get-AcText 'ui.status.error' @($Project.name, $_))
    }
}

function Update-StatusPanel {
    $config = Get-AcConfig
    if (-not $config -or @($config.projects).Count -eq 0) {
        $TxtStatus.Text = Get-AcText 'ui.status.noProjects'
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-AcText 'ui.status.machineHeader' @($config.machineId, @($config.projects).Count)))
    foreach ($p in @($config.projects)) { $lines.Add('  ' + (Get-ProjectStatusLine -Project $p)) }

    $project = Get-SelectedProject
    if ($project) {
        $lines.Add('')
        $lines.Add((Get-AcText 'ui.status.detailHeader' @($project.name)))
        $lines.Add("worktree: $($project.worktreePath)")
        try {
            $lastTx = Get-AcLastTransaction -ProjectId $project.projectId
            if ($lastTx.Record) {
                $lines.Add((Get-AcText 'ui.status.lastTx' @($lastTx.Record.generation, $lastTx.Record.sourceMachineId)))
            } else { $lines.Add((Get-AcText 'ui.status.lastTxNone')) }
            if (Test-Path (Join-Path $project.worktreePath '.git')) {
                $dirty = @((Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('status', '--porcelain')).Output | Where-Object { $_ })
                $lines.Add((Get-AcText 'ui.status.dirty' @($dirty.Count)))
            }
        } catch { $lines.Add((Get-AcText 'ui.status.detailError' @($_))) }
    }
    $TxtStatus.Text = ($lines -join "`n")
}

# --- async launcher runner --------------------------------------------------

$script:OutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:CurrentProc = $null
$script:RunningLabel = ''
$script:AfterExit = $null

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $line = $null
    while ($script:OutQueue.TryDequeue([ref]$line)) {
        $TxtLog.AppendText($line + "`r`n")
    }
    $TxtLog.ScrollToEnd()
    if ($script:CurrentProc -and $script:CurrentProc.HasExited) {
        $code = $script:CurrentProc.ExitCode
        $script:CurrentProc = $null
        $timer.Stop()
        foreach ($b in @($BtnStart, $BtnFinish, $BtnRecover, $BtnRefresh, $BtnAddProject, $BtnMoveWorktree, $BtnEditProfile)) { $b.IsEnabled = $true }
        if ($code -eq 0) { Set-Banner green (Get-AcText 'ui.run.done' @($script:RunningLabel)) }
        else { Set-Banner red (Get-AcText 'ui.run.aborted' @($script:RunningLabel, $code)) }
        if ($script:AfterExit) {
            $cb = $script:AfterExit; $script:AfterExit = $null
            try { & $cb $code } catch { Write-AcLog -Level WARN -Message (Get-AcText 'ui.warn.postProcess' @($_)) }
        }
        Update-StatusPanel
    }
})

function Start-LauncherProcess {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $ScriptRel,
        [string[]] $Arguments = @(),
        [switch] $NoProject,          # Setup 등 프로젝트 선택과 무관한 스크립트
        [scriptblock] $OnExit         # 종료 코드(int)를 받아 UI 후처리
    )
    if ($script:CurrentProc) { return }
    $fullArgs = $Arguments
    if (-not $NoProject) {
        $project = Get-SelectedProject
        if (-not $project) { Set-Banner red (Get-AcText 'ui.selectProject'); return }
        $fullArgs = @('-ProjectName', $project.name) + $Arguments
    }
    $TxtLog.Clear()
    Set-Banner yellow (Get-AcText 'ui.run.running' @($Label))
    $script:RunningLabel = $Label
    $script:AfterExit = $OnExit
    foreach ($b in @($BtnStart, $BtnFinish, $BtnRecover, $BtnRefresh, $BtnAddProject, $BtnMoveWorktree, $BtnEditProfile)) { $b.IsEnabled = $false }

    # 한국어 Windows 의 기본 콘솔 코드페이지(CP949)로 인한 로그 깨짐 방지:
    # 자식 pwsh 가 UTF-8 로 출력하도록 -Command 래퍼에서 인코딩을 고정한다.
    $scriptPath = Join-Path $script:AcRoot $ScriptRel
    $quotedArgs = foreach ($a in $fullArgs) {
        if ($a -like '-*') { $a } else { "'" + ($a -replace "'", "''") + "'" }
    }
    $inner = "`$PSStyle.OutputRendering='PlainText'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
        "& '" + ($scriptPath -replace "'", "''") + "' " + ($quotedArgs -join ' ') + "; exit `$LASTEXITCODE"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $inner)) {
        $psi.ArgumentList.Add($a)
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $queue = $script:OutQueue
    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $queue -Action {
        if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    } | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $queue -Action {
        if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    } | Out-Null
    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:CurrentProc = $proc
    $timer.Start()
}

# ---------------------------------------------------------------------------
# recovery center dialog
# ---------------------------------------------------------------------------

function Show-RecoveryDialog {
    $dlg = [Windows.Markup.XamlReader]::Parse((Expand-AcXamlText $recoverXaml))
    $dlg.Owner = $window
    $cmbAction = $dlg.FindName('CmbAction')
    $txtBackup = $dlg.FindName('TxtBackup')
    $chkForce = $dlg.FindName('ChkForce')
    foreach ($a in @('LeaseInfo', 'PreserveOrphan', 'BackToLastTransaction', 'ReleaseRetry', 'Diagnostics', 'Takeover', 'ListBackups', 'VerifyBackup', 'RestoreBackup', 'NewRescueBundle')) {
        $cmbAction.Items.Add($a) | Out-Null
    }
    $cmbAction.SelectedIndex = 0
    $dlg.FindName('BtnBrowse').Add_Click({
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter = Get-AcText 'ui.filter.backup'
        $backupRoot = Join-Path (Get-AcHome) 'backups'
        if (Test-Path $backupRoot) { $ofd.InitialDirectory = $backupRoot }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtBackup.Text = $ofd.FileName }
    })
    $dlg.FindName('BtnClose').Add_Click({ $dlg.Close() })
    $dlg.FindName('BtnRun').Add_Click({
        $arguments = @('-Action', [string]$cmbAction.SelectedItem)
        if ($txtBackup.Text) { $arguments += @('-BackupFile', $txtBackup.Text) }
        if ($chkForce.IsChecked) { $arguments += '-Force' }
        $dlg.Close()
        Start-LauncherProcess -Label (Get-AcText 'ui.label.recover' @([string]$cmbAction.SelectedItem)) -ScriptRel 'launcher/Recover-Work.ps1' -Arguments $arguments
    })
    $dlg.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------------------
# project registration / worktree move (D2: UI 안의 Setup 마법사)
# ---------------------------------------------------------------------------

function Update-ProjectList {
    param([string] $SelectName)
    $CmbProject.Items.Clear()
    $config = Get-AcConfig
    if ($config) {
        foreach ($p in @($config.projects)) { $CmbProject.Items.Add($p.name) | Out-Null }
    }
    if ($SelectName -and $CmbProject.Items.Contains($SelectName)) { $CmbProject.SelectedItem = $SelectName }
    elseif ($CmbProject.Items.Count -gt 0 -and $null -eq $CmbProject.SelectedItem) { $CmbProject.SelectedIndex = 0 }
}

function Select-Folder {
    param([string] $Description)
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Show-ProjectDialog {
    # Mode 'Add' = 새 프로젝트 등록 (설정이 아예 없으면 기기·vault 까지 입력받는
    # 최초 설정을 겸함). Mode 'Move' = 선택된 프로젝트의 worktree 경로 변경.
    param([ValidateSet('Add', 'Move')] [string] $Mode)
    $config = Get-AcConfig
    $project = $null
    if ($Mode -eq 'Move') {
        $project = Get-SelectedProject
        if (-not $project) { Set-Banner red (Get-AcText 'ui.selectProject'); return }
    }

    $dlg = [Windows.Markup.XamlReader]::Parse((Expand-AcXamlText $projectXaml))
    $dlg.Owner = $window
    $txtMachine = $dlg.FindName('TxtMachine'); $txtVault = $dlg.FindName('TxtVault')
    $txtName = $dlg.FindName('TxtName'); $txtRemote = $dlg.FindName('TxtRemote')
    $cmbAgent = $dlg.FindName('CmbAgent'); $txtPath = $dlg.FindName('TxtPath')
    foreach ($a in @('codex', 'claude', 'none')) { $cmbAgent.Items.Add($a) | Out-Null }

    if ($config) {
        $txtMachine.Text = $config.machineId; $txtMachine.IsReadOnly = $true
        $txtVault.Text = $config.vaultRemote; $txtVault.IsReadOnly = $true
    }
    if ($Mode -eq 'Move') {
        $dlg.Title = Get-AcText 'ui.moveTitle' @($project.name)
        $txtName.Text = $project.name; $txtName.IsReadOnly = $true
        $txtRemote.Text = $project.projectRemote; $txtRemote.IsReadOnly = $true
        $cmbAgent.SelectedItem = [string]$project.agent
        $txtPath.Text = [string]$project.worktreePath
        $dlg.FindName('BtnOk').Content = Get-AcText 'ui.btn.changePath'
    } else {
        $cmbAgent.SelectedIndex = 0
    }

    $dlg.FindName('BtnPickPath').Add_Click({
        $picked = Select-Folder -Description (Get-AcText 'ui.folder.pick')
        if ($picked) { $txtPath.Text = $picked }
    })
    $dlg.FindName('BtnCancel').Add_Click({ $dlg.Close() })
    $dlg.FindName('BtnOk').Add_Click({
        foreach ($pair in @(@($txtMachine.Text, (Get-AcText 'ui.project.machine')), @($txtVault.Text, (Get-AcText 'ui.field.vaultShort')),
                @($txtName.Text, (Get-AcText 'ui.project.name')), @($txtRemote.Text, (Get-AcText 'ui.project.remote')))) {
            if (-not $pair[0].Trim()) {
                [System.Windows.MessageBox]::Show($dlg, (Get-AcText 'ui.validation.required' @($pair[1])), 'Agent Continuity',
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
        }
        $setupArgs = @(
            '-MachineId', $txtMachine.Text.Trim(), '-VaultRemote', $txtVault.Text.Trim(),
            '-ProjectName', $txtName.Text.Trim(), '-ProjectRemote', $txtRemote.Text.Trim(),
            '-Agent', [string]$cmbAgent.SelectedItem
        )
        if ($txtPath.Text.Trim()) { $setupArgs += @('-WorktreePath', $txtPath.Text.Trim()) }
        $label = if ($Mode -eq 'Move') { Get-AcText 'ui.btn.moveWorktree' } else { Get-AcText 'ui.project.title' }
        $targetName = $txtName.Text.Trim()
        $dlg.Close()
        Start-LauncherProcess -Label $label -ScriptRel 'bootstrap/Setup-AgentContinuity.ps1' `
            -Arguments $setupArgs -NoProject -OnExit { param($code)
                if ($code -eq 0) { Update-ProjectList -SelectName $targetName }
            }.GetNewClosure()
    })
    $dlg.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------------------
# profile editor (§7-2: allowedGlobs/excludedGlobs 편집)
# ---------------------------------------------------------------------------

function Show-ProfileDialog {
    # profile 은 로컬 파일이라 launcher 를 거치지 않고 core 의 검증·저장 함수를
    # 직접 쓴다. 검증 실패 시 기존 파일은 그대로 남는다 (fail-closed).
    $project = Get-SelectedProject
    if (-not $project) { Set-Banner red (Get-AcText 'ui.selectProject'); return }
    try { $acProfile = Read-AcProfile -ProjectId $project.projectId }
    catch { Set-Banner red (Get-AcText 'ui.profile.readFail' @($_)); return }

    $dlg = [Windows.Markup.XamlReader]::Parse((Expand-AcXamlText $profileXaml))
    $dlg.Owner = $window
    $dlg.Title = Get-AcText 'ui.profile.titleFor' @($project.name)
    $txtAllowed = $dlg.FindName('TxtAllowed'); $txtExcluded = $dlg.FindName('TxtExcluded')
    $chkTracked = $dlg.FindName('ChkTrackedOnly'); $txtMaxBytes = $dlg.FindName('TxtMaxBytes')
    $txtAllowed.Text = (@($acProfile.allowedGlobs) -join "`r`n")
    $txtExcluded.Text = (@($acProfile.excludedGlobs) -join "`r`n")
    $chkTracked.IsChecked = [bool]$acProfile.trackedOnly
    $txtMaxBytes.Text = [string]$acProfile.maxDiffSizeBytes

    $dlg.FindName('BtnCancel').Add_Click({ $dlg.Close() })
    $dlg.FindName('BtnSave').Add_Click({
        $maxBytes = 0L
        if (-not [long]::TryParse($txtMaxBytes.Text.Trim(), [ref]$maxBytes)) {
            [System.Windows.MessageBox]::Show($dlg, (Get-AcText 'ui.profile.maxBytesInt'), 'Agent Continuity',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
        $toLines = { param($text) @($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $candidate = [pscustomobject]@{
            allowedGlobs     = & $toLines $txtAllowed.Text
            excludedGlobs    = & $toLines $txtExcluded.Text
            trackedOnly      = [bool]$chkTracked.IsChecked
            maxDiffSizeBytes = $maxBytes
        }
        try {
            Save-AcProfile -ProjectId $project.projectId -ProjectProfile $candidate
        } catch {
            [System.Windows.MessageBox]::Show($dlg, [string]$_, 'Agent Continuity',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
        $dlg.Close()
        Set-Banner green (Get-AcText 'ui.profile.saved')
        Update-StatusPanel
    })
    $dlg.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------------------
# tray icon
# ---------------------------------------------------------------------------

$tray = [System.Windows.Forms.NotifyIcon]::new()
$tray.Icon = [System.Drawing.SystemIcons]::Application
# 사용자 지정 아이콘: assets/icon.png 를 두면 .ico 로 변환해 창·트레이에 적용
$customIcon = Get-AcIconPath -ToolRoot $script:AcRoot
if ($customIcon) {
    try {
        $tray.Icon = [System.Drawing.Icon]::new($customIcon)
        $pngPath = Join-Path $script:AcRoot 'assets/icon.png'
        $iconSource = if (Test-Path $pngPath) { $pngPath } else { $customIcon }
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconSource))
    } catch {
        Write-AcLog -Level WARN -Message (Get-AcText 'ui.warn.iconApply' @($_))
    }
}
$tray.Text = 'Agent Continuity'
$tray.Visible = $false
$tray.Add_DoubleClick({
    $window.Show()
    $window.WindowState = 'Normal'
    $window.Activate()
    $tray.Visible = $false
})

# ---------------------------------------------------------------------------
# wire up
# ---------------------------------------------------------------------------

Update-ProjectList -SelectName $ProjectName

$CmbProject.Add_SelectionChanged({ Update-StatusPanel })
$BtnRefresh.Add_Click({ Update-StatusPanel; Set-Banner gray (Get-AcText 'ui.banner.refreshed') })
$BtnStart.Add_Click({ Start-LauncherProcess -Label (Get-AcText 'ui.btn.start') -ScriptRel 'launcher/Start-Work.ps1' -Arguments @() })
$BtnFinish.Add_Click({ Start-LauncherProcess -Label (Get-AcText 'ui.btn.finish') -ScriptRel 'launcher/Finish-Work.ps1' -Arguments @() })
$BtnRecover.Add_Click({ Show-RecoveryDialog })
$BtnAddProject.Add_Click({ Show-ProjectDialog -Mode Add })
$BtnMoveWorktree.Add_Click({ Show-ProjectDialog -Mode Move })
$BtnEditProfile.Add_Click({ Show-ProfileDialog })
$BtnTray.Add_Click({
    $tray.Visible = $true
    $window.Hide()
})
$window.Add_Closing({
    param($sender, $e)
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        # 진행 중인 인계 작업은 절대 강제 종료하지 않는다: 창만 트레이로 보낸다.
        $e.Cancel = $true
        $tray.Visible = $true
        $window.Hide()
        $tray.ShowBalloonTip(3000, 'Agent Continuity', (Get-AcText 'ui.tray.balloon'), 'Info')
    } else {
        $tray.Dispose()
    }
})

Update-StatusPanel
if (-not (Get-AcConfig)) {
    Set-Banner yellow (Get-AcText 'ui.banner.noConfig')
} else {
    Set-Banner gray (Get-AcText 'ui.banner.ready')
}
$window.ShowDialog() | Out-Null
