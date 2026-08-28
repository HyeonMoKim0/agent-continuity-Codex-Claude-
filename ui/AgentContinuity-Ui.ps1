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

if (-not $IsWindows) {
    Write-Host '이 UI 는 Windows 전용입니다. 다른 OS 에서는 launcher/*.ps1 을 직접 사용하세요.'
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:AcRoot = Split-Path -Parent $PSScriptRoot
foreach ($m in @('Common', 'Lease', 'Transaction')) {
    Import-Module (Join-Path $script:AcRoot "core/$m.psm1") -Force -DisableNameChecking
}

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Agent Continuity" Width="760" Height="620" MinWidth="620" MinHeight="480"
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
      <TextBlock Text="프로젝트:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <Button x:Name="BtnRefresh" Content="상태 새로고침" DockPanel.Dock="Right" Padding="10,4" Margin="8,0,0,0"/>
      <ComboBox x:Name="CmbProject" VerticalAlignment="Center"/>
    </DockPanel>

    <Border Grid.Row="1" BorderBrush="#CCCCCC" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,8" Background="#F7F7F7">
      <TextBlock x:Name="TxtStatus" TextWrapping="Wrap" FontFamily="Consolas" Text="상태를 불러오는 중..."/>
    </Border>

    <Border Grid.Row="2" x:Name="Banner" CornerRadius="4" Padding="10,6" Margin="0,0,0,8" Background="#EEEEEE">
      <TextBlock x:Name="TxtBanner" Text="준비" FontWeight="Bold"/>
    </Border>

    <TextBox Grid.Row="3" x:Name="TxtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             TextWrapping="NoWrap" Background="#1E1E1E" Foreground="#DDDDDD"/>

    <UniformGrid Grid.Row="4" Columns="4" Margin="0,10,0,0">
      <Button x:Name="BtnStart" Content="작업 시작" Height="42" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnFinish" Content="종료·인계" Height="42" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnRecover" Content="복구 센터" Height="42" Margin="0,0,6,0"/>
      <Button x:Name="BtnTray" Content="트레이로 최소화" Height="42"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$recoverXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="복구 센터" Width="520" Height="300" WindowStartupLocation="CenterOwner" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="작업:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="CmbAction"/>
    </DockPanel>
    <DockPanel Grid.Row="1" Margin="0,0,0,8">
      <TextBlock Text="백업 파일:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <Button x:Name="BtnBrowse" Content="찾기" DockPanel.Dock="Right" Padding="10,2" Margin="8,0,0,0"/>
      <TextBox x:Name="TxtBackup"/>
    </DockPanel>
    <CheckBox Grid.Row="2" x:Name="ChkForce" Content="-Force (되돌리기·복원·인수는 먼저 보존 후 실행됨)" Margin="0,0,0,8"/>
    <TextBlock Grid.Row="3" TextWrapping="Wrap" Foreground="#666666"
               Text="복구 센터는 안전한 작업만 제공합니다: 마지막 완결 transaction 으로 되돌리기, orphan 보존, lease 조회, 백업 검증·복원, 안전하게 인계받기. force push·백업 삭제는 없습니다 (plan §10.3)."/>
    <UniformGrid Grid.Row="4" Columns="2">
      <Button x:Name="BtnRun" Content="실행" Height="34" Margin="0,0,6,0" FontWeight="Bold"/>
      <Button x:Name="BtnClose" Content="닫기" Height="34"/>
    </UniformGrid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in @('CmbProject', 'BtnRefresh', 'TxtStatus', 'Banner', 'TxtBanner', 'TxtLog', 'BtnStart', 'BtnFinish', 'BtnRecover', 'BtnTray')) {
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

function Update-StatusPanel {
    $project = Get-SelectedProject
    if (-not $project) { $TxtStatus.Text = '등록된 프로젝트가 없습니다. Setup-AgentContinuity.ps1 을 먼저 실행하세요.'; return }
    $config = Get-AcConfig
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("기기: $($config.machineId)   worktree: $($project.worktreePath)")
    try {
        $leaseInfo = Get-AcLease -ProjectId $project.projectId
        if ($leaseInfo.Lease) {
            $lease = $leaseInfo.Lease
            $expired = if (Test-AcLeaseExpired -Lease $lease) { ' (만료)' } else { '' }
            $lines.Add("lease : $($lease.state)$expired · 소유=$($lease.machineId) · gen=$($lease.generation)")
        } else { $lines.Add('lease : 없음') }
        $keeper = if (Test-AcKeeperAlive -ProjectId $project.projectId) { '실행 중' } else { '없음' }
        $lines.Add("keeper: $keeper")
        $lastTx = Get-AcLastTransaction -ProjectId $project.projectId
        if ($lastTx.Record) {
            $lines.Add("마지막 완결 transaction: gen=$($lastTx.Record.generation) · 기기=$($lastTx.Record.sourceMachineId)")
        } else { $lines.Add('마지막 완결 transaction: 없음 (초기 상태)') }
        if (Test-Path (Join-Path $project.worktreePath '.git')) {
            $dirty = @((Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('status', '--porcelain')).Output | Where-Object { $_ })
            $lines.Add("dirty : $($dirty.Count) 개 파일")
        }
    } catch {
        $lines.Add("상태 조회 오류: $_")
    }
    $TxtStatus.Text = ($lines -join "`n")
}

# --- async launcher runner --------------------------------------------------

$script:OutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:CurrentProc = $null
$script:RunningLabel = ''

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
        foreach ($b in @($BtnStart, $BtnFinish, $BtnRecover, $BtnRefresh)) { $b.IsEnabled = $true }
        if ($code -eq 0) { Set-Banner green "$($script:RunningLabel) 완료" }
        else { Set-Banner red "$($script:RunningLabel) 중단 (코드 $code) — 로그의 원인·보존 위치·권장 행동을 확인하세요" }
        Update-StatusPanel
    }
})

function Start-LauncherProcess {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $ScriptRel,
        [string[]] $Arguments = @()
    )
    if ($script:CurrentProc) { return }
    $project = Get-SelectedProject
    if (-not $project) { Set-Banner red '프로젝트를 선택하세요'; return }
    $TxtLog.Clear()
    Set-Banner yellow "$Label 실행 중..."
    $script:RunningLabel = $Label
    foreach ($b in @($BtnStart, $BtnFinish, $BtnRecover, $BtnRefresh)) { $b.IsEnabled = $false }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $script:AcRoot $ScriptRel), '-ProjectName', $project.name) + $Arguments) {
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
    $dlg = [Windows.Markup.XamlReader]::Parse($recoverXaml)
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
        $ofd.Filter = '암호화 백업 (*.age)|*.age|모든 파일|*.*'
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
        Start-LauncherProcess -Label "복구($([string]$cmbAction.SelectedItem))" -ScriptRel 'launcher/Recover-Work.ps1' -Arguments $arguments
    })
    $dlg.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------------------
# tray icon
# ---------------------------------------------------------------------------

$tray = [System.Windows.Forms.NotifyIcon]::new()
$tray.Icon = [System.Drawing.SystemIcons]::Application
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

$config = Get-AcConfig
if ($config) {
    foreach ($p in @($config.projects)) { $CmbProject.Items.Add($p.name) | Out-Null }
    if ($ProjectName -and $CmbProject.Items.Contains($ProjectName)) { $CmbProject.SelectedItem = $ProjectName }
    elseif ($CmbProject.Items.Count -gt 0) { $CmbProject.SelectedIndex = 0 }
}

$CmbProject.Add_SelectionChanged({ Update-StatusPanel })
$BtnRefresh.Add_Click({ Update-StatusPanel; Set-Banner gray '상태 갱신됨' })
$BtnStart.Add_Click({ Start-LauncherProcess -Label '작업 시작' -ScriptRel 'launcher/Start-Work.ps1' -Arguments @() })
$BtnFinish.Add_Click({ Start-LauncherProcess -Label '종료·인계' -ScriptRel 'launcher/Finish-Work.ps1' -Arguments @() })
$BtnRecover.Add_Click({ Show-RecoveryDialog })
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
        $tray.ShowBalloonTip(3000, 'Agent Continuity', '작업이 끝날 때까지 트레이에서 계속 실행됩니다.', 'Info')
    } else {
        $tray.Dispose()
    }
})

Update-StatusPanel
Set-Banner gray '준비 — 정상 사용은 작업 시작 1회, 종료·인계 1회면 충분합니다'
$window.ShowDialog() | Out-Null
