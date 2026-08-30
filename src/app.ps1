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

# Live Console Logger Function (Streams to Terminal + GUI + Pumps Dispatcher)
function Log-Console {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = "[+]"
    $hostColor = "Cyan"
    if ($Level -eq "SUCCESS") { $prefix = "[OK]"; $hostColor = "Green" }
    elseif ($Level -eq "WARN") { $prefix = "[!]"; $hostColor = "Yellow" }
    elseif ($Level -eq "ERROR") { $prefix = "[X]"; $hostColor = "Red" }
    
    $logLine = "$timestamp $prefix $Message"
    
    # 1. Real-time stream to Terminal console
    try {
        Write-Host "$timestamp " -NoNewline -ForegroundColor DarkGray
        Write-Host "$prefix " -NoNewline -ForegroundColor $hostColor
        Write-Host $Message -ForegroundColor White
    } catch {}
    
    # 2. Append to in-app WPF Console Box
    $txtConsole = Find-Control "TxtConsoleLog"
    if ($txtConsole) {
        $txtConsole.AppendText("$logLine`r`n")
        $txtConsole.ScrollToEnd()
    }

    # 3. Message pump to keep WPF UI responsive and prevent freezing
    try {
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
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
$txtSelectedCatInfo        = Find-Control "TxtSelectedCategoryInfo"
$txtSelectedCatDesc        = Find-Control "TxtSelectedCategoryDesc"
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
$global:ScannedCleanupItems = [System.Collections.ArrayList]@()
$global:CurrentFilterGroup  = "All"

# Function: Update C: Drive Metrics Display
function Update-CDriveMetricsDisplay {
    $cMetrics = Get-CDriveMetrics
    if ($cMetrics) {
        $txtCDriveTotal.Text = "$($cMetrics.TotalGB) GB"
        $txtCDriveUsed.Text  = "$($cMetrics.UsedGB) GB"
        $txtCDriveFree.Text  = "$($cMetrics.FreeGB) GB"
        $progressCDrive.Value = $cMetrics.UsedPercent
        $txtCBarPercent.Text = "$($cMetrics.UsedPercent)% Used ($($cMetrics.StatusText))"
        $txtCBarStatus.Text  = "Drive C: [$($cMetrics.VolumeLabel)] ($($cMetrics.FileSystem))"
        
        $txtGlobalStat.Text  = "C: Drive Status: $($cMetrics.FreeGB) GB Free of $($cMetrics.TotalGB) GB ($($cMetrics.StatusText))"
        Log-Console "C: Drive Status: $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)"
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

# Function: Apply Filter on Cleanable Grid
function Apply-CleanupFilter {
    param([string]$Group)
    $global:CurrentFilterGroup = $Group
    
    if ($Group -eq "All") {
        $gridCleanCategories.ItemsSource = $global:ScannedCleanupItems
    } else {
        $filtered = $global:ScannedCleanupItems | Where-Object { $_.Group -like "*$Group*" }
        $gridCleanCategories.ItemsSource = [System.Collections.ArrayList]@($filtered)
    }
}

# Function: Scan C: Drive Junk
function Start-ScanCJunk {
    Log-Console "Scanning C: drive for unnecessary files, caches, logs, and trash..."
    $items = Scan-SmartCleanupItems
    
    $global:ScannedCleanupItems = [System.Collections.ArrayList]@($items)
    Apply-CleanupFilter $global:CurrentFilterGroup
    
    # Update Inspect dropdown
    $cmbInspectTarget.Items.Clear()
    $totalReclaimable = 0
    
    foreach ($item in $items) {
        $totalReclaimable += $item.RawBytes
        $cmbInspectTarget.Items.Add("$($item.Id) - $($item.CategoryName)") | Out-Null
        
        if ($item.RawBytes -gt 0) {
            Log-Console "Detected $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount)) at $($item.Target)"
        }
    }
    
    if ($cmbInspectTarget.Items.Count -gt 0) {
        $cmbInspectTarget.SelectedIndex = 0
    }
    
    $txtCReclaimable.Text = "~$(Format-Bytes -Bytes $totalReclaimable)"
    Update-SelectedCleanupBadge
    Log-Console "Scan complete! Total reclaimable space on C: drive: $(Format-Bytes -Bytes $totalReclaimable)" "SUCCESS"
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
    Log-Console "Applied recommended cleanup selection preset (Advanced targets excluded by default)."
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
        $txtSelectedCatInfo.Text = "$($sel.DisplayName) - Size: $($sel.DisplaySize) ($($sel.FileCount))"
        $txtSelectedCatDesc.Text = "$($sel.Description)"
        Update-SelectedCleanupBadge
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
        if ($cmbInspectTarget.Items[$i] -like "$($sel.Id)*") {
            $cmbInspectTarget.SelectedIndex = $i
            break
        }
    }
    
    $mainTabControl.SelectedIndex = 1
    $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

# 3. Action: Clean Selected Junk (Bulk with Live Streaming Progress)
$btnRunCleanup.add_Click({
    $targetsToClean = @()
    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.IsSelected -eq $true -and $item.RawBytes -gt 0) {
            $targetsToClean += $item
        }
    }

    if ($targetsToClean.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No items are selected for cleanup.`n`nPlease check the boxes next to the categories you want to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $totalBytes = ($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum
    $hasAdvanced = ($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Advanced' -or $_.Id -in @('WinUpdateCache', 'DeliveryOpt') }).Count -gt 0
    $advWarning = ""
    if ($hasAdvanced) {
        $advWarning = "`n`n[ADVANCED CLEANUP NOTICE]`nWindows Update Cache cleanup is selected. Diskman will verify that Windows Update and servicing components are idle before cleaning. Windows may need to re-download update files if updates are in progress."
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Proceed with cleaning $(Format-Bytes -Bytes $totalBytes) across $($targetsToClean.Count) selected C: drive junk categories?$advWarning`n`nDiskman will safely remove selected cache files and purge trash.`n`nReal-time deletion progress will stream live to the terminal window and activity log.",
        "Confirm C: Drive Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "=========================================================="
        Log-Console "EXECUTING C: DRIVE CLEANUP PIPELINE"
        Log-Console "Total Selected Space: $(Format-Bytes -Bytes $totalBytes) ($($targetsToClean.Count) categories)"
        
        $hasAdminTargets = ($targetsToClean | Where-Object { $_.RequiresAdmin -eq $true }).Count -gt 0
        if ($hasAdminTargets -and -not $isAdmin) {
            Log-Console "Notice: Selected system items require Administrator rights. Run via run.bat (Admin) if locked items are skipped." "WARN"
        }
        Log-Console "=========================================================="
        
        $btnRunCleanup.IsEnabled = $false
        $txtGlobalStat.Text = "Cleaning C: Drive in progress... (Live logs in terminal)"
        
        $res = Invoke-ExecuteCleanup -SelectedItems $targetsToClean -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        
        $btnRunCleanup.IsEnabled = $true
        Log-Console "==========================================================" "SUCCESS"
        Log-Console "CLEANUP FINISHED! Total space freed: $($res.DisplayFreed) ($($res.DeletedCount) items purged)" "SUCCESS"
        Log-Console "==========================================================" "SUCCESS"
        
        [System.Windows.MessageBox]::Show(
            "C: Drive Cleanup Complete!`n`nFreed Space: $($res.DisplayFreed)`nPurged Items: $($res.DeletedCount)`n`nSee Terminal window for full execution logs.",
            "Diskman - C: Drive Cleaned",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )

        Update-CDriveMetricsDisplay
        Start-ScanCJunk
    }
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

    $advNotice = ""
    if ($sel.SafetyLevel -eq 'Advanced' -or $sel.Id -in @('WinUpdateCache', 'DeliveryOpt')) {
        $advNotice = "`n`n[ADVANCED CLEANUP NOTICE]`nThis removes downloaded Windows Update cache files. Windows may need to download them again. Do not use this while Windows is installing updates or waiting for a restart."
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Clean all files in '$($sel.CategoryName)' ($($sel.DisplaySize))?$advNotice`n`nLocation: $($sel.Target)",
        "Confirm Category Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "Purging single category: $($sel.CategoryName)..."
        $btnCleanSingleCategory.IsEnabled = $false
        
        $res = Invoke-ExecuteCategoryCleanup -TargetId $sel.Id -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        
        $btnCleanSingleCategory.IsEnabled = $true
        [System.Windows.MessageBox]::Show(
            "Category Cleaned: $($sel.CategoryName)`nFreed Space: $($res.DisplayFreed)",
            "Diskman",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        Update-CDriveMetricsDisplay
        Start-ScanCJunk
    }
})

# Tab 2: File Inspector Logic
$btnRefreshInspectFiles.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    
    $targetId = ($selTargetStr -split " - ")[0].Trim()
    Log-Console "Loading file list for $targetId..."
    
    $files = Get-CleanableCategoryFiles -TargetId $targetId -Limit 250
    $gridInspectFiles.ItemsSource = $files
    
    $totalInspectBytes = ($files | Measure-Object -Property RawBytes -Sum).Sum
    if (-not $totalInspectBytes) { $totalInspectBytes = 0 }
    
    $txtInspectSummary.Text = "Loaded $($files.Count) files (Total: $(Format-Bytes -Bytes $totalInspectBytes))"
    Log-Console "Loaded $($files.Count) files for $targetId ($(Format-Bytes -Bytes $totalInspectBytes))" "SUCCESS"
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
            "Delete file '$($sel.Name)' ($($sel.DisplaySize))?`n`nPath: $($sel.FullPath)",
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
    
    $confirm = [System.Windows.MessageBox]::Show(
        "Clear all files currently inspected in '$selTargetStr'?",
        "Confirm Clear All",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        $res = Invoke-ExecuteCategoryCleanup -TargetId $targetId -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        Log-Console "Cleared category: $targetId (Freed: $($res.DisplayFreed))" "SUCCESS"
        $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Update-CDriveMetricsDisplay
        Start-ScanCJunk
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
$cmbHuntCat.Items.Add("AI Model / Weights")    | Out-Null
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
    Log-Console "Hunting large unnecessary files in C:\ ($($cmbHuntSize.SelectedItem) | $cat)..."

    $files = Find-LargeFiles -TargetPath "C:\" -MinSizeBytes $minSize -CategoryFilter $cat -Limit 100
    $gridLargeFiles.ItemsSource = $files
    Log-Console "Discovered $($files.Count) large files on C: drive." "SUCCESS"
})

$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel) {
        $txtSelectedLargeFile.Text = "$($sel.Name) ($($sel.DisplaySize))"
    } else {
        $txtSelectedLargeFile.Text = "Select a large file to perform action."
    }
})

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
            "Move this file to Recycle Bin?`n`nFile: $($sel.Name)`nSize: $($sel.DisplaySize)",
            "Safe Recycle Confirmation",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $res = Send-ItemToRecycleBin -Path $sel.FullPath
            Log-Console "Recycled file: $($sel.FullPath)" "SUCCESS"
            [System.Windows.MessageBox]::Show($res.Message, "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            $btnHuntScan.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Update-CDriveMetricsDisplay
        }
    }
})

$btnPermDeleteLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "PERMANENT DELETE WARNING!`n`nThis cannot be undone.`n`nFile: $($sel.Name)`nSize: $($sel.DisplaySize)`n`nProceed?",
            "Permanent Delete",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $res = Remove-ItemPermanently -Path $sel.FullPath
            Log-Console "Deleted file: $($sel.FullPath)" "WARN"
            [System.Windows.MessageBox]::Show($res.Message, "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            $btnHuntScan.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Update-CDriveMetricsDisplay
        }
    }
})

# Tab 4: Directory Explorer Setup
function Load-Directory {
    param([string]$Path)
    Log-Console "Scanning C: directory: $Path"
    $txtPath.Text = $Path
    $global:CurrentExplorerPath = $Path

    $items = Start-FolderScan -DirectoryPath $Path
    $gridDir.ItemsSource = $items
    Log-Console "Loaded $($items.Count) items in $Path" "SUCCESS"
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
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

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
Start-ScanCJunk
Load-Directory "C:\"

# Show Window
$window.ShowDialog() | Out-Null
