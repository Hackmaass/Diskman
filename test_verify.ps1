$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DISKMAN SAFETY VERIFICATION & TEST SUITE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Safety net: allow-listed commands (hibernation off, DISM, diskpart...) are only reported, never executed, even if this runs elevated
$env:DISKMAN_DRY_RUN = '1'
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
Write-Host "`n[1/9] Testing Module Ingestion..." -ForegroundColor Yellow
. (Join-Path $ScriptDir "src\modules\00-Utils.ps1")
. (Join-Path $ScriptDir "src\modules\Get-DriveMetrics.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-SmartCleanup.ps1")
. (Join-Path $ScriptDir "src\modules\Find-LargeFiles.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-ShellActions.ps1")
. (Join-Path $ScriptDir "src\modules\Scan-DriveTree.ps1")
. (Join-Path $ScriptDir "src\modules\Get-SystemSpace.ps1")
. (Join-Path $ScriptDir "src\modules\Get-SpaceRules.ps1")
. (Join-Path $ScriptDir "src\modules\Find-AppCaches.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-DiskCompact.ps1")
Assert-Test "Module Ingestion" $true "All modules loaded successfully."

# 2. Test Path Safety Engine (Comprehensive Safety Matrix)
Write-Host "`n[2/9] Running System Servicing & Path Safety Guard Unit Tests..." -ForegroundColor Yellow

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

# L. Critical System Files
$resPagefile = Test-PathSafety -Path "$sysDrive\pagefile.sys"
Assert-Test "Protect pagefile.sys" (-not $resPagefile.Safe) $resPagefile.Reason

$resManifest = Test-PathSafety -Path "$sysRoot\servicing\update.manifest"
Assert-Test "Protect *.manifest servicing file" (-not $resManifest.Safe) $resManifest.Reason

# M. Browser Sensitive Data
$userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$resLoginData = Test-PathSafety -Path (Join-Path $userProfile "AppData\Local\Google\Chrome\User Data\Default\Login Data")
Assert-Test "Protect Chrome Login Data" (-not $resLoginData.Safe) $resLoginData.Reason

$resCookies = Test-PathSafety -Path (Join-Path $userProfile "AppData\Local\Google\Chrome\User Data\Default\Cookies")
Assert-Test "Protect Chrome Cookies" (-not $resCookies.Safe) $resCookies.Reason

# 3. Test Windows Servicing State Detector (Detailed Scenarios)
Write-Host "`n[3/9] Testing Indicator-Based Windows Servicing & Reboot Detection..." -ForegroundColor Yellow

# C: Active BITS transfer causes servicing-active
$bitsMock = Test-WindowsServicingActive -MockOverrides @{ ActiveBits = $true }
Assert-Test "Active BITS transfer causes servicing-active" ($bitsMock.IsActive -eq $true -and $bitsMock.Status -eq "ACTIVE") "Reason: $($bitsMock.Reason)"

# D: CBS RebootPending causes servicing-active
$cbsRebootMock = Test-WindowsServicingActive -MockOverrides @{ CbsRebootPending = $true }
Assert-Test "CBS RebootPending causes servicing-active" ($cbsRebootMock.IsActive -eq $true -and $cbsRebootMock.Status -eq "ACTIVE") "Component: $($cbsRebootMock.Component)"

# E: CBS RebootInProgress causes servicing-active
$cbsProgressMock = Test-WindowsServicingActive -MockOverrides @{ CbsRebootInProgress = $true }
Assert-Test "CBS RebootInProgress causes servicing-active" ($cbsProgressMock.IsActive -eq $true -and $cbsProgressMock.Status -eq "ACTIVE") "Component: $($cbsProgressMock.Component)"

# F: Windows Update RebootRequired causes servicing-active
$wuRebootMock = Test-WindowsServicingActive -MockOverrides @{ WuRebootRequired = $true }
Assert-Test "Windows Update RebootRequired causes servicing-active" ($wuRebootMock.IsActive -eq $true -and $wuRebootMock.Status -eq "ACTIVE") "Component: $($wuRebootMock.Component)"

# G: Unknown servicing state fails closed
$unknownMock = Test-WindowsServicingActive -MockOverrides @{ ForceUnknown = $true }
Assert-Test "Unknown servicing state fails closed" ($unknownMock.IsActive -eq $true -and $unknownMock.Status -eq "UNKNOWN") "Reason: $($unknownMock.Reason)"

# 4. Test Reparse Point Fail-Closed Semantics & Safe Traversal
Write-Host "`n[4/9] Testing Reparse Point Fail-Closed Semantics & Isolation..." -ForegroundColor Yellow

# H: Reparse inspection failure fails closed
$reparseEmpty = Test-ReparsePoint -Path ""
Assert-Test "Empty path to Test-ReparsePoint fails closed" (-not $reparseEmpty.Success -and $reparseEmpty.IsReparsePoint) $reparseEmpty.Reason

$reparseSys32 = Test-ReparsePoint -Path "$sysRoot\System32"
Assert-Test "Normal directory returns Success=true, IsReparsePoint=false" ($reparseSys32.Success -and -not $reparseSys32.IsReparsePoint) "Reason: $($reparseSys32.Reason)"

# I & J: Reparse point sandbox test (verify cleanup and file inspection never follow reparse points)
$testTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "Diskman_Reparse_Test_$([System.Guid]::NewGuid().ToString('N'))"
try {
    New-Item -Path $testTempRoot -ItemType Directory -Force | Out-Null
    $realFolder = Join-Path $testTempRoot "RealFolder"
    New-Item -Path $realFolder -ItemType Directory -Force | Out-Null
    $testFile = Join-Path $realFolder "sample.txt"
    Set-Content -Path $testFile -Value "Diskman safety test file"

    # Create target folder that junction will point to
    $outsideTarget = Join-Path $testTempRoot "OutsideTarget"
    New-Item -Path $outsideTarget -ItemType Directory -Force | Out-Null
    $outsideFile = Join-Path $outsideTarget "outside_secret.txt"
    Set-Content -Path $outsideFile -Value "Should never be touched"

    # Create a directory junction inside RealFolder pointing to OutsideTarget
    $junctionPath = Join-Path $realFolder "LinkedJunction"
    $cmdOutput = cmd /c "mklink /J `"$junctionPath`" `"$outsideTarget`"" 2>&1

    if (Test-Path -LiteralPath $junctionPath) {
        $junctionCheck = Test-ReparsePoint -Path $junctionPath
        Assert-Test "Test-ReparsePoint detects directory junction" ($junctionCheck.Success -and $junctionCheck.IsReparsePoint) "Reason: $($junctionCheck.Reason)"

        # Verify Get-FolderSizeFast does not count contents across junction
        $sizeResult = Get-FolderSizeFast -Path $realFolder
        Assert-Test "Get-FolderSizeFast does NOT traverse into junction" ($sizeResult.FileCount -eq 1) "File count in RealFolder: $($sizeResult.FileCount) (Expected 1)"
    } else {
        Assert-Test "Junction could be created for the reparse test" $false "mklink /J failed: $cmdOutput"
    }
} finally {
    if (Test-Path -LiteralPath $testTempRoot) {
        # If junction exists, remove it non-recursively first
        $junc = Join-Path $testTempRoot "RealFolder\LinkedJunction"
        if (Test-Path -LiteralPath $junc) {
            try { [System.IO.Directory]::Delete($junc, $false) } catch {}
        }
        Remove-Item -LiteralPath $testTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 5. Test Target Definitions & Safety Classifications
Write-Host "`n[5/9] Auditing All Cleanable Target Safety Classifications..." -ForegroundColor Yellow
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

# Comprehensive Explanation & Safety Audit across ALL cleanable targets
$missingWhatDeleted = @($targets | Where-Object { [string]::IsNullOrWhiteSpace($_.WhatGetsDeleted) })
Assert-Test "All targets define accurate 'WhatGetsDeleted' explanations" ($missingWhatDeleted.Count -eq 0) "Missing count: $($missingWhatDeleted.Count)"

$missingSafetyExp = @($targets | Where-Object { [string]::IsNullOrWhiteSpace($_.SafetyExplanation) })
Assert-Test "All targets define detailed 'SafetyExplanation' rationale" ($missingSafetyExp.Count -eq 0) "Missing count: $($missingSafetyExp.Count)"

$missingConsequences = @($targets | Where-Object { [string]::IsNullOrWhiteSpace($_.Consequences) })
Assert-Test "All targets define clear 'Consequences' post-deletion behavior" ($missingConsequences.Count -eq 0) "Missing count: $($missingConsequences.Count)"

$invalidSafetyLevels = @($targets | Where-Object { $_.SafetyLevel -notin @('Safe', 'Optional', 'Advanced') })
Assert-Test "All targets conform to strict 3-tier Safety taxonomy ('Safe', 'Optional', 'Advanced')" ($invalidSafetyLevels.Count -eq 0) "Invalid count: $($invalidSafetyLevels.Count)"

$invalidSafetyBadges = @($targets | Where-Object { $_.SafetyBadge -notin @('SAFE', 'OPTIONAL', 'ADVANCED') })
Assert-Test "All targets define valid uppercase SafetyBadges" ($invalidSafetyBadges.Count -eq 0) "Invalid count: $($invalidSafetyBadges.Count)"


# 6. Test C: Drive Scanner & File Inspection
Write-Host "`n[6/9] Testing C: Drive Junk Scanner & Shell Functions..." -ForegroundColor Yellow
$junkItems = Scan-SmartCleanupItems
Assert-Test "Scan-SmartCleanupItems executed successfully" ($junkItems.Count -gt 0) "Scanned $($junkItems.Count) categories."

# Verify items claiming space are sorted on top, and 0-byte items are at the end
$foundZero = $false
$sortingValid = $true
foreach ($item in $junkItems) {
    if ($item.RawBytes -eq 0) {
        $foundZero = $true
    } elseif ($foundZero -and $item.RawBytes -gt 0) {
        $sortingValid = $false
        break
    }
}
Assert-Test "Scan-SmartCleanupItems sorts space-claiming items on top and 0 bytes at the end" $sortingValid

$functions = @("Show-ItemInExplorer", "Open-FolderInExplorer", "Send-ItemToRecycleBin", "Remove-ItemPermanently")
foreach ($fn in $functions) {
    $hasFn = [bool](Get-Command -Name $fn -ErrorAction SilentlyContinue)
    Assert-Test "Function $fn is available" $hasFn
}

# Test Find-LargeFiles AI & Incomplete Download Classification
# Outside AppData on purpose: the single-file gate never offers files from there
$hunterTestDir = Join-Path $env:PUBLIC ("Diskman_HuntTest_" + [System.Guid]::NewGuid().ToString("N"))
try {
    New-Item -Path $hunterTestDir -ItemType Directory -Force | Out-Null
    
    # Create test dummy files (each 1.5MB)
    $dummyBytes = New-Object byte[] (1.5MB)
    [System.IO.File]::WriteAllBytes((Join-Path $hunterTestDir "Qwen3.5-9B-Model.part"), $dummyBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $hunterTestDir "random_download.part"), $dummyBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $hunterTestDir "installer.exe"), $dummyBytes)

    $allFound = Find-LargeFiles -TargetPath $hunterTestDir -MinSizeBytes 1MB -CategoryFilter "All Categories"
    $aiFound  = Find-LargeFiles -TargetPath $hunterTestDir -MinSizeBytes 1MB -CategoryFilter "AI Model / Weights"
    $partFound = Find-LargeFiles -TargetPath $hunterTestDir -MinSizeBytes 1MB -CategoryFilter "Incomplete / Temp Download"

    $qwenItem = $allFound | Where-Object { $_.Name -like "*Qwen*" } | Select-Object -First 1
    Assert-Test "Find-LargeFiles classifies .part AI model as 'AI Model / Weights'" ($qwenItem.Category -eq "AI Model / Weights") "Category: $($qwenItem.Category)"

    $randItem = $allFound | Where-Object { $_.Name -like "*random_download*" } | Select-Object -First 1
    Assert-Test "Find-LargeFiles classifies generic .part as 'Incomplete / Temp Download'" ($randItem.Category -eq "Incomplete / Temp Download") "Category: $($randItem.Category)"

    Assert-Test "Find-LargeFiles category filter 'AI Model / Weights' matches model .part" (@($aiFound | Where-Object { $_.Name -like "*Qwen*" }).Count -eq 1 -and @($aiFound | Where-Object { $_.Name -like "*random_download*" }).Count -eq 0)

    Assert-Test "Find-LargeFiles category filter 'Incomplete / Temp Download' matches generic .part" (@($partFound | Where-Object { $_.Name -like "*random_download*" }).Count -eq 1 -and @($partFound | Where-Object { $_.Name -like "*Qwen*" }).Count -eq 0)
} finally {
    if (Test-Path -LiteralPath $hunterTestDir) {
        Remove-Item -LiteralPath $hunterTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 7. Sandbox deletion, Hunter gating, and background-worker wiring
Write-Host "`n[7/9] Testing real deletion in a sandbox, Hunter safety gate, and worker wiring..." -ForegroundColor Yellow

# Hunter / single-file gate: user folders allowed, apps / VMs / WSL / OneDrive blocked, bulk gate unchanged
$up = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$pf = if ($env:ProgramFiles) { $env:ProgramFiles } else { "C:\Program Files" }
Assert-Test "Bulk gate still blocks Downloads" (-not (Test-PathSafety -Path "$up\Downloads\big.iso").Safe)
Assert-Test "Single-file gate allows Downloads" ((Test-PathSafety -Path "$up\Downloads\big.iso" -SingleFile).Safe)
Assert-Test "Single-file gate blocks Program Files contents" (-not (Test-PathSafety -Path "$pf\SomeGame\data.bin" -SingleFile).Safe)
Assert-Test "Single-file gate blocks WSL distro disk (Packages\...\ext4.vhdx)" (-not (Test-PathSafety -Path "$up\AppData\Local\Packages\Distro\LocalState\ext4.vhdx" -SingleFile).Safe)
Assert-Test "Single-file gate blocks per-user app installs (AppData\Local\Programs)" (-not (Test-PathSafety -Path "$up\AppData\Local\Programs\Microsoft VS Code\Code.exe" -SingleFile).Safe)
Assert-Test "Single-file gate blocks Discord / Electron installs (AppData\Local\Discord)" (-not (Test-PathSafety -Path "$up\AppData\Local\Discord\app-1.0\Discord.exe" -SingleFile).Safe)
Assert-Test "Single-file gate blocks hidden tool folders (.vscode\extensions)" (-not (Test-PathSafety -Path "$up\.vscode\extensions\x\native.exe" -SingleFile).Safe)
Assert-Test "Single-file gate allows AI model stores (.ollama\models)" ((Test-PathSafety -Path "$up\.ollama\models\blobs\sha256-abc" -SingleFile).Safe)
Assert-Test "Single-file gate blocks game libraries (SteamLibrary / steamapps)" (-not (Test-PathSafety -Path "C:\SteamLibrary\steamapps\common\G\game.pak" -SingleFile).Safe)
Assert-Test "Single-file gate blocks VM folders (VirtualBox VMs)" (-not (Test-PathSafety -Path "$up\VirtualBox VMs\dev\dev.vdi" -SingleFile).Safe)
Assert-Test "Single-file gate blocks Windows files" (-not (Test-PathSafety -Path "$sysRoot\System32\kernel32.dll" -SingleFile).Safe)
Assert-Test "Bulk gate blocks 'OneDrive - Company' folders" (-not (Test-PathSafety -Path "$up\OneDrive - Contoso\a.zip").Safe)
Assert-Test "Single-file gate blocks 'OneDrive - Company' folders" (-not (Test-PathSafety -Path "$up\OneDrive - Contoso\a.zip" -SingleFile).Safe)

# Recycle Bin definition: real path (no stray backtick), never pre-selected
$recycleTarget = $targets | Where-Object { $_.Id -eq 'RecycleBin' } | Select-Object -First 1
Assert-Test "Recycle Bin path has no stray backtick" ($recycleTarget.Path -eq (Join-Path $sysDrive '$Recycle.Bin')) "Path: $($recycleTarget.Path)"
Assert-Test "Recycle Bin is Optional and not Recommended" ($recycleTarget.SafetyLevel -eq 'Optional' -and -not $recycleTarget.Recommended)
Assert-Test "Scan-SmartCleanupItems -Id scans only that target" (@(Scan-SmartCleanupItems -Id 'UserTemp').Count -eq 1)

# Same function set the app copies into its background worker (read from app.ps1 so the two cannot drift)
$appText = Get-Content -Path (Join-Path $ScriptDir "src\app.ps1") -Raw
$workerBlock = [regex]::Match($appText, '\$workerFunctions\s*=\s*@\(([\s\S]*?)\)').Groups[1].Value
$workerFns = @([regex]::Matches($workerBlock, "'([\w-]+)'") | ForEach-Object { $_.Groups[1].Value })
$missingFns = @($workerFns | Where-Object { -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
Assert-Test "Every worker function exists in the modules" ($workerFns.Count -gt 0 -and $missingFns.Count -eq 0) "Missing: $($missingFns -join ', ')"

function Invoke-InWorker {
    param([string]$Script, [hashtable]$Vars = @{})
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in $workerFns) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, (Get-Command $fn -CommandType Function).Definition)))
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Script)
    try { return @($ps.Invoke()) } finally { $ps.Dispose(); $rs.Dispose() }
}

$workerScan = Invoke-InWorker -Script 'Scan-SmartCleanupItems -Id "UserTemp"'
Assert-Test "Worker runspace can scan (all dependencies present)" (@($workerScan).Count -eq 1 -and $workerScan[0].Id -eq 'UserTemp')

# Sandbox: a fake cleanup target with a nested junction, a read-only file, a subfolder and a locked file
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "Diskman_CleanTest_$([System.Guid]::NewGuid().ToString('N'))"
$lockStream = $null
try {
    $outside  = Join-Path $sandbox "outside"
    $cache    = Join-Path $sandbox "cache"
    $linkRoot = Join-Path $sandbox "linked_root"
    New-Item -ItemType Directory -Path $outside, $cache, (Join-Path $cache "sub") -Force | Out-Null
    Set-Content -Path (Join-Path $outside "outside_secret.txt") -Value "must survive"
    Set-Content -Path (Join-Path $cache "a.tmp") -Value "junk"
    Set-Content -Path (Join-Path $cache "sub\b.tmp") -Value "junk"
    Set-Content -Path (Join-Path $cache "ro.tmp") -Value "junk"
    Set-ItemProperty -Path (Join-Path $cache "ro.tmp") -Name IsReadOnly -Value $true
    $lockStream = [System.IO.File]::Open((Join-Path $cache "locked.tmp"), 'Create', 'ReadWrite', 'None')
    cmd /c "mklink /J `"$(Join-Path $cache 'link')`" `"$outside`"" | Out-Null
    cmd /c "mklink /J `"$linkRoot`" `"$outside`"" | Out-Null

    $sizeInside = Get-FolderSizeFast -Path $cache
    Assert-Test "Get-FolderSizeFast does not count through the junction" ($sizeInside.FileCount -eq 4) "Files: $($sizeInside.FileCount) (expected 4: a.tmp, b.tmp, ro.tmp, locked.tmp)"
    $sizeLink = Get-FolderSizeFast -Path $linkRoot
    Assert-Test "A target that is itself a junction is sized as empty" ($sizeLink.IsLink -eq $true -and $sizeLink.RawBytes -eq 0)

    $makeItem = {
        param($path)
        $stats = Get-FolderSizeFast -Path $path
        [PSCustomObject]@{ Id = 'SandboxTest'; CategoryName = 'Sandbox'; Target = $path; Type = 'DirectoryContents'
            IsSelected = $true; RequiresAdmin = $false; RawBytes = [long]$stats.RawBytes; RawCount = [int]$stats.FileCount
            DisplaySize = Format-Bytes -Bytes $stats.RawBytes; FileCount = "$($stats.FileCount) items" }
    }

    $res = Invoke-InWorker -Script 'Invoke-ExecuteCleanup -SelectedItems @($Item)' -Vars @{ Item = (& $makeItem $cache) } | Select-Object -Last 1
    Assert-Test "Cleanup left the file behind the nested junction untouched" (Test-Path -LiteralPath (Join-Path $outside "outside_secret.txt"))
    $deletedAll = (-not (Test-Path -LiteralPath (Join-Path $cache "a.tmp"))) -and (-not (Test-Path -LiteralPath (Join-Path $cache "ro.tmp"))) -and (-not (Test-Path -LiteralPath (Join-Path $cache "sub")))
    Assert-Test "Cleanup deleted plain, read-only and nested files" $deletedAll
    Assert-Test "Cleanup skipped the locked file instead of failing" (Test-Path -LiteralPath (Join-Path $cache "locked.tmp"))
    Assert-Test "Cleanup reports freed bytes from a measurement (above 0, never above what the scan saw)" ($res.TotalFreedBytes -gt 0 -and $res.TotalFreedBytes -le $sizeInside.RawBytes) "Freed: $($res.DisplayFreed)"

    # The exact worker script the app uses ($cleanupWork in app.ps1): progress lines must cross from the worker to the UI queue
    $cleanupScript = [regex]::Match($appText, '\$cleanupWork = \{([\s\S]*?)\n\}').Groups[1].Value
    Assert-Test "Found the app's worker cleanup script" ($cleanupScript -match 'Invoke-ExecuteCleanup')
    $cache2 = Join-Path $sandbox "cache2"
    New-Item -ItemType Directory -Path (Join-Path $cache2 "sub") -Force | Out-Null
    Set-Content -Path (Join-Path $cache2 "x.tmp") -Value "junk"
    Set-Content -Path (Join-Path $cache2 "sub\y.tmp") -Value "junk"
    $logQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $res3 = Invoke-InWorker -Script $cleanupScript -Vars @{ LogQueue = $logQueue; TargetId = $null; Items = @(& $makeItem $cache2) } | Select-Object -Last 1
    $queued = @(); $line = $null
    while ($logQueue.TryDequeue([ref]$line)) { $queued += , $line }
    Assert-Test "Worker progress reaches the UI queue" (@($queued | Where-Object { $_[0] -like 'Purged Sandbox*' }).Count -eq 1) "Queued lines: $($queued.Count)"
    Assert-Test "Worker cleanup removed the files and reports freed bytes" ((-not (Test-Path -LiteralPath (Join-Path $cache2 "x.tmp"))) -and $res3.TotalFreedBytes -gt 0)

    $res2 = Invoke-InWorker -Script 'Invoke-ExecuteCleanup -SelectedItems @($Item)' -Vars @{ Item = (& $makeItem $linkRoot) } | Select-Object -Last 1
    Assert-Test "Cleanup refuses a target that is itself a junction" ((Test-Path -LiteralPath (Join-Path $outside "outside_secret.txt")) -and $res2.DeletedCount -eq 0)
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    foreach ($j in @((Join-Path $sandbox "cache\link"), (Join-Path $sandbox "linked_root"))) {
        if (Test-Path -LiteralPath $j) { try { [System.IO.Directory]::Delete($j, $false) } catch {} }
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# GUI wiring: every control app.ps1 looks up must exist in the XAML (a typo would otherwise only show at click time)
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue
    [xml]$xamlDoc = Get-Content -Path (Join-Path $ScriptDir "src\xaml\MainWindow.xaml") -Raw
    $testWindow = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))
    $controlNames = @([regex]::Matches($appText, 'Find-Control\s+"(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $missingControls = @($controlNames | Where-Object { -not $testWindow.FindName($_) })
    Assert-Test "XAML loads and all $($controlNames.Count) controls used by app.ps1 exist" ($controlNames.Count -gt 0 -and $missingControls.Count -eq 0) "Missing: $($missingControls -join ', ')"
} else {
    Write-Host "  [SKIP] GUI wiring check needs an STA host (run with powershell -STA)" -ForegroundColor DarkYellow
}

# 8. Space analyzer: tree walker, accounting, rules, allowed commands
Write-Host "`n[8/9] Testing the space analyzer (tree, accounting, rules, commands)..." -ForegroundColor Yellow

$treeSandbox = Join-Path $env:PUBLIC "Diskman_TreeTest_$([System.Guid]::NewGuid().ToString('N'))"
try {
    $treeOutside = Join-Path $treeSandbox "outside"
    $treeRoot = Join-Path $treeSandbox "root"
    New-Item -ItemType Directory -Path $treeOutside, (Join-Path $treeRoot "a[1]\deep"), (Join-Path $treeRoot "many") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $treeOutside "secret.bin"), (New-Object byte[] 3MB))
    [System.IO.File]::WriteAllBytes((Join-Path $treeRoot "f1.bin"), (New-Object byte[] 2MB))
    [System.IO.File]::WriteAllBytes((Join-Path $treeRoot "a[1]\deep\f2.bin"), (New-Object byte[] 5MB))
    1..200 | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $treeRoot "many\d$_") | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $treeRoot "many\d$_\t.bin"), (New-Object byte[] 1000))
    }
    cmd /c "mklink /J `"$(Join-Path $treeRoot 'link')`" `"$treeOutside`"" | Out-Null

    $tree = Scan-DriveTree -Root $treeRoot
    $expected = 2MB + 5MB + 200000
    Assert-Test "TreeScan total equals the known file sizes (junction content excluded)" ($tree.Bytes -eq $expected) "Bytes: $($tree.Bytes), expected $expected"

    function Test-TreeInvariant($n) {
        $sum = $n.OwnBytes
        foreach ($c in $n.Children) { $sum += $c.Bytes; if (-not (Test-TreeInvariant $c)) { return $false } }
        return ($sum -eq $n.Bytes)
    }
    Assert-Test "TreeScan invariant holds for every node (Bytes = OwnBytes + children)" (Test-TreeInvariant $tree)
    $many = $tree.Children | Where-Object { $_.Name -eq 'many' }
    Assert-Test "Folders under 1 MB are rolled into the parent but totals are unchanged" ($null -eq $many -or $many.Children.Count -eq 0)
    Assert-Test "A folder with brackets in its name is found by exact path" ($null -ne ($tree.Children | Where-Object { $_.Path -eq (Join-Path $treeRoot 'a[1]') }))

    [Diskman.TreeScan]::Cancel = $true
    $null = [Diskman.TreeScan]::Scan($treeRoot)
    $treeAgain = Scan-DriveTree -Root $treeRoot
    Assert-Test "After a cancelled scan, Reset lets the next scan finish completely" ($treeAgain.Bytes -eq $tree.Bytes -and -not [Diskman.TreeScan]::Cancel)

    $rowsPos = Get-SpaceAccounting -Root $tree -UsedBytes ($tree.Bytes + 10MB) -Elevated $false
    Assert-Test "Accounting rows sum to used space with a Protected remainder" ((($rowsPos | Measure-Object Bytes -Sum).Sum -eq ($tree.Bytes + 10MB)) -and ($rowsPos | Where-Object Kind -eq 'Protected'))
    $rowsNeg = Get-SpaceAccounting -Root $tree -UsedBytes ($tree.Bytes - 1MB) -Elevated $true
    Assert-Test "A negative remainder becomes 'Windows shared files' and rows still sum to used" ((($rowsNeg | Measure-Object Bytes -Sum).Sum -eq ($tree.Bytes - 1MB)) -and ($rowsNeg | Where-Object Kind -eq 'Shared'))
    $cats = Get-SpaceCategory -Root $tree
    Assert-Test "Category totals add up to the scanned bytes" ((($cats.Values | Measure-Object -Sum).Sum) -eq $tree.Bytes)
    $biggest = @(Get-BiggestFolders -Root $tree -Max 5 -MinBytes 1MB)
    Assert-Test "Biggest folders steps into a dominant child (a[1] -> a[1]\deep)" ($biggest.Count -ge 1 -and $biggest[0].Path -eq (Join-Path $treeRoot 'a[1]\deep')) "First: $($biggest[0].Path)"
} finally {
    $j = Join-Path $treeSandbox "root\link"
    if (Test-Path -LiteralPath $j) { try { [System.IO.Directory]::Delete($j, $false) } catch {} }
    if (Test-Path -LiteralPath $treeSandbox) { Remove-Item -LiteralPath $treeSandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# Rules: evidence-based, exact paths, never a parent folder, Claude-Data never deletable
$ruleList = Get-SpaceRules
$cleanRules = @($ruleList | Where-Object { $_.Verdict -eq 'Clean' })
$unsafeClean = @($cleanRules | Where-Object { -not (Test-PathSafety -Path $_.Path).Safe -and $_.TargetId -notin @('RecycleBin') })
Assert-Test "Every Clean rule passes the bulk safety gate" ($cleanRules.Count -ge 30 -and $unsafeClean.Count -eq 0) "Unsafe: $(($unsafeClean | ForEach-Object { $_.Path }) -join '; ')"
$claudeRule = Find-SpaceRule -Path (Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Claude-Data')
Assert-Test "Claude-Data is Review and has no delete or command action" ($claudeRule.Verdict -eq 'Review' -and -not $claudeRule.TargetId -and -not $claudeRule.CommandId)
$parents = @($ruleList | Where-Object { $_.Verdict -in 'Clean', 'Command' -and $_.Path -in @($env:ProgramData, ([System.Environment]::GetFolderPath('LocalApplicationData')), ([System.Environment]::GetFolderPath('ApplicationData'))) })
Assert-Test "No delete or command rule points at a ProgramData / AppData parent" ($parents.Count -eq 0)
Assert-Test "Unknown folders have no rule" ($null -eq (Find-SpaceRule -Path "$env:SystemDrive\Definitely\Not\A\Known\Folder"))
Assert-Test "Rules match exact paths only (a sibling with the same prefix does not match)" ($null -eq (Find-SpaceRule -Path ((Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Claude-Data') + '2')))

# Allowed commands: exact strings and consent text with the side effects named
$allowed = Get-AllowedCommands
Assert-Test "DockerPrune command string" ("$($allowed.DockerPrune.Exe) $($allowed.DockerPrune.Args -join ' ')" -eq 'docker.exe system prune -f')
Assert-Test "ComponentCleanup command string" ("$($allowed.ComponentCleanup.Exe) $($allowed.ComponentCleanup.Args -join ' ')" -eq 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup' -and $allowed.ComponentCleanup.RequiresAdmin)
Assert-Test "HibernateOff command string and Fast Startup warning" ("$($allowed.HibernateOff.Exe) $($allowed.HibernateOff.Args -join ' ')" -eq 'powercfg.exe /h off' -and $allowed.HibernateOff.Consent -match 'Fast Startup')
Assert-Test "ShadowDelete command string and restore point warning" ("$($allowed.ShadowDelete.Exe) $($allowed.ShadowDelete.Args -join ' ')" -eq "vssadmin.exe delete shadows /for=$($env:SystemDrive) /oldest /quiet" -and $allowed.ShadowDelete.Consent -match 'restore point')
$rejected = $false
try { Invoke-AllowedCommand -Id 'FormatDrive' | Out-Null } catch { $rejected = $true }
Assert-Test "Invoke-AllowedCommand rejects an id that is not on the allow-list" $rejected
$isAdminNow = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdminNow) {
    $lines = New-Object System.Collections.Generic.List[string]
    $code = Invoke-AllowedCommand -Id 'HibernateOff' -OnLine { param($t) $lines.Add($t) }
    Assert-Test "An admin-only command is refused (not run) when not elevated" ($code -eq -1 -and ($lines -join ' ') -match 'Administrator')
}

# Admin-only cleanup rows cannot be ticked unless elevated, and say why
$sysTempItem = Scan-SmartCleanupItems -Id 'SystemTemp' | Select-Object -First 1
Assert-Test "Admin-only rows have CanSelect = elevated and a tooltip reason" ($sysTempItem.CanSelect -eq $isAdminNow -and ($isAdminNow -or $sysTempItem.SelectTip -match 'administrator'))

# app.ps1 wiring that must not regress: confirmations default to No, everything is written to the audit log
$appSource = Get-Content -Path (Join-Path $ScriptDir "src\app.ps1") -Raw
Assert-Test "Only Confirm-Action uses a Yes/No dialog (and it defaults to No)" (([regex]::Matches($appSource, 'MessageBoxButton\]::YesNo')).Count -eq 1 -and $appSource -match 'MessageBoxResult\]::No\)')
Assert-Test "Log-Console writes every line to the audit log" ($appSource -match '(?s)function Log-Console.*?Write-AuditLog')

# Every text/background pair the UI uses meets WCAG AA (4.5:1); the list lives in tools\Measure-Contrast.ps1
$contrastRows = @(& (Join-Path $ScriptDir "tools\Measure-Contrast.ps1") -Quiet)
$contrastFails = @($contrastRows | Where-Object { $_.Result -ne 'pass' })
Assert-Test "All $($contrastRows.Count) UI colour pairs meet 4.5:1 contrast" ($contrastRows.Count -gt 0 -and $contrastFails.Count -eq 0) "Failing: $(($contrastFails | ForEach-Object { $_.Pair }) -join '; ')"

# System space panel
$sysRows = Get-SystemSpace -Root $null -Elevated $isAdminNow
Assert-Test "System space reports swapfile, paging file, hibernation and shadow copies" (@($sysRows | Where-Object { $_.Name -match 'swapfile|Paging|Hibernation|Shadow' }).Count -ge 4)
Assert-Test "Shadow copies need administrator when not elevated" ($isAdminNow -or (($sysRows | Where-Object { $_.Name -match 'Shadow' }).NeedsAdmin -eq $true))

# 8b. Detected app caches, multi-target cleaning, disk compaction
Write-Host "`n[8b] Testing app cache detection, multi-folder cleaning and disk compaction guards..." -ForegroundColor Yellow

# npm's real cache lives under LocalAppData (the old path pointed at Roaming and never existed)
$npmTarget = (Get-CleanableTargets | Where-Object { $_.Id -eq 'NpmCache' })
Assert-Test "NpmCache points at %LOCALAPPDATA%\npm-cache\_cacache" ($npmTarget.Path -eq (Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'npm-cache\_cacache')) "Path: $($npmTarget.Path)"
$npxTarget = (Get-CleanableTargets | Where-Object { $_.Id -eq 'NpmNpxCache' })
Assert-Test "npx packages (code that running tools execute) are Optional and never one-click" ($npxTarget.SafetyLevel -eq 'Optional' -and -not $npxTarget.Recommended -and $npxTarget.Path -like '*npm-cache\_npx')

# Exclusions: the helper itself, tested on plain strings
$fixedPaths = @(Get-CleanableTargets | ForEach-Object { $_.Path })
$userLocal = [System.Environment]::GetFolderPath('LocalApplicationData')
Assert-Test "Claude-Data is always excluded" (Test-AppCacheExcluded -Path "$userLocal\Claude-Data\claude_x\Cache" -FixedTargetPaths $fixedPaths)
Assert-Test "Store app packages are excluded" (Test-AppCacheExcluded -Path "$userLocal\Packages\Some.App_123\LocalCache\Cache" -FixedTargetPaths $fixedPaths)
Assert-Test "A folder already covered by a fixed target is excluded (never counted twice)" (Test-AppCacheExcluded -Path "$($npmTarget.Path)\content-v2" -FixedTargetPaths $fixedPaths)
Assert-Test "An ordinary app folder is not excluded" (-not (Test-AppCacheExcluded -Path "$userLocal\SomeEditor\Cache" -FixedTargetPaths $fixedPaths))

# Detection by structure, in a sandbox that stands in for AppData
$cacheBox = Join-Path $userLocal "Diskman_CacheTest_$([System.Guid]::NewGuid().ToString('N'))"
try {
    $mk = { param($rel, $mb) $f = Join-Path $cacheBox $rel; New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null; [System.IO.File]::WriteAllBytes($f, (New-Object byte[] ($mb * 1MB))) }
    & $mk 'Chromish\User Data\Default\Cache\Cache_Data\index' 0
    & $mk 'Chromish\User Data\Default\Cache\Cache_Data\data_0' 2
    & $mk 'Chromish\User Data\Default\Code Cache\js\a.bin' 2
    & $mk 'Chromish\User Data\Default\GPUCache\index' 0
    & $mk 'Chromish\User Data\Default\GPUCache\data_0' 2
    & $mk 'Chromish\User Data\Default\Service Worker\Database\000003.log' 0
    & $mk 'Chromish\User Data\Default\Service Worker\CacheStorage\blob.bin' 2
    & $mk 'Chromish\User Data\Default\Login Data' 1
    & $mk 'Decoy\Cache\notes.bin' 3
    & $mk 'Editor\User\settings.json' 0
    & $mk 'Editor\CachedData\z.bin' 2
    & $mk 'Claude-Data\app\Cache\Cache_Data\index' 0
    & $mk 'Claude-Data\app\Cache\Cache_Data\data_0' 2

    Assert-Test "A bare 'Cache' folder without Cache_Data\index is not a cache" ($null -eq (Get-AppCacheKind -Path (Join-Path $cacheBox 'Decoy\Cache')))
    Assert-Test "A real Chromium Cache folder is recognised" ($null -ne (Get-AppCacheKind -Path (Join-Path $cacheBox 'Chromish\User Data\Default\Cache')))

    $treeC = Scan-DriveTree -Root $cacheBox
    $found = @(Find-AppCaches -Root $treeC -MinBytes 1MB -AppDataPath $cacheBox)
    $chrom = $found | Where-Object { $_.CategoryName -like 'Chromish*' }
    $editor = $found | Where-Object { $_.CategoryName -like 'Editor*' }
    Assert-Test "Detection finds the fake Chromium app with its cache folders and nothing else" ($chrom -and @($chrom.Targets).Count -eq 4 -and -not (@($chrom.Targets) -match 'Login Data'))
    Assert-Test "A group containing a service worker cache is Optional; plain caches are Safe" ($chrom.SafetyLevel -eq 'Optional' -and $editor.SafetyLevel -eq 'Safe')
    Assert-Test "The VS Code-style app is found only because settings.json exists" ($editor -and @($editor.Targets).Count -eq 1)
    Assert-Test "The decoy folder and Claude-Data are never in the results" (-not (@($found | ForEach-Object { $_.Targets }) -match 'Decoy|Claude-Data'))
    Assert-Test "Detected items look like cleanup items (id, bytes, Dynamic flag)" ($chrom.Id -like 'App:*' -and $chrom.RawBytes -ge 6MB -and $chrom.Dynamic -eq $true)

    # Rules follow the detection, so the Overview and Explorer can advise on each folder
    Set-DetectedCacheItems -Items $found
    $cacheRule = Find-SpaceRule -Path (Join-Path $cacheBox 'Chromish\User Data\Default\Code Cache')
    Assert-Test "Each detected folder gets a Clean rule that points at its app group" ($cacheRule.Verdict -eq 'Clean' -and $cacheRule.TargetId -eq $chrom.Id)
    Set-DetectedCacheItems -Items @()
    Assert-Test "Clearing detected items removes their rules" ($null -eq (Find-SpaceRule -Path (Join-Path $cacheBox 'Chromish\User Data\Default\Code Cache')))

    # Cleaning one app group (several folders) through the same worker path as everything else
    $chrom.IsSelected = $true
    $cleaned = Invoke-InWorker -Script 'Invoke-ExecuteCleanup -SelectedItems @($Item)' -Vars @{ Item = $chrom } | Select-Object -Last 1
    $left = (Get-ChildItem -LiteralPath (Join-Path $cacheBox 'Chromish\User Data\Default\Cache') -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    Assert-Test "A multi-folder item cleans every folder and reports measured bytes" (($cleaned.TotalFreedBytes -ge 6MB) -and ($left -eq 0) -and (Test-Path -LiteralPath (Join-Path $cacheBox 'Chromish\User Data\Default\Login Data')))
    Assert-Test "The decoy and Claude-Data caches were not touched" ((Test-Path -LiteralPath (Join-Path $cacheBox 'Decoy\Cache\notes.bin')) -and (Test-Path -LiteralPath (Join-Path $cacheBox 'Claude-Data\app\Cache\Cache_Data\data_0')))
    [void](Update-DetectedItemSize -Item $chrom)
    Assert-Test "Update-DetectedItemSize re-measures a cleaned item to zero" ($chrom.RawBytes -eq 0 -and $chrom.IsSelected -eq $false)
} finally {
    Set-DetectedCacheItems -Items @()
    if (Test-Path -LiteralPath $cacheBox) { Remove-Item -LiteralPath $cacheBox -Recurse -Force -ErrorAction SilentlyContinue }
}

# Disk compaction: only registered Docker/WSL disks, never a VM disk of another app
Assert-Test "The detach script (run after every attempt) is exactly select and detach with noerr" ((New-DiskpartDetachScript -Path 'C:\x\disk.vhdx') -eq "select vdisk file=`"C:\x\disk.vhdx`"`r`ndetach vdisk noerr`r`nexit`r`n")
Assert-Test "The diskpart script is exactly select, attach readonly, compact, detach" ((New-DiskpartCompactScript -Path 'C:\x\disk.vhdx') -eq "select vdisk file=`"C:\x\disk.vhdx`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit`r`n")
$compactable = @(Get-CompactableDisks)
Assert-Test "Registered disks never include another app's VM disk (Claude-Data)" (-not (@($compactable | ForEach-Object { $_.Path }) -match 'Claude-Data'))
$refusal = New-Object System.Collections.Generic.List[string]
$refCode = Invoke-VhdCompact -Path "$userLocal\Claude-Data\claude_x\vm_bundles\claudevm.bundle\rootfs.vhdx" -OnLine { param($t) $refusal.Add($t) }
Assert-Test "Compaction refuses a disk that is not a registered Docker/WSL disk" ($refCode -eq -1 -and ($refusal -join ' ') -match 'Refused')
$viaAllowList = New-Object System.Collections.Generic.List[string]
$viaCode = Invoke-AllowedCommand -Id 'CompactDisk' -Path 'C:\Windows\System32\config\SYSTEM' -OnLine { param($t) $viaAllowList.Add($t) }
Assert-Test "The allow-list entry CompactDisk refuses an arbitrary path too" ($viaCode -eq -1 -and ($viaAllowList -join ' ') -match 'Refused')
if (-not $isAdminNow -and $compactable.Count -gt 0) {
    $adminMsg = New-Object System.Collections.Generic.List[string]
    $adminCode = Invoke-VhdCompact -Path $compactable[0].Path -OnLine { param($t) $adminMsg.Add($t) }
    Assert-Test "Compacting a real registered disk is refused when not elevated" ($adminCode -eq -1 -and ($adminMsg -join ' ') -match 'Administrator')
}
Assert-Test "CompactDisk consent says Docker Desktop must be quit" ((Get-AllowedCommands).CompactDisk.Consent -match 'Docker Desktop must be quit' -and (Get-AllowedCommands).CompactDisk.RequiresAdmin)
Assert-Test "DockerPrune consent says Docker Desktop must be running" ((Get-AllowedCommands).DockerPrune.Consent -match 'must be running')
Assert-Test "Test-DockerEngineRunning returns a boolean without starting anything" ((Test-DockerEngineRunning) -is [bool])

# 8c. Portability: advice for unknown folders, Temp age floor, dry run, drive-aware helpers
Write-Host "`n[8c] Testing portability (generic advice, age floor, dry run, drive-aware helpers)..." -ForegroundColor Yellow

$pfDir = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
$pf86Dir = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }
$profileDir = [System.Environment]::GetFolderPath('UserProfile')
$localDir = [System.Environment]::GetFolderPath('LocalApplicationData')
$sampleAdvice = [ordered]@{
    "$pfDir\SomeCoolApp"                       = 'Uninstall'
    "$pfDir\NVIDIA Corporation"                = 'System'
    "$pfDir\Windows Defender"                  = 'System'
    "$pfDir\Common Files"                      = 'System'
    "$pf86Dir\Intel"                           = 'System'
    "$pf86Dir\Steam\steamapps\common\Big Game" = 'Review'
    "$profileDir\Documents\Taxes"              = 'Review'
    "$localDir\Packages\Some.App_1abc"         = 'Review'
    "$profileDir\.cargo"                       = 'Review'
    "$localDir\SomeVendor"                     = 'Review'
    "$($env:SystemRoot)\Fonts"                 = 'System'
}
$badAdvice = @()
foreach ($path in $sampleAdvice.Keys) {
    $a = Get-GenericAdvice -Path $path
    if (-not $a -or $a.Verdict -ne $sampleAdvice[$path] -or $a.TargetId -or $a.CommandId -or -not $a.Generic) { $badAdvice += "$path -> $($a.Verdict)" }
}
Assert-Test "Generic advice gives the expected verdict for 11 typical locations (drivers and Windows are never 'uninstall')" ($badAdvice.Count -eq 0) "Wrong: $($badAdvice -join '; ')"
Assert-Test "Generic advice returns nothing for a folder it knows nothing about" ($null -eq (Get-GenericAdvice -Path 'Z:\Some\Random\Folder'))
Assert-Test "Generic advice handles drive roots and empty paths without throwing" ($null -eq (Get-GenericAdvice -Path "$($env:SystemDrive)\") -and $null -eq (Get-GenericAdvice -Path $env:SystemDrive) -and $null -eq (Get-GenericAdvice -Path ''))
Assert-Test "Generic advice can never offer Clean or Command" (@($sampleAdvice.Keys | ForEach-Object { (Get-GenericAdvice -Path $_).Verdict } | Where-Object { $_ -in 'Clean', 'Command' }).Count -eq 0)
Assert-Test "An exact rule is not shadowed by generic advice (Find-SpaceRule stays exact-only)" ($null -eq (Find-SpaceRule -Path "$pfDir\SomeCoolApp"))
$roamingDir = [System.Environment]::GetFolderPath('ApplicationData')
Assert-Test "iPhone backup folder has a Review rule (never delete advice)" ((Find-SpaceRule -Path "$roamingDir\Apple Computer\MobileSync\Backup").Verdict -eq 'Review')

# Temp age floor: a fresh file (an installer may be using it) is kept, an old one is cleaned
$ageBox = Join-Path $env:PUBLIC "Diskman_AgeTest_$([System.Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $ageBox -Force | Out-Null
    Set-Content -Path (Join-Path $ageBox 'old.tmp') -Value 'old'
    Set-Content -Path (Join-Path $ageBox 'fresh.tmp') -Value 'fresh'
    (Get-Item -LiteralPath (Join-Path $ageBox 'old.tmp')).LastWriteTime = (Get-Date).AddDays(-3)
    $ageStats = Get-FolderSizeFast -Path $ageBox
    $ageItem = [PSCustomObject]@{ Id = 'AgeTest'; CategoryName = 'Age test'; Target = $ageBox; Type = 'DirectoryContents'; IsSelected = $true; RequiresAdmin = $false
        RawBytes = [long]$ageStats.RawBytes; RawCount = [int]$ageStats.FileCount; DisplaySize = 'x'; FileCount = '2 items'; MinAgeHours = 24 }
    $ageRes = Invoke-InWorker -Script 'Invoke-ExecuteCleanup -SelectedItems @($Item)' -Vars @{ Item = $ageItem } | Select-Object -Last 1
    Assert-Test "Items changed in the last 24 h are kept, older ones are cleaned" ((-not (Test-Path -LiteralPath (Join-Path $ageBox 'old.tmp'))) -and (Test-Path -LiteralPath (Join-Path $ageBox 'fresh.tmp'))) "Log: $($ageRes.Logs -join ' | ')"
    Assert-Test "The cleanup log says how many recent items were kept" (($ageRes.Logs -join ' ') -match 'kept')
} finally {
    if (Test-Path -LiteralPath $ageBox) { Remove-Item -LiteralPath $ageBox -Recurse -Force -ErrorAction SilentlyContinue }
}
$userTempTarget = Get-CleanableTargets | Where-Object { $_.Id -eq 'UserTemp' }
$sysTempTarget = Get-CleanableTargets | Where-Object { $_.Id -eq 'SystemTemp' }
Assert-Test "Both Temp targets carry the 24 hour age floor" ($userTempTarget.MinAgeHours -eq 24 -and $sysTempTarget.MinAgeHours -eq 24)

# Dry run: an allow-listed command that needs no admin is reported, not executed
$dryLines = New-Object System.Collections.Generic.List[string]
$dryCode = Invoke-AllowedCommand -Id 'DockerPrune' -OnLine { param($t) $dryLines.Add($t) }
Assert-Test "DISKMAN_DRY_RUN reports the command instead of running it" ($dryCode -eq 0 -and ($dryLines -join ' ') -match 'Dry run: would run docker.exe')

# Drive-aware helpers
$par = Get-ScanParallelism -Root "$($env:SystemDrive)\"
Assert-Test "Scan parallelism is 2 (HDD), 4 (unknown) or 8 (SSD)" ($par -in 2, 4, 8) "Value: $par"
$sysMetrics = Get-CDriveMetrics
Assert-Test "Drive metrics describe the Windows drive" ($null -ne $sysMetrics -and $sysMetrics.TotalGB -gt 0)
Assert-Test "System space rows carry a Settings link for Windows leftovers when present" (@(Get-SystemSpace -Root $null -Elevated $false | Where-Object { $_.PSObject.Properties['Uri'] }).Count -ge 1)

# 9. Standalone Compilation & Release AST Parsing
Write-Host "`n[9/9] Compiling Standalone Distribution Bundle & Syntax Verification..." -ForegroundColor Yellow
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

    $rawBytes = [System.IO.File]::ReadAllBytes($releaseFile)
    $hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
    Assert-Test "Compiled bundle is UTF-8 without BOM (prevents irm | iex '#' error)" (-not $hasBom) "First byte: $($rawBytes[0])"

    $firstChar = if ($rawBytes.Length -gt 0) { [char]$rawBytes[0] } else { '' }
    Assert-Test "Compiled bundle begins with ASCII comment '#' (0x23)" ($firstChar -eq '#') "First char: '$firstChar'"
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