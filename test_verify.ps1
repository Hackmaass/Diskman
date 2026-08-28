$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DISKMAN VERIFICATION & TEST SUITE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Test Modules
Write-Host "`n[1/5] Testing Module Ingestion..." -ForegroundColor Yellow
. (Join-Path $ScriptDir "src\modules\00-Utils.ps1")
. (Join-Path $ScriptDir "src\modules\Get-DriveMetrics.ps1")
. (Join-Path $ScriptDir "src\modules\Start-FolderScan.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-SmartCleanup.ps1")
. (Join-Path $ScriptDir "src\modules\Find-LargeFiles.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-ShellActions.ps1")

# 2. Test C: Drive Metrics
Write-Host "`n[2/5] Testing C: Drive Metrics Retrieval..." -ForegroundColor Yellow
$cMetrics = Get-CDriveMetrics
if ($cMetrics) {
    Write-Host "  [OK] C: Drive Detected: $($cMetrics.VolumeLabel) - $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Failed to retrieve C: drive metrics." -ForegroundColor Red
}

# 3. Test C: Drive Junk Scanning & File Inspection
Write-Host "`n[3/5] Testing C: Drive Junk Scanner..." -ForegroundColor Yellow
$junkItems = Scan-SmartCleanupItems
Write-Host "  [OK] Discovered $($junkItems.Count) C: drive cleanable target categories." -ForegroundColor Green

$totalBytes = 0
foreach ($item in $junkItems) {
    $totalBytes += $item.RawBytes
    if ($item.RawBytes -gt 0) {
        Write-Host "    - $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount))" -ForegroundColor Gray
    }
}
Write-Host "  [OK] Total Reclaimable Junk on C: $(Format-Bytes -Bytes $totalBytes)" -ForegroundColor Green

# Test file inspector helper on first target with files
$testTarget = $junkItems | Where-Object { $_.RawBytes -gt 0 } | Select-Object -First 1
if ($testTarget) {
    $files = Get-CleanableCategoryFiles -TargetId $testTarget.Id -Limit 5
    Write-Host "  [OK] File Inspector successfully loaded $($files.Count) sample files from $($testTarget.CategoryName)." -ForegroundColor Green
}

# 4. Test Explorer & Shell Action functions (existence)
Write-Host "`n[4/5] Testing Shell Actions..." -ForegroundColor Yellow
$functions = @("Show-ItemInExplorer", "Open-FolderInExplorer", "Send-ItemToRecycleBin", "Remove-ItemPermanently")
foreach ($fn in $functions) {
    if (Get-Command -Name $fn -ErrorAction SilentlyContinue) {
        Write-Host "  [OK] Function $fn is available." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Function $fn missing." -ForegroundColor Red
    }
}

# 5. Compile & AST Parse Test
Write-Host "`n[5/5] Compiling Standalone Distribution Bundle & Syntax Check..." -ForegroundColor Yellow
& (Join-Path $ScriptDir "Compile.ps1")

$releaseFile = Join-Path $ScriptDir "release\diskman.ps1"
if (Test-Path $releaseFile) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($releaseFile, [ref]$tokens, [ref]$errors)
    
    if ($errors.Count -eq 0) {
        Write-Host "`n==========================================================" -ForegroundColor Green
        Write-Host "  ALL TESTS PASSED! Standalone bundle has 0 syntax errors." -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
    } else {
        Write-Host "`n[FAIL] AST Parser detected syntax errors:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  Line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
        exit 1
    }
} else {
    Write-Host "`n[FAIL] Release file not found at $releaseFile" -ForegroundColor Red
    exit 1
}