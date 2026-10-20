# Diskman - Main Application Controller (C: drive space cleaner)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, Microsoft.VisualBasic -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import modules if running uncompiled
$modulesPath = Join-Path $ScriptDir "modules"
if (Test-Path $modulesPath) {
    Get-ChildItem -Path $modulesPath -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

# Load XAML
$xamlPath = Join-Path $ScriptDir "xaml\MainWindow.xaml"
if (-not (Test-Path $xamlPath)) {
    Write-Error "MainWindow.xaml not found at $xamlPath"
    return
}

[xml]$xaml = Get-Content -Path $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Helper to find XAML controls
function Find-Control {
    param([string]$Name)
    return $window.FindName($Name)
}

# Audit trail: every log line is also appended to a daily file, so there is a record after the window closes
$global:AuditLogDir = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Diskman\logs'
function Write-AuditLog {
    param([string]$Line)
    try {
        if (-not (Test-Path -LiteralPath $global:AuditLogDir)) { New-Item -ItemType Directory -Path $global:AuditLogDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $global:AuditLogDir ("diskman-{0:yyyyMMdd}.log" -f (Get-Date))) -Value $Line -Encoding UTF8
    } catch {}
}

# Live log (terminal + in-app box + audit file). Only ever called on the UI thread.
function Log-Console {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = "[+]"
    $hostColor = "Cyan"
    if ($Level -eq "SUCCESS") { $prefix = "[OK]"; $hostColor = "Green" }
    elseif ($Level -eq "WARN") { $prefix = "[!]"; $hostColor = "Yellow" }
    elseif ($Level -eq "ERROR") { $prefix = "[X]"; $hostColor = "Red" }

    try {
        Write-Host "$timestamp " -NoNewline -ForegroundColor DarkGray
        Write-Host "$prefix " -NoNewline -ForegroundColor $hostColor
        Write-Host $Message -ForegroundColor White
    } catch {}

    if ($txtConsoleLog) {
        # Keep the log box bounded: a long session must not grow it without limit
        if ($txtConsoleLog.Text.Length -gt 200000) { $txtConsoleLog.Text = $txtConsoleLog.Text.Substring(100000) }
        $txtConsoleLog.AppendText("$timestamp $prefix $Message`r`n")
        $txtConsoleLog.ScrollToEnd()
    }
    Write-AuditLog ("{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $prefix, $Message)
}

# Control References
$txtConsoleLog             = Find-Control "TxtConsoleLog"
$txtGlobalStat             = Find-Control "TxtGlobalStatus"
$txtLogLocation            = Find-Control "TxtLogLocation"
$btnCancelAction           = Find-Control "BtnCancelAction"
$mainTabControl            = Find-Control "MainTabControl"
$tabOverview               = Find-Control "TabOverview"
$tabCleaner                = Find-Control "TabCleaner"
$tabExplorer               = Find-Control "TabExplorer"
$tabHunter                 = Find-Control "TabHunter"
$tabInspector              = Find-Control "TabInspector"

# Drive strip
$txtCDriveTotal            = Find-Control "TxtCDriveTotal"
$txtCDriveUsed             = Find-Control "TxtCDriveUsed"
$txtCDriveFree             = Find-Control "TxtCDriveFree"
$progressCDrive            = Find-Control "ProgressCDrive"
$txtCBarPercent            = Find-Control "TxtCBarPercent"
$txtCBarStatus             = Find-Control "TxtCBarStatus"
$txtCReclaimable           = Find-Control "TxtCReclaimable"
$btnRestartAdmin           = Find-Control "BtnRestartAdmin"
$btnTopQuickScan           = Find-Control "BtnTopQuickScan"

# Overview
$txtOverviewVerdict        = Find-Control "TxtOverviewVerdict"
$txtOverviewSub            = Find-Control "TxtOverviewSub"
$panelScan                 = Find-Control "PanelScan"
$txtScanProgress           = Find-Control "TxtScanProgress"
$btnCancelScan             = Find-Control "BtnCancelScan"
$barCategories             = Find-Control "BarCategories"
$panelLegend               = Find-Control "PanelLegend"
$gridTopFolders            = Find-Control "GridTopFolders"
$txtEmptyTop               = Find-Control "TxtEmptyTop"
$txtOverviewSelected       = Find-Control "TxtOverviewSelected"
$btnOverviewOpen           = Find-Control "BtnOverviewOpen"
$btnOverviewAction         = Find-Control "BtnOverviewAction"
$btnFreeSafely             = Find-Control "BtnFreeSafely"
$txtFreeSafelyNote         = Find-Control "TxtFreeSafelyNote"
$txtAdminHint              = Find-Control "TxtAdminHint"
$panelActions              = Find-Control "PanelActions"
$panelSystemSpace          = Find-Control "PanelSystemSpace"

# Space Explorer
$btnSpaceUp                = Find-Control "BtnSpaceUp"
$panelCrumbs               = Find-Control "PanelCrumbs"
$gridSpace                 = Find-Control "GridSpace"
$txtEmptyExplorer          = Find-Control "TxtEmptyExplorer"
$txtSpaceSelected          = Find-Control "TxtSpaceSelected"
$btnSpaceOpen              = Find-Control "BtnSpaceOpen"
$btnSpaceCopy              = Find-Control "BtnSpaceCopy"
$btnSpaceAction            = Find-Control "BtnSpaceAction"

# Cleaner
$btnSelectRec              = Find-Control "BtnSelectRecommended"
$btnSelectAll              = Find-Control "BtnSelectAll"
$btnClearSel               = Find-Control "BtnClearSelection"
$btnFilterAll              = Find-Control "BtnFilterAll"
$btnFilterSys              = Find-Control "BtnFilterSystem"
$btnFilterGaming           = Find-Control "BtnFilterGaming"
$btnFilterDev              = Find-Control "BtnFilterDev"
$btnFilterBrowser          = Find-Control "BtnFilterBrowser"
$txtCleanBadge             = Find-Control "TxtCleanSelectedBadge"
$btnScanClean              = Find-Control "BtnScanCleanable"
$btnRunCleanup             = Find-Control "BtnRunCleanup"
$gridCleanCategories       = Find-Control "GridCleanableCategories"
$txtSelectedCatTitle       = Find-Control "TxtSelectedCategoryTitle"
$badgeSafetyLevel          = Find-Control "BadgeSafetyLevel"
$txtSelectedCatSafetyBadge = Find-Control "TxtSelectedCategorySafetyBadge"
$txtSelectedCatSizeInfo    = Find-Control "TxtSelectedCategorySizeInfo"
$txtCategoryWhatDeleted    = Find-Control "TxtCategoryWhatDeleted"
$txtCategorySafetyExp      = Find-Control "TxtCategorySafetyExp"
$txtCategoryConsequences   = Find-Control "TxtCategoryConsequences"
$btnOpenCatInExplorer      = Find-Control "BtnOpenCategoryInExplorer"
$btnInspectCatFiles        = Find-Control "BtnInspectCategoryFiles"
$btnCleanSingleCategory    = Find-Control "BtnCleanSingleCategory"

# File Inspector
$cmbInspectTarget          = Find-Control "CmbInspectTarget"
$btnRefreshInspectFiles    = Find-Control "BtnRefreshInspectFiles"
$txtInspectSummary         = Find-Control "TxtInspectSummary"
$gridInspectFiles          = Find-Control "GridInspectFiles"
$txtEmptyInspector         = Find-Control "TxtEmptyInspector"
$txtSelectedInspectInfo    = Find-Control "TxtSelectedInspectFileInfo"
$btnRevealInspectFile       = Find-Control "BtnRevealInspectFileInExplorer"
$btnDeleteSingleInspectFile = Find-Control "BtnDeleteSingleInspectFile"
$btnPurgeAllInspect         = Find-Control "BtnPurgeAllInspectFiles"

# Large Files
$cmbHuntSize               = Find-Control "CmbHunterSize"
$cmbHuntCat                = Find-Control "CmbHunterCategory"
$btnHuntScan               = Find-Control "BtnStartHunterScan"
$gridLargeFiles            = Find-Control "GridLargeFiles"
$txtEmptyHunter            = Find-Control "TxtEmptyHunter"
$txtSelectedLargeFile      = Find-Control "TxtSelectedFileInfo"
$btnRevealLargeFile        = Find-Control "BtnRevealInExplorer"
$btnTrashLargeFile         = Find-Control "BtnSendToTrash"
$btnPermDeleteLargeFile    = Find-Control "BtnPermanentDelete"

# Internal State
$global:ScannedCleanupItems = [System.Collections.ArrayList]@()
$global:CurrentFilterGroup  = "All"
$global:Jobs                = @{ action = $null; scan = $null }
$global:SpaceTree           = $null
$global:SpaceStack          = New-Object System.Collections.ArrayList
$global:ScanPartial         = $false
$global:TickCount           = 0
$global:RescanPending       = $false

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$brushConverter = New-Object System.Windows.Media.BrushConverter
$releaseUrl = 'https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1'
$driveRoot = if ($env:SystemDrive) { "$($env:SystemDrive.TrimEnd('\'))\" } else { 'C:\' }
$driveLetter = $driveRoot.Substring(0, 2)   # "C:" on most PCs; the Windows drive is not always C:

# ---------------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------------

# Every destructive confirmation defaults to No, so pressing Enter never deletes
function Confirm-Action {
    param([string]$Message, [string]$Title = 'Diskman', [string]$Icon = 'Warning')
    $answer = [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::$Icon, [System.Windows.MessageBoxResult]::No)
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-Info {
    param([string]$Message, [string]$Title = 'Diskman', [string]$Icon = 'Information')
    [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::$Icon) | Out-Null
}

# Empty-state text is visible only while the grid has nothing to show
function Set-Empty {
    param($TextBlock, $Items)
    $TextBlock.Visibility = if (@($Items).Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Format-Count { param([long]$N) return $N.ToString('N0') }

# ---------------------------------------------------------------------------
# Background work: two slots share one runspace-per-job design.
#   action: scans of cleanup targets, cleaning, hunting, commands (one at a time; disables action buttons)
#   scan:   the whole-drive tree scan (read-only; can run while an action runs; cancellable)
# The worker pushes log lines onto a queue; a DispatcherTimer on the UI thread drains it.
# ---------------------------------------------------------------------------

# Functions copied into the worker by definition, so this works uncompiled and in the single-file release
$workerFunctions = @(
    'Format-Bytes', 'Test-IsSubpathOrEqual', 'Test-ReparsePoint', 'Test-WindowsServicingActive', 'Test-PathSafety',
    'Get-FolderSizeFast', 'Get-CleanableTargets', 'Scan-SmartCleanupItems', 'Get-CleanableCategoryFiles',
    'Invoke-ExecuteCleanup', 'Invoke-ExecuteCategoryCleanup', 'Find-LargeFiles', 'Scan-DriveTree',
    'Get-AllowedCommands', 'Invoke-AllowedCommand', 'Invoke-VhdCompact', 'Get-CompactableDisks', 'New-DiskpartCompactScript', 'New-DiskpartDetachScript',
    'Get-ScanParallelism', 'Find-TreeNode', 'Find-AppCaches', 'Test-AppCacheExcluded', 'Get-AppCacheKind', 'Get-AppCacheGroupKey', 'Get-SpaceCategory'
)

# Everything that must not be clicked while an action job runs
$actionControls = @(
    $btnSelectRec, $btnSelectAll, $btnClearSel, $btnScanClean, $btnRunCleanup, $btnCleanSingleCategory,
    $btnRefreshInspectFiles, $btnDeleteSingleInspectFile, $btnPurgeAllInspect,
    $btnHuntScan, $btnTrashLargeFile, $btnPermDeleteLargeFile, $btnFreeSafely
)

function Update-BusyState {
    $actionBusy = [bool]$global:Jobs.action
    $scanBusy   = [bool]$global:Jobs.scan
    foreach ($c in $actionControls) { $c.IsEnabled = -not $actionBusy }
    $btnTopQuickScan.IsEnabled = -not ($scanBusy -or $actionBusy)
    $btnCancelAction.Visibility = if ($actionBusy) { 'Visible' } else { 'Collapsed' }
    $panelScan.Visibility = if ($scanBusy) { 'Visible' } else { 'Collapsed' }
    Show-OverviewSelection
    Show-SpaceSelection
    if (-not $actionBusy) { Update-FreeSafely }
}

function Stop-BackgroundJob {
    param([string]$Slot)
    $job = $global:Jobs[$Slot]
    if (-not $job) { return }
    $job.Context['Cancelled'] = $true
    if ($Slot -eq 'scan') {
        # The walker checks this flag and returns the partial tree normally
        [Diskman.TreeScan]::Cancel = $true
    } else {
        $null = $job.Ps.BeginStop($null, $null)
    }
    Log-Console "Cancelling: $($job.Status)..." "WARN"
}

$jobTimer = New-Object System.Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$jobTimer.add_Tick({
    $global:TickCount++
    foreach ($slot in @('action', 'scan')) {
        $job = $global:Jobs[$slot]
        if (-not $job) { continue }

        $msg = $null
        while ($job.Queue.TryDequeue([ref]$msg)) { Log-Console $msg[0] $msg[1] }
        $elapsed = [int]((Get-Date) - $job.Started).TotalSeconds
        if ($slot -eq 'action') {
            $txtGlobalStat.Text = "$($job.Status)... $($elapsed)s"
        } else {
            Update-ScanProgress -Elapsed $elapsed
        }
        if (-not $job.Async.IsCompleted) { continue }

        $output = @()
        $failure = $null
        try { $output = @($job.Ps.EndInvoke($job.Async)) } catch { $failure = $_ }
        $job.Ps.Dispose()
        $job.Runspace.Dispose()
        $global:Jobs[$slot] = $null
        Update-BusyState
        Update-CDriveMetricsDisplay -Quiet

        if ($failure) {
            if ($job.Context['Cancelled']) {
                Log-Console "$($job.Status) was cancelled." "WARN"
                if ($job.Context['Ids']) { Start-ScanCJunk -Id $job.Context['Ids'] }
            } else {
                Log-Console "$($job.Status) failed: $failure" "ERROR"
            }
        } else {
            & $job.OnDone $output $job.Context
        }
    }
    if (-not $global:Jobs.action -and -not $global:Jobs.scan) { $jobTimer.Stop() }
})

function Start-BackgroundJob {
    param(
        [ValidateSet('action', 'scan')][string]$Slot = 'action',
        [string]$Status,
        [scriptblock]$Work,
        [hashtable]$Vars = @{},
        [hashtable]$Context = @{},
        [scriptblock]$OnDone
    )

    if ($global:Jobs[$Slot]) {
        Log-Console "Another operation is still running; wait for it to finish." "WARN"
        return
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in $workerFunctions) {
        $def = (Get-Command -Name $fn -CommandType Function).Definition
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $def)))
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs.SessionStateProxy.SetVariable('LogQueue', $queue)
    foreach ($key in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($key, $Vars[$key]) }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    # Pass the text, not the scriptblock: a scriptblock stays bound to this (UI) runspace and fails on the worker
    $null = $ps.AddScript($Work.ToString())

    $global:Jobs[$Slot] = @{
        Status = $Status; Ps = $ps; Runspace = $rs; Queue = $queue; OnDone = $OnDone; Context = $Context
        Started = Get-Date; Async = $ps.BeginInvoke()
    }
    Update-BusyState
    Log-Console "$Status..."
    $jobTimer.Start()
}

# ---------------------------------------------------------------------------
# Drive strip and Overview
# ---------------------------------------------------------------------------

function Get-DriveState {
    $d = [System.IO.DriveInfo]::new($driveRoot)
    return [PSCustomObject]@{ Total = [long]$d.TotalSize; Free = [long]$d.AvailableFreeSpace; Used = [long]($d.TotalSize - $d.AvailableFreeSpace) }
}

function Update-CDriveMetricsDisplay {
    param([switch]$Quiet)
    $cMetrics = Get-CDriveMetrics
    if ($cMetrics) {
        $txtCDriveTotal.Text = "$($cMetrics.TotalGB) GB"
        $txtCDriveUsed.Text  = "$($cMetrics.UsedGB) GB"
        $txtCDriveFree.Text  = "$($cMetrics.FreeGB) GB"
        $progressCDrive.Value = $cMetrics.UsedPercent
        $txtCBarPercent.Text = "$($cMetrics.UsedPercent)% used - $($cMetrics.StatusText)"
        $txtCBarStatus.Text  = "Drive $driveLetter [$($cMetrics.VolumeLabel)] ($($cMetrics.FileSystem))"
        if (-not $global:Jobs.action) { $txtGlobalStat.Text = "$driveLetter $($cMetrics.FreeGB) GB free of $($cMetrics.TotalGB) GB ($($cMetrics.StatusText))" }
        if (-not $Quiet) {
            Log-Console "$driveLetter drive status: $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)"
        }
    }
    Update-OverviewVerdict
}

# Safe-tier categories the user can clean right now (the one-click win)
function Get-SafeCleanItems {
    return @($global:ScannedCleanupItems | Where-Object { $_.SafetyLevel -eq 'Safe' -and $_.Recommended -and $_.RawBytes -gt 0 -and $_.CanSelect -and $_.Type -ne 'RecycleBin' })
}

function Update-OverviewVerdict {
    $drive = Get-DriveState
    $pct = if ($drive.Total -gt 0) { 100.0 * $drive.Free / $drive.Total } else { 100 }
    $level = if ($drive.Free -lt 2GB -or $pct -lt 5) { 'Critically low' } elseif ($pct -lt 10) { 'Low' } else { 'Healthy' }
    $color = switch ($level) { 'Critically low' { '#FF6B6B' } 'Low' { '#FFB703' } default { '#2EC4B6' } }
    $safe = Get-SafeCleanItems
    $safeBytes = [long](($safe | Measure-Object -Property RawBytes -Sum).Sum)

    $text = "$(Format-Bytes $drive.Free) free of $(Format-Bytes $drive.Total). $level."
    if ($safeBytes -gt 50MB) { $text += " About $(Format-Bytes $safeBytes) can be freed safely right now." }
    elseif ($global:ScannedCleanupItems.Count -gt 0 -and $level -eq 'Healthy') { $text += " Nothing large to clean." }
    $txtOverviewVerdict.Text = $text
    $txtOverviewVerdict.Foreground = $brushConverter.ConvertFromString($color)

    if ($global:Jobs.scan) {
        $txtOverviewSub.Text = "Scanning the whole drive to show where the rest went. Results appear as they are found."
    } elseif ($global:SpaceTree) {
        $scanned = [long]$global:SpaceTree.Bytes
        $share = if ($drive.Used -gt 0) { [math]::Min(100, [math]::Round(100.0 * $scanned / $drive.Used)) } else { 100 }
        $gap = $drive.Used - $scanned
        if ($global:ScanPartial) {
            $txtOverviewSub.Text = "Partial result: the scan was cancelled, so these numbers are incomplete. Click Rescan for the full picture."
        } elseif ($gap -gt 0) {
            $txtOverviewSub.Text = if ($isAdmin) { "Accounted for $share% of used space. $(Format-Bytes $gap) could not be read (in use by Windows or protected)." }
                                   else { "Accounted for $share% of used space. $(Format-Bytes $gap) sits in protected areas (such as shadow copies). Restart as Administrator to break it down." }
        } else {
            $txtOverviewSub.Text = "Accounted for all of the used space. Some Windows files are shared, so folder sizes can add up to slightly more than the drive reports."
        }
    } else {
        $txtOverviewSub.Text = ''
    }
    $txtOverviewSub.ToolTip = $txtOverviewSub.Text
    Update-AdminHint
}

# What administrator rights would unlock, so the Restart button has a reason attached
function Update-AdminHint {
    if ($isAdmin) { $txtAdminHint.Visibility = 'Collapsed'; return }
    $locked = [long](($global:ScannedCleanupItems | Where-Object { $_.RequiresAdmin -and $_.Type -ne 'RecycleBin' } | Measure-Object -Property RawBytes -Sum).Sum)
    $gap = if ($global:SpaceTree -and -not $global:ScanPartial) { [math]::Max([long]0, (Get-DriveState).Used - [long]$global:SpaceTree.Bytes) } else { [long]0 }
    if ($locked -lt 50MB -and $gap -lt 500MB) { $txtAdminHint.Visibility = 'Collapsed'; return }
    $parts = @()
    if ($locked -ge 50MB) { $parts += "about $(Format-Bytes $locked) of system caches that are skipped now" }
    if ($gap -ge 500MB) { $parts += "a look inside $(Format-Bytes $gap) of protected space (shadow copies, system files)" }
    $txtAdminHint.Text = "As administrator you would also unlock " + ($parts -join ' and ') + ". Use Restart as Administrator."
    $txtAdminHint.Visibility = 'Visible'
}

# One-click win: Safe-tier categories only, one confirmation
function Update-FreeSafely {
    $safe = Get-SafeCleanItems
    $bytes = [long](($safe | Measure-Object -Property RawBytes -Sum).Sum)
    if ($safe.Count -gt 0 -and $bytes -gt 50MB) {
        $btnFreeSafely.Content = "Free $(Format-Bytes $bytes) safely"
        $btnFreeSafely.IsEnabled = -not $global:Jobs.action
        $txtFreeSafelyNote.Text = "Cleans only Safe categories: " + (($safe | Select-Object -First 4 | ForEach-Object { $_.CategoryName }) -join ', ') + $(if ($safe.Count -gt 4) { " and $($safe.Count - 4) more" } else { '' }) + ". You confirm first."
    } else {
        $btnFreeSafely.Content = "Nothing safe to free right now"
        $btnFreeSafely.IsEnabled = $false
        $txtFreeSafelyNote.Text = if ($global:ScannedCleanupItems.Count -eq 0) { "Waiting for the cleanup scan..." } else { "The Safe categories are already small. See the recommended actions below for bigger items." }
    }
}

$categoryColors = [ordered]@{
    'Apps and games' = '#00B4D8'; 'Developer tools' = '#8B7CF6'; 'Windows and system' = '#6B7B8C'
    'Your files' = '#2EC4B6'; 'Caches and temp' = '#FFB703'; 'Other' = '#A1A1AA'; 'Protected or unreadable' = '#52525B'
}

function Show-CategoryBar {
    param($Cats, [long]$GapBytes)
    $cats = $Cats
    $segments = New-Object System.Collections.ArrayList
    foreach ($name in $categoryColors.Keys) {
        $bytes = if ($name -eq 'Protected or unreadable') { [math]::Max([long]0, $GapBytes) } else { [long]$cats[$name] }
        if ($bytes -gt 0) { [void]$segments.Add([PSCustomObject]@{ Name = $name; Bytes = $bytes; Color = $categoryColors[$name] }) }
    }
    $total = [long](($segments | Measure-Object -Property Bytes -Sum).Sum)
    $barCategories.Children.Clear(); $barCategories.ColumnDefinitions.Clear(); $panelLegend.Children.Clear()
    $i = 0
    foreach ($seg in $segments) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = New-Object System.Windows.GridLength ([double]$seg.Bytes), ([System.Windows.GridUnitType]::Star)
        $barCategories.ColumnDefinitions.Add($col)
        $pct = [math]::Round(100.0 * $seg.Bytes / [math]::Max([long]1, $total), 1)
        $b = New-Object System.Windows.Controls.Border
        $b.Background = $brushConverter.ConvertFromString($seg.Color)
        $b.ToolTip = "$($seg.Name): $(Format-Bytes $seg.Bytes) ($pct%)"
        $b.BorderThickness = New-Object System.Windows.Thickness 0, 0, 1, 0
        $b.BorderBrush = $brushConverter.ConvertFromString('#16161A')
        [System.Windows.Controls.Grid]::SetColumn($b, $i)
        [void]$barCategories.Children.Add($b)

        $item = New-Object System.Windows.Controls.StackPanel
        $item.Orientation = 'Horizontal'; $item.Margin = New-Object System.Windows.Thickness 0, 0, 12, 2
        $sw = New-Object System.Windows.Shapes.Rectangle
        $sw.Width = 10; $sw.Height = 10; $sw.RadiusX = 2; $sw.RadiusY = 2; $sw.VerticalAlignment = 'Center'
        $sw.Fill = $brushConverter.ConvertFromString($seg.Color); $sw.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "$($seg.Name)  $(Format-Bytes $seg.Bytes) ($pct%)"; $lbl.FontSize = 10.5
        $lbl.Foreground = $brushConverter.ConvertFromString('#D4D4D8')
        [void]$item.Children.Add($sw); [void]$item.Children.Add($lbl); [void]$panelLegend.Children.Add($item)
        $i++
    }
}

function Get-InsightText {
    param($Rule)
    if (-not $Rule) { return 'Review in Explorer' }
    switch ($Rule.Verdict) {
        'Clean'     { return "Clean ($($Rule.Safety))" }
        'Command'   { return (Get-AllowedCommands)[$Rule.CommandId].Short }
        'Uninstall' { return 'Uninstall in Settings' }
        'System'    { return 'Windows-managed' }
        default     { return 'Review' }
    }
}

function New-SpaceRow {
    param($Node, [long]$ParentBytes, [string]$Name = $null, [string]$Display = $null)
    $rule = if ($Node) { Find-SpaceRule -Path $Node.Path } else { $null }
    if (-not $rule -and $Node) { $rule = Get-GenericAdvice -Path $Node.Path }
    $pct = if ($ParentBytes -gt 0) { 100.0 * $Node.Bytes / $ParentBytes } else { 0 }
    $modified = if ($Node.ModifiedTicks -gt 0) { ([datetime]::new($Node.ModifiedTicks, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd') } else { '' }
    $profilePath = [System.Environment]::GetFolderPath('UserProfile')
    $shown = if ($Display) { $Display } elseif ($Node.Path.StartsWith($profilePath, [System.StringComparison]::OrdinalIgnoreCase)) { '~' + $Node.Path.Substring($profilePath.Length) } else { $Node.Path }
    return [PSCustomObject]@{
        Name = if ($Name) { $Name } else { $Node.Name }; Display = $shown; Path = $Node.Path
        Bytes = [long]$Node.Bytes; DisplaySize = Format-Bytes $Node.Bytes
        PctValue = [math]::Round($pct, 1); PctText = $(if ($pct -ge 0.1) { "$([math]::Round($pct, 1))%" } else { '<0.1%' })
        Files = [long]$Node.Files; FilesText = Format-Count $Node.Files; Modified = $modified
        Insight = Get-InsightText $rule; Rule = $rule; Node = $Node
    }
}

# While the scan runs: top-level folders appear as soon as each finishes
function Show-PartialRows {
    $drive = Get-DriveState
    $rows = @([Diskman.TreeScan]::Partial.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 12 | ForEach-Object {
        $b = [long]$_.Value
        [PSCustomObject]@{ Name = $_.Key; Display = $_.Key; Path = $_.Key; Bytes = $b; DisplaySize = Format-Bytes $b
            PctValue = 0; PctText = "$([math]::Round(100.0 * $b / [math]::Max([long]1, $drive.Used), 1))%"; Insight = 'scanning...'; Rule = $null; Node = $null }
    })
    $gridTopFolders.ItemsSource = $rows
    Set-Empty $txtEmptyTop $rows
}

function Update-ScanProgress {
    param([int]$Elapsed)
    $files = [Diskman.TreeScan]::ScannedFiles
    $bytes = [Diskman.TreeScan]::ScannedBytes
    $cur = [Diskman.TreeScan]::Current
    $txtScanProgress.Text = "Scanning $driveLetter   $(Format-Count $files) files   |   $(Format-Bytes $bytes)   |   now in $cur   |   $([TimeSpan]::FromSeconds($Elapsed).ToString('m\:ss'))"
    if (($global:TickCount % 5) -eq 0) { Show-PartialRows }
}

# App caches found by structure join the Cleaner list and the rules (so the Overview and Explorer advise on them)
function Merge-DetectedCaches {
    param($Items)
    $kept = @($global:ScannedCleanupItems | Where-Object { -not $_.Dynamic })
    $all = @($kept + @($Items)) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    Set-ScanResults -Items $all -Quiet
}

# The scan worker already did the heavy work (tree, detected caches, category totals): this only renders them
function Show-ScanResults {
    param($Bundle, [bool]$Partial)
    $prepared = [System.Diagnostics.Stopwatch]::StartNew()
    $Tree = $Bundle.Tree
    $global:SpaceTree = $Tree
    $global:ScanPartial = $Partial
    $detected = @($Bundle.Detected)
    Set-DetectedCacheItems -Items $detected
    Merge-DetectedCaches -Items $detected
    if ($detected.Count -gt 0) {
        Log-Console "Detected $($detected.Count) apps with cache folders: $(Format-Bytes ([long](($detected | Measure-Object -Property RawBytes -Sum).Sum))) in total." "SUCCESS"
    }
    $drive = Get-DriveState
    $rows = Get-SpaceAccounting -Root $Tree -UsedBytes $drive.Used -Elevated $isAdmin
    $gap = [long](($rows | Where-Object { $_.Kind -in 'Protected', 'Unreadable' } | Measure-Object -Property Bytes -Sum).Sum)

    Show-CategoryBar -Cats $Bundle.Categories -GapBytes $gap

    $top = @(Get-BiggestFolders -Root $Tree -Max 12 | ForEach-Object { New-SpaceRow -Node $_ -ParentBytes $drive.Used })
    $gridTopFolders.ItemsSource = $top
    Set-Empty $txtEmptyTop $top
    if ($top.Count -eq 0) { $txtEmptyTop.Text = 'No folder over 100 MB was found.' }

    Show-SystemSpace
    Set-SpaceNode -Node $Tree -Reset
    Update-ActionCards
    Update-OverviewVerdict
    $covered = @($top | Where-Object { $_.Rule -and -not $_.Rule.Generic }).Count
    $general = @($top | Where-Object { $_.Rule -and $_.Rule.Generic }).Count
    Log-Console "Drive scan complete: $(Format-Bytes $Tree.Bytes) in $(Format-Count $Tree.Files) files, $($rows.Count) accounting rows, $covered of $($top.Count) biggest folders have specific advice and $general general guidance (results prepared in $($prepared.ElapsedMilliseconds) ms)." "SUCCESS"
}

function Show-SystemSpace {
    $panelSystemSpace.Children.Clear()
    foreach ($r in (Get-SystemSpace -Root $global:SpaceTree -Elevated $isAdmin)) {
        $card = New-Object System.Windows.Controls.StackPanel
        $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
        $head = New-Object System.Windows.Controls.DockPanel
        $size = New-Object System.Windows.Controls.TextBlock
        $size.Text = if ($null -ne $r.Bytes) { Format-Bytes $r.Bytes } elseif ($r.NeedsAdmin -and -not $isAdmin) { 'needs administrator' } else { 'not measured' }
        $size.FontWeight = 'Bold'; $size.Foreground = $brushConverter.ConvertFromString('#00B4D8'); $size.FontSize = 12
        [System.Windows.Controls.DockPanel]::SetDock($size, 'Right')
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $r.Name; $name.FontWeight = 'SemiBold'; $name.FontSize = 12; $name.TextTrimming = 'CharacterEllipsis'
        $name.Foreground = $brushConverter.ConvertFromString('#EDEDED')
        [void]$head.Children.Add($size); [void]$head.Children.Add($name)
        $note = New-Object System.Windows.Controls.TextBlock
        $note.Text = $r.Note; $note.TextWrapping = 'Wrap'; $note.FontSize = 11; $note.Foreground = $brushConverter.ConvertFromString('#A1A1AA')
        [void]$card.Children.Add($head); [void]$card.Children.Add($note)
        if ($r.CommandId -and ($null -ne $r.Bytes -or $r.NeedsAdmin)) {
            $cmd = (Get-AllowedCommands)[$r.CommandId]
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = if ($cmd.RequiresAdmin -and -not $isAdmin) { 'Restart as Administrator to run' } else { $cmd.Title }
            $btn.FontSize = 11; $btn.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4; $btn.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
            $btn.HorizontalAlignment = 'Left'; $btn.Tag = $r.CommandId
            $btn.add_Click({ param($s, $e) Invoke-CommandAction -Id $s.Tag })
            [void]$card.Children.Add($btn)
        }
        if ($r.Uri) {
            $open = New-Object System.Windows.Controls.Button
            $open.Content = 'Open Settings'; $open.FontSize = 11; $open.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
            $open.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0; $open.HorizontalAlignment = 'Left'; $open.Tag = $r.Uri
            $open.add_Click({ param($s, $e) Start-Process $s.Tag })
            [void]$card.Children.Add($open)
        }
        [void]$panelSystemSpace.Children.Add($card)
    }
}

# Recommended actions: biggest safe wins first, then commands and uninstalls
function Update-ActionCards {
    $panelActions.Children.Clear()
    $cands = New-Object System.Collections.ArrayList

    foreach ($item in ($global:ScannedCleanupItems | Where-Object { $_.RawBytes -ge 100MB -and $_.Type -ne 'RecycleBin' })) {
        $order = switch ($item.SafetyLevel) { 'Safe' { 0 } 'Optional' { 1 } default { 3 } }
        [void]$cands.Add([PSCustomObject]@{ Order = $order; Bytes = [long]$item.RawBytes; Title = $item.CategoryName; Safety = $item.SafetyLevel; Why = $item.Description
            Label = $(if ($item.CanSelect) { 'Clean...' } else { 'Needs administrator' }); Kind = 'Clean'; Item = $item; Rule = $null; Path = $item.Target })
    }
    if ($global:SpaceTree) {
        foreach ($node in (Get-BiggestFolders -Root $global:SpaceTree -Max 20 -MinBytes 500MB)) {
            $rule = Find-SpaceRule -Path $node.Path
            if ($rule -and $rule.Verdict -in 'Command', 'Uninstall') {
                $label = if ($rule.Verdict -eq 'Command') { (Get-AllowedCommands)[$rule.CommandId].Short } else { 'Open Settings' }
                if ($rule.CommandId -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) { $label = 'Start Docker to prune' }
                if ($rule.RequiresAdmin -and -not $isAdmin) { $label = 'Needs administrator' }
                [void]$cands.Add([PSCustomObject]@{ Order = $(if ($rule.Verdict -eq 'Command') { 2 } else { 4 }); Bytes = [long]$node.Bytes; Title = $rule.Title; Safety = $rule.Safety
                    Why = $(if ($rule.Effect) { "$($rule.What)`nEffect: $($rule.Effect)" } else { $rule.What }); Label = $label; Kind = $rule.Verdict; Item = $null; Rule = $rule; Path = $node.Path })
            }
        }
    }

    # Docker / WSL virtual disks that can give space back (found by registration, never by searching for .vhdx)
    foreach ($disk in (Get-CompactableDisks | Where-Object { $_.Bytes -ge 500MB })) {
        $drule = Find-SpaceRule -Path (Split-Path -Path $disk.Path -Parent)
        if ($drule) {
            [void]$cands.Add([PSCustomObject]@{ Order = 2; Bytes = [long]$disk.Bytes; Title = "Compact: $($disk.Name)"; Safety = 'Advanced'
                Why = "$($drule.What)`nEffect: $($drule.Effect)"; Label = $(if ($isAdmin) { 'Compact...' } else { 'Needs administrator' }); Kind = 'Command'; Item = $null; Rule = $drule; Path = $disk.Path })
        }
    }

    # Safe cleans first, but the biggest commands/uninstalls always get a place: they are often the largest lever
    $ranked = @($cands | Sort-Object -Property @{ Expression = { $_.Order } }, @{ Expression = { $_.Bytes }; Descending = $true })
    $lead = @($ranked | Select-Object -First 5)
    $bigActions = @($ranked | Where-Object { $_.Kind -ne 'Clean' -and $_ -notin $lead } | Sort-Object -Property Bytes -Descending | Select-Object -First 3)
    $top = @($lead + $bigActions)
    if ($top.Count -eq 0) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = if ($global:Jobs.scan -or $global:Jobs.action) { 'Recommendations appear when the scans finish.' } else { 'Nothing large to act on.' }
        $t.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $t.FontSize = 12; $t.TextWrapping = 'Wrap'
        [void]$panelActions.Children.Add($t)
        return
    }
    foreach ($c in $top) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = $brushConverter.ConvertFromString('#1B1B1F'); $card.BorderBrush = $brushConverter.ConvertFromString('#333338')
        $card.BorderThickness = New-Object System.Windows.Thickness 1; $card.CornerRadius = New-Object System.Windows.CornerRadius 6
        $card.Padding = New-Object System.Windows.Thickness 10, 8, 10, 8; $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.DockPanel
        $size = New-Object System.Windows.Controls.TextBlock
        $size.Text = if ($c.Kind -eq 'Clean') { Format-Bytes $c.Bytes } elseif ($c.Rule -and $c.Rule.CommandId -eq 'CompactDisk') { "File: $(Format-Bytes $c.Bytes)" } else { "Folder: $(Format-Bytes $c.Bytes)" }
        $size.FontWeight = 'Bold'; $size.Foreground = $brushConverter.ConvertFromString('#00B4D8')
        [System.Windows.Controls.DockPanel]::SetDock($size, 'Right')
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $c.Title; $title.FontWeight = 'SemiBold'; $title.TextTrimming = 'CharacterEllipsis'; $title.Foreground = $brushConverter.ConvertFromString('#EDEDED')
        [void]$head.Children.Add($size); [void]$head.Children.Add($title)
        $why = New-Object System.Windows.Controls.TextBlock
        $why.Text = $c.Why; $why.TextWrapping = 'Wrap'; $why.FontSize = 11; $why.MaxHeight = 62; $why.TextTrimming = 'CharacterEllipsis'
        $why.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $why.Margin = New-Object System.Windows.Thickness 0, 3, 0, 6
        $why.ToolTip = $c.Why
        $foot = New-Object System.Windows.Controls.DockPanel
        $badge = New-Object System.Windows.Controls.TextBlock
        $badge.Text = $c.Safety.ToUpper(); $badge.FontSize = 10; $badge.FontWeight = 'Bold'; $badge.VerticalAlignment = 'Center'
        $badge.Foreground = $brushConverter.ConvertFromString($(switch ($c.Safety) { 'Safe' { '#2EC4B6' } 'Optional' { '#FFB703' } 'Advanced' { '#FF8A80' } default { '#A1A1AA' } }))
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $c.Label; $btn.FontSize = 11; $btn.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4; $btn.Tag = $c
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        $btn.add_Click({ param($s, $e) Invoke-ActionCard $s.Tag })
        [void]$foot.Children.Add($btn); [void]$foot.Children.Add($badge)
        [void]$stack.Children.Add($head); [void]$stack.Children.Add($why); [void]$stack.Children.Add($foot)
        $card.Child = $stack
        [void]$panelActions.Children.Add($card)
    }
}

function Invoke-ActionCard {
    param($Card)
    if ($Card.Label -eq 'Needs administrator') { Restart-AsAdministrator; return }
    switch ($Card.Kind) {
        'Clean'     { Start-CleanCategory -Item $Card.Item }
        'Command'   { Invoke-CommandAction -Id $Card.Rule.CommandId -Param $Card.Rule.Param }
        'Uninstall' { Open-Settings -Rule $Card.Rule }
    }
}

function Open-Settings {
    param($Rule)
    $uri = if ($Rule.Uri) { $Rule.Uri } else { 'ms-settings:appsfeatures' }
    Start-Process $uri
    Log-Console "Opened Windows Settings for $($Rule.Title)." "SUCCESS"
}

# ---------------------------------------------------------------------------
# Admin: restart elevated, and run allow-listed commands
# ---------------------------------------------------------------------------

function Restart-AsAdministrator {
    if ($global:Jobs.action -or $global:Jobs.scan) {
        Show-Info "Wait for the running operation to finish (or cancel it), then restart as administrator."
        return
    }
    try {
        if ($PSCommandPath) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        } else {
            # Started from the web: there is no local file to relaunch, so the current release is fetched again
            if (-not (Confirm-Action "Diskman was started from the web, so there is no local file to relaunch.`n`nIt will download and run the current release from GitHub again, as administrator:`n$releaseUrl`n`nContinue?" 'Restart as Administrator' 'Question')) { return }
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', "irm '$releaseUrl' | iex")
        }
        Log-Console "Restarting as administrator..." "WARN"
        $window.Close()
    } catch {
        Log-Console "Administrator restart was cancelled or failed: $($_.Exception.Message)" "WARN"
    }
}

function Invoke-CommandAction {
    param([string]$Id, [string]$Param = $null)
    $cmd = (Get-AllowedCommands)[$Id]
    if (-not $cmd) { return }
    if ($Id -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) {
        Show-Info "Docker Desktop is not running, so there is nothing to prune yet.`n`nStart Docker Desktop, wait until its engine is running, then try again. To shrink the disk file itself, quit Docker Desktop and use Compact instead."
        return
    }
    if ($cmd.RequiresAdmin -and -not $isAdmin) { Restart-AsAdministrator; return }
    $detail = if ($Param) { "`n`nDisk: $Param" } else { '' }
    if (-not (Confirm-Action "$($cmd.Consent)$detail`n`nRun it now?" $cmd.Title 'Warning')) { return }
    Log-Console "Command approved by user: $($cmd.Title) ($($cmd.Exe) $($cmd.Args -join ' '))$(if ($Param) { " on $Param" })" "WARN"
    Start-BackgroundJob -Status $cmd.Title `
        -Vars @{ CmdId = $Id; CmdPath = $Param } `
        -Context @{ FreeBefore = (Get-DriveState).Free } `
        -Work { Invoke-AllowedCommand -Id $CmdId -Path $CmdPath -OnLine { param($t) $LogQueue.Enqueue(@($t, 'INFO')) } } `
        -OnDone {
            param($out, $ctx)
            $code = @($out) | Where-Object { $_ -is [int] } | Select-Object -Last 1
            Log-Console "Command finished (exit code $code). $driveLetter free space went from $(Format-Bytes $ctx.FreeBefore) to $(Format-Bytes (Get-DriveState).Free). Rescanning to show the new sizes." $(if ($code -eq 0) { 'SUCCESS' } else { 'WARN' })
            Start-SpaceScan
        }
}

# ---------------------------------------------------------------------------
# Selected-row action bar, shared by Overview and Space Explorer
# ---------------------------------------------------------------------------

function Set-ActionBar {
    param($Row, $Text, $OpenBtn, $ActionBtn, $CopyBtn = $null)
    $busy = [bool]$global:Jobs.action
    if (-not $Row) {
        $OpenBtn.IsEnabled = $false; $ActionBtn.IsEnabled = $false; $ActionBtn.Content = 'Action'
        if ($CopyBtn) { $CopyBtn.IsEnabled = $false }
        return
    }
    $rule = $Row.Rule
    $hasPath = [bool]$Row.Path -and (Test-Path -LiteralPath $Row.Path)
    $OpenBtn.IsEnabled = $hasPath
    if ($CopyBtn) { $CopyBtn.IsEnabled = [bool]$Row.Path }
    $what = if ($rule) { "$($rule.Title): $($rule.What)" } else { 'Not recognised. Open it in Explorer to decide; Diskman only offers deletion for folders it knows are safe.' }
    $Text.Text = "$($Row.Path)  -  $($Row.DisplaySize)`n$what"
    $Text.ToolTip = $Text.Text
    $label = 'Review only'; $enabled = $false
    if ($rule) {
        switch ($rule.Verdict) {
            'Clean'     { $label = 'Clean...'; $enabled = $true }
            'Command'   {
                $label = (Get-AllowedCommands)[$rule.CommandId].Short; $enabled = $true
                if ($rule.CommandId -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) { $label = 'Start Docker to prune' }
            }
            'Uninstall' { $label = 'Open Settings'; $enabled = $true }
            'System'    { $label = 'Windows-managed' }
        }
        if ($enabled -and $rule.RequiresAdmin -and -not $isAdmin) { $label = 'Needs administrator' }
    }
    $ActionBtn.Content = $label
    $ActionBtn.IsEnabled = $enabled -and -not $busy
}

function Show-OverviewSelection { Set-ActionBar -Row $gridTopFolders.SelectedItem -Text $txtOverviewSelected -OpenBtn $btnOverviewOpen -ActionBtn $btnOverviewAction }
function Show-SpaceSelection { Set-ActionBar -Row $gridSpace.SelectedItem -Text $txtSpaceSelected -OpenBtn $btnSpaceOpen -ActionBtn $btnSpaceAction -CopyBtn $btnSpaceCopy }

function Invoke-RowAction {
    param($Row)
    if (-not $Row -or -not $Row.Rule) { return }
    $rule = $Row.Rule
    if ($rule.RequiresAdmin -and -not $isAdmin) { Restart-AsAdministrator; return }
    switch ($rule.Verdict) {
        'Clean' {
            $item = $global:ScannedCleanupItems | Where-Object { $_.Id -eq $rule.TargetId } | Select-Object -First 1
            if ($item) { Start-CleanCategory -Item $item } else { Log-Console "Run Rescan first: the cleanup scan has no entry for $($rule.Title)." "WARN" }
        }
        'Command'   { Invoke-CommandAction -Id $rule.CommandId -Param $rule.Param }
        'Uninstall' { Open-Settings -Rule $rule }
    }
}

function Open-RowInExplorer {
    param($Row)
    if ($Row -and $Row.Path) {
        if (Test-Path -LiteralPath $Row.Path -PathType Leaf) { Show-ItemInExplorer -Path $Row.Path | Out-Null } else { Open-FolderInExplorer -Path $Row.Path | Out-Null }
        Log-Console "Opened in File Explorer: $($Row.Path)" "SUCCESS"
    }
}

# ---------------------------------------------------------------------------
# Space Explorer
# ---------------------------------------------------------------------------

function Set-SpaceNode {
    param($Node, [switch]$Reset)
    if ($Reset) { $global:SpaceStack.Clear() }
    [void]$global:SpaceStack.Add($Node)

    $panelCrumbs.Children.Clear()
    for ($i = 0; $i -lt $global:SpaceStack.Count; $i++) {
        $n = $global:SpaceStack[$i]
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = if ($i -eq 0) { $n.Path } else { $n.Name }
        $btn.Style = $window.FindResource('CrumbButton'); $btn.Tag = $i
        $btn.add_Click({ param($s, $e) Move-SpaceUp -ToIndex ([int]$s.Tag) })
        [void]$panelCrumbs.Children.Add($btn)
        if ($i -lt $global:SpaceStack.Count - 1) {
            $sep = New-Object System.Windows.Controls.TextBlock
            $sep.Text = '>'; $sep.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $sep.VerticalAlignment = 'Center'
            [void]$panelCrumbs.Children.Add($sep)
        }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($child in $Node.Children) { [void]$rows.Add((New-SpaceRow -Node $child -ParentBytes $Node.Bytes)) }
    if ($Node.OwnBytes -gt 0) {
        $own = [PSCustomObject]@{ Path = $Node.Path; Bytes = [long]$Node.OwnBytes; Files = [long]0; ModifiedTicks = 0 }
        $row = New-SpaceRow -Node $own -ParentBytes $Node.Bytes -Name '(files and small folders here)' -Display $Node.Path
        $row.Insight = ''; $row.FilesText = ''; $row.Rule = $null; $row.Node = $null
        [void]$rows.Add($row)
    }
    $gridSpace.ItemsSource = $rows
    Set-Empty $txtEmptyExplorer $rows
    if ($rows.Count -eq 0) { $txtEmptyExplorer.Text = 'This folder has nothing over 1 MB.' }
    $btnSpaceUp.IsEnabled = $global:SpaceStack.Count -gt 1
    if ($rows.Count -gt 0) { $gridSpace.SelectedIndex = 0 }
    Show-SpaceSelection
}

function Move-SpaceUp {
    param([int]$ToIndex = -1)
    if ($global:SpaceStack.Count -le 1) { return }
    if ($ToIndex -lt 0) { $ToIndex = $global:SpaceStack.Count - 2 }
    while ($global:SpaceStack.Count -gt $ToIndex + 1) { $global:SpaceStack.RemoveAt($global:SpaceStack.Count - 1) }
    $target = $global:SpaceStack[$global:SpaceStack.Count - 1]
    $global:SpaceStack.RemoveAt($global:SpaceStack.Count - 1)
    Set-SpaceNode -Node $target
}

function Enter-SpaceRow {
    $row = $gridSpace.SelectedItem
    if ($row -and $row.Node -is [Diskman.Node]) { Set-SpaceNode -Node $row.Node }
}

# ---------------------------------------------------------------------------
# Scans
# ---------------------------------------------------------------------------

function Start-SpaceScan {
    # A scan that is already running would show sizes from before the change that asked for a new one: queue exactly one more
    if ($global:Jobs.scan) {
        $global:RescanPending = $true
        Log-Console "A drive scan is already running; another will start when it finishes so the sizes are current." "WARN"
        return
    }
    Start-BackgroundJob -Slot scan -Status "Scanning the whole $driveLetter drive" `
        -Context @{} `
        -Work {
            $tree = Scan-DriveTree -Root "$($env:SystemDrive)\"
            # Everything that only reads the finished tree runs here, so the window never freezes at the end of a scan
            [PSCustomObject]@{ Tree = $tree; Detected = @(Find-AppCaches -Root $tree); Categories = (Get-SpaceCategory -Root $tree) }
        } `
        -OnDone {
            param($out, $ctx)
            $bundle = @($out) | Where-Object { $_.PSObject.Properties['Tree'] } | Select-Object -Last 1
            if ($bundle) { Show-ScanResults -Bundle $bundle -Partial ([bool]$ctx['Cancelled']) } else { Log-Console "The drive scan returned no data." "ERROR" }
            $again = $global:RescanPending -and -not $ctx['Cancelled']
            $global:RescanPending = $false
            if ($again) { Start-SpaceScan }
        }
}

# ---------------------------------------------------------------------------
# Cleaner tab
# ---------------------------------------------------------------------------

function Update-SelectedCleanupBadge {
    $totalSelectedBytes = 0
    $selectedCount = 0
    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.IsSelected -eq $true) { $totalSelectedBytes += $item.RawBytes; $selectedCount++ }
    }
    $txtCleanBadge.Text = "Selected: $(Format-Bytes -Bytes $totalSelectedBytes) ($selectedCount categories)"
}

function Apply-CleanupFilter {
    param([string]$Group)
    $global:CurrentFilterGroup = $Group

    if ($Group -eq "All") {
        $gridCleanCategories.ItemsSource = [System.Collections.ArrayList]@($global:ScannedCleanupItems)
    } else {
        $filtered = @($global:ScannedCleanupItems | Where-Object { $_.Group -like "*$Group*" })
        $gridCleanCategories.ItemsSource = [System.Collections.ArrayList]@($filtered)
    }

    $chips = @{
        "All" = $btnFilterAll; "Windows & System" = $btnFilterSys; "Gaming" = $btnFilterGaming
        "Developer" = $btnFilterDev; "Browser" = $btnFilterBrowser
    }
    foreach ($key in $chips.Keys) {
        $active = ($key -eq $Group)
        $chips[$key].Background  = $brushConverter.ConvertFromString($(if ($active) { "#0077B6" } else { "#2A2A30" }))
        $chips[$key].BorderBrush = $brushConverter.ConvertFromString($(if ($active) { "#00B4D8" } else { "#3F3F46" }))
    }
    if ($gridCleanCategories.Items.Count -gt 0) { $gridCleanCategories.SelectedIndex = 0 }
}

# Full scan replaces the list; a partial scan (after cleaning) replaces only those rows.
function Set-ScanResults {
    param($Items, [switch]$Merge, [switch]$Quiet)

    $items = @($Items | Where-Object { $_ -and $_.Id })
    if ($Merge) {
        $ids = @($items | ForEach-Object { $_.Id })
        $kept = @($global:ScannedCleanupItems | Where-Object { $_.Id -notin $ids })
        $items = @($kept + $items) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    }
    if (-not $Merge -and -not $Quiet) {
        # A fresh scan of the fixed categories must not forget the app caches detected by the drive scan
        $items = @($items + @($global:ScannedCleanupItems | Where-Object { $_.Dynamic })) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    }
    $global:ScannedCleanupItems = [System.Collections.ArrayList]@($items)
    Apply-CleanupFilter $global:CurrentFilterGroup

    $previousId = if ($cmbInspectTarget.SelectedItem) { ($cmbInspectTarget.SelectedItem -split " - ")[0].Trim() } else { $null }
    $cmbInspectTarget.Items.Clear()
    $totalReclaimable = 0
    foreach ($item in $items) {
        $totalReclaimable += $item.RawBytes
        $dispLabel = if ($item.RawBytes -gt 0) { "$($item.Id) - $($item.CategoryName) ($($item.DisplaySize))" } else { "$($item.Id) - $($item.CategoryName)" }
        if (-not $item.Dynamic) { $cmbInspectTarget.Items.Add($dispLabel) | Out-Null }
        if (-not $Merge -and -not $Quiet -and $item.RawBytes -gt 0) {
            Log-Console "Detected $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount)) at $($item.Target)"
        }
    }
    $restore = 0
    if ($previousId) {
        for ($i = 0; $i -lt $cmbInspectTarget.Items.Count; $i++) {
            if ($cmbInspectTarget.Items[$i] -like "$previousId - *") { $restore = $i; break }
        }
    }
    if ($cmbInspectTarget.Items.Count -gt 0) { $cmbInspectTarget.SelectedIndex = $restore }

    $txtCReclaimable.Text = "~$(Format-Bytes -Bytes $totalReclaimable)"
    Update-SelectedCleanupBadge
    Update-FreeSafely
    Update-ActionCards
    Update-OverviewVerdict
    if (-not $Merge -and -not $Quiet) {
        Log-Console "Cleaner scan complete: $(Format-Bytes -Bytes $totalReclaimable) found across cleanup categories." "SUCCESS"
    }
}

function Start-ScanCJunk {
    param([string[]]$Id)
    Start-BackgroundJob -Status "Scanning cleanup categories" `
        -Vars @{ Ids = $Id } `
        -Context @{ Merge = [bool]$Id } `
        -Work { if ($Ids) { Scan-SmartCleanupItems -Id $Ids } else { Scan-SmartCleanupItems } } `
        -OnDone { param($out, $ctx) Set-ScanResults -Items $out -Merge:$ctx.Merge }
}

# Full rescan of everything: cleanup categories (action slot) and the whole-drive tree (scan slot)
function Start-FullRescan {
    Update-CDriveMetricsDisplay
    Start-ScanCJunk
    Start-SpaceScan
}

# Worker-side progress callback shared by both cleanup actions (runs on the worker, queues lines for the UI)
$cleanupWork = {
    $onProgress = { param($m, $l) $LogQueue.Enqueue(@($m, $l)) }
    if ($TargetId) { Invoke-ExecuteCategoryCleanup -TargetId $TargetId -OnProgress $onProgress }
    else { Invoke-ExecuteCleanup -SelectedItems $Items -OnProgress $onProgress }
}

# Shared completion for both cleanup actions: report, then rescan only the rows that changed
$cleanupDone = {
    param($out, $ctx)
    $res = @($out) | Where-Object { $_.PSObject.Properties['TotalFreedBytes'] } | Select-Object -Last 1
    $freed = if ($res) { $res.DisplayFreed } else { "0 B" }
    $purged = if ($res) { $res.DeletedCount } else { 0 }
    $delta = if ($ctx.FreeBefore) { "$driveLetter free space went from $(Format-Bytes $ctx.FreeBefore) to $(Format-Bytes (Get-DriveState).Free)." } else { '' }
    Log-Console "CLEANUP FINISHED! Total space freed: $freed ($purged items purged). $delta" "SUCCESS"
    Show-Info "$($ctx.Title) complete.`n`nFreed space: $freed`nPurged items: $purged`n$delta`n`nThe Activity log (and the audit file in $global:AuditLogDir) lists anything that was skipped."
    # Detected app caches are not in the fixed list, so they are re-measured directly; fixed categories are rescanned by id
    foreach ($id in @($ctx.Ids | Where-Object { $_ -like 'App:*' })) {
        $item = $global:ScannedCleanupItems | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($item) { [void](Update-DetectedItemSize -Item $item) }
    }
    $fixedIds = @($ctx.Ids | Where-Object { $_ -notlike 'App:*' })
    if ($fixedIds.Count -gt 0) { Start-ScanCJunk -Id $fixedIds }
    else { Set-ScanResults -Items @($global:ScannedCleanupItems) -Quiet }
    if ($global:SpaceTree) { Start-SpaceScan }
}

function Start-BulkClean {
    param($Targets)
    $targetsToClean = @($Targets)
    $totalCleanBytes = [int64](($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum)
    if ($targetsToClean.Count -eq 0) {
        Show-Info "No items are selected for cleanup.`n`nTick the boxes next to the categories you want to clean."
        return
    }

    $safeCount = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Safe' }).Count
    $optCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Optional' }).Count
    $advCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Advanced' }).Count

    $breakdown = "Selected: $safeCount Safe, $optCount Optional, $advCount Advanced."
    if ($advCount -gt 0) { $breakdown += "`n`n[ADVANCED] Windows Update and servicing caches are selected. Diskman skips them while Windows Update, BITS or servicing reports activity or a pending reboot." }
    if ($optCount -gt 0) { $breakdown += "`n`n[OPTIONAL] Developer, offline media or Recycle Bin items are selected. Caches are re-downloaded on demand." }
    if (@($targetsToClean | Where-Object { $_.Type -eq 'RecycleBin' }).Count -gt 0) {
        $breakdown += "`n`n[RECYCLE BIN] Everything currently in the Recycle Bin will be permanently deleted. It cannot be restored."
    }

    $bullet = [char]0x2022
    $largest = ($targetsToClean | Sort-Object -Property RawBytes -Descending | Select-Object -First 10 | ForEach-Object { "$bullet $($_.CategoryName): $($_.DisplaySize)" }) -join "`n"
    if ($targetsToClean.Count -gt 10) { $largest += "`n$bullet ... and $($targetsToClean.Count - 10) more" }
    $confirmMsg = "Clean $(Format-Bytes -Bytes $totalCleanBytes) across $($targetsToClean.Count) categories on ${driveLetter}?`n`nLargest:`n$largest`n`n$breakdown`n`n" +
                  "What Diskman will and will not touch:`n" +
                  "$bullet Only the folders listed in the table are cleaned. Deleted files do NOT go to the Recycle Bin.`n" +
                  "$bullet Documents, Desktop, Downloads, Pictures, Music, Videos and OneDrive are blocked from bulk cleanup.`n" +
                  "$bullet Browser passwords, cookies, history and bookmarks are never deleted.`n" +
                  "$bullet Files that are in use are skipped and reported in the log.`n`n" +
                  "Clean now?"
    if (-not (Confirm-Action $confirmMsg "Confirm $driveLetter drive cleanup")) { return }

    Log-Console "=========================================================="
    Log-Console "Cleaning approved by user: $(Format-Bytes -Bytes $totalCleanBytes) in $($targetsToClean.Count) categories ($safeCount Safe, $optCount Optional, $advCount Advanced)"
    if (@($targetsToClean | Where-Object { $_.RequiresAdmin -eq $true }).Count -gt 0 -and -not $isAdmin) {
        Log-Console "Notice: Selected system items require Administrator rights and will be skipped." "WARN"
    }

    Start-BackgroundJob -Status "Cleaning $driveLetter drive" `
        -Vars @{ Items = $targetsToClean; TargetId = $null } `
        -Context @{ Title = "$driveLetter drive cleanup"; Ids = @($targetsToClean | ForEach-Object { $_.Id }); FreeBefore = (Get-DriveState).Free } `
        -Work $cleanupWork -OnDone $cleanupDone
}

function Start-CleanCategory {
    param($Item)
    if (-not $Item) { return }
    if ($Item.RawBytes -le 0) { Show-Info "The selected category ($($Item.CategoryName)) is already empty."; return }
    if (-not $Item.CanSelect) { Restart-AsAdministrator; return }

    $safetyText = if ($Item.SafetyExplanation) { $Item.SafetyExplanation } else { "Safe to delete. User files and credentials are untouched." }
    $deletedText = if ($Item.WhatGetsDeleted) { $Item.WhatGetsDeleted } else { $Item.Description }
    $consequencesText = if ($Item.Consequences) { $Item.Consequences } else { "Files auto-regenerate on next launch." }
    $badgeText = if ($Item.SafetyBadge) { $Item.SafetyBadge } else { $Item.SafetyLevel.ToUpper() }

    $dialogMsg = "Category: $($Item.CategoryName) [$badgeText]`n" +
                 "Size: $($Item.DisplaySize) ($($Item.FileCount))`n" +
                 "Path: $($Item.Target)`n`n" +
                 "[WHAT GETS DELETED]`n$deletedText`n`n" +
                 "[SAFETY & PROTECTED DATA]`n$safetyText`n`n" +
                 "[CONSEQUENCES & REBUILD]`n$consequencesText`n`n" +
                 "Deleted files do not go to the Recycle Bin. Proceed?"
    if (-not (Confirm-Action $dialogMsg "Confirm cleanup - $($Item.CategoryName)" 'Question')) { return }

    Log-Console "Cleaning approved by user: $($Item.CategoryName) ($($Item.DisplaySize)) at $(@($Item.Targets + $Item.Target | Where-Object { $_ } | Select-Object -Unique) -join '; ')" "WARN"
    # Every item goes through Invoke-ExecuteCleanup (detected ones are not known to Invoke-ExecuteCategoryCleanup)
    $Item.IsSelected = $true
    Start-BackgroundJob -Status "Purging $($Item.CategoryName)" `
        -Vars @{ Items = @($Item); TargetId = $null } `
        -Context @{ Title = $Item.CategoryName; Ids = @($Item.Id); FreeBefore = (Get-DriveState).Free } `
        -Work $cleanupWork -OnDone $cleanupDone
}

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------

$btnSelectRec.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        if (-not $item.CanSelect) { $item.IsSelected = $false }
        else { $item.IsSelected = ($item.Recommended -and $item.SafetyLevel -ne 'Advanced' -and $item.RawBytes -gt 0) }
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Applied recommended cleanup selection preset (Advanced and Optional targets excluded by default)."
})
$btnSelectAll.add_Click({
    foreach ($item in $global:ScannedCleanupItems) { $item.IsSelected = ($item.RawBytes -gt 0 -and $item.CanSelect) }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Selected all available junk categories."
})
$btnClearSel.add_Click({
    foreach ($item in $global:ScannedCleanupItems) { $item.IsSelected = $false }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Cleared all selections."
})
$gridCleanCategories.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ Update-SelectedCleanupBadge })

$btnFilterAll.add_Click({ Apply-CleanupFilter "All" })
$btnFilterSys.add_Click({ Apply-CleanupFilter "Windows & System" })
$btnFilterGaming.add_Click({ Apply-CleanupFilter "Gaming" })
$btnFilterDev.add_Click({ Apply-CleanupFilter "Developer" })
$btnFilterBrowser.add_Click({ Apply-CleanupFilter "Browser" })

$gridCleanCategories.add_SelectionChanged({
    $sel = $gridCleanCategories.SelectedItem
    if ($sel) {
        $txtSelectedCatTitle.Text = "$($sel.DisplayName)"
        $bullet = [char]0x2022
        $txtSelectedCatSizeInfo.Text = "$bullet Size: $($sel.DisplaySize) ($($sel.FileCount))"
        $txtSelectedCatSafetyBadge.Text = if ($sel.SafetyBadge) { $sel.SafetyBadge } else { $sel.SafetyLevel.ToUpper() }
        $badgeColor = switch ($sel.SafetyLevel) { 'Advanced' { "#C1121F" } 'Optional' { "#FFB703" } default { "#2EC4B6" } }
        $badgeSafetyLevel.Background = $brushConverter.ConvertFromString($badgeColor)
        $txtSelectedCatSafetyBadge.Foreground = $brushConverter.ConvertFromString($(if ($sel.SafetyLevel -eq 'Advanced') { '#FFFFFF' } else { '#141416' }))
        $txtCategoryWhatDeleted.Text = if ($sel.WhatGetsDeleted) { $sel.WhatGetsDeleted } else { $sel.Description }
        $txtCategorySafetyExp.Text = if ($sel.SafetyExplanation) { $sel.SafetyExplanation } else { "Safe to delete. User documents and credentials are untouched." }
        $txtCategoryConsequences.Text = if ($sel.Consequences) { $sel.Consequences } else { "Files will be regenerated or re-downloaded as needed." }
    }
})

$btnOpenCatInExplorer.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to open in File Explorer."; return }
    if ($sel.Type -eq "RecycleBin") {
        Start-Process "explorer.exe" -ArgumentList "shell:RecycleBinFolder"
        Log-Console "Opened Windows Recycle Bin in File Explorer." "SUCCESS"
    } elseif (Open-FolderInExplorer -Path $sel.Target) {
        Log-Console "Opened in File Explorer: $($sel.Target)" "SUCCESS"
    } else {
        Log-Console "Folder does not exist or is currently empty: $($sel.Target)" "WARN"
        Show-Info "The target folder ($($sel.Target)) does not exist or has no files."
    }
})

$btnInspectCatFiles.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to inspect its files."; return }
    if ($sel.Dynamic) {
        # Detected app caches are not in the Inspector's list: show the first folder in Explorer instead of loading some other category
        Open-FolderInExplorer -Path $sel.Target | Out-Null
        Log-Console "Opened $($sel.Target) in File Explorer (detected caches are not listed in the File Inspector)." "SUCCESS"
        return
    }
    for ($i = 0; $i -lt $cmbInspectTarget.Items.Count; $i++) {
        if ($cmbInspectTarget.Items[$i] -like "$($sel.Id) - *") { $cmbInspectTarget.SelectedIndex = $i; break }
    }
    $mainTabControl.SelectedItem = $tabInspector
    $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

$btnRunCleanup.add_Click({ Start-BulkClean -Targets @($global:ScannedCleanupItems | Where-Object { $_.IsSelected -eq $true -and $_.RawBytes -gt 0 }) })
$btnCleanSingleCategory.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to clean."; return }
    Start-CleanCategory -Item $sel
})
$btnFreeSafely.add_Click({ Start-BulkClean -Targets (Get-SafeCleanItems) })

# File Inspector
$btnRefreshInspectFiles.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    $targetId = ($selTargetStr -split " - ")[0].Trim()
    Start-BackgroundJob -Status "Loading file list for $targetId" `
        -Vars @{ TargetId = $targetId } `
        -Context @{ TargetId = $targetId } `
        -Work { Get-CleanableCategoryFiles -TargetId $TargetId -Limit 250 } `
        -OnDone {
            param($out, $ctx)
            $files = @($out)
            $gridInspectFiles.ItemsSource = $files
            Set-Empty $txtEmptyInspector $files
            if ($files.Count -eq 0) { $txtEmptyInspector.Text = 'No files found in this category.' }
            $totalInspectBytes = [int64](($files | Measure-Object -Property RawBytes -Sum).Sum)
            $txtInspectSummary.Text = "Loaded $($files.Count) files (Total: $(Format-Bytes -Bytes $totalInspectBytes))"
            Log-Console "Loaded $($files.Count) files for $($ctx.TargetId) ($(Format-Bytes -Bytes $totalInspectBytes))" "SUCCESS"
        }
})
$gridInspectFiles.add_SelectionChanged({
    $sel = $gridInspectFiles.SelectedItem
    $txtSelectedInspectInfo.Text = if ($sel) { "$($sel.Name) ($($sel.DisplaySize)) - Path: $($sel.FullPath)" } else { "Select a file to inspect or delete." }
})
$btnRevealInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed in File Explorer: $($sel.FullPath)" "SUCCESS"
    } else { Show-Info "Select a valid file to reveal." }
})
$btnDeleteSingleInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        if (Confirm-Action "Permanently delete file '$($sel.Name)' ($($sel.DisplaySize))?`n`nPath: $($sel.FullPath)" "Confirm file delete" 'Question') {
            $res = Remove-ItemPermanently -Path $sel.FullPath
            if ($res.Success) {
                Log-Console "Deleted file: $($sel.FullPath)" "SUCCESS"
                $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Failed to delete file: $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Error'
            }
        }
    }
})
$btnPurgeAllInspect.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    $targetId = ($selTargetStr -split " - ")[0].Trim()
    if (-not (Confirm-Action "Delete EVERYTHING in '$selTargetStr'?`n`nThis cleans the whole category, not only the files listed in this table. Deleted files do not go to the Recycle Bin." "Confirm clear all")) { return }
    Log-Console "Whole-category cleaning approved by user: $selTargetStr" "WARN"
    Start-BackgroundJob -Status "Purging $targetId" `
        -Vars @{ Items = $null; TargetId = $targetId } `
        -Context @{ Title = $targetId; Ids = @($targetId) } `
        -Work $cleanupWork -OnDone {
            param($out, $ctx)
            & $cleanupDone $out $ctx
            $gridInspectFiles.ItemsSource = @()
            Set-Empty $txtEmptyInspector @()
            $txtInspectSummary.Text = "Pick a category and click Load Files to list its biggest files."
        }
})

# Large Files
$cmbHuntSize.Items.Add("> 100 MB") | Out-Null
$cmbHuntSize.Items.Add("> 500 MB") | Out-Null
$cmbHuntSize.Items.Add("> 1 GB")   | Out-Null
$cmbHuntSize.Items.Add("> 5 GB")   | Out-Null
$cmbHuntSize.SelectedIndex = 0
foreach ($c in 'All Categories', 'Installer / Package', 'Disk Image / ISO', 'Archive / Zip', 'Video / Media', 'Log / Dump File', 'AI Model / Weights', 'Incomplete / Temp Download') { $cmbHuntCat.Items.Add($c) | Out-Null }
$cmbHuntCat.SelectedIndex = 0

$btnHuntScan.add_Click({
    $sizeMap = @{ "> 100 MB" = 100MB; "> 500 MB" = 500MB; "> 1 GB" = 1GB; "> 5 GB" = 5GB }
    $minSize = $sizeMap[$cmbHuntSize.SelectedItem]
    if (-not $minSize) { $minSize = 100MB }
    $cat = $cmbHuntCat.SelectedItem
    Start-BackgroundJob -Status "Hunting large files on $driveRoot ($($cmbHuntSize.SelectedItem) | $cat)" `
        -Vars @{ MinSize = $minSize; Cat = $cat; Root = $driveRoot } `
        -Work { Find-LargeFiles -TargetPath $Root -MinSizeBytes $MinSize -CategoryFilter $Cat -Limit 100 } `
        -OnDone {
            param($out)
            $files = @($out)
            $gridLargeFiles.ItemsSource = $files
            Set-Empty $txtEmptyHunter $files
            if ($files.Count -eq 0) { $txtEmptyHunter.Text = 'No matching files found. Try a lower minimum size or All Categories.' }
            Log-Console "Discovered $($files.Count) large files on the $driveLetter drive." "SUCCESS"
        }
})
$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    $txtSelectedLargeFile.Text = if ($sel) { "$($sel.Name) ($($sel.DisplaySize)) - $($sel.FullPath)" } else { "Select a large file to perform action." }
})
function Remove-HunterRow {
    param([string]$FullPath)
    $remaining = @($gridLargeFiles.ItemsSource | Where-Object { $_.FullPath -ne $FullPath })
    $gridLargeFiles.ItemsSource = $remaining
    Set-Empty $txtEmptyHunter $remaining
}
$btnRevealLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed file in File Explorer: $($sel.FullPath)" "SUCCESS"
    }
})
$btnTrashLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        if (Confirm-Action "Move this file to the Recycle Bin?`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)" "Move to Recycle Bin" 'Question') {
            $res = Send-ItemToRecycleBin -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Recycled file: $($sel.FullPath)" "SUCCESS"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not recycle $($sel.FullPath): $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Warning'
            }
        }
    }
})
$btnPermDeleteLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        $diskImageNote = if ($sel.Category -eq 'Disk Image / ISO') { "`n`nDisk images can hold a whole virtual machine or OS install. Make sure you do not need it." } else { "" }
        if (Confirm-Action "PERMANENT DELETE`n`nThis cannot be undone and skips the Recycle Bin.`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)$diskImageNote`n`nDelete it?" "Permanent delete") {
            $res = Remove-ItemPermanently -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Deleted file permanently: $($sel.FullPath)" "WARN"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not delete $($sel.FullPath): $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Warning'
            }
        }
    }
})

# Overview and Space Explorer
$gridTopFolders.add_SelectionChanged({ Show-OverviewSelection })
$btnOverviewOpen.add_Click({ Open-RowInExplorer $gridTopFolders.SelectedItem })
$btnOverviewAction.add_Click({ Invoke-RowAction $gridTopFolders.SelectedItem })
$gridSpace.add_SelectionChanged({ Show-SpaceSelection })
$gridSpace.add_MouseDoubleClick({ Enter-SpaceRow })
$gridSpace.add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { Enter-SpaceRow; $e.Handled = $true }
    elseif ($e.Key -eq 'Back') { Move-SpaceUp; $e.Handled = $true }
})
$btnSpaceUp.add_Click({ Move-SpaceUp })
$btnSpaceOpen.add_Click({ Open-RowInExplorer $gridSpace.SelectedItem })
$btnSpaceCopy.add_Click({
    $row = $gridSpace.SelectedItem
    if ($row -and $row.Path) { [System.Windows.Clipboard]::SetText($row.Path); Log-Console "Copied path: $($row.Path)" "SUCCESS" }
})
$btnSpaceAction.add_Click({ Invoke-RowAction $gridSpace.SelectedItem })

# Header and status bar
$btnTopQuickScan.add_Click({ Start-FullRescan })
$btnScanClean.add_Click({ Start-ScanCJunk })
$btnCancelScan.add_Click({ Stop-BackgroundJob -Slot scan })
$btnCancelAction.add_Click({ Stop-BackgroundJob -Slot action })
$btnRestartAdmin.add_Click({ Restart-AsAdministrator })
$btnRestartAdmin.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
$txtLogLocation.Text = "Audit log: $global:AuditLogDir"

# Startup banner
Log-Console "=========================================================="
Log-Console "DISKMAN - DRIVE SPACE CLEANER ($driveLetter)"
Log-Console "Every action is logged here and in $global:AuditLogDir"
if ($isAdmin) {
    Log-Console "Elevated Administrator mode: system areas can be measured and cleaned." "SUCCESS"
} else {
    Log-Console "Standard mode: some system areas are skipped. Use Restart as Administrator for the full picture." "WARN"
}
Log-Console "=========================================================="

Apply-CleanupFilter "All"
Set-Empty $txtEmptyHunter @()
Set-Empty $txtEmptyInspector @()
Set-Empty $txtEmptyExplorer @()
Set-Empty $txtEmptyTop @()
$window.Title = "Diskman - $driveLetter drive space cleaner"
(Find-Control 'TxtBrandSub').Text = "  |  $driveLetter drive space cleaner"
Update-CDriveMetricsDisplay
Update-FreeSafely
Update-ActionCards

# Render the window immediately, then scan in the background
$window.add_ContentRendered({
    if (-not $global:ScanStarted) {
        $global:ScanStarted = $true
        Start-ScanCJunk
        Start-SpaceScan
    }
})

# Do not let the window close in the middle of a delete without asking
$window.add_Closing({
    param($sender, $e)
    if ($global:Jobs.action -or $global:Jobs.scan) {
        if (-not (Confirm-Action "An operation is still running. Closing now stops it part-way.`n`nClose anyway?" "Diskman")) { $e.Cancel = $true }
    }
})

# Show Window
$window.ShowDialog() | Out-Null
