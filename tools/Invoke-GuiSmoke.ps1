# Developer tool: launches the real app from a scratch copy of src/, lets the scans finish, takes screenshots of each
# tab (default size and the 950x700 minimum), writes a summary and closes the window. Read-only: it never cleans anything.
# Usage: powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\Invoke-GuiSmoke.ps1 [-OutDir <folder>] [-TimeoutSeconds 600]
param(
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "diskman_smoke_out"),
    [int]$TimeoutSeconds = 600
)

$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("diskman_smoke_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $OutDir -Force | Out-Null
Copy-Item -Path (Join-Path $repo 'src') -Destination (Join-Path $work 'src') -Recurse

$appCopy = Join-Path $work 'src\app.ps1'
$text = [System.IO.File]::ReadAllText($appCopy)
$marker = '$window.ShowDialog() | Out-Null'
if (-not $text.Contains($marker)) { throw "ShowDialog marker not found in app.ps1" }

$hook = @'
$outDir = "__OUT__"
$shot = {
    param($name)
    $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create((Join-Path $outDir "$name.png")); $enc.Save($fs); $fs.Dispose()
}
# Safety net: even if this runs elevated, allow-listed commands are only reported, never executed
$env:DISKMAN_DRY_RUN = '1'
# Dialogs would block an unattended run: answer Yes and capture the text (only the sandbox clean below ever asks)
function Confirm-Action { param($Message, $Title, $Icon) $global:LastConfirm = $Message; return $true }
function Show-Info { param($Message, $Title, $Icon) $global:LastInfo = $Message }
$global:Tick = 0; $global:Stage = 0; $global:Delay = 0; $global:T0 = Get-Date
$smoke = New-Object System.Windows.Threading.DispatcherTimer
$smoke.Interval = [TimeSpan]::FromSeconds(1)
$smoke.add_Tick({
    $global:Tick++
    $idle = (-not $global:Jobs.action) -and (-not $global:Jobs.scan)
    if ($global:Tick -eq 20) { & $shot "1_scanning" }
    $wait = { if ($global:Jobs.scan -or $global:Jobs.action) { 'wait' } }
    $waitAction = { if ($global:Jobs.action) { 'wait' } }
    $makeSandboxItem = {
        param($id, $folders)
        $box = Join-Path $env:PUBLIC "diskman_smoke_clean_$([guid]::NewGuid().ToString('N'))"
        $targets = foreach ($f in $folders) {
            $t = Join-Path $box $f
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $t 'a.bin'), (New-Object byte[] (3MB)))
            [System.IO.File]::WriteAllBytes((Join-Path $t 'b.bin'), (New-Object byte[] (2MB)))
            $t
        }
        $m = $targets | ForEach-Object { Get-FolderSizeFast -Path $_ }
        $bytes = [long](($m | ForEach-Object { $_.RawBytes } | Measure-Object -Sum).Sum)
        [PSCustomObject]@{ Id = $id; Group = 'Browser & App Caches'; CategoryName = "Smoke test caches (detected) $id"; DisplayName = "Smoke test $id"; Target = $targets[0]; Targets = @($targets)
            Type = 'DirectoryContents'; SafetyLevel = 'Safe'; SafetyBadge = 'SAFE'; WhatGetsDeleted = 'sandbox files'; SafetyExplanation = 'sandbox'; Consequences = 'none'
            RawBytes = $bytes; DisplaySize = Format-Bytes $bytes; FileCount = '4 items'; RawCount = 4; Description = 'sandbox'; Recommended = $true; RequiresAdmin = $false
            IsSelected = $true; PathExists = $true; CanSelect = $true; SelectTip = ''; Dynamic = $true; Box = $box }
    }
    $delay = { param($n) $global:Delay++; if ($global:Delay -lt $n) { 'wait' } else { $global:Delay = 0 } }
    $note = { param($t) $t | Out-File (Join-Path $outDir "summary.txt") -Append }
    $steps = @(
        { "scan finished after $([int]((Get-Date) - $global:T0).TotalSeconds)s" | Out-File (Join-Path $outDir "summary.txt") },
        { $gridTopFolders.SelectedIndex = 0 },
        { & $shot "2_overview_default" },
        { $window.Width = 950; $window.Height = 700 },
        { },
        { & $shot "3_overview_min"; $window.Width = 1140; $window.Height = 800; $mainTabControl.SelectedItem = $tabExplorer },
        { },
        { & $shot "4_explorer"; $gridSpace.SelectedIndex = 0; Enter-SpaceRow },
        { },
        { & $shot "5_explorer_drill"; $mainTabControl.SelectedItem = $tabCleaner },
        { },
        { & $shot "6_cleaner"; $mainTabControl.SelectedItem = $tabHunter },
        { },
        { & $shot "7_large_files"; $mainTabControl.SelectedItem = $tabInspector },
        { },
        { & $shot "8_inspector"; $mainTabControl.SelectedItem = $tabOverview },
        {
            $drive = Get-DriveState
            $rows = Get-SpaceAccounting -Root $global:SpaceTree -UsedBytes $drive.Used -Elevated $isAdmin
            $top = @($gridTopFolders.ItemsSource)
            $lines = @(("accounted={0:N1}% rows={1} biggest={2} specificAdvice={3} generalGuidance={4}" -f (100.0 * $global:SpaceTree.Bytes / $drive.Used), $rows.Count, $top.Count, @($top | Where-Object { $_.Rule -and -not $_.Rule.Generic }).Count, @($top | Where-Object { $_.Rule -and $_.Rule.Generic }).Count))
            $lines += $top | ForEach-Object { "{0,10}  {1,-34} {2}" -f $_.DisplaySize, $_.Insight, $_.Display }
            $lines += "verdict: $($txtOverviewVerdict.Text)"; $lines += "sub: $($txtOverviewSub.Text)"
            $lines += "action cards: $($panelActions.Children.Count); free safely: $($btnFreeSafely.Content)"
            $lines | Out-File (Join-Path $outDir "summary.txt") -Append
            & $shot "9_final_overview"
        },
        # A real clean through the UI code path (Clean... card and bulk path), on sandbox folders only
        { $global:SmokeA = & $makeSandboxItem 'App:smokea' @('Cache', 'Code Cache'); $global:SmokeB = & $makeSandboxItem 'App:smokeb' @('GPUCache'); $global:FreeBeforeSmoke = (Get-DriveState).Free
          Merge-DetectedCaches -Items @($global:SmokeA, $global:SmokeB) },
        { & $note ("SANDBOX READY: rows in cleaner list=" + @($global:ScannedCleanupItems | Where-Object { $_.Id -like 'App:smoke*' }).Count + " free-safely=[$($btnFreeSafely.Content)]") },
        { Start-CleanCategory -Item $global:SmokeA },
        $waitAction,
        { & $note ("CLEAN CARD PATH: filesGone=" + (-not (Test-Path -LiteralPath (Join-Path $global:SmokeA.Targets[0] 'a.bin'))) + " bothFolders=" + (-not (Test-Path -LiteralPath (Join-Path $global:SmokeA.Targets[1] 'b.bin'))) +
              " remeasured=" + ($global:SmokeA.RawBytes -eq 0) + " otherItemUntouched=" + (Test-Path -LiteralPath (Join-Path $global:SmokeB.Targets[0] 'a.bin')) + " freeSpaceLine=" + ([string]$global:LastInfo -match 'C: free space went from')); Stop-BackgroundJob -Slot scan },
        $wait,
        { Merge-DetectedCaches -Items @($global:SmokeB); Start-BulkClean -Targets @($global:SmokeB) },
        $waitAction,
        { $logFile = Join-Path $global:AuditLogDir ("diskman-{0:yyyyMMdd}.log" -f (Get-Date)); $logText = Get-Content -LiteralPath $logFile -Raw
          & $note ("CLEAN BULK PATH: filesGone=" + (-not (Test-Path -LiteralPath (Join-Path $global:SmokeB.Targets[0] 'a.bin'))) + " remeasured=" + ($global:SmokeB.RawBytes -eq 0) +
              " auditLog=" + (($logText -match 'Cleaning approved by user') -and ($logText -match 'CLEANUP FINISHED')) + " freeAfter=" + (Format-Bytes (Get-DriveState).Free) + " (before " + (Format-Bytes $global:FreeBeforeSmoke) + ")")
          Stop-BackgroundJob -Slot scan
          foreach ($i in @($global:SmokeA, $global:SmokeB)) { if (Test-Path -LiteralPath $i.Box) { Remove-Item -LiteralPath $i.Box -Recurse -Force -ErrorAction SilentlyContinue } } },
        $wait,
        # Cancel a drive scan through the real code path
        { Start-SpaceScan },
        { & $delay 3 },
        { Stop-BackgroundJob -Slot scan },
        $wait,
        { & $note ("CANCEL SCAN: partial=$($global:ScanPartial) sub=[$($txtOverviewSub.Text)]") },
        # Cancel a slow action job through the real code path (the job engine is shared by every action)
        { Start-BackgroundJob -Status 'Smoke test: slow job' -Work { Start-Sleep -Seconds 60 } -OnDone { } },
        { & $delay 1 },
        { & $note ("action job running at cancel time: $([bool]$global:Jobs.action)"); Stop-BackgroundJob -Slot action },
        $wait,
        { & $note ("CANCEL ACTION: logged=$($txtConsoleLog.Text -match 'was cancelled') buttonsEnabled=$($btnHuntScan.IsEnabled)") },
        { }
    )
    if ($global:Stage -eq 0 -and $global:Tick -gt 8 -and $idle) { $global:Stage = 1 }
    if ($global:Stage -ge 1) {
        if ($global:Stage -le $steps.Count) {
            $result = & $steps[$global:Stage - 1]
            if ($result -ne 'wait') { $global:Stage++ }
        } else {
            $window.Close()
        }
    }
    if ($global:Tick -gt __TIMEOUT__) { $global:Jobs.action = $null; $global:Jobs.scan = $null; $window.Close() }
})
$smoke.Start()

'@
$hook = $hook.Replace('__OUT__', $OutDir.Replace('\', '\\')).Replace('__TIMEOUT__', [string]$TimeoutSeconds)
[System.IO.File]::WriteAllText($appCopy, $text.Replace($marker, $hook + $marker))

& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $appCopy *> (Join-Path $OutDir 'host.txt')
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Screenshots and summary in $OutDir"
Get-Content (Join-Path $OutDir 'summary.txt') -ErrorAction SilentlyContinue
$errors = Select-String -Path (Join-Path $OutDir 'host.txt') -Pattern 'Exception|Cannot convert|is not recognized|Cannot find' -SimpleMatch:$false -ErrorAction SilentlyContinue
if ($errors) { Write-Host "Errors seen in the host output:" -ForegroundColor Red; $errors | Select-Object -First 8 | ForEach-Object { Write-Host "  $($_.Line)" } }
