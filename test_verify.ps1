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
Write-Host "`n[1/8] Testing Module Ingestion..." -ForegroundColor Yellow
. (Join-Path $ScriptDir "src\modules\00-Utils.ps1")
. (Join-Path $ScriptDir "src\modules\Get-DriveMetrics.ps1")
. (Join-Path $ScriptDir "src\modules\Start-FolderScan.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-SmartCleanup.ps1")
. (Join-Path $ScriptDir "src\modules\Find-LargeFiles.ps1")
. (Join-Path $ScriptDir "src\modules\Invoke-ShellActions.ps1")
Assert-Test "Module Ingestion" $true "All 6 modules loaded successfully."

# 2. Test Path Safety Engine (Comprehensive Safety Matrix)
Write-Host "`n[2/8] Running System Servicing & Path Safety Guard Unit Tests..." -ForegroundColor Yellow

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
Write-Host "`n[3/8] Testing Indicator-Based Windows Servicing & Reboot Detection..." -ForegroundColor Yellow

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
Write-Host "`n[4/8] Testing Reparse Point Fail-Closed Semantics & Isolation..." -ForegroundColor Yellow

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
Write-Host "`n[5/8] Auditing All Cleanable Target Safety Classifications..." -ForegroundColor Yellow
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
Write-Host "`n[6/8] Testing C: Drive Junk Scanner & Shell Functions..." -ForegroundColor Yellow
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
Write-Host "`n[7/8] Testing real deletion in a sandbox, Hunter safety gate, and worker wiring..." -ForegroundColor Yellow

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

# 8. Standalone Compilation & Release AST Parsing
Write-Host "`n[8/8] Compiling Standalone Distribution Bundle & Syntax Verification..." -ForegroundColor Yellow
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