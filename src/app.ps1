# Diskman - Main Application Controller (WinUtil Style)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms -ErrorAction SilentlyContinue

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

# Console Logger Function
function Log-Console {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = "[+]"
    if ($Level -eq "SUCCESS") { $prefix = "[OK]" }
    elseif ($Level -eq "WARN") { $prefix = "[!]" }
    elseif ($Level -eq "ERROR") { $prefix = "[X]" }
    
    $logLine = "$timestamp $prefix $Message`r`n"
    
    $txtConsole = Find-Control "TxtConsoleLog"
    if ($txtConsole) {
        $txtConsole.AppendText($logLine)
        $txtConsole.ScrollToEnd()
    }
}

# Core Controls
$txtConsoleLog   = Find-Control "TxtConsoleLog"
$txtGlobalStat   = Find-Control "TxtGlobalStatus"
$panelCards      = Find-Control "PanelDriveCards"
$txtTotalStorage = Find-Control "TxtTotalSystemStorage"
$txtTotalFree    = Find-Control "TxtTotalSystemFree"
$txtReclaimable  = Find-Control "TxtEstimatedReclaimable"

$btnTopRefresh   = Find-Control "BtnTopRefresh"
$btnTopQuickScan = Find-Control "BtnTopQuickScan"

# Cleanup Controls
$btnSelectRec    = Find-Control "BtnSelectRecommended"
$btnSelectAll    = Find-Control "BtnSelectAll"
$btnClearSel     = Find-Control "BtnClearSelection"
$txtCleanBadge   = Find-Control "TxtCleanTotalBadge"
$btnScanClean    = Find-Control "BtnScanCleanable"
$btnRunCleanup   = Find-Control "BtnRunCleanup"

$chkUserTemp     = Find-Control "ChkUserTemp"
$chkSysTemp      = Find-Control "ChkSysTemp"
$chkCrashDumps   = Find-Control "ChkCrashDumps"
$chkWerLogs      = Find-Control "ChkWerLogs"
$chkPipCache     = Find-Control "ChkPipCache"
$chkPipDCache    = Find-Control "ChkPipDCache"
$chkNpmCache     = Find-Control "ChkNpmCache"
$chkPyCache      = Find-Control "ChkPyCache"
$chkChromeCache  = Find-Control "ChkChromeCache"
$chkEdgeCache    = Find-Control "ChkEdgeCache"
$chkBraveCache   = Find-Control "ChkBraveCache"
$chkRecycleBin   = Find-Control "ChkRecycleBin"
$chkOldDownloads = Find-Control "ChkOldDownloads"

# Hunter Controls
$cmbHuntDrive    = Find-Control "CmbHunterDrive"
$cmbHuntSize     = Find-Control "CmbHunterSize"
$cmbHuntCat      = Find-Control "CmbHunterCategory"
$btnHuntScan     = Find-Control "BtnStartHunterScan"
$gridLargeFiles  = Find-Control "GridLargeFiles"
$txtSelected     = Find-Control "TxtSelectedFileInfo"
$btnReveal       = Find-Control "BtnRevealInExplorer"
$btnTrash        = Find-Control "BtnSendToTrash"
$btnPermDelete   = Find-Control "BtnPermanentDelete"

# Explorer Controls
$cmbExpDrive     = Find-Control "CmbExplorerDrive"
$btnFolderUp     = Find-Control "BtnFolderUp"
$txtPath         = Find-Control "TxtCurrentPath"
$btnScanDir      = Find-Control "BtnScanCurrentDir"
$gridDir         = Find-Control "GridDirectories"

# State
$global:CurrentExplorerPath = "C:\"
$global:ScannedCleanableTargets = @{}

# Load Drives
function Load-DrivesOverview {
    Log-Console "Enumerating physical and logical storage volumes..."
    $panelCards.Children.Clear()
    $cmbExpDrive.Items.Clear()
    $cmbHuntDrive.Items.Clear()

    $metrics = Get-DriveMetrics
    $totalSysBytes = 0
    $totalFreeBytes = 0

    foreach ($m in $metrics) {
        $totalSysBytes += $m.RawTotal
        $totalFreeBytes += $m.RawFree

        $cmbExpDrive.Items.Add("$($m.DriveLetter)\") | Out-Null
        $cmbHuntDrive.Items.Add("$($m.DriveLetter)\") | Out-Null

        # Build clean WinUtil style Drive GroupBox
        $cardXaml = @"
        <GroupBox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                  Header="$($m.DisplayName)" Width="310" Height="170" Margin="4" Foreground="#00B4D8" BorderBrush="#3F3F46" Background="#27272A">
            <Grid Margin="6,4">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0">
                    <TextBlock Text="File System: $($m.FileSystem)" FontSize="11" Foreground="#A1A1AA" HorizontalAlignment="Left"/>
                    <TextBlock Text="$($m.StatusText)" FontSize="11" FontWeight="Bold" Foreground="$($m.StatusColor)" HorizontalAlignment="Right"/>
                </Grid>

                <StackPanel Grid.Row="1" Margin="0,8,0,0">
                    <Grid>
                        <TextBlock Text="$($m.UsedGB) GB used ($($m.UsedPercent)%)" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Left"/>
                        <TextBlock Text="$($m.FreeGB) GB free" FontSize="11" Foreground="#2EC4B6" HorizontalAlignment="Right"/>
                    </Grid>
                    <ProgressBar Height="8" Margin="0,4,0,0" Value="$($m.UsedPercent)" Maximum="100" Background="#18181B" Foreground="$($m.StatusColor)" BorderThickness="0"/>
                </StackPanel>

                <Grid Grid.Row="3" Margin="0,8,0,0">
                    <Button Tag="$($m.DriveLetter)\" Content="Inspect in Explorer" Height="26" FontSize="11" Background="#333338" Foreground="#00B4D8" BorderBrush="#4F4F56" Cursor="Hand"/>
                </Grid>
            </Grid>
        </GroupBox>
"@
        $cardReader = New-Object System.Xml.XmlNodeReader ([xml]$cardXaml)
        $cardElement = [System.Windows.Markup.XamlReader]::Load($cardReader)

        $btnInspect = $cardElement.Content.Children[2].Children[0]
        $btnInspect.add_Click({
            param($sender, $e)
            $global:CurrentExplorerPath = $sender.Tag
            $cmbExpDrive.SelectedItem = $sender.Tag
            Load-Directory $global:CurrentExplorerPath
            # Switch to explorer tab
            $tabCtrl = $window.Content.Children[1]
            $tabCtrl.SelectedIndex = 3
        })

        $panelCards.Children.Add($cardElement) | Out-Null
        Log-Console "Discovered Drive $($m.DriveLetter) [$($m.VolumeLabel)]: $($m.UsedGB) GB / $($m.TotalGB) GB ($($m.FreeGB) GB free)"
    }

    $txtTotalStorage.Text = Format-Bytes -Bytes $totalSysBytes
    $txtTotalFree.Text    = Format-Bytes -Bytes $totalFreeBytes

    if ($cmbExpDrive.Items.Count -gt 0) { $cmbExpDrive.SelectedIndex = 0 }
    if ($cmbHuntDrive.Items.Count -gt 0) { $cmbHuntDrive.SelectedIndex = 0 }

    $txtGlobalStat.Text = "Ready | Discovered $($metrics.Count) mounted partitions."
}

# Explorer: Load Directory
function Load-Directory {
    param([string]$Path)
    Log-Console "Scanning folder: $Path"
    $txtPath.Text = $Path
    $global:CurrentExplorerPath = $Path

    $items = Start-FolderScan -DirectoryPath $Path
    $gridDir.ItemsSource = $items
    Log-Console "Loaded $($items.Count) items in $Path" "SUCCESS"
}

# Cleanup: Checkbox Selection helpers
$btnSelectRec.add_Click({
    $chkUserTemp.IsChecked = $true
    $chkSysTemp.IsChecked = $true
    $chkCrashDumps.IsChecked = $true
    $chkWerLogs.IsChecked = $true
    $chkPipCache.IsChecked = $true
    $chkPipDCache.IsChecked = $true
    $chkNpmCache.IsChecked = $true
    $chkPyCache.IsChecked = $true
    $chkChromeCache.IsChecked = $true
    $chkEdgeCache.IsChecked = $true
    $chkBraveCache.IsChecked = $false
    $chkRecycleBin.IsChecked = $true
    $chkOldDownloads.IsChecked = $false
    Log-Console "Applied recommended cleanup presets."
})

$btnSelectAll.add_Click({
    $chkUserTemp.IsChecked = $true
    $chkSysTemp.IsChecked = $true
    $chkCrashDumps.IsChecked = $true
    $chkWerLogs.IsChecked = $true
    $chkPipCache.IsChecked = $true
    $chkPipDCache.IsChecked = $true
    $chkNpmCache.IsChecked = $true
    $chkPyCache.IsChecked = $true
    $chkChromeCache.IsChecked = $true
    $chkEdgeCache.IsChecked = $true
    $chkBraveCache.IsChecked = $true
    $chkRecycleBin.IsChecked = $true
    $chkOldDownloads.IsChecked = $true
    Log-Console "Selected all cleanup items."
})

$btnClearSel.add_Click({
    $chkUserTemp.IsChecked = $false
    $chkSysTemp.IsChecked = $false
    $chkCrashDumps.IsChecked = $false
    $chkWerLogs.IsChecked = $false
    $chkPipCache.IsChecked = $false
    $chkPipDCache.IsChecked = $false
    $chkNpmCache.IsChecked = $false
    $chkPyCache.IsChecked = $false
    $chkChromeCache.IsChecked = $false
    $chkEdgeCache.IsChecked = $false
    $chkBraveCache.IsChecked = $false
    $chkRecycleBin.IsChecked = $false
    $chkOldDownloads.IsChecked = $false
    Log-Console "Cleared cleanup selection."
})

# Scan Cleanable Items
function Start-AnalyzeStorageJunk {
    Log-Console "Starting deep storage cleanup scan across all drives..."
    $items = Scan-SmartCleanupItems
    
    $totalFound = 0
    foreach ($item in $items) {
        $global:ScannedCleanableTargets[$item.Id] = $item
        $totalFound += $item.RawBytes
        if ($item.RawBytes -gt 0) {
            Log-Console "Found $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount))"
        }
    }

    $txtCleanBadge.Text = "Reclaimable: $(Format-Bytes -Bytes $totalFound)"
    $txtReclaimable.Text = "~$(Format-Bytes -Bytes $totalFound)"
    Log-Console "Storage analysis complete. Total reclaimable: $(Format-Bytes -Bytes $totalFound)" "SUCCESS"
}

$btnScanClean.add_Click({ Start-AnalyzeStorageJunk })

# Run Cleanup
$btnRunCleanup.add_Click({
    $targetsToClean = @()
    $allItems = Scan-SmartCleanupItems

    $checkboxMap = @{
        "UserTemp"        = $chkUserTemp.IsChecked
        "SystemTemp"      = $chkSysTemp.IsChecked
        "CrashDumps"      = $chkCrashDumps.IsChecked
        "WERLogs"         = $chkWerLogs.IsChecked
        "PipCache"        = $chkPipCache.IsChecked
        "PipCustomCache"  = $chkPipDCache.IsChecked
        "NpmCache"        = $chkNpmCache.IsChecked
        "ChromeCache"     = $chkChromeCache.IsChecked
        "EdgeCache"       = $chkEdgeCache.IsChecked
        "RecycleBin"      = $chkRecycleBin.IsChecked
    }

    foreach ($item in $allItems) {
        if ($checkboxMap[$item.Id] -eq $true) {
            $item.IsSelected = $true
            $targetsToClean += $item
        }
    }

    if ($targetsToClean.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Please select at least one item to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $totalBytes = ($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum
    $confirm = [System.Windows.MessageBox]::Show(
        "Proceed with cleaning $(Format-Bytes -Bytes $totalBytes) across $($targetsToClean.Count) selected categories?",
        "Confirm WinUtil Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "Executing cleanup sequence..."
        $res = Invoke-ExecuteCleanup -SelectedItems $targetsToClean
        foreach ($log in $res.Logs) {
            Log-Console $log "SUCCESS"
        }
        Log-Console "Cleanup finished! Total space freed: $($res.DisplayFreed) ($($res.DeletedCount) items purged)" "SUCCESS"
        
        [System.Windows.MessageBox]::Show(
            "Cleanup Complete!`n`nFreed Space: $($res.DisplayFreed)`nPurged Items: $($res.DeletedCount)",
            "Diskman - Storage Cleaned",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )

        Load-DrivesOverview
        Start-AnalyzeStorageJunk
    }
})

# Large File Hunter Setup
$cmbHuntSize.Items.Add("> 100 MB") | Out-Null
$cmbHuntSize.Items.Add("> 500 MB") | Out-Null
$cmbHuntSize.Items.Add("> 1 GB")   | Out-Null
$cmbHuntSize.Items.Add("> 5 GB")   | Out-Null
$cmbHuntSize.SelectedIndex = 0

$cmbHuntCat.Items.Add("All Categories") | Out-Null
$cmbHuntCat.Items.Add("Video")          | Out-Null
$cmbHuntCat.Items.Add("Archive")        | Out-Null
$cmbHuntCat.Items.Add("AI Model")       | Out-Null
$cmbHuntCat.Items.Add("Disk Image")     | Out-Null
$cmbHuntCat.Items.Add("Executable")     | Out-Null
$cmbHuntCat.Items.Add("Dataset")        | Out-Null
$cmbHuntCat.SelectedIndex = 0

$btnHuntScan.add_Click({
    $drive = $cmbHuntDrive.SelectedItem
    if (-not $drive) { $drive = "C:\" }

    $sizeMap = @{
        "> 100 MB" = 100MB
        "> 500 MB" = 500MB
        "> 1 GB"   = 1GB
        "> 5 GB"   = 5GB
    }
    $minSize = $sizeMap[$cmbHuntSize.SelectedItem]
    if (-not $minSize) { $minSize = 100MB }

    $cat = $cmbHuntCat.SelectedItem
    Log-Console "Scanning for large files in $drive ($($cmbHuntSize.SelectedItem) | $cat)..."

    $files = Find-LargeFiles -TargetPath $drive -MinSizeBytes $minSize -CategoryFilter $cat -Limit 60
    $gridLargeFiles.ItemsSource = $files
    Log-Console "Found $($files.Count) matching large files in $drive." "SUCCESS"
})

$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel) {
        $txtSelected.Text = "$($sel.Name) ($($sel.DisplaySize))"
    } else {
        $txtSelected.Text = "Select a file to perform action."
    }
})

$btnReveal.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed file in Windows Explorer: $($sel.FullPath)"
    }
})

$btnTrash.add_Click({
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
        }
    }
})

$btnPermDelete.add_Click({
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
        }
    }
})

# Explorer Events
$btnTopRefresh.add_Click({ Load-DrivesOverview })
$btnTopQuickScan.add_Click({
    $tabCtrl = $window.Content.Children[1]
    $tabCtrl.SelectedIndex = 1
    Start-AnalyzeStorageJunk
})

$btnScanDir.add_Click({ Load-Directory $txtPath.Text })
$cmbExpDrive.add_SelectionChanged({
    if ($cmbExpDrive.SelectedItem) {
        Load-Directory $cmbExpDrive.SelectedItem
    }
})
$btnFolderUp.add_Click({
    $parent = Split-Path -Parent $global:CurrentExplorerPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Load-Directory $parent
    }
})
$gridDir.add_MouseDoubleClick({
    $selected = $gridDir.SelectedItem
    if ($selected -and $selected.IsFolder -and (Test-Path -LiteralPath $selected.FullPath)) {
        Load-Directory $selected.FullPath
    }
})

# Initial Startup
Log-Console "================================================="
Log-Console "Diskman Windows Storage Utility initialized."
Log-Console "Inspired by ChrisTitusTech/winutil architecture."
Log-Console "================================================="

Load-DrivesOverview
Load-Directory "C:\"

# Show Window
$window.ShowDialog() | Out-Null
