# Diskman - Main Application Controller (C: Drive Trash & Junk Purger)
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

# Live Console Logger Function (Streams to Terminal + GUI). Only ever called on the UI thread.
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
}

# Control References
$txtConsoleLog             = Find-Control "TxtConsoleLog"
$txtGlobalStat             = Find-Control "TxtGlobalStatus"
$mainTabControl            = Find-Control "MainTabControl"

# C: Drive Metrics Strip Controls
$txtCDriveTotal            = Find-Control "TxtCDriveTotal"
$txtCDriveUsed             = Find-Control "TxtCDriveUsed"
$txtCDriveFree             = Find-Control "TxtCDriveFree"
$progressCDrive            = Find-Control "ProgressCDrive"
$txtCBarPercent            = Find-Control "TxtCBarPercent"
$txtCBarStatus             = Find-Control "TxtCBarStatus"
$txtCReclaimable           = Find-Control "TxtCReclaimable"
$btnTopRefresh             = Find-Control "BtnTopRefresh"
$btnTopQuickScan           = Find-Control "BtnTopQuickScan"

# Tab 1: C: Junk Cleaner Controls
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

# Tab 2: File Inspector Controls
$cmbInspectTarget          = Find-Control "CmbInspectTarget"
$btnRefreshInspectFiles    = Find-Control "BtnRefreshInspectFiles"
$txtInspectSummary         = Find-Control "TxtInspectSummary"
$gridInspectFiles          = Find-Control "GridInspectFiles"
$txtSelectedInspectInfo    = Find-Control "TxtSelectedInspectFileInfo"
$btnRevealInspectFile       = Find-Control "BtnRevealInspectFileInExplorer"
$btnDeleteSingleInspectFile = Find-Control "BtnDeleteSingleInspectFile"
$btnPurgeAllInspect         = Find-Control "BtnPurgeAllInspectFiles"

# Tab 3: Hunter Controls
$cmbHuntSize               = Find-Control "CmbHunterSize"
$cmbHuntCat                = Find-Control "CmbHunterCategory"
$btnHuntScan               = Find-Control "BtnStartHunterScan"
$gridLargeFiles            = Find-Control "GridLargeFiles"
$txtSelectedLargeFile      = Find-Control "TxtSelectedFileInfo"
$btnRevealLargeFile        = Find-Control "BtnRevealInExplorer"
$btnTrashLargeFile         = Find-Control "BtnSendToTrash"
$btnPermDeleteLargeFile    = Find-Control "BtnPermanentDelete"

# Tab 4: Directory Explorer Controls
$btnFolderUp               = Find-Control "BtnFolderUp"
$txtPath                   = Find-Control "TxtCurrentPath"
$btnScanDir                = Find-Control "BtnScanCurrentDir"
$btnOpenDirInExplorer      = Find-Control "BtnOpenCurrentInExplorer"
$gridDir                   = Find-Control "GridDirectories"

# Internal State
$global:CurrentExplorerPath = "C:\"
$global:ExplorerLoaded      = $false
$global:ScannedCleanupItems = [System.Collections.ArrayList]@()
$global:CurrentFilterGroup  = "All"
$global:Job                 = $null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$brushConverter = New-Object System.Windows.Media.BrushConverter

# ---------------------------------------------------------------------------
# Background work: scans and deletes run in their own runspace so the window never freezes.
# The worker pushes log lines onto a queue; a DispatcherTimer on the UI thread drains it.
# ---------------------------------------------------------------------------

# Functions copied into the worker by definition, so this works uncompiled and in the single-file release
$workerFunctions = @(
    'Format-Bytes', 'Test-IsSubpathOrEqual', 'Test-ReparsePoint', 'Test-WindowsServicingActive', 'Test-PathSafety',
    'Get-FolderSizeFast', 'Get-CleanableTargets', 'Scan-SmartCleanupItems', 'Get-CleanableCategoryFiles',
    'Invoke-ExecuteCleanup', 'Invoke-ExecuteCategoryCleanup', 'Find-LargeFiles', 'Start-FolderScan'
)

# Everything that must not be clicked while a job runs (one job at a time; no nested handlers)
$busyControls = @(
    $btnTopRefresh, $btnTopQuickScan, $btnSelectRec, $btnSelectAll, $btnClearSel, $btnScanClean, $btnRunCleanup,
    $btnCleanSingleCategory, $btnRefreshInspectFiles, $btnDeleteSingleInspectFile, $btnPurgeAllInspect,
    $btnHuntScan, $btnTrashLargeFile, $btnPermDeleteLargeFile, $btnScanDir, $btnFolderUp
)

function Set-Busy {
    param([bool]$Busy)
    foreach ($c in $busyControls) { $c.IsEnabled = -not $Busy }
}

$jobTimer = New-Object System.Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$jobTimer.add_Tick({
    $job = $global:Job
    if (-not $job) { $jobTimer.Stop(); return }

    $msg = $null
    while ($job.Queue.TryDequeue([ref]$msg)) { Log-Console $msg[0] $msg[1] }
    $txtGlobalStat.Text = "$($job.Status)... $([int]((Get-Date) - $job.Started).TotalSeconds)s (window stays usable; actions are paused)"

    if (-not $job.Async.IsCompleted) { return }

    $jobTimer.Stop()
    $output = @()
    $failure = $null
    try { $output = @($job.Ps.EndInvoke($job.Async)) } catch { $failure = $_ }
    $job.Ps.Dispose()
    $job.Runspace.Dispose()
    $global:Job = $null
    Set-Busy $false
    Update-CDriveMetricsDisplay -Quiet

    if ($failure) {
        Log-Console "$($job.Status) failed: $failure" "ERROR"
    } else {
        & $job.OnDone $output $job.Context
    }
})

function Start-BackgroundJob {
    param(
        [string]$Status,
        [scriptblock]$Work,
        [hashtable]$Vars = @{},
        [hashtable]$Context = @{},
        [scriptblock]$OnDone
    )

    if ($global:Job) {
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

    $global:Job = @{
        Status = $Status; Ps = $ps; Runspace = $rs; Queue = $queue; OnDone = $OnDone; Context = $Context
        Started = Get-Date; Async = $ps.BeginInvoke()
    }
    Set-Busy $true
    Log-Console "$Status..."
    $jobTimer.Start()
}

# Function: Update C: Drive Metrics Display
function Update-CDriveMetricsDisplay {
    param([switch]$Quiet)
    $cMetrics = Get-CDriveMetrics
    if ($cMetrics) {
        $txtCDriveTotal.Text = "$($cMetrics.TotalGB) GB"
        $txtCDriveUsed.Text  = "$($cMetrics.UsedGB) GB"
        $txtCDriveFree.Text  = "$($cMetrics.FreeGB) GB"
        $progressCDrive.Value = $cMetrics.UsedPercent
        $txtCBarPercent.Text = "$($cMetrics.UsedPercent)% used - $($cMetrics.StatusText)"
        $txtCBarStatus.Text  = "Drive C: [$($cMetrics.VolumeLabel)] ($($cMetrics.FileSystem))"

        $txtGlobalStat.Text  = "C: Drive Status: $($cMetrics.FreeGB) GB Free of $($cMetrics.TotalGB) GB ($($cMetrics.StatusText))"
        if (-not $Quiet) {
            Log-Console "C: Drive Status: $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)"
        }
    }
}

# Function: Recalculate Selected Total Badge
function Update-SelectedCleanupBadge {
    $totalSelectedBytes = 0
    $selectedCount = 0

    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.IsSelected -eq $true) {
            $totalSelectedBytes += $item.RawBytes
            $selectedCount++
        }
    }

    $txtCleanBadge.Text = "Selected: $(Format-Bytes -Bytes $totalSelectedBytes) ($selectedCount categories)"
}

# Function: Apply Filter on Cleanable Grid and highlight the active chip
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

    if ($gridCleanCategories.Items.Count -gt 0) {
        $gridCleanCategories.SelectedIndex = 0
    }
}

# Function: Show scan results. Full scan replaces the list; a partial scan (after cleaning) replaces only those rows.
function Set-ScanResults {
    param($Items, [switch]$Merge)

    $items = @($Items | Where-Object { $_ -and $_.Id })
    if ($Merge) {
        $ids = @($items | ForEach-Object { $_.Id })
        $kept = @($global:ScannedCleanupItems | Where-Object { $_.Id -notin $ids })
        $items = @($kept + $items) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    }
    $global:ScannedCleanupItems = [System.Collections.ArrayList]@($items)
    Apply-CleanupFilter $global:CurrentFilterGroup

    # Rebuild the Inspector dropdown (ordered by size) and keep the user's current choice
    $previousId = if ($cmbInspectTarget.SelectedItem) { ($cmbInspectTarget.SelectedItem -split " - ")[0].Trim() } else { $null }
    $cmbInspectTarget.Items.Clear()
    $totalReclaimable = 0
    foreach ($item in $items) {
        $totalReclaimable += $item.RawBytes
        $dispLabel = if ($item.RawBytes -gt 0) { "$($item.Id) - $($item.CategoryName) ($($item.DisplaySize))" } else { "$($item.Id) - $($item.CategoryName)" }
        $cmbInspectTarget.Items.Add($dispLabel) | Out-Null
        if (-not $Merge -and $item.RawBytes -gt 0) {
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
    if (-not $Merge) {
        Log-Console "Scan complete! Total reclaimable space on C: drive: $(Format-Bytes -Bytes $totalReclaimable)" "SUCCESS"
    }
}

# Function: Scan C: Drive Junk (all targets, or only the given ids after a cleanup)
function Start-ScanCJunk {
    param([string[]]$Id)
    Start-BackgroundJob -Status "Scanning C: drive for unnecessary files, caches, logs, and trash" `
        -Vars @{ Ids = $Id } `
        -Context @{ Merge = [bool]$Id } `
        -Work { if ($Ids) { Scan-SmartCleanupItems -Id $Ids } else { Scan-SmartCleanupItems } } `
        -OnDone { param($out, $ctx) Set-ScanResults -Items $out -Merge:$ctx.Merge }
}

# Selection Presets
$btnSelectRec.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.RequiresAdmin -and -not $isAdmin) {
            $item.IsSelected = $false
        } else {
            $item.IsSelected = ($item.Recommended -and $item.SafetyLevel -ne 'Advanced' -and $item.RawBytes -gt 0)
        }
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Applied recommended cleanup selection preset (Advanced and Optional targets excluded by default)."
})

$btnSelectAll.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        $item.IsSelected = ($item.RawBytes -gt 0)
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Selected all available C: junk categories."
})

$btnClearSel.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        $item.IsSelected = $false
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Cleared all selections."
})

# Ticking a box in the grid bubbles a Click up to the grid: refresh the total
$gridCleanCategories.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ Update-SelectedCleanupBadge })

# Filter Chips
$btnFilterAll.add_Click({ Apply-CleanupFilter "All" })
$btnFilterSys.add_Click({ Apply-CleanupFilter "Windows & System" })
$btnFilterGaming.add_Click({ Apply-CleanupFilter "Gaming" })
$btnFilterDev.add_Click({ Apply-CleanupFilter "Developer" })
$btnFilterBrowser.add_Click({ Apply-CleanupFilter "Browser" })

# Category Selection Changed in Grid
$gridCleanCategories.add_SelectionChanged({
    $sel = $gridCleanCategories.SelectedItem
    if ($sel) {
        $txtSelectedCatTitle.Text = "$($sel.DisplayName)"
        $bullet = [char]0x2022
        $txtSelectedCatSizeInfo.Text = "$bullet Size on C: $($sel.DisplaySize) ($($sel.FileCount))"

        $badgeText = if ($sel.SafetyBadge) { $sel.SafetyBadge } else { $sel.SafetyLevel.ToUpper() }
        $txtSelectedCatSafetyBadge.Text = $badgeText
        $badgeColor = switch ($sel.SafetyLevel) { 'Advanced' { "#E63946" } 'Optional' { "#FFB703" } default { "#2EC4B6" } }
        $badgeSafetyLevel.Background = $brushConverter.ConvertFromString($badgeColor)

        $txtCategoryWhatDeleted.Text = if ($sel.WhatGetsDeleted) { $sel.WhatGetsDeleted } else { $sel.Description }
        $txtCategorySafetyExp.Text = if ($sel.SafetyExplanation) { $sel.SafetyExplanation } else { "Safe to delete. User documents and credentials are untouched." }
        $txtCategoryConsequences.Text = if ($sel.Consequences) { $sel.Consequences } else { "Files will be regenerated or re-downloaded as needed." }
    }
})

# 1. Action: Open in File Explorer
$btnOpenCatInExplorer.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show("Please select a junk category to open in File Explorer.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    if ($sel.Type -eq "RecycleBin") {
        Start-Process "explorer.exe" -ArgumentList "shell:RecycleBinFolder"
        Log-Console "Opened Windows Recycle Bin in File Explorer." "SUCCESS"
    } else {
        $opened = Open-FolderInExplorer -Path $sel.Target
        if ($opened) {
            Log-Console "Opened in File Explorer: $($sel.Target)" "SUCCESS"
        } else {
            Log-Console "Folder does not exist or is currently empty: $($sel.Target)" "WARN"
            [System.Windows.MessageBox]::Show("The target folder ($($sel.Target)) does not exist or has no files.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    }
})

# 2. Action: Inspect Category Files (Switch to File Inspector Tab)
$btnInspectCatFiles.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show("Please select a category to inspect its files.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    for ($i = 0; $i -lt $cmbInspectTarget.Items.Count; $i++) {
        if ($cmbInspectTarget.Items[$i] -like "$($sel.Id) - *") {
            $cmbInspectTarget.SelectedIndex = $i
            break
        }
    }

    $mainTabControl.SelectedIndex = 1
    $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

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
    Log-Console "CLEANUP FINISHED! Total space freed: $freed ($purged items purged)" "SUCCESS"
    [System.Windows.MessageBox]::Show(
        "$($ctx.Title) Complete!`n`nFreed Space: $freed`nPurged Items: $purged`n`nSee the Activity log for details, including anything skipped.",
        "Diskman - Cleanup finished",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )
    Start-ScanCJunk -Id $ctx.Ids
}

# 3. Action: Clean Selected Junk (bulk)
$btnRunCleanup.add_Click({
    $targetsToClean = @($global:ScannedCleanupItems | Where-Object { $_.IsSelected -eq $true -and $_.RawBytes -gt 0 })
    $totalCleanBytes = [int64](($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum)

    if ($targetsToClean.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No items are selected for cleanup.`n`nPlease check the boxes next to the categories you want to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $safeCount = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Safe' }).Count
    $optCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Optional' }).Count
    $advCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Advanced' }).Count

    $breakdown = "Selected Breakdown: $safeCount Safe, $optCount Optional, $advCount Advanced."
    if ($advCount -gt 0) {
        $breakdown += "`n`n[ADVANCED NOTICE] Windows Update and servicing caches are selected. Diskman skips them while Windows Update, BITS or servicing reports activity or a pending reboot."
    }
    if ($optCount -gt 0) {
        $breakdown += "`n`n[OPTIONAL NOTICE] Developer, offline media or Recycle Bin items are selected. Caches are re-downloaded on demand."
    }
    if (@($targetsToClean | Where-Object { $_.Type -eq 'RecycleBin' }).Count -gt 0) {
        $breakdown += "`n`n[RECYCLE BIN] Everything currently in the Recycle Bin will be permanently deleted. It cannot be restored."
    }

    $bullet = [char]0x2022
    $confirmMsg = "Proceed with cleaning $(Format-Bytes -Bytes $totalCleanBytes) across $($targetsToClean.Count) selected C: drive categories?`n`n" +
                  "$breakdown`n`n" +
                  "What Diskman will and will not touch:`n" +
                  "$bullet Only the folders listed in the table are cleaned. Deleted files do NOT go to the Recycle Bin.`n" +
                  "$bullet Documents, Desktop, Downloads, Pictures, Music, Videos and OneDrive are blocked from bulk cleanup.`n" +
                  "$bullet Browser passwords, cookies, history and bookmarks are never deleted.`n" +
                  "$bullet Files that are in use are skipped and reported in the log.`n`n" +
                  "Execute cleanup?"

    $confirm = [System.Windows.MessageBox]::Show(
        $confirmMsg,
        "Confirm C: Drive Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Log-Console "=========================================================="
    Log-Console "Total Selected Space: $(Format-Bytes -Bytes $totalCleanBytes) ($($targetsToClean.Count) categories: $safeCount Safe, $optCount Optional, $advCount Advanced)"
    if (@($targetsToClean | Where-Object { $_.RequiresAdmin -eq $true }).Count -gt 0 -and -not $isAdmin) {
        Log-Console "Notice: Selected system items require Administrator rights. Run via run.bat (Admin) if locked items are skipped." "WARN"
    }

    Start-BackgroundJob -Status "Cleaning C: drive" `
        -Vars @{ Items = $targetsToClean; TargetId = $null } `
        -Context @{ Title = "C: Drive Cleanup"; Ids = @($targetsToClean | ForEach-Object { $_.Id }) } `
        -Work $cleanupWork -OnDone $cleanupDone
})

# 4. Action: Clean Single Category
$btnCleanSingleCategory.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show("Please select a category to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    if ($sel.RawBytes -le 0) {
        [System.Windows.MessageBox]::Show("The selected category ($($sel.CategoryName)) is already empty.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $safetyText = if ($sel.SafetyExplanation) { $sel.SafetyExplanation } else { "Safe to delete. User files and credentials are untouched." }
    $deletedText = if ($sel.WhatGetsDeleted) { $sel.WhatGetsDeleted } else { $sel.Description }
    $consequencesText = if ($sel.Consequences) { $sel.Consequences } else { "Files auto-regenerate on next launch." }
    $badgeText = if ($sel.SafetyBadge) { $sel.SafetyBadge } else { $sel.SafetyLevel.ToUpper() }

    $dialogMsg = "CLEANUP VERIFICATION & IMPACT DETAILS`n`n" +
                 "Category: $($sel.CategoryName) [$badgeText]`n" +
                 "Size on C: $($sel.DisplaySize) ($($sel.FileCount))`n" +
                 "Path: $($sel.Target)`n`n" +
                 "[WHAT GETS DELETED]`n$deletedText`n`n" +
                 "[SAFETY & PROTECTED DATA]`n$safetyText`n`n" +
                 "[CONSEQUENCES & REBUILD]`n$consequencesText`n`n" +
                 "Deleted files do not go to the Recycle Bin. Proceed?"

    $confirm = [System.Windows.MessageBox]::Show(
        $dialogMsg,
        "Confirm Cleanup - $($sel.CategoryName)",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Start-BackgroundJob -Status "Purging $($sel.CategoryName)" `
        -Vars @{ Items = $null; TargetId = $sel.Id } `
        -Context @{ Title = $sel.CategoryName; Ids = @($sel.Id) } `
        -Work $cleanupWork -OnDone $cleanupDone
})

# Tab 2: File Inspector Logic
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
            $totalInspectBytes = [int64](($files | Measure-Object -Property RawBytes -Sum).Sum)
            $txtInspectSummary.Text = "Loaded $($files.Count) files (Total: $(Format-Bytes -Bytes $totalInspectBytes))"
            Log-Console "Loaded $($files.Count) files for $($ctx.TargetId) ($(Format-Bytes -Bytes $totalInspectBytes))" "SUCCESS"
        }
})

$gridInspectFiles.add_SelectionChanged({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel) {
        $txtSelectedInspectInfo.Text = "$($sel.Name) ($($sel.DisplaySize)) - Path: $($sel.FullPath)"
    } else {
        $txtSelectedInspectInfo.Text = "Select a file to inspect or delete."
    }
})

$btnRevealInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed in File Explorer: $($sel.FullPath)" "SUCCESS"
    } else {
        [System.Windows.MessageBox]::Show("Please select a valid file to reveal.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    }
})

$btnDeleteSingleInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "Permanently delete file '$($sel.Name)' ($($sel.DisplaySize))?`n`nPath: $($sel.FullPath)",
            "Confirm File Delete",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $res = Remove-ItemPermanently -Path $sel.FullPath
            if ($res.Success) {
                Log-Console "Deleted file: $($sel.FullPath)" "SUCCESS"
                $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Failed to delete file: $($res.Message)" "ERROR"
                [System.Windows.MessageBox]::Show($res.Message, "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    }
})

$btnPurgeAllInspect.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    $targetId = ($selTargetStr -split " - ")[0].Trim()

    # This button cleans the whole category, not just the (at most 250) files listed in the table
    $confirm = [System.Windows.MessageBox]::Show(
        "Delete EVERYTHING in '$selTargetStr'?`n`nThis cleans the whole category, not only the files listed in this table. Deleted files do not go to the Recycle Bin.",
        "Confirm Clear All",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Start-BackgroundJob -Status "Purging $targetId" `
        -Vars @{ Items = $null; TargetId = $targetId } `
        -Context @{ Title = $targetId; Ids = @($targetId) } `
        -Work $cleanupWork -OnDone {
            param($out, $ctx)
            & $cleanupDone $out $ctx
            $gridInspectFiles.ItemsSource = @()
            $txtInspectSummary.Text = "Select a category and click Load Files to inspect individual files."
        }
})

# Tab 3: Large File Hunter Setup
$cmbHuntSize.Items.Add("> 100 MB") | Out-Null
$cmbHuntSize.Items.Add("> 500 MB") | Out-Null
$cmbHuntSize.Items.Add("> 1 GB")   | Out-Null
$cmbHuntSize.Items.Add("> 5 GB")   | Out-Null
$cmbHuntSize.SelectedIndex = 0

$cmbHuntCat.Items.Add("All Categories")        | Out-Null
$cmbHuntCat.Items.Add("Installer / Package")   | Out-Null
$cmbHuntCat.Items.Add("Disk Image / ISO")      | Out-Null
$cmbHuntCat.Items.Add("Archive / Zip")         | Out-Null
$cmbHuntCat.Items.Add("Video / Media")         | Out-Null
$cmbHuntCat.Items.Add("Log / Dump File")       | Out-Null
$cmbHuntCat.Items.Add("AI Model / Weights")         | Out-Null
$cmbHuntCat.Items.Add("Incomplete / Temp Download") | Out-Null
$cmbHuntCat.SelectedIndex = 0

$btnHuntScan.add_Click({
    $sizeMap = @{
        "> 100 MB" = 100MB
        "> 500 MB" = 500MB
        "> 1 GB"   = 1GB
        "> 5 GB"   = 5GB
    }
    $minSize = $sizeMap[$cmbHuntSize.SelectedItem]
    if (-not $minSize) { $minSize = 100MB }
    $cat = $cmbHuntCat.SelectedItem

    Start-BackgroundJob -Status "Hunting large files in C:\ ($($cmbHuntSize.SelectedItem) | $cat)" `
        -Vars @{ MinSize = $minSize; Cat = $cat } `
        -Work { Find-LargeFiles -TargetPath "C:\" -MinSizeBytes $MinSize -CategoryFilter $Cat -Limit 100 } `
        -OnDone {
            param($out)
            $files = @($out)
            $gridLargeFiles.ItemsSource = $files
            Log-Console "Discovered $($files.Count) large files on C: drive." "SUCCESS"
        }
})

$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel) {
        $txtSelectedLargeFile.Text = "$($sel.Name) ($($sel.DisplaySize)) - $($sel.FullPath)"
    } else {
        $txtSelectedLargeFile.Text = "Select a large file to perform action."
    }
})

# Remove a handled file from the Hunter table without rescanning the whole drive
function Remove-HunterRow {
    param([string]$FullPath)
    $gridLargeFiles.ItemsSource = @($gridLargeFiles.ItemsSource | Where-Object { $_.FullPath -ne $FullPath })
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
        $confirm = [System.Windows.MessageBox]::Show(
            "Move this file to Recycle Bin?`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)",
            "Safe Recycle Confirmation",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $res = Send-ItemToRecycleBin -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Recycled file: $($sel.FullPath)" "SUCCESS"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not recycle $($sel.FullPath): $($res.Message)" "ERROR"
                [System.Windows.MessageBox]::Show($res.Message, "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        }
    }
})

$btnPermDeleteLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        $diskImageNote = if ($sel.Category -eq 'Disk Image / ISO') { "`n`nDisk images can hold a whole virtual machine or OS install. Make sure you do not need it." } else { "" }
        $confirm = [System.Windows.MessageBox]::Show(
            "PERMANENT DELETE WARNING!`n`nThis cannot be undone and skips the Recycle Bin.`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)$diskImageNote`n`nProceed?",
            "Permanent Delete",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $res = Remove-ItemPermanently -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Deleted file: $($sel.FullPath)" "WARN"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not delete $($sel.FullPath): $($res.Message)" "ERROR"
                [System.Windows.MessageBox]::Show($res.Message, "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
        }
    }
})

# Tab 4: Directory Explorer Setup
function Load-Directory {
    param([string]$Path)
    $txtPath.Text = $Path
    $global:CurrentExplorerPath = $Path
    $global:ExplorerLoaded = $true

    Start-BackgroundJob -Status "Scanning C: directory $Path (folder sizes can take a while on large folders)" `
        -Vars @{ Dir = $Path } `
        -Context @{ Dir = $Path } `
        -Work { Start-FolderScan -DirectoryPath $Dir } `
        -OnDone {
            param($out, $ctx)
            $items = @($out)
            $gridDir.ItemsSource = $items
            Log-Console "Loaded $($items.Count) items in $($ctx.Dir)" "SUCCESS"
        }
}

$btnScanDir.add_Click({ Load-Directory $txtPath.Text })
$btnFolderUp.add_Click({
    $parent = Split-Path -Parent $global:CurrentExplorerPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Load-Directory $parent
    }
})
$btnOpenDirInExplorer.add_Click({
    Open-FolderInExplorer -Path $global:CurrentExplorerPath
    Log-Console "Opened in File Explorer: $global:CurrentExplorerPath" "SUCCESS"
})
$gridDir.add_MouseDoubleClick({
    $selected = $gridDir.SelectedItem
    if ($selected -and $selected.IsFolder -and (Test-Path -LiteralPath $selected.FullPath)) {
        Load-Directory $selected.FullPath
    }
})

# Top Header Actions
$btnTopRefresh.add_Click({
    Update-CDriveMetricsDisplay
    Start-ScanCJunk
})
$btnTopQuickScan.add_Click({
    $mainTabControl.SelectedIndex = 0
    Start-ScanCJunk
})
$btnScanClean.add_Click({ Start-ScanCJunk })

# Initial Startup Banner in Terminal & UI
Log-Console "=========================================================="
Log-Console "DISKMAN - C: DRIVE STORAGE CLEANER & JUNK PURGER"
Log-Console "Real-time activity and deletion logs will stream live below."
if ($isAdmin) {
    Log-Console "Elevated Administrator Mode active [Full Access - Protected Servicing Boundaries Enforced]" "SUCCESS"
} else {
    Log-Console "Standard Mode: Run as Administrator to clean system items" "WARN"
}
Log-Console "=========================================================="

Update-CDriveMetricsDisplay
Apply-CleanupFilter "All"

# Render the GUI window immediately, then scan in the background
$window.add_ContentRendered({
    if (-not $global:ScanStarted) {
        $global:ScanStarted = $true
        Start-ScanCJunk
    }
})

# Load the Directory Explorer the first time its tab is opened (ignore selection events bubbling up from the grids)
$mainTabControl.add_SelectionChanged({
    param($sender, $e)
    if ($e.OriginalSource -eq $mainTabControl -and $mainTabControl.SelectedIndex -eq 3 -and -not $global:ExplorerLoaded) {
        Load-Directory $global:CurrentExplorerPath
    }
})

# Do not let the window close in the middle of a delete without asking
$window.add_Closing({
    param($sender, $e)
    if ($global:Job) {
        $answer = [System.Windows.MessageBox]::Show(
            "An operation is still running. Closing now stops it part-way.`n`nClose anyway?",
            "Diskman", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true }
    }
})

# Show Window
$window.ShowDialog() | Out-Null
