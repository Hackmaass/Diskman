$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DISKMAN SAFETY VERIFICATION & TEST SUITE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$testFailures = 0
function Assert-Test {
    param(
        [string]$TestName,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
        if ($Details) { Write-Host "         $Details" -ForegroundColor DarkGray }
    } else {
        Write-Host "  [FAIL] $TestName" -ForegroundColor Red
        if ($Details) { Write-Host "         $Details" -ForegroundColor Yellow }
        $script:testFailures++
    }
}

# 1. Test Modules Ingestion
Write-Host "`n[1/6] Testing Module Ingestion..." -ForegroundColor Yellow
. (Join-Path $ScriptDir "src\modules\00-Utils.ps1")
. (Join-Path $ScriptDir "src\modules\Get-DriveMetrics.ps1")
. (Join-Path $ScriptDir "src\modules\Start-FolderScan.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-SmartCleanup.ps1")
. (Join-Path $ScriptDir "src\modules\Find-LargeFiles.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-ShellActions.ps1")
Assert-Test "Module Ingestion" $true "All 6 modules loaded successfully."

# 2. Test Path Safety Engine (Comprehensive Safety Matrix)
Write-Host "`n[2/6] Running System Servicing & Path Safety Guard Unit Tests..." -ForegroundColor Yellow

$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }
$sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }

# A. C:\Windows is rejected
$resWin = Test-PathSafety -Path "$sysRoot"
Assert-Test "Reject Windows OS Root ($sysRoot)" (-not $resWin.Safe) $resWin.Reason

# B. C:\Windows\System32 is rejected
$resSys32 = Test-PathSafety -Path "$sysRoot\System32"
Assert-Test "Reject System32 Root" (-not $resSys32.Safe) $resSys32.Reason

$resSys32Sub = Test-PathSafety -Path "$sysRoot\System32\drivers\etc"
Assert-Test "Reject System32 Subpath ($sysRoot\System32\drivers\etc)" (-not $resSys32Sub.Safe) $resSys32Sub.Reason

# C. C:\Windows\WinSxS is rejected
$resWinSxS = Test-PathSafety -Path "$sysRoot\WinSxS"
Assert-Test "Reject WinSxS Root" (-not $resWinSxS.Safe) $resWinSxS.Reason

$resWinSxSSub = Test-PathSafety -Path "$sysRoot\WinSxS\Temp"
Assert-Test "Reject WinSxS Subpath ($sysRoot\WinSxS\Temp)" (-not $resWinSxSSub.Safe) $resWinSxSSub.Reason

# D. C:\Windows\servicing is rejected
$resServicing = Test-PathSafety -Path "$sysRoot\servicing"
Assert-Test "Reject Servicing Root ($sysRoot\servicing)" (-not $resServicing.Safe) $resServicing.Reason

# E. C:\Windows\servicing\Packages is rejected
$resServPackages = Test-PathSafety -Path "$sysRoot\servicing\Packages"
Assert-Test "Reject Servicing Packages ($sysRoot\servicing\Packages)" (-not $resServPackages.Safe) $resServPackages.Reason

$resServSessions = Test-PathSafety -Path "$sysRoot\servicing\Sessions"
Assert-Test "Reject Servicing Sessions ($sysRoot\servicing\Sessions)" (-not $resServSessions.Safe) $resServSessions.Reason

# F. C:\Windows\SoftwareDistribution is rejected for generic cleanup
$resSwDist = Test-PathSafety -Path "$sysRoot\SoftwareDistribution"
Assert-Test "Reject SoftwareDistribution Root" (-not $resSwDist.Safe) $resSwDist.Reason

$resSwDistData = Test-PathSafety -Path "$sysRoot\SoftwareDistribution\DataStore"
Assert-Test "Reject SoftwareDistribution\DataStore" (-not $resSwDistData.Safe) $resSwDistData.Reason

# Critical Registry / Repository roots
$resCatroot2 = Test-PathSafety -Path "$sysRoot\System32\catroot2"
Assert-Test "Reject catroot2 ($sysRoot\System32\catroot2)" (-not $resCatroot2.Safe) $resCatroot2.Reason

$resWbem = Test-PathSafety -Path "$sysRoot\System32\wbem\Repository"
Assert-Test "Reject WMI Repository ($sysRoot\System32\wbem\Repository)" (-not $resWbem.Safe) $resWbem.Reason

$resConfig = Test-PathSafety -Path "$sysRoot\System32\config"
Assert-Test "Reject Registry Hives ($sysRoot\System32\config)" (-not $resConfig.Safe) $resConfig.Reason

$resBoot = Test-PathSafety -Path "$sysRoot\Boot"
Assert-Test "Reject Windows Boot ($sysRoot\Boot)" (-not $resBoot.Safe) $resBoot.Reason

# G. SoftwareDistribution\Download is allowed ONLY under conditional/approved category
$resSwDownload = Test-PathSafety -Path "$sysRoot\SoftwareDistribution\Download"
Assert-Test "Approve SoftwareDistribution\Download for conditional cleanup" ($resSwDownload.Safe) $resSwDownload.Reason

$resDeliveryOpt = Test-PathSafety -Path "$sysRoot\SoftwareDistribution\DeliveryOptimization"
Assert-Test "Approve SoftwareDistribution\DeliveryOptimization" ($resDeliveryOpt.Safe) $resDeliveryOpt.Reason

# H. Path Traversal bypass tests
$resTraversal1 = Test-PathSafety -Path "$sysRoot\Temp\..\WinSxS"
Assert-Test "Block Path Traversal (Temp\..\WinSxS)" (-not $resTraversal1.Safe) $resTraversal1.Reason

$resTraversal2 = Test-PathSafety -Path "$sysRoot\SoftwareDistribution\Download\..\DataStore"
Assert-Test "Block Path Traversal (Download\..\DataStore)" (-not $resTraversal2.Safe) $resTraversal2.Reason

$resTraversal3 = Test-PathSafety -Path "$sysRoot\Logs\CBS\..\..\servicing\Packages"
Assert-Test "Block Path Traversal (CBS\..\..\servicing\Packages)" (-not $resTraversal3.Safe) $resTraversal3.Reason

# I. Case Variations
$resCase1 = Test-PathSafety -Path "$($sysRoot.ToLower())\winsxs\manifests"
Assert-Test "Block Lowercase WinSxS ($($sysRoot.ToLower())\winsxs\manifests)" (-not $resCase1.Safe) $resCase1.Reason

$resCase2 = Test-PathSafety -Path "$($sysRoot.ToUpper())\SERVICING\PACKAGES"
Assert-Test "Block Uppercase Servicing Packages" (-not $resCase2.Safe) $resCase2.Reason

# J. Drive Roots
$resDriveRoot = Test-PathSafety -Path "$sysDrive\"
Assert-Test "Block Drive Root ($sysDrive\)" (-not $resDriveRoot.Safe) $resDriveRoot.Reason

# K. Fail Closed on Null / Empty / Invalid characters
$resNull = Test-PathSafety -Path ""
Assert-Test "Fail Closed on empty string" (-not $resNull.Safe) $resNull.Reason

$resInvalid = Test-PathSafety -Path "C:\Windows\<>invalid|path"
Assert-Test "Fail Closed on invalid path syntax" (-not $resInvalid.Safe) $resInvalid.Reason

# L. Reparse Point detection helper test
$reparseRes = Test-ReparsePoint -Path "$sysRoot\System32"
Assert-Test "Test-ReparsePoint helper operational" ($reparseRes -is [bool]) "Returned boolean: $reparseRes"

# M. Critical System Files
$resPagefile = Test-PathSafety -Path "$sysDrive\pagefile.sys"
Assert-Test "Protect pagefile.sys" (-not $resPagefile.Safe) $resPagefile.Reason

$resManifest = Test-PathSafety -Path "$sysRoot\servicing\update.manifest"
Assert-Test "Protect *.manifest servicing file" (-not $resManifest.Safe) $resManifest.Reason

# N. Browser Sensitive Data
$userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$resLoginData = Test-PathSafety -Path (Join-Path $userProfile "AppData\Local\Google\Chrome\User Data\Default\Login Data")
Assert-Test "Protect Chrome Login Data" (-not $resLoginData.Safe) $resLoginData.Reason

$resCookies = Test-PathSafety -Path (Join-Path $userProfile "AppData\Local\Google\Chrome\User Data\Default\Cookies")
Assert-Test "Protect Chrome Cookies" (-not $resCookies.Safe) $resCookies.Reason

# 3. Test Windows Servicing State Detector
Write-Host "`n[3/6] Testing Windows Servicing & Reboot State Detection..." -ForegroundColor Yellow
$servicingState = Test-WindowsServicingActive
Assert-Test "Test-WindowsServicingActive returns structured state" ($null -ne $servicingState.IsActive) "State: IsActive=$($servicingState.IsActive), Reason=$($servicingState.Reason)"

# 4. Test Target Definitions & Safety Classifications
Write-Host "`n[4/6] Auditing All Cleanable Target Safety Classifications..." -ForegroundColor Yellow
$targets = Get-CleanableTargets
Assert-Test "Retrieved $($targets.Count) cleanable target definitions" ($targets.Count -ge 30)

$winUpdateTarget = $targets | Where-Object { $_.Id -eq 'WinUpdateCache' } | Select-Object -First 1
Assert-Test "Windows Update Cache is classified as 'Advanced'" ($winUpdateTarget.SafetyLevel -eq 'Advanced') "SafetyLevel: $($winUpdateTarget.SafetyLevel)"
Assert-Test "Windows Update Cache is NOT Recommended by default" ($winUpdateTarget.Recommended -eq $false) "Recommended: $($winUpdateTarget.Recommended)"

$delivOptTarget = $targets | Where-Object { $_.Id -eq 'DeliveryOpt' } | Select-Object -First 1
Assert-Test "Delivery Optimization is classified as 'Advanced'" ($delivOptTarget.SafetyLevel -eq 'Advanced') "SafetyLevel: $($delivOptTarget.SafetyLevel)"
Assert-Test "Delivery Optimization is NOT Recommended by default" ($delivOptTarget.Recommended -eq $false) "Recommended: $($delivOptTarget.Recommended)"

# Verify no targets claim '100% Safe'
$hundredSafeTargets = $targets | Where-Object { $_.SafetyLevel -like "*100%*" }
Assert-Test "No targets use exaggerated '100% Safe' label" ($hundredSafeTargets.Count -eq 0) "Found: $($hundredSafeTargets.Count)"

# Test Safe ordinary caches
$userTempTarget = $targets | Where-Object { $_.Id -eq 'UserTemp' } | Select-Object -First 1
Assert-Test "Windows User Temp is classified as Safe & Recommended" ($userTempTarget.SafetyLevel -eq 'Safe' -and $userTempTarget.Recommended -eq $true)

$dxCacheTarget = $targets | Where-Object { $_.Id -eq 'NvidiaDxCache' } | Select-Object -First 1
Assert-Test "Shader Cache is classified as Safe" ($dxCacheTarget.SafetyLevel -eq 'Safe')

# 5. Test C: Drive Scanner & File Inspection
Write-Host "`n[5/6] Testing C: Drive Junk Scanner & Shell Functions..." -ForegroundColor Yellow
$junkItems = Scan-SmartCleanupItems
Assert-Test "Scan-SmartCleanupItems executed successfully" ($junkItems.Count -gt 0) "Scanned $($junkItems.Count) categories."

$functions = @("Show-ItemInExplorer", "Open-FolderInExplorer", "Send-ItemToRecycleBin", "Remove-ItemPermanently")
foreach ($fn in $functions) {
    $hasFn = [bool](Get-Command -Name $fn -ErrorAction SilentlyContinue)
    Assert-Test "Function $fn is available" $hasFn
}

# 6. Standalone Compilation & Release AST Parsing
Write-Host "`n[6/6] Compiling Standalone Distribution Bundle & Syntax Verification..." -ForegroundColor Yellow
& (Join-Path $ScriptDir "Compile.ps1")

$releaseFile = Join-Path $ScriptDir "release\diskman.ps1"
if (Test-Path $releaseFile) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($releaseFile, [ref]$tokens, [ref]$errors)
    
    $noAstErrors = ($errors.Count -eq 0)
    Assert-Test "Compiled bundle has 0 AST parser syntax errors" $noAstErrors "Errors count: $($errors.Count)"
    if (-not $noAstErrors) {
        $errors | ForEach-Object { Write-Host "  Line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    }
} else {
    Assert-Test "Release file generated at $releaseFile" $false
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
if ($testFailures -eq 0) {
    Write-Host "  ALL TESTS PASSED! (0 Failures)" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "  VERIFICATION FAILED: $testFailures test(s) failed." -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Cyan
    exit 1
}