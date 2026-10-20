# =====================================================================
# Diskman - Windows Storage Analyzer & Smart Storage Cleaner
# Distributed via PowerShell + WPF (Zero Dependencies)
# =====================================================================

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
    Write-Host "Restarting Diskman in STA apartment mode for WPF..." -ForegroundColor Cyan
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "& { `$script = [System.IO.File]::ReadAllText('$PSCommandPath'); Invoke-Expression `$script }"
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, Microsoft.VisualBasic -ErrorAction SilentlyContinue

# --- Module: 00-Utils.ps1 ---
function Format-Bytes {
    [CmdletBinding()]
    param([long]$Bytes)

    if ($Bytes -ge 1TB) {
        return "$([math]::Round($Bytes / 1TB, 2)) TB"
    } elseif ($Bytes -ge 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) GB"
    } elseif ($Bytes -ge 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) MB"
    } elseif ($Bytes -ge 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) KB"
    } else {
        return "$Bytes B"
    }
}

function Test-IsSubpathOrEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Candidate,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Parent
    )

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Parent)) {
        return $false
    }

    try {
        $candNorm = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
        $parNorm  = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')

        if ($candNorm -ieq $parNorm) {
            return $true
        }

        $parPrefix = $parNorm + [System.IO.Path]::DirectorySeparatorChar
        return $candNorm.StartsWith($parPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-ReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    # Fail Closed: empty, null, or whitespace cannot be verified
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{
            Success        = $false
            IsReparsePoint = $true
            Reason         = "Path is empty or null (failing closed as reparse point)."
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return @{
                Success        = $true
                IsReparsePoint = $false
                Reason         = "Path does not exist."
            }
        }

        $attr = [System.IO.File]::GetAttributes($Path)
        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) {
            return @{
                Success        = $true
                IsReparsePoint = $true
                Reason         = "Reparse point (junction / symlink) detected."
            }
        }

        return @{
            Success        = $true
            IsReparsePoint = $false
            Reason         = "Normal non-reparse file system item."
        }
    } catch {
        # Fail Closed: Any metadata access or inspection failure is treated as unsafe/reparse
        return @{
            Success        = $false
            IsReparsePoint = $true
            Reason         = "Reparse inspection failed ($($_.Exception.Message)) - failing closed."
        }
    }
}

function Test-WindowsServicingActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$MockOverrides = $null
    )

    try {
        # Support test mock overrides if provided
        if ($null -ne $MockOverrides) {
            if ($MockOverrides.ContainsKey('ForceUnknown') -and $MockOverrides['ForceUnknown']) {
                throw [System.Exception]"Simulated servicing inspection error"
            }
            if ($MockOverrides.ContainsKey('ActiveBits') -and $MockOverrides['ActiveBits']) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "Active BITS update/payload transfer jobs are in progress."
                    Component = "bits"
                }
            }
            if ($MockOverrides.ContainsKey('CbsRebootPending') -and $MockOverrides['CbsRebootPending']) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "Windows CBS reports a reboot is pending to apply staged updates."
                    Component = "CBS\RebootPending"
                }
            }
            if ($MockOverrides.ContainsKey('CbsRebootInProgress') -and $MockOverrides['CbsRebootInProgress']) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "Windows CBS reports update servicing is in progress."
                    Component = "CBS\RebootInProgress"
                }
            }
            if ($MockOverrides.ContainsKey('WuRebootRequired') -and $MockOverrides['WuRebootRequired']) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "Windows Update reports a reboot is required to finalize installed updates."
                    Component = "WindowsUpdate\RebootRequired"
                }
            }
        }

        # 1. Check Active BITS (Background Intelligent Transfer Service) Transfer Jobs
        try {
            $bitsJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue
            if ($bitsJobs) {
                $activeBitsJobs = $bitsJobs | Where-Object { $_.JobState -in @('Transferring', 'Connecting', 'Queued', 'Transferred') }
                if ($activeBitsJobs) {
                    return @{
                        IsActive  = $true
                        Status    = "ACTIVE"
                        Reason    = "Active BITS update/payload transfer jobs are in progress."
                        Component = "bits"
                    }
                }
            }
        } catch {}

        # 2. Check Component Based Servicing (CBS) Registry Reboot / Staging Keys
        $cbsRebootPending = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        if (Test-Path -LiteralPath $cbsRebootPending) {
            return @{
                IsActive  = $true
                Status    = "ACTIVE"
                Reason    = "Windows CBS reports a reboot is pending to apply staged updates."
                Component = "CBS\RebootPending"
            }
        }

        $cbsRebootInProgress = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress"
        if (Test-Path -LiteralPath $cbsRebootInProgress) {
            return @{
                IsActive  = $true
                Status    = "ACTIVE"
                Reason    = "Windows CBS reports update servicing is in progress."
                Component = "CBS\RebootInProgress"
            }
        }

        $cbsPackagesPending = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending"
        if (Test-Path -LiteralPath $cbsPackagesPending) {
            return @{
                IsActive  = $true
                Status    = "ACTIVE"
                Reason    = "Windows CBS reports packages are pending servicing."
                Component = "CBS\PackagesPending"
            }
        }

        # 3. Check Windows Update AutoUpdate Reboot Required Keys
        $wuRebootRequired = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        if (Test-Path -LiteralPath $wuRebootRequired) {
            return @{
                IsActive  = $true
                Status    = "ACTIVE"
                Reason    = "Windows Update reports a reboot is required to finalize installed updates."
                Component = "WindowsUpdate\RebootRequired"
            }
        }

        $wuPostReboot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting"
        if (Test-Path -LiteralPath $wuPostReboot) {
            return @{
                IsActive  = $true
                Status    = "ACTIVE"
                Reason    = "Windows Update is awaiting post-reboot servicing reporting."
                Component = "WindowsUpdate\PostRebootReporting"
            }
        }

        # 4. Check Session Manager PendingFileRenameOperations
        try {
            $smKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
            $pendingRenames = (Get-ItemProperty -Path $smKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pendingRenames -and $pendingRenames.Count -gt 0) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "System has PendingFileRenameOperations queued for next reboot."
                    Component = "SessionManager\PendingFileRenameOperations"
                }
            }
        } catch {}

        # 5. Check UpdateExeVolatile
        try {
            $updateVolatileKey = "HKLM:\SOFTWARE\Microsoft\Updates"
            $volatileVal = (Get-ItemProperty -Path $updateVolatileKey -Name "UpdateExeVolatile" -ErrorAction SilentlyContinue).UpdateExeVolatile
            if ($null -ne $volatileVal -and [int]$volatileVal -ne 0) {
                return @{
                    IsActive  = $true
                    Status    = "ACTIVE"
                    Reason    = "UpdateExeVolatile flag is active ($volatileVal)."
                    Component = "Updates\UpdateExeVolatile"
                }
            }
        } catch {}

        # Idle: Services (e.g. wuauserv, TrustedInstaller) may be running, but there is no evidence of active update staging or pending reboots
        return @{
            IsActive  = $false
            Status    = "IDLE"
            Reason    = "Servicing state is idle."
            Component = $null
        }
    } catch {
        # Fail Closed: If servicing state cannot be verified, fail closed
        return @{
            IsActive  = $true
            Status    = "UNKNOWN"
            Reason    = "Unable to verify servicing state ($($_.Exception.Message)) - failing closed."
            Component = "Unknown"
        }
    }
}

function Test-PathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        # Single-file actions (Large Files Hunter) may touch user folders such as Downloads,
        # but get extra blocks for application, VM and WSL data. Bulk cleanup never sets this.
        [switch]$SingleFile
    )

    # Fail Closed: Check null, empty or whitespace
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Safe = $false; Reason = "Path is empty or null." }
    }

    try {
        # Normalize and resolve full absolute path
        $normalized = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        return @{ Safe = $false; Reason = "Invalid or unresolvable path ($($_.Exception.Message))." }
    }

    try {
        # Dynamic OS environment resolution
        $sysRoot      = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\', '/') } else { "C:\Windows" }
        $sysDrive     = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', '/') } else { "C:" }
        $progFiles    = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\', '/') } else { "C:\Program Files" }
        $progFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\', '/') } else { "C:\Program Files (x86)" }
        $progData     = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\', '/') } else { "C:\ProgramData" }
        $userProfile  = if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\', '/') } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\', '/') }
        $usersRoot    = [System.IO.Path]::GetDirectoryName($userProfile)
        if ([string]::IsNullOrWhiteSpace($usersRoot)) { $usersRoot = "$sysDrive\Users" }

        # -------------------------------------------------------------
        # 1. Block Drive Roots (e.g. C:, C:\, D:, D:\)
        # -------------------------------------------------------------
        if ($normalized -match '^[A-Za-z]:$' -or $normalized.Length -le 3) {
            return @{ Safe = $false; Reason = "Drive roots cannot be targeted for cleanup." }
        }

        # -------------------------------------------------------------
        # 2. Block Critical System Boot, Virtual Memory & Kernel Files
        # -------------------------------------------------------------
        $fileName = [System.IO.Path]::GetFileName($normalized)
        $blockedSystemFiles = @(
            "pagefile.sys",
            "swapfile.sys",
            "hiberfil.sys",
            "bootmgr",
            "bootstat.dat",
            "BCD",
            "NTUSER.DAT",
            "UsrClass.dat"
        )

        foreach ($sysFile in $blockedSystemFiles) {
            if ($fileName -ieq $sysFile -or $fileName -ilike "$sysFile.*") {
                return @{ Safe = $false; Reason = "Protected Windows system boot/kernel file ($fileName)." }
            }
        }

        # Block servicing state files and database files
        if ($fileName -ilike "*.mum" -or $fileName -ilike "*.manifest" -or $fileName -ieq "pending.xml" -or $fileName -ieq "reboot.xml" -or $fileName -ieq "DataStore.edb") {
            return @{ Safe = $false; Reason = "Protected Windows servicing state/manifest file ($fileName)." }
        }

        # -------------------------------------------------------------
        # 3. Block Browser Sensitive Files (Passwords, Cookies, Sessions)
        # -------------------------------------------------------------
        $blockedBrowserFiles = @(
            "Login Data",
            "Login Data-journal",
            "Cookies",
            "Cookies-journal",
            "History",
            "History-journal",
            "Bookmarks",
            "Bookmarks.bak",
            "Preferences",
            "Secure Preferences",
            "Web Data",
            "Local State"
        )

        if ($fileName -in $blockedBrowserFiles) {
            return @{ Safe = $false; Reason = "Protected user browser profile/credential data ($fileName)." }
        }

        # -------------------------------------------------------------
        # 4. Block Hard System-Servicing & Protected Hierarchies
        # -------------------------------------------------------------
        $strictlyProtectedTrees = @(
            (Join-Path $sysRoot "WinSxS"),
            (Join-Path $sysRoot "servicing"),
            (Join-Path $sysRoot "System32\catroot"),
            (Join-Path $sysRoot "System32\catroot2"),
            (Join-Path $sysRoot "System32\wbem\Repository"),
            (Join-Path $sysRoot "System32\config"),
            (Join-Path $sysRoot "System32\drivers"),
            (Join-Path $sysRoot "System32\DriverStore"),
            (Join-Path $sysRoot "System32\Boot"),
            (Join-Path $sysRoot "Boot"),
            (Join-Path $sysDrive "Boot"),
            (Join-Path $sysDrive "EFI"),
            (Join-Path $sysRoot "SystemApps"),
            (Join-Path $sysRoot "assembly"),
            (Join-Path $sysRoot "Microsoft.NET"),
            (Join-Path $sysRoot "inf"),
            (Join-Path $sysRoot "Fonts"),
            (Join-Path $sysDrive "Recovery"),
            (Join-Path $sysDrive "System Volume Information"),
            (Join-Path $sysDrive "`$WINDOWS.~BT"),
            (Join-Path $sysDrive "`$WINDOWS.~WS"),
            (Join-Path $sysDrive "`$SysReset")
        )

        foreach ($tree in $strictlyProtectedTrees) {
            if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $tree) {
                return @{ Safe = $false; Reason = "Windows servicing / protected OS component path ($tree)." }
            }
        }

        # -------------------------------------------------------------
        # 5. Block System32 and SysWOW64 Hierarchies
        # -------------------------------------------------------------
        $sys32 = Join-Path $sysRoot "System32"
        $sysWow64 = Join-Path $sysRoot "SysWOW64"

        if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $sys32) {
            return @{ Safe = $false; Reason = "Windows System32 directory and contents are protected." }
        }

        if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $sysWow64) {
            return @{ Safe = $false; Reason = "Windows SysWOW64 directory and contents are protected." }
        }

        # -------------------------------------------------------------
        # 6. Windows Root and SoftwareDistribution Protection
        # -------------------------------------------------------------
        if ($normalized -ieq $sysRoot) {
            return @{ Safe = $false; Reason = "Windows system root directory cannot be targeted." }
        }

        # If path is inside Windows directory, only permit explicitly designated safe sub-areas
        if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $sysRoot) {
            $allowedWindowsSubpaths = @(
                (Join-Path $sysRoot "Temp"),
                (Join-Path $sysRoot "Logs\CBS"),
                (Join-Path $sysRoot "Logs\DISM"),
                (Join-Path $sysRoot "SoftwareDistribution\Download"),
                (Join-Path $sysRoot "SoftwareDistribution\DeliveryOptimization")
            )

            $isPermittedSubpath = $false
            foreach ($allowed in $allowedWindowsSubpaths) {
                if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $allowed) {
                    $isPermittedSubpath = $true
                    break
                }
            }

            if (-not $isPermittedSubpath) {
                # Specifically explain if it's SoftwareDistribution non-download or generic Windows directory
                $swDistRoot = Join-Path $sysRoot "SoftwareDistribution"
                if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $swDistRoot) {
                    return @{ Safe = $false; Reason = "SoftwareDistribution parent database/metadata path is protected ($normalized)." }
                }
                return @{ Safe = $false; Reason = "Path is within protected Windows root and is not an approved safe subfolder ($normalized)." }
            }
        }

        # -------------------------------------------------------------
        # 7. Block Program Files, ProgramData, and Users Root Directories
        # -------------------------------------------------------------
        $protectedExactRoots = @(
            $progFiles,
            $progFilesX86,
            $progData,
            $usersRoot,
            $userProfile
        )

        foreach ($exactRoot in $protectedExactRoots) {
            if ($normalized -ieq $exactRoot) {
                return @{ Safe = $false; Reason = "Root directory is protected from bulk cleanup ($exactRoot)." }
            }
        }

        # -------------------------------------------------------------
        # 8. Block User Personal Data Folders
        # -------------------------------------------------------------
        $blockedUserFolders = @(
            (Join-Path $userProfile "Desktop"),
            (Join-Path $userProfile "Documents"),
            (Join-Path $userProfile "Downloads"),
            (Join-Path $userProfile "Pictures"),
            (Join-Path $userProfile "Videos"),
            (Join-Path $userProfile "Music"),
            (Join-Path $userProfile "Contacts"),
            (Join-Path $userProfile "Favorites"),
            (Join-Path $userProfile "Saved Games"),
            (Join-Path $userProfile "OneDrive")
        )

        if (-not $SingleFile) {
            foreach ($uFolder in $blockedUserFolders) {
                if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $uFolder) {
                    return @{ Safe = $false; Reason = "Path is a protected user personal data directory ($uFolder)." }
                }
            }
        }

        # Cloud-synced folders ("OneDrive", "OneDrive - Contoso"): deleting here deletes in the cloud too
        $oneDrivePattern = [System.Management.Automation.WildcardPattern]::Escape($userProfile) + '\OneDrive*'
        if ($normalized -ilike $oneDrivePattern) {
            return @{ Safe = $false; Reason = "Path is inside a OneDrive synced folder." }
        }

        # -------------------------------------------------------------
        # 9. Single-file actions: block installed apps and VM / WSL / Docker data
        # -------------------------------------------------------------
        if ($SingleFile) {
            foreach ($blocked in @($progFiles, $progFilesX86, $progData)) {
                if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $blocked) {
                    return @{ Safe = $false; Reason = "Installed application data ($blocked) cannot be deleted from here." }
                }
            }

            # Per-user installs (VS Code, Discord, Docker Desktop, WSL distros, VM bundles...) live under AppData and
            # hidden tool folders such as .vscode or .codex; only the AI model stores below are fair game.
            if ($normalized.StartsWith($userProfile + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $normalized.Substring($userProfile.Length + 1)
                if ($relative -match '^AppData(\\|$)') {
                    return @{ Safe = $false; Reason = "AppData holds installed apps, WSL distros and VM disks; use the Cleaner tab for its caches." }
                }
                if ($relative -match '^\.(?!(ollama|cache|lmstudio)(\\|$))') {
                    return @{ Safe = $false; Reason = "Hidden tool folder in the user profile ($($relative.Split('\')[0])) is not offered for deletion." }
                }
            }

            # Game libraries and VM folders anywhere on the drive
            if ($normalized -match '\\(steamapps|SteamLibrary|Epic Games|XboxGames|WindowsApps|GOG Games|VirtualBox VMs|Virtual Machines|Virtual hard disks|Hyper-V)(\\|$)') {
                return @{ Safe = $false; Reason = "Game library or virtual machine folder is not offered for deletion." }
            }
        }

        # Passed all multi-layer safety barriers
        return @{ Safe = $true; Reason = "OK" }
    } catch {
        # Fail Closed on any unexpected error
        return @{ Safe = $false; Reason = "Safety evaluation exception: $($_.Exception.Message)" }
    }
}


# --- Module: Find-LargeFiles.ps1 ---
function Find-LargeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$TargetPath = "C:\",

        [Parameter(Mandatory = $false)]
        [long]$MinSizeBytes = 100MB,

        [Parameter(Mandatory = $false)]
        [string]$CategoryFilter = "All Categories",

        [Parameter(Mandatory = $false)]
        [int]$Limit = 100,

        [Parameter(Mandatory = $false)]
        [int]$MaxFolders = 30000
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return @()
    }

    $results = New-Object System.Collections.Generic.List[object]

    $installerExt = @(".exe", ".msi", ".pkg", ".appinstaller", ".cab", ".msu")
    $diskExt      = @(".iso", ".vhd", ".vhdx", ".img", ".vmdk", ".qcow2", ".wim")
    $archiveExt   = @(".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz", ".zst", ".tgz")
    $videoExt     = @(".mp4", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv", ".m4v", ".ts")
    $aiExt        = @(".bin", ".safetensors", ".gguf", ".pt", ".pth", ".onnx", ".model", ".h5", ".ckpt", ".weight", ".weights", ".safetensor")
    $logExt       = @(".log", ".dmp", ".trace", ".etl", ".bak", ".old")
    $dataExt      = @(".csv", ".parquet", ".db", ".sqlite", ".sql")
    $partExt      = @(".part", ".crdownload", ".download", ".partial")

    $sysRoot = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\', '/') } else { "C:\Windows" }
    $progFiles = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\', '/') } else { "C:\Program Files" }
    $progFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\', '/') } else { "C:\Program Files (x86)" }
    $progData = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\', '/') } else { "C:\ProgramData" }
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\', '/') } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\', '/') }
    $usersRoot = [System.IO.Path]::GetDirectoryName($userProfile)
    if ([string]::IsNullOrWhiteSpace($usersRoot)) { $usersRoot = "C:\Users" }

    $dirQueue = New-Object System.Collections.Generic.Queue[string]

    # If scanning drive root, prioritize User profiles first, then custom drive directories, and skip Windows OS tree
    $isDriveRoot = ($TargetPath -match '^[A-Za-z]:\\?$')
    if ($isDriveRoot) {
        if (Test-Path -LiteralPath $usersRoot) {
            # Enqueue current user profile first, then other profiles
            if (Test-Path -LiteralPath $userProfile) {
                $dirQueue.Enqueue($userProfile)
            }
            try {
                $uDir = New-Object System.IO.DirectoryInfo($usersRoot)
                foreach ($sub in $uDir.EnumerateDirectories()) {
                    if ($sub.FullName -ine $userProfile -and (-not ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
                        $dirQueue.Enqueue($sub.FullName)
                    }
                }
            } catch {}
        }

        # Enqueue other root drive folders except Windows and Users
        try {
            $rootInfo = New-Object System.IO.DirectoryInfo($TargetPath)
            foreach ($sub in $rootInfo.EnumerateDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($sub.FullName -ieq $usersRoot -or $sub.FullName -ieq $sysRoot) { continue }
                # Installed apps and shared app data are never offered for deletion, so do not spend scan budget there
                if ($sub.FullName -ieq $progFiles -or $sub.FullName -ieq $progFilesX86 -or $sub.FullName -ieq $progData) { continue }
                if ($sub.Name -ieq "`$Recycle.Bin" -or $sub.Name -ieq "System Volume Information" -or $sub.Name -ieq "`$WinREAgent") { continue }
                $dirQueue.Enqueue($sub.FullName)
            }
        } catch {}
    } else {
        $dirQueue.Enqueue($TargetPath)
    }

    $scannedFolders = 0

    while ($dirQueue.Count -gt 0 -and $scannedFolders -lt $MaxFolders) {
        $currentDir = $dirQueue.Dequeue()
        $scannedFolders++

        # Skip system protected folders unless explicitly targeted by the caller
        if ($isDriveRoot -and ($currentDir -ieq $sysRoot -or $currentDir -ilike "$sysRoot\*")) {
            continue
        }

        # Same exclusions as Test-PathSafety -SingleFile (which stays the authority); pruning here only saves scan time
        if ($currentDir -match '\\\$RECYCLE\.BIN|\\System Volume Information|\\assembly|\\Users\\[^\\]+\\AppData$|\\Users\\[^\\]+\\\.(?!(ollama|cache|lmstudio)$)[^\\]+$|\\(steamapps|SteamLibrary|Epic Games|XboxGames|WindowsApps|GOG Games|VirtualBox VMs|Virtual Machines|Virtual hard disks|Hyper-V)$') {
            continue
        }

        try {
            $dInfo = New-Object System.IO.DirectoryInfo($currentDir)
            
            # Check direct files
            foreach ($f in $dInfo.EnumerateFiles()) {
                if ($f.Length -ge $MinSizeBytes) {
                    # Safety check on file: block critical OS files
                    $safety = Test-PathSafety -Path $f.FullName -SingleFile
                    if (-not $safety.Safe) { continue }

                    $ext = $f.Extension.ToLower()
                    $cat = "Other File"

                    if ($ext -in $installerExt) { $cat = "Installer / Package" }
                    elseif ($ext -in $diskExt) { $cat = "Disk Image / ISO" }
                    elseif ($ext -in $archiveExt) { $cat = "Archive / Zip" }
                    elseif ($ext -in $videoExt) { $cat = "Video / Media" }
                    elseif ($ext -in $logExt) { $cat = "Log / Dump File" }
                    elseif ($ext -in $aiExt) { $cat = "AI Model / Weights" }
                    elseif ($ext -in $dataExt) { $cat = "Dataset / Database" }
                    elseif ($ext -in $partExt) {
                        # Distinguish AI model downloads from generic partial downloads
                        if ($f.Name -match '(?i)qwen|llama|gemma|mistral|deepseek|gguf|safetensors|model|bert|whisper|weights|phi' -or
                            $f.FullName -match '(?i)\\models\\|\\hermes\\|\\ollama\\|\\huggingface\\|\\text-generation-webui|\\lm-studio') {
                            $cat = "AI Model / Weights"
                        } else {
                            $cat = "Incomplete / Temp Download"
                        }
                    }

                    $matchesCat = ($CategoryFilter -eq "All Categories" -or
                        $cat -like "*$CategoryFilter*" -or
                        ($CategoryFilter -eq "AI Model / Weights" -and $cat -like "*AI Model*") -or
                        ($CategoryFilter -eq "Incomplete / Temp Download" -and ($cat -like "*Incomplete*" -or $cat -like "*Download*")))

                    if ($matchesCat) {
                        $results.Add([PSCustomObject]@{
                            Name          = $f.Name
                            FullPath      = $f.FullName
                            RawSize       = $f.Length
                            DisplaySize   = Format-Bytes -Bytes $f.Length
                            Category      = $cat
                            LastWriteTime = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                            Extension     = $ext
                        })
                    }
                }
            }

            # Enqueue subdirectories
            foreach ($sub in $dInfo.EnumerateDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    continue
                }
                # Skip package node_modules or .git during broad disk search
                if ($sub.Name -ieq "node_modules" -or $sub.Name -ieq ".git") {
                    continue
                }
                $dirQueue.Enqueue($sub.FullName)
            }
        } catch {
            continue
        }
    }

    return @($results | Sort-Object RawSize -Descending | Select-Object -First $Limit)
}


# --- Module: Get-DriveMetrics.ps1 ---
function Get-CDriveMetrics {
    [CmdletBinding()]
    param()

    try {
        $cDrive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -like "C:*" -and $_.IsReady } | Select-Object -First 1
        if ($cDrive) {
            $totalGB = [math]::Round($cDrive.TotalSize / 1GB, 2)
            $freeGB = [math]::Round($cDrive.AvailableFreeSpace / 1GB, 2)
            $usedGB = [math]::Round(($cDrive.TotalSize - $cDrive.AvailableFreeSpace) / 1GB, 2)
            $usedPercent = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 1) } else { 0 }

            $statusText = if ($usedPercent -ge 90) { "Critical - low space" } elseif ($usedPercent -ge 75) { "High usage" } else { "Healthy" }

            return [PSCustomObject]@{
                VolumeLabel   = if ([string]::IsNullOrWhiteSpace($cDrive.VolumeLabel)) { "Local Disk" } else { $cDrive.VolumeLabel }
                FileSystem    = $cDrive.DriveFormat
                TotalGB       = $totalGB
                UsedGB        = $usedGB
                FreeGB        = $freeGB
                UsedPercent   = $usedPercent
                StatusText    = $statusText
            }
        }
    } catch {}

    return $null
}


# --- Module: Invoke-ShellActions.ps1 ---
# Add VisualBasic assembly for native Windows Recycle Bin operations
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue

function Show-ItemInExplorer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$Path`""
        return $true
    } elseif (Test-Path -LiteralPath (Split-Path -Parent $Path)) {
        Start-Process "explorer.exe" -ArgumentList "`"$(Split-Path -Parent $Path)`""
        return $true
    } else {
        return $false
    }
}

function Open-FolderInExplorer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Start-Process "explorer.exe" -ArgumentList "`"$Path`""
        return $true
    } else {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
            Start-Process "explorer.exe" -ArgumentList "`"$parent`""
            return $true
        }
        return $false
    }
}

function Send-ItemToRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        # Large Files Hunter only: allow user folders such as Downloads (apps, VM and WSL data stay blocked)
        [switch]$SingleFile
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Strict multi-layer safety check
    $safety = Test-PathSafety -Path $Path -SingleFile:$SingleFile
    if (-not $safety.Safe) {
        return @{ Success = $false; Message = "Protected Path: $($safety.Reason)" }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
        return @{ Success = $true; Message = "Item moved to Recycle Bin safely." }
    } catch {
        return @{ Success = $false; Message = "Failed to recycle: $($_.Exception.Message)" }
    }
}

function Remove-ItemPermanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        # Large Files Hunter only: allow user folders such as Downloads (apps, VM and WSL data stay blocked)
        [switch]$SingleFile
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Strict multi-layer safety check
    $safety = Test-PathSafety -Path $Path -SingleFile:$SingleFile
    if (-not $safety.Safe) {
        return @{ Success = $false; Message = "Action Blocked: $($safety.Reason)" }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $reparseCheck = Test-ReparsePoint -Path $Path
            if (-not $reparseCheck.Success) {
                return @{ Success = $false; Message = "Action Blocked: Could not verify reparse point status ($($reparseCheck.Reason))." }
            }

            if ($reparseCheck.IsReparsePoint) {
                [System.IO.Directory]::Delete($Path, $false)
            } else {
                [System.IO.Directory]::Delete($Path, $true)
            }
        } else {
            [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($Path)
        }
        return @{ Success = $true; Message = "Item permanently deleted." }
    } catch {
        return @{ Success = $false; Message = "Delete failed: $($_.Exception.Message)" }
    }
}


# --- Module: Invoke-SmartCleanup.ps1 ---
# Folder sizing is the hot path (hundreds of thousands of files): a small compiled walker is ~100x faster than a
# PowerShell loop. Loaded once per process; the background worker runspace shares it.
if (-not ('Diskman.FastSize' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
namespace Diskman {
    public static class FastSize {
        // Returns { total bytes, file count }. Junctions and symlinks are never followed.
        public static long[] Measure(string root) {
            long bytes = 0, count = 0;
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count > 0) {
                try {
                    foreach (var entry in new DirectoryInfo(pending.Pop()).EnumerateFileSystemInfos()) {
                        var dir = entry as DirectoryInfo;
                        if (dir != null) {
                            if ((dir.Attributes & FileAttributes.ReparsePoint) == 0) pending.Push(dir.FullName);
                        } else {
                            try { bytes += ((FileInfo)entry).Length; count++; } catch { }
                        }
                    }
                } catch { }
            }
            return new long[] { bytes, count };
        }
    }
}
'@
}

function Get-FolderSizeFast {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ RawBytes = [long]0; FileCount = 0; Exists = $false }
    }

    # A target that is itself a junction/symlink points somewhere else (often another drive): never size it
    if ((Test-ReparsePoint -Path $Path).IsReparsePoint) {
        return @{ RawBytes = [long]0; FileCount = 0; Exists = $true; IsLink = $true }
    }

    # Fail loudly: if security software blocked the compile, silent zeros would look like "nothing to clean"
    if (-not ('Diskman.FastSize' -as [type])) {
        throw "The Diskman folder-size helper could not be compiled (blocked by security software or a restricted PowerShell mode?). Sizes cannot be measured."
    }

    try {
        $m = [Diskman.FastSize]::Measure($Path)
        return @{ RawBytes = [long]$m[0]; FileCount = [int]$m[1]; Exists = $true }
    } catch {
        return @{ RawBytes = [long]0; FileCount = 0; Exists = $true }
    }
}

function Get-CleanableTargets {
    [CmdletBinding()]
    param()

    $sysRoot      = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\', '/') } else { "C:\Windows" }
    $sysDrive     = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', '/') } else { "C:" }
    $progData     = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\', '/') } else { "C:\ProgramData" }
    $userTempPath = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    $appData      = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData)
    $userProfile  = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)

    $targets = @(
        @{
            Id                = 'UserTemp'
            Group             = 'Windows & System'
            Category          = 'Windows User Temp'
            Icon              = '[TEMP]'
            Path              = $userTempPath
            Description       = 'Temporary application and cache files created by running user programs'
            WhatGetsDeleted   = 'Temporary session files, scratch buffers, installer extractors, and ephemeral .tmp files in %LOCALAPPDATA%\Temp.'
            SafetyExplanation = 'Safe: Temporary scratch space used by running programs. Files actively locked by open processes are automatically skipped. User documents, personal files, and program installations are never stored here.'
            Consequences      = 'None. Running applications will automatically create fresh temporary files during future sessions as needed.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SystemTemp'
            Group             = 'Windows & System'
            Category          = 'Windows System Temp'
            Icon              = '[SYS]'
            Path              = (Join-Path $sysRoot 'Temp')
            Description       = 'Operating system temporary cache files and service leftovers'
            WhatGetsDeleted   = 'Operating system service scratch files, driver extraction folders, and background installer leftovers in C:\Windows\Temp.'
            SafetyExplanation = 'Safe (Admin): Temporary files discarded by completed Windows updates and service installations. Active Windows kernel/service files are locked and skipped.'
            Consequences      = 'None. System services and installers generate new temporary files when required.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'WinUpdateCache'
            Group             = 'Windows & System'
            Category          = 'Windows Update Cache'
            Icon              = '[UPDATE]'
            Path              = (Join-Path $sysRoot 'SoftwareDistribution\Download')
            Description       = 'Advanced cleanup - Downloaded Windows Update packages and staging payloads'
            WhatGetsDeleted   = 'Downloaded Windows Update payload .cab archives, patch packages, and cumulative update staging files in C:\Windows\SoftwareDistribution\Download.'
            SafetyExplanation = 'Advanced (Admin): Only safe when Windows Update is idle. Diskman actively confirms Windows Update, BITS, and CBS are idle before proceeding. Parent metadata (DataStore) is strictly protected.'
            Consequences      = 'If an update was staged and pending restart, Windows Update will re-download the installation files from Microsoft servers during the next scan.'
            SafetyBadge       = 'ADVANCED'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Advanced'
            Recommended       = $false
            RequiresAdmin     = $true
        },
        @{
            Id                = 'DeliveryOpt'
            Group             = 'Windows & System'
            Category          = 'Delivery Optimization Files'
            Icon              = '[OPT]'
            Path              = (Join-Path $sysRoot 'SoftwareDistribution\DeliveryOptimization')
            Description       = 'Advanced cleanup - Cached Windows peer-to-peer delivery optimization chunks'
            WhatGetsDeleted   = 'Cached peer-to-peer Windows update chunk files and local network distribution bits in C:\Windows\SoftwareDistribution\DeliveryOptimization.'
            SafetyExplanation = 'Advanced (Admin): Cached chunks used solely to seed updates to other computers on your local network. Core OS files and update registries are not touched.'
            Consequences      = 'Future updates will download directly from Microsoft cloud CDNs rather than peer-to-peer cache.'
            SafetyBadge       = 'ADVANCED'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Advanced'
            Recommended       = $false
            RequiresAdmin     = $true
        },
        @{
            Id                = 'CrashDumps'
            Group             = 'Windows & System'
            Category          = 'Crash Dumps & Minidumps'
            Icon              = '[DUMP]'
            Path              = (Join-Path $localAppData 'CrashDumps')
            Description       = 'Application crash dumps (.dmp files) from previously crashed applications'
            WhatGetsDeleted   = 'Windows Error Reporting post-mortem memory dumps (.dmp) in %LOCALAPPDATA%\CrashDumps.'
            SafetyExplanation = 'Safe: Diagnostic crash memory snapshots captured after past application crashes. They are solely for developer debugging and have zero operational value.'
            Consequences      = 'None. Frees storage. A new dump will only be generated if a program crashes in the future.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'WERLogs'
            Group             = 'Windows & System'
            Category          = 'Windows Error Reports (WER)'
            Icon              = '[LOG]'
            Path              = (Join-Path $localAppData 'Microsoft\Windows\WER')
            Description       = 'Queued and archived Windows error reporting telemetry diagnostic data'
            WhatGetsDeleted   = 'Queued and archived Windows Error Reporting diagnostic reports in %LOCALAPPDATA%\Microsoft\Windows\WER.'
            SafetyExplanation = 'Safe: Telemetry and diagnostic queues waiting to be sent to Microsoft servers. Purging them removes accumulated telemetry without impacting any applications.'
            Consequences      = 'None. Diagnostic error queues are cleared.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'CbsLogs'
            Group             = 'Windows & System'
            Category          = 'Windows CBS & Component Logs'
            Icon              = '[LOG]'
            Path              = (Join-Path $sysRoot 'Logs\CBS')
            Description       = 'Historical Windows Component-Based Servicing installation log files'
            WhatGetsDeleted   = 'Historical Component-Based Servicing installation logs (CBS.log, CbsPersist_*.log/cab) in C:\Windows\Logs\CBS.'
            SafetyExplanation = 'Safe (Admin): Diagnostic text records from past Windows servicing and SFC commands. Active logs in use are skipped. Servicing state files and package manifests are strictly protected.'
            Consequences      = 'Historical installation text history is wiped; Windows CBS initiates a clean, fresh log upon the next servicing event.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'DismLogs'
            Group             = 'Windows & System'
            Category          = 'DISM & Servicing Logs'
            Icon              = '[LOG]'
            Path              = (Join-Path $sysRoot 'Logs\DISM')
            Description       = 'Deployment Image Servicing and Management log files'
            WhatGetsDeleted   = 'Diagnostic log files (dism.log) generated by Deployment Image Servicing and Management in C:\Windows\Logs\DISM.'
            SafetyExplanation = 'Safe (Admin): Historical servicing text logs from DISM operations.'
            Consequences      = 'None. Fresh logs are created when DISM is executed in the future.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'NvidiaDxCache'
            Group             = 'Gaming & GPU'
            Category          = 'NVIDIA DirectX Shader Cache (DXCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'NVIDIA\DXCache')
            Description       = 'Compiled DirectX game shader cache. Rebuilt dynamically by NVIDIA GPU driver.'
            WhatGetsDeleted   = 'Precompiled DirectX GPU shader pipeline binaries (.bin, .toc) in %LOCALAPPDATA%\NVIDIA\DXCache.'
            SafetyExplanation = 'Safe: Machine-code shaders compiled by the NVIDIA graphics driver. Clearing corrupt shaders resolves graphics glitches and game crashes. Game saves, profiles, and graphics settings are untouched.'
            Consequences      = 'Games may experience a brief one-time loading delay or minor stutter upon first launch while the GPU driver recompiles shaders.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NvidiaGlCache'
            Group             = 'Gaming & GPU'
            Category          = 'NVIDIA OpenGL/Vulkan Cache (GLCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'NVIDIA\GLCache')
            Description       = 'Compiled OpenGL and Vulkan game shader cache from NVIDIA GPU'
            WhatGetsDeleted   = 'Precompiled OpenGL and Vulkan GPU shader binaries in %LOCALAPPDATA%\NVIDIA\GLCache.'
            SafetyExplanation = 'Safe: Compiled graphics shaders. Game saves, user profiles, and driver configurations are never touched.'
            Consequences      = 'Rebuilt automatically by the NVIDIA graphics driver during gameplay.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'DirectXShaderCache'
            Group             = 'Gaming & GPU'
            Category          = 'Windows DirectX Shader Cache (D3DSCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'D3DSCache')
            Description       = 'Global Windows DirectX shader cache shared across game titles'
            WhatGetsDeleted   = 'Global Windows Direct3D shader cache entries in %LOCALAPPDATA%\D3DSCache.'
            SafetyExplanation = 'Safe: Windows standard DirectX shader cache (equivalent to Windows Disk Cleanup cleanmgr.exe).'
            Consequences      = 'DirectX shaders will be recompiled dynamically by graphics drivers as 3D applications run.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'AmdDxCache'
            Group             = 'Gaming & GPU'
            Category          = 'AMD Radeon Shader Cache'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'AMD\DxCache')
            Description       = 'Compiled game shader cache for AMD Radeon graphics cards'
            WhatGetsDeleted   = 'Compiled DirectX graphics shaders for AMD Radeon GPUs in %LOCALAPPDATA%\AMD\DxCache.'
            SafetyExplanation = 'Safe: Machine-code shaders compiled by AMD Adrenalin. Game saves and driver settings are completely preserved.'
            Consequences      = 'Brief shader compilation upon first launch of 3D games.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'IntelShaderCache'
            Group             = 'Gaming & GPU'
            Category          = 'Intel Graphics Shader Cache'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'Intel\ShaderCache')
            Description       = 'Compiled game shader cache for Intel Arc and Iris graphics'
            WhatGetsDeleted   = 'Precompiled shader binaries for Intel Arc and integrated GPUs in %LOCALAPPDATA%\Intel\ShaderCache.'
            SafetyExplanation = 'Safe: Rebuilt dynamically by Intel graphics drivers. User settings and profiles are untouched.'
            Consequences      = 'Brief one-time shader recompilation on initial game launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SteamWebCache'
            Group             = 'Gaming & GPU'
            Category          = 'Steam Web & HTTP Cache'
            Icon              = '[STEAM]'
            Path              = (Join-Path $localAppData 'Steam\htmlcache')
            Description       = 'Cached store web assets, media thumbnails, and browser cache in Steam'
            WhatGetsDeleted   = 'Embedded Chromium browser cache (store thumbnails, community images, web CSS) in %LOCALAPPDATA%\Steam\htmlcache.'
            SafetyExplanation = 'Safe: Only store and community browser graphics. Game files (steamapps), save games, and user credentials (config/) are strictly protected and never touched.'
            Consequences      = 'Steam store and community pages will re-fetch images and stylesheet assets from Steam servers upon browsing.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EpicGamesCache'
            Group             = 'Gaming & GPU'
            Category          = 'Epic Games Launcher Cache'
            Icon              = '[EPIC]'
            Path              = (Join-Path $localAppData 'EpicGamesLauncher\Saved\webcache')
            Description       = 'Cached store assets and web interface data in Epic Games Launcher'
            WhatGetsDeleted   = 'Storefront web assets, promotion graphics, and thumbnail caches in %LOCALAPPDATA%\EpicGamesLauncher\Saved\webcache.'
            SafetyExplanation = 'Safe: Only web interface cache. Installed game files, cloud saves, and login authentication tokens are completely untouched.'
            Consequences      = 'Store banners and thumbnails will re-download from Epic Games CDN when the launcher is opened.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EaAppCache'
            Group             = 'Gaming & GPU'
            Category          = 'EA Desktop / Origin Cache'
            Icon              = '[EA]'
            Path              = (Join-Path $localAppData 'Electronic Arts\EA Desktop\Cache')
            Description       = 'Cached game store artwork and web data in EA Desktop'
            WhatGetsDeleted   = 'Storefront graphics, web views, and interface cache in %LOCALAPPDATA%\Electronic Arts\EA Desktop\Cache.'
            SafetyExplanation = 'Safe: Launcher interface assets only. Installed games and local game saves remain completely untouched.'
            Consequences      = 'EA Desktop will re-cache store images upon launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UbisoftCache'
            Group             = 'Gaming & GPU'
            Category          = 'Ubisoft Connect Cache'
            Icon              = '[UBI]'
            Path              = (Join-Path $localAppData 'Ubisoft Game Launcher\cache')
            Description       = 'Cached client assets and avatars in Ubisoft Connect Launcher'
            WhatGetsDeleted   = 'Launcher avatars, news banners, and web UI cache in %LOCALAPPDATA%\Ubisoft Game Launcher\cache.'
            SafetyExplanation = 'Safe: Only UI cache. Installed games, save files, and login tokens are safely stored in separate folders and untouched.'
            Consequences      = 'Launcher will re-download store and avatar graphics when browsed.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'BattlenetCache'
            Group             = 'Gaming & GPU'
            Category          = 'Battle.net / Blizzard Agent Cache'
            Icon              = '[BNET]'
            Path              = (Join-Path $progData 'Battle.net\Agent\data\cache')
            Description       = 'Battle.net Agent patcher and installer cached metadata'
            WhatGetsDeleted   = 'Blizzard Agent patcher and installer cached metadata in %PROGRAMDATA%\Battle.net\Agent\data\cache.'
            SafetyExplanation = 'Safe (Admin): Ephemeral Blizzard agent patcher data. Game installations, save data, and user logins are preserved.'
            Consequences      = 'Battle.net Agent re-checks patch status from Blizzard servers when games are launched or updated.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'RiotClientLogs'
            Group             = 'Gaming & GPU'
            Category          = 'Riot Games Client Logs'
            Icon              = '[RIOT]'
            Path              = (Join-Path $localAppData 'Riot Games\Riot Client\Logs')
            Description       = 'Historical log dumps from Riot Client (League of Legends, Valorant)'
            WhatGetsDeleted   = 'Historical session text logs and crash traces in %LOCALAPPDATA%\Riot Games\Riot Client\Logs.'
            SafetyExplanation = 'Safe: Diagnostic text logs only. Vanguard anti-cheat, game files, and credentials are untouched.'
            Consequences      = 'None. Fresh session logs will begin on the next match.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UnrealEngineDdc'
            Group             = 'Gaming & GPU'
            Category          = 'Unreal Engine Derived Data Cache (DDC)'
            Icon              = '[UE]'
            Path              = (Join-Path $localAppData 'UnrealEngine\Common\DerivedDataCache')
            Description       = 'Derived data cache for Unreal Engine 4 and 5 game compilations'
            WhatGetsDeleted   = 'Derived Data Cache (cooked textures, audio, and compiled shaders) in %LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache.'
            SafetyExplanation = 'Optional: Safe to delete to free large disk space; project files and source code are completely untouched. However, recompilation requires significant CPU time.'
            Consequences      = 'Unreal Engine projects will take longer to load on the first open while the engine recompiles shaders and recooks assets.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UnityCache'
            Group             = 'Gaming & GPU'
            Category          = 'Unity Editor & Asset Cache'
            Icon              = '[UNITY]'
            Path              = (Join-Path $localAppData 'Unity\cache')
            Description       = 'Downloaded package and asset store caches for Unity games'
            WhatGetsDeleted   = 'Downloaded Unity Asset Store packages and package manager tarballs in %LOCALAPPDATA%\Unity\cache.'
            SafetyExplanation = 'Optional: Safe duplicate archive of downloaded packages. Project source files are never touched.'
            Consequences      = 'Packages will re-download from the Unity Package Manager registry when opened in a project, requiring an active internet connection.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'PipCache'
            Group             = 'Developer Caches'
            Category          = 'Python Pip Wheel Cache'
            Icon              = '[PIP]'
            Path              = (Join-Path $localAppData 'pip\cache')
            Description       = 'Cached Python wheel binaries and download archives'
            WhatGetsDeleted   = 'Cached .whl binaries and source download tarballs in %LOCALAPPDATA%\pip\cache.'
            SafetyExplanation = 'Safe: Download copies of Python packages. Installed Python environments, virtual environments (venv), and scripts are NOT touched.'
            Consequences      = 'Subsequent pip install commands will fetch packages from PyPI instead of the local cache.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NpmCache'
            Group             = 'Developer Caches'
            Category          = 'Node.js NPM Cache'
            Icon              = '[NPM]'
            Path              = (Join-Path $appData 'npm-cache')
            Description       = 'Global Node Package Manager download cache'
            WhatGetsDeleted   = 'Global tarball archives cached by npm in %APPDATA%\npm-cache.'
            SafetyExplanation = 'Safe: Duplicate package download archives. Project node_modules, package.json, and global binaries are untouched.'
            Consequences      = 'Future npm install for previously cached packages will re-download tarballs from the npm registry.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'YarnCache'
            Group             = 'Developer Caches'
            Category          = 'Yarn Package Cache'
            Icon              = '[YARN]'
            Path              = (Join-Path $localAppData 'Yarn\Cache')
            Description       = 'Yarn package manager cached archives'
            WhatGetsDeleted   = 'Cached package archives in %LOCALAPPDATA%\Yarn\Cache.'
            SafetyExplanation = 'Safe: Duplicate package download archives. Project files, lockfiles, and application source code are untouched.'
            Consequences      = 'Packages will be re-downloaded from the registry if installed in new projects.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NugetCache'
            Group             = 'Developer Caches'
            Category          = 'NuGet / .NET Cache'
            Icon              = '[NUGET]'
            Path              = (Join-Path $userProfile '.nuget\packages')
            Description       = 'Local cache of downloaded NuGet packages'
            WhatGetsDeleted   = 'Global cache of unpacked NuGet packages in %USERPROFILE%\.nuget\packages.'
            SafetyExplanation = 'Optional: Safe to delete to free massive space. Project source code and solution files are untouched.'
            Consequences      = 'The next dotnet build or Visual Studio build will automatically run dotnet restore to re-download required packages from nuget.org.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'GradleCache'
            Group             = 'Developer Caches'
            Category          = 'Gradle Build Cache'
            Icon              = '[GRADLE]'
            Path              = (Join-Path $userProfile '.gradle\caches')
            Description       = 'Downloaded jar artifacts and distribution zip caches in Gradle'
            WhatGetsDeleted   = 'Downloaded dependency JARs, wrapper distributions, and build outputs in %USERPROFILE%\.gradle\caches.'
            SafetyExplanation = 'Optional: Often consumes 10-50 GB. Safe to purge; project source code is completely untouched.'
            Consequences      = 'The next ./gradlew build will re-download project dependencies and plugins from Maven Central/Google repository.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'CargoCache'
            Group             = 'Developer Caches'
            Category          = 'Rust Cargo Registry Cache'
            Icon              = '[CARGO]'
            Path              = (Join-Path $userProfile '.cargo\registry\cache')
            Description       = 'Cached Rust crate archive files'
            WhatGetsDeleted   = 'Cached .crate download archives in %USERPROFILE%\.cargo\registry\cache.'
            SafetyExplanation = 'Optional: Download archives. Cargo source checkouts and compiled binaries in target/ are untouched.'
            Consequences      = 'Cargo will re-download .crate files from crates.io on the next build.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'ChromeCache'
            Group             = 'Browser & App Caches'
            Category          = 'Google Chrome Web Cache'
            Icon              = '[CHROME]'
            Path              = (Join-Path $localAppData 'Google\Chrome\User Data\Default\Cache')
            Description       = 'Cached web pages, images, and script assets in Google Chrome'
            WhatGetsDeleted   = 'Cached website images, scripts, stylesheets, and video buffers in %LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. PASSWORDS, LOGINS, BROWSING HISTORY, BOOKMARKS, COOKIES, AND EXTENSIONS ARE STRICTLY PROTECTED AND NEVER TOUCHED.'
            Consequences      = 'Websites will re-download images and stylesheet assets on the first visit, which may slightly increase initial page load time.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EdgeCache'
            Group             = 'Browser & App Caches'
            Category          = 'Microsoft Edge Web Cache'
            Icon              = '[EDGE]'
            Path              = (Join-Path $localAppData 'Microsoft\Edge\User Data\Default\Cache')
            Description       = 'Cached media and webpage assets in Microsoft Edge'
            WhatGetsDeleted   = 'Cached media and webpage assets in %LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. Passwords, cookies, browsing history, bookmarks, and open tabs are strictly protected and never touched.'
            Consequences      = 'First page visits will re-fetch images and scripts from web servers.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'BraveCache'
            Group             = 'Browser & App Caches'
            Category          = 'Brave Browser Cache'
            Icon              = '[BRAVE]'
            Path              = (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
            Description       = 'Cached web data in Brave Browser'
            WhatGetsDeleted   = 'Web asset cache in %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. Crypto wallet keys, passwords, shields settings, and history are strictly protected and untouched.'
            Consequences      = 'Webpages re-cache static assets upon visit.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'DiscordCache'
            Group             = 'Browser & App Caches'
            Category          = 'Discord App Media Cache'
            Icon              = '[DISCORD]'
            Path              = (Join-Path $appData 'discord\Cache')
            Description       = 'Cached Discord media, avatars, and attachments'
            WhatGetsDeleted   = 'Cached Discord server avatars, emojis, stickers, and voice buffers in %APPDATA%\discord\Cache.'
            SafetyExplanation = 'Safe: Media buffer cache only. User logins, server lists, settings, and chats are in separate folders and untouched.'
            Consequences      = 'Server emojis and avatars re-download seamlessly in the background as you view channels.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SpotifyCache'
            Group             = 'Browser & App Caches'
            Category          = 'Spotify Track Storage'
            Icon              = '[SPOTIFY]'
            Path              = (Join-Path $localAppData 'Spotify\Storage')
            Description       = 'Locally cached music streams and playback buffers in Spotify'
            WhatGetsDeleted   = 'Streamed track chunks and offline song storage in %LOCALAPPDATA%\Spotify\Storage.'
            SafetyExplanation = 'Optional: Safe to delete to free gigabytes. Cloud playlists, user account, and library are untouched.'
            Consequences      = 'Any songs previously downloaded for offline listening will need to be re-downloaded over Wi-Fi.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'VsCodeCache'
            Group             = 'Browser & App Caches'
            Category          = 'VS Code Editor Cache'
            Icon              = '[VSCODE]'
            Path              = (Join-Path $appData 'Code\Cache')
            Description       = 'VS Code editor cached runtime files and buffers'
            WhatGetsDeleted   = 'V8 code cache and Electron web view buffers in %APPDATA%\Code\Cache.'
            SafetyExplanation = 'Safe: Internal editor buffer cache. Extensions, user settings (settings.json), keybindings, and workspaces are completely untouched.'
            Consequences      = 'Rebuilt automatically on next VS Code launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'AdobeMediaCache'
            Group             = 'Browser & App Caches'
            Category          = 'Adobe Premiere Media Cache'
            Icon              = '[ADOBE]'
            Path              = (Join-Path $appData 'Adobe\Common\Media Cache Files')
            Description       = 'Cached video peak files, conformed audio, and render frames in Adobe CC'
            WhatGetsDeleted   = 'Conformed audio (.cfa), peak files (.pek), and video index frames in %APPDATA%\Adobe\Common\Media Cache Files.'
            SafetyExplanation = 'Safe: Scratch files generated when media is imported into timelines. Master media files and project files (.prproj, .aep) are NEVER touched.'
            Consequences      = 'The next time an Adobe project is opened, Premiere or After Effects will regenerate peak and audio waveform files in the background.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'TelegramCache'
            Group             = 'Browser & App Caches'
            Category          = 'Telegram Desktop Media Cache'
            Icon              = '[TELEGRAM]'
            Path              = (Join-Path $appData 'Telegram Desktop\tdata\user_data\media_cache')
            Description       = 'Locally cached stickers, images, and voice notes in Telegram'
            WhatGetsDeleted   = 'Cached sticker packs, voice note buffers, and image thumbnails in %APPDATA%\Telegram Desktop\tdata\user_data\media_cache.'
            SafetyExplanation = 'Optional: Safe to delete. All media is safely retained in the Telegram cloud. Downloaded files in Downloads folder and account logins are untouched.'
            Consequences      = 'Stickers and photo previews will re-download from the Telegram cloud as you scroll through chats.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'RecycleBin'
            Group             = 'Recycle Bin'
            Category          = 'Windows Recycle Bin (C:)'
            Icon              = '[TRASH]'
            Path              = (Join-Path $sysDrive '$Recycle.Bin')
            Description       = 'Deleted files and folders residing in the Windows Recycle Bin'
            WhatGetsDeleted   = 'Files and folders previously discarded into the Recycle Bin on drive C:.'
            SafetyExplanation = 'Optional: Permanently purges everything you previously deleted on C:. Review the Recycle Bin first if you might want something back.'
            Consequences      = 'Purged items are permanently deleted and cannot be restored.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'RecycleBin'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        }
    )

    return $targets
}

function Scan-SmartCleanupItems {
    [CmdletBinding()]
    param(
        # Scan only these target ids (default: all targets)
        [string[]]$Id
    )

    $targets = Get-CleanableTargets
    if ($Id) { $targets = @($targets | Where-Object { $_.Id -in $Id }) }
    $results = @()
    $isAdminCurrent = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    foreach ($t in $targets) {
        $stats = Get-FolderSizeFast -Path $t.Path
        $rawBytes = $stats.RawBytes
        $fileCount = $stats.FileCount
        $pathExists = $stats.Exists

        $disp = Format-Bytes -Bytes $rawBytes
        $isSelected = ($t.Recommended -and $rawBytes -gt 0 -and (-not $t.RequiresAdmin -or $isAdminCurrent))
        $displayName = if ($t.RequiresAdmin -and -not $isAdminCurrent) { "$($t.Category) [Admin Required]" } else { $t.Category }

        $results += [PSCustomObject]@{
            Id                = $t.Id
            Group             = $t.Group
            CategoryName      = $t.Category
            Icon              = $t.Icon
            DisplayName       = $displayName
            Target            = $t.Path
            Type              = $t.Type
            SafetyLevel       = $t.SafetyLevel
            SafetyBadge       = $t.SafetyBadge
            WhatGetsDeleted   = $t.WhatGetsDeleted
            SafetyExplanation = $t.SafetyExplanation
            Consequences      = $t.Consequences
            RawBytes          = [long]$rawBytes
            DisplaySize       = $disp
            FileCount         = "$fileCount items"
            RawCount          = [int]$fileCount
            Description       = $t.Description
            Recommended       = [bool]$t.Recommended
            RequiresAdmin     = [bool]$t.RequiresAdmin
            IsSelected        = [bool]$isSelected
            PathExists        = [bool]$pathExists
        }
    }

    # Sort items by size descending: space-claiming items on top, 0-byte items at the end
    $sortedResults = @($results | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false })
    return $sortedResults
}

function Get-CleanableCategoryFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetId,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 200
    )

    $targets = Get-CleanableTargets
    $target = $targets | Where-Object { $_.Id -eq $TargetId } | Select-Object -First 1

    if (-not $target) {
        return @()
    }

    $fileList = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $target.Path) {
        try {
            $targetSafety = Test-PathSafety -Path $target.Path
            if (-not $targetSafety.Safe) {
                return @()
            }
            # A linked target points elsewhere: list nothing rather than files from another drive
            if ((Test-ReparsePoint -Path $target.Path).IsReparsePoint) {
                return @()
            }

            # Queue-based safe traversal: never follow or recurse through reparse points
            $queue = New-Object System.Collections.Generic.Queue[string]
            $queue.Enqueue($target.Path)
            $maxInspectItems = 5000
            $inspectedCount = 0

            while ($queue.Count -gt 0 -and $inspectedCount -lt $maxInspectItems) {
                $current = $queue.Dequeue()
                try {
                    $dirInfo = New-Object System.IO.DirectoryInfo($current)

                    # Enumerate direct files in current directory
                    foreach ($f in $dirInfo.EnumerateFiles()) {
                        try {
                            $fileSafety = Test-PathSafety -Path $f.FullName
                            if (-not $fileSafety.Safe) { continue }

                            $fileList.Add([PSCustomObject]@{
                                Name          = $f.Name
                                FullPath      = $f.FullName
                                RawBytes      = [long]$f.Length
                                DisplaySize   = Format-Bytes -Bytes $f.Length
                                LastWriteTime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                                Extension     = $f.Extension
                            })
                            $inspectedCount++
                        } catch {}
                    }

                    # Enumerate direct subdirectories; skip all reparse points
                    foreach ($sub in $dirInfo.EnumerateDirectories()) {
                        if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                        $queue.Enqueue($sub.FullName)
                    }
                } catch {}
            }
        } catch {}
    }

    return @($fileList | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } | Select-Object -First $Limit)
}

function Invoke-ExecuteCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$SelectedItems,

        [Parameter(Mandatory = $false)]
        [scriptblock]$OnProgress = $null
    )

    $totalFreedBytes = [long]0
    $totalDeletedCount = 0
    $logMessages = @()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    foreach ($item in $SelectedItems) {
        if (-not $item.IsSelected) { continue }

        # Check if item requires Administrator rights
        if ($item.RequiresAdmin -and -not $isAdmin) {
            $msg = "Skipped $($item.CategoryName): Task cannot be completed due to lack of Administrator privileges. Launch Diskman as Administrator (run.bat) to clean this item."
            $logMessages += $msg
            if ($null -ne $OnProgress) {
                & $OnProgress "Starting purge of $($item.CategoryName) ($($item.DisplaySize))..." "INFO"
                & $OnProgress "  [!] $msg" "WARN"
            }
            continue
        }

        if ($null -ne $OnProgress) {
            & $OnProgress "Starting purge of $($item.CategoryName) ($($item.DisplaySize))..." "INFO"
        }

        # -------------------------------------------------------------
        # State-Aware Windows Update & Servicing Safety Check
        # -------------------------------------------------------------
        if ($item.Id -in @('WinUpdateCache', 'DeliveryOpt')) {
            $servicingState = Test-WindowsServicingActive
            if ($servicingState.IsActive) {
                $skipMsg = "SKIPPED $($item.CategoryName): Windows servicing or update operation is currently active ($($servicingState.Reason)). Cleanup aborted to safeguard OS integrity."
                $logMessages += $skipMsg
                if ($null -ne $OnProgress) {
                    & $OnProgress "  [!] $skipMsg" "WARN"
                }
                continue
            }
        }

        if ($item.Type -eq 'RecycleBin') {
            $driveLetter = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', ':') } else { "C" }
            try {
                if ($null -ne $OnProgress) {
                    & $OnProgress "Clearing Windows Recycle Bin ($($driveLetter):)... (Purging $($item.FileCount) / $($item.DisplaySize), please wait)" "INFO"
                }

                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $ProgressPreference = 'SilentlyContinue'
                Clear-RecycleBin -DriveLetter $driveLetter -Force -ErrorAction Stop
                $timer.Stop()

                # Report what actually left the bin, not what the scan saw before
                $remaining = Get-FolderSizeFast -Path $item.Target
                $freed = [math]::Max([long]0, [long]$item.RawBytes - [long]$remaining.RawBytes)
                $totalFreedBytes += $freed
                $totalDeletedCount += [math]::Max(0, [int]$item.RawCount - [int]$remaining.FileCount)
                $durationSec = [math]::Round($timer.Elapsed.TotalSeconds, 1)
                $msg = "Emptied Recycle Bin ($($driveLetter):) (Freed $(Format-Bytes -Bytes $freed) in $($durationSec)s)"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "SUCCESS"
                }
            } catch {
                # Clear-RecycleBin can report a problem after emptying most of the bin: still report what really left it
                $remaining = Get-FolderSizeFast -Path $item.Target
                $freed = [math]::Max([long]0, [long]$item.RawBytes - [long]$remaining.RawBytes)
                $totalFreedBytes += $freed
                $msg = "Recycle Bin purge reported a problem: $_ (freed $(Format-Bytes -Bytes $freed))"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "WARN"
                }
            }
            continue
        }

        $targetPath = $item.Target
        if (Test-Path -LiteralPath $targetPath) {
            # Strict Safety Gate: Test-PathSafety is the final and absolute authority.
            # No hardcoded exceptions or bypasses allowed.
            $targetSafety = Test-PathSafety -Path $targetPath
            if (-not $targetSafety.Safe) {
                $msg = "BLOCKED: Target directory failed safety check: $($targetSafety.Reason)"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress "  [X] $msg" "ERROR"
                }
                continue
            }

            # A target that is itself a junction/symlink points elsewhere (e.g. a cache moved to D:): never delete through it
            if ((Test-ReparsePoint -Path $targetPath).IsReparsePoint) {
                $msg = "SKIPPED $($item.CategoryName): $targetPath is a link to another location, so Diskman will not clean through it."
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress "  [!] $msg" "WARN"
                }
                continue
            }

            $initialCategoryBytes = [long]$item.RawBytes
            $catFreedBytes = [long]0
            $catDeletedCount = 0
            $catSkippedCount = 0

            try {
                $itemsToClean = Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $totalInCat = ($itemsToClean | Measure-Object).Count

                foreach ($entry in $itemsToClean) {
                    # Rigorous safety validation on every single child item
                    $itemSafety = Test-PathSafety -Path $entry.FullName
                    if (-not $itemSafety.Safe) {
                        $catSkippedCount++
                        if ($null -ne $OnProgress) {
                            & $OnProgress "  [SAFETY GUARD] Skipped protected item: $($entry.Name) ($($itemSafety.Reason))" "WARN"
                        }
                        continue
                    }

                    $entryDeleted = $false

                    try {
                        if ($entry.PSIsContainer) {
                            # Detect Reparse Points / Junctions / Symbolic Links (Fail-Closed)
                            $reparseCheck = Test-ReparsePoint -Path $entry.FullName
                            if (-not $reparseCheck.Success) {
                                # Unknown reparse state = do not delete
                                $catSkippedCount++
                                if ($null -ne $OnProgress) {
                                    & $OnProgress "  [SAFETY GUARD] Skipped unverified reparse item: $($entry.Name) ($($reparseCheck.Reason))" "WARN"
                                }
                                continue
                            }

                            if ($reparseCheck.IsReparsePoint) {
                                # Delete only the link itself without recursive traversal
                                try {
                                    [System.IO.Directory]::Delete($entry.FullName, $false)
                                    $entryDeleted = $true
                                } catch {
                                    $entryDeleted = $false
                                }
                            } else {
                                try {
                                    $attr = [System.IO.File]::GetAttributes($entry.FullName)
                                    if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
                                        [System.IO.File]::SetAttributes($entry.FullName, [System.IO.FileAttributes]::Normal)
                                    }
                                } catch {}

                                try {
                                    [System.IO.Directory]::Delete($entry.FullName, $true)
                                    $entryDeleted = $true
                                } catch [System.UnauthorizedAccessException] {
                                    $entryDeleted = $false
                                } catch {
                                    try {
                                        Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
                                        $entryDeleted = $true
                                    } catch {
                                        $entryDeleted = $false
                                    }
                                }
                            }
                        } else {
                            try {
                                [System.IO.File]::SetAttributes($entry.FullName, [System.IO.FileAttributes]::Normal)
                            } catch {}

                            try {
                                [System.IO.File]::Delete($entry.FullName)
                                $entryDeleted = $true
                            } catch [System.UnauthorizedAccessException] {
                                $entryDeleted = $false
                            } catch {
                                try {
                                    Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
                                    $entryDeleted = $true
                                } catch {
                                    $entryDeleted = $false
                                }
                            }
                        }

                        if ($entryDeleted) {
                            $catDeletedCount++

                            if ($catDeletedCount % 5 -eq 0 -or $catDeletedCount -le 3 -or $catDeletedCount -eq $totalInCat) {
                                if ($null -ne $OnProgress) {
                                    & $OnProgress "  [$catDeletedCount / $totalInCat] Cleaned: $($entry.Name)" "INFO"
                                }
                            }
                        } else {
                            $catSkippedCount++
                        }
                    } catch {
                        $catSkippedCount++
                    }

                }

                # Freed = what the scan saw minus what is still there now (never an estimate)
                $remaining = Get-FolderSizeFast -Path $targetPath
                $catFreedBytes = [math]::Max([long]0, $initialCategoryBytes - [long]$remaining.RawBytes)

                $totalFreedBytes += $catFreedBytes
                $totalDeletedCount += $catDeletedCount

                $freedFormatted = Format-Bytes -Bytes $catFreedBytes
                $msg = "Purged $($item.CategoryName): Cleaned $catDeletedCount items (Freed $freedFormatted)"
                if ($catSkippedCount -gt 0) {
                    if (-not $isAdmin) {
                        $msg += " [$catSkippedCount locked/in-use items skipped (run as Administrator to clean system items)]"
                    } else {
                        $msg += " [$catSkippedCount locked/protected items skipped]"
                    }
                }

                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "SUCCESS"
                }
            } catch {
                $msg = "Notice on $($item.CategoryName): $_"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "WARN"
                }
            }
        }
    }

    return [PSCustomObject]@{
        TotalFreedBytes = $totalFreedBytes
        DisplayFreed    = Format-Bytes -Bytes $totalFreedBytes
        DeletedCount    = $totalDeletedCount
        Logs            = $logMessages
    }
}

function Invoke-ExecuteCategoryCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetId,

        [Parameter(Mandatory = $false)]
        [scriptblock]$OnProgress = $null
    )

    $item = Scan-SmartCleanupItems -Id $TargetId | Select-Object -First 1
    if (-not $item) {
        return [PSCustomObject]@{ TotalFreedBytes = [long]0; DisplayFreed = '0 B'; DeletedCount = 0; Logs = @('Target category not found.') }
    }

    $item.IsSelected = $true
    $res = Invoke-ExecuteCleanup -SelectedItems @($item) -OnProgress $OnProgress
    return $res
}


# --- Module: Start-FolderScan.ps1 ---
function Start-FolderScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        return @()
    }

    $results = @()
    $fso = New-Object -ComObject Scripting.FileSystemObject

    try {
        $folder = $fso.GetFolder($DirectoryPath)
        $parentSize = 0
        try {
            $parentSize = $folder.Size
        } catch {
            $parentSize = 0
        }

        # Process Subfolders
        foreach ($sub in $folder.SubFolders) {
            $name = $sub.Name
            $type = "DIR"
            $rawSize = 0
            $dispSize = "0 MB"
            $itemCount = 0
            $lastMod = ""

            try {
                $lastMod = $sub.DateLastModified.ToString("yyyy-MM-dd HH:mm")
            } catch {
                $lastMod = "-"
            }

            if ($name -match '^\$RECYCLE\.BIN$|^System Volume Information$') {
                $results += [PSCustomObject]@{
                    Name         = "[DIR] $name"
                    RawName      = $name
                    FullPath     = $sub.Path
                    Type         = $type
                    RawSize      = 0
                    DisplaySize  = "<Protected>"
                    Percent      = 0
                    PercentStr   = "-"
                    ItemCount    = "-"
                    LastModified = $lastMod
                    IsFolder     = $true
                }
                continue
            }

            try {
                $rawSize = $sub.Size
                $dispSize = Format-Bytes -Bytes $rawSize
                try {
                    $itemCount = $sub.Files.Count + $sub.SubFolders.Count
                } catch {
                    $itemCount = "-"
                }
            } catch {
                $dispSize = "<Access Denied>"
                $rawSize = 0
            }

            $pct = if ($parentSize -gt 0 -and $rawSize -gt 0) { [math]::Round(($rawSize / $parentSize) * 100, 1) } else { 0 }
            $pctStr = if ($pct -gt 0) { "$pct %" } else { "< 0.1%" }

            $results += [PSCustomObject]@{
                Name         = "[DIR] $name"
                RawName      = $name
                FullPath     = $sub.Path
                Type         = $type
                RawSize      = $rawSize
                DisplaySize  = $dispSize
                Percent      = $pct
                PercentStr   = $pctStr
                ItemCount    = $itemCount
                LastModified = $lastMod
                IsFolder     = $true
            }
        }

        # Process Direct Files
        foreach ($file in $folder.Files) {
            $name = $file.Name
            $type = "FILE"
            $rawSize = $file.Size
            $dispSize = Format-Bytes -Bytes $rawSize
            $lastMod = ""

            try {
                $lastMod = $file.DateLastModified.ToString("yyyy-MM-dd HH:mm")
            } catch {
                $lastMod = "-"
            }

            $pct = if ($parentSize -gt 0 -and $rawSize -gt 0) { [math]::Round(($rawSize / $parentSize) * 100, 1) } else { 0 }
            $pctStr = if ($pct -gt 0) { "$pct %" } else { "< 0.1%" }

            $results += [PSCustomObject]@{
                Name         = "[FILE] $name"
                RawName      = $name
                FullPath     = $file.Path
                Type         = $type
                RawSize      = $rawSize
                DisplaySize  = $dispSize
                Percent      = $pct
                PercentStr   = $pctStr
                ItemCount    = "1 file"
                LastModified = $lastMod
                IsFolder     = $false
            }
        }
    } catch {
        # Fallback to .NET DirectoryInfo
        try {
            $dirInfo = New-Object System.IO.DirectoryInfo($DirectoryPath)
            foreach ($sub in $dirInfo.GetDirectories()) {
                $results += [PSCustomObject]@{
                    Name         = "[DIR] $($sub.Name)"
                    RawName      = $sub.Name
                    FullPath     = $sub.FullName
                    Type         = "DIR"
                    RawSize      = 0
                    DisplaySize  = "Folder"
                    Percent      = 0
                    PercentStr   = "-"
                    ItemCount    = "-"
                    LastModified = $sub.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    IsFolder     = $true
                }
            }
            foreach ($f in $dirInfo.GetFiles()) {
                $results += [PSCustomObject]@{
                    Name         = "[FILE] $($f.Name)"
                    RawName      = $f.Name
                    FullPath     = $f.FullName
                    Type         = "FILE"
                    RawSize      = $f.Length
                    DisplaySize  = Format-Bytes -Bytes $f.Length
                    Percent      = 0
                    PercentStr   = "-"
                    ItemCount    = "1 file"
                    LastModified = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    IsFolder     = $false
                }
            }
        } catch {}
    }

    return ($results | Sort-Object RawSize -Descending)
}


$embeddedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diskman - C: Drive Trash &amp; Storage Cleaner" 
        Height="800" Width="1140" 
        MinHeight="700" MinWidth="950"
        WindowStartupLocation="CenterScreen"
        Background="#141416"
        Foreground="#EDEDED"
        FontFamily="Segoe UI"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        TextOptions.TextRenderingMode="ClearType"
        RenderOptions.ClearTypeHint="Enabled">

    <Window.Resources>
        <!-- Fluent Dark Color Palette -->
        <SolidColorBrush x:Key="WinDarkBg" Color="#141416"/>
        <SolidColorBrush x:Key="CardBg" Color="#1E1E22"/>
        <SolidColorBrush x:Key="CardHeaderBg" Color="#25252A"/>
        <SolidColorBrush x:Key="BorderDark" Color="#333338"/>
        <SolidColorBrush x:Key="BorderMedium" Color="#3F3F46"/>
        <SolidColorBrush x:Key="AccentCyan" Color="#00B4D8"/>
        <SolidColorBrush x:Key="AccentTeal" Color="#2EC4B6"/>
        <SolidColorBrush x:Key="AccentAmber" Color="#FFB703"/>
        <SolidColorBrush x:Key="AccentRed" Color="#E63946"/>
        <SolidColorBrush x:Key="ConsoleBg" Color="#0D0D0F"/>

        <!-- Keyboard focus ring (visible for Tab navigation, hidden for mouse clicks) -->
        <Style x:Key="FocusRing">
            <Setter Property="Control.Template">
                <Setter.Value>
                    <ControlTemplate>
                        <Rectangle Margin="-2" Stroke="#90E0EF" StrokeThickness="2" RadiusX="6" RadiusY="6" SnapsToDevicePixels="True"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Standard Button Style -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2A2A30"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="#383842"/>
                                <Setter TargetName="btnBorder" Property="BorderBrush" Value="#00B4D8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="#1C1C20"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="btnBorder" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary Action Button (Cyan) -->
        <Style x:Key="PrimaryActionBtn" TargetType="Button">
            <Setter Property="Background" Value="#0077B6"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#00B4D8"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#0096C7"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#90E0EF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#023E8A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Danger Button (Red) -->
        <Style x:Key="DangerActionBtn" TargetType="Button">
            <Setter Property="Background" Value="#9D0208"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#E63946"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#DC2F02"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF6B6B"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#6A040F"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- GroupBox Style -->
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#00B4D8"/>
            <Setter Property="BorderBrush" Value="#333338"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GroupBox">
                        <Grid SnapsToDevicePixels="True">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="#1C1C20" BorderBrush="#333338" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="12,6">
                                <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" SnapsToDevicePixels="True"/>
                            </Border>
                            <Border Grid.Row="1" Background="#16161A" BorderBrush="#333338" BorderThickness="1" CornerRadius="0,0,6,6" Padding="{TemplateBinding Padding}">
                                <ContentPresenter SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Flat Dark ProgressBar -->
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="#141416"/>
            <Setter Property="Foreground" Value="#00B4D8"/>
            <Setter Property="BorderBrush" Value="#333338"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" SnapsToDevicePixels="True">
                            <Grid x:Name="PART_Track">
                                <Rectangle x:Name="PART_Indicator" Fill="{TemplateBinding Foreground}" HorizontalAlignment="Left" RadiusX="3" RadiusY="3"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- TabItem Fluent Style -->
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#1C1C20"/>
            <Setter Property="Foreground" Value="#A1A1AA"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="18,9"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="#333338" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="{TemplateBinding Padding}" Margin="0,0,4,0" SnapsToDevicePixels="True">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#28282E"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#16161A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#00B4D8"/>
                                <Setter Property="Foreground" Value="#00B4D8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Clean DataGrid Cell Style (Removes blue / dotted selection artifacts) -->
        <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#0077B6"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- DataGrid Row Style -->
        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="#16161A"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#25252C"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#0077B6"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- DataGrid Style -->
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#16161A"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderBrush" Value="#333338"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="RowBackground" Value="#16161A"/>
            <Setter Property="AlternatingRowBackground" Value="#1C1C20"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#26262B"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="SelectionMode" Value="Single"/>
            <Setter Property="SelectionUnit" Value="FullRow"/>
            <Setter Property="RowHeight" Value="32"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <!-- DataGrid Column Header Style -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#202026"/>
            <Setter Property="Foreground" Value="#A1A1AA"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="BorderBrush" Value="#333338"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>

        <!-- ComboBox Dark Style (full template: the stock one ignores Background and renders white) -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="itemBorder" Background="Transparent" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="#2A2A30"/>
                            </Trigger>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="#0077B6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#202026"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="toggle" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="box" Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderThickness="1" CornerRadius="5">
                                            <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0"
                                                  Data="M0,0 L4,4 L8,0" Stroke="#A1A1AA" StrokeThickness="1.5"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="box" Property="BorderBrush" Value="#00B4D8"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                              Margin="10,3,28,3" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,2,0,0"
                                        Background="#202026" BorderBrush="#3F3F46" BorderThickness="1" CornerRadius="5">
                                    <ScrollViewer>
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="96"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Top Header & C: Drive Status Bar -->
        <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Brand Row -->
            <Grid Grid.Row="0" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Diskman" FontSize="20" FontWeight="Bold" Foreground="#00B4D8" VerticalAlignment="Center"/>
                    <TextBlock Text="  |  C: Drive Storage Cleaner &amp; Junk Purger" FontSize="13" Foreground="#A1A1AA" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnTopRefresh" Content="Refresh Stats" Margin="0,0,8,0"/>
                    <Button x:Name="BtnTopQuickScan" Content="Scan C: Drive Junk" Style="{StaticResource PrimaryActionBtn}"/>
                </StackPanel>
            </Grid>

            <!-- C: Drive Real-Time Metrics Strip -->
            <Border Grid.Row="1" Background="#1C1C20" BorderBrush="#333338" BorderThickness="1" CornerRadius="6" Padding="14,10">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="190"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Margin="0,0,10,0">
                        <TextBlock Text="C: Total Capacity" Foreground="#A1A1AA" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveTotal" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="#EDEDED" Margin="0,2,0,0"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="0,0,10,0">
                        <TextBlock Text="C: Used Storage" Foreground="#A1A1AA" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveUsed" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="#FFB703" Margin="0,2,0,0"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="0,0,10,0">
                        <TextBlock Text="C: Free Available" Foreground="#A1A1AA" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveFree" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="#2EC4B6" Margin="0,2,0,0"/>
                    </StackPanel>

                    <!-- Drive Meter Bar -->
                    <StackPanel Grid.Column="3" VerticalAlignment="Center" Margin="10,0,20,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="TxtCBarStatus" Grid.Column="0" Text="Drive C: Volume" FontSize="11" Foreground="#A1A1AA" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
                            <TextBlock x:Name="TxtCBarPercent" Grid.Column="1" Text="-- % used" FontSize="11" FontWeight="Bold" Foreground="#00B4D8"/>
                        </Grid>
                        <ProgressBar x:Name="ProgressCDrive" Height="10" Value="50" Maximum="100"/>
                    </StackPanel>

                    <StackPanel Grid.Column="4" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <TextBlock Text="Reclaimable Junk on C:" Foreground="#A1A1AA" FontSize="11" HorizontalAlignment="Right"/>
                        <TextBlock x:Name="TxtCReclaimable" Text="Scanning..." FontSize="16" FontWeight="Bold" Foreground="#00B4D8" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Main TabControl -->
        <TabControl x:Name="MainTabControl" Grid.Row="1" Background="#16161A" BorderBrush="#333338" BorderThickness="1">

            <!-- TAB 1: C: DRIVE JUNK CLEANER (PRIMARY VIEW) -->
            <TabItem Header="  C: Drive Junk Cleaner  ">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Presets & Actions Toolbar (two rows so it fits at the minimum window width) -->
                    <StackPanel Grid.Row="0" Margin="0,0,0,10">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <!-- Selection Presets -->
                            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                <Button x:Name="BtnSelectRecommended" Content="Select Recommended" Margin="0,0,6,0"/>
                                <Button x:Name="BtnSelectAll" Content="Select All" Margin="0,0,6,0"/>
                                <Button x:Name="BtnClearSelection" Content="Clear All" Margin="0,0,16,0"/>
                            </StackPanel>

                            <!-- Right Scan & Clean Buttons -->
                            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock x:Name="TxtCleanSelectedBadge" Text="Selected: 0 B (0 categories)" FontWeight="Bold" Foreground="#00B4D8" VerticalAlignment="Center" Margin="0,0,12,0" FontSize="13"/>
                                <Button x:Name="BtnScanCleanable" Content="Scan Junk" Margin="0,0,8,0"/>
                                <Button x:Name="BtnRunCleanup" Content="Clean Selected Junk" Style="{StaticResource DangerActionBtn}"/>
                            </StackPanel>
                        </Grid>

                        <!-- Filter Chips (the active chip is highlighted from app.ps1) -->
                        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                            <TextBlock Text="Filter:" Foreground="#A1A1AA" VerticalAlignment="Center" Margin="0,0,6,0" FontSize="11"/>
                            <Button x:Name="BtnFilterAll" Content="All" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterSystem" Content="System" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterGaming" Content="Gaming &amp; GPU" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterDev" Content="Developer" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterBrowser" Content="Apps &amp; Web" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                        </StackPanel>
                    </StackPanel>

                    <!-- Junk Categories DataGrid -->
                    <DataGrid x:Name="GridCleanableCategories" Grid.Row="1" AutoGenerateColumns="False"
                              CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False"
                              VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.ScrollUnit="Pixel">
                        <DataGrid.Columns>
                            <!-- Template column: one click toggles the box (the stock checkbox column needs a select click first) -->
                            <DataGridTemplateColumn Header="Clean?" Width="55">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="Category" Binding="{Binding DisplayName}" Width="270" FontWeight="SemiBold"/>
                            <DataGridTextColumn Header="Group" Binding="{Binding Group}" Width="140"/>
                            <DataGridTextColumn Header="Size on C:" Binding="{Binding DisplaySize}" SortMemberPath="RawBytes" SortDirection="Descending" Width="105" FontWeight="Bold" Foreground="#00B4D8"/>
                            <DataGridTextColumn Header="Items" Binding="{Binding FileCount}" SortMemberPath="RawCount" Width="95"/>
                            <DataGridTextColumn Header="Safety" Binding="{Binding SafetyLevel}" Width="100"/>
                            <DataGridTextColumn Header="Path on C: Drive" Binding="{Binding Target}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Category Safety & Deletion Details Card (Fixed Height = Zero Layout Shift) -->
                    <Border Grid.Row="2" Height="116" Background="#1B1B1F" BorderBrush="#333338" BorderThickness="1" CornerRadius="6" Margin="0,10,0,0" Padding="12,10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <!-- Header Row: Category Title + Safety Badge Pill + Action Buttons -->
                            <Grid Grid.Row="0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <TextBlock x:Name="TxtSelectedCategoryTitle" Text="Category Details &amp; Safety Profile" FontWeight="Bold" FontSize="13" Foreground="#EDEDED" VerticalAlignment="Center"/>
                                    <Border x:Name="BadgeSafetyLevel" Background="#2EC4B6" CornerRadius="3" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center" MinWidth="68">
                                        <TextBlock x:Name="TxtSelectedCategorySafetyBadge" Text="SAFE" FontSize="10" FontWeight="Bold" Foreground="#141416" TextAlignment="Center" HorizontalAlignment="Center"/>
                                    </Border>
                                    <TextBlock x:Name="TxtSelectedCategorySizeInfo" Text="" Foreground="#A1A1AA" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button x:Name="BtnOpenCategoryInExplorer" Content="Open in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,6,0"/>
                                    <Button x:Name="BtnInspectCategoryFiles" Content="View Files in Inspector" Margin="0,0,6,0"/>
                                    <Button x:Name="BtnCleanSingleCategory" Content="Clean Category" Style="{StaticResource DangerActionBtn}"/>
                                </StackPanel>
                            </Grid>

                            <!-- Divider -->
                            <Rectangle Grid.Row="1" Height="1" Fill="#27272A" Margin="0,8,0,8"/>

                            <!-- 3-Column Explanations Grid: What Gets Deleted | Why It's Safe & Protected | Consequences & Rebuild -->
                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Column 1: What Gets Deleted -->
                                <Border Grid.Column="0" Background="#141416" BorderBrush="#27272A" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,0,6,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="TARGET FILES &amp; DATA" FontSize="10" FontWeight="Bold" Foreground="#00B4D8" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategoryWhatDeleted" Text="Select a category above to view specific target file types and paths." FontSize="11" Foreground="#D4D4D8" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>

                                <!-- Column 2: Why It's Safe & Protected Data -->
                                <Border Grid.Column="1" Background="#141416" BorderBrush="#27272A" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="3,0,3,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="SAFETY &amp; PROTECTED DATA" FontSize="10" FontWeight="Bold" Foreground="#2EC4B6" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategorySafetyExp" Text="Personal documents, passwords, credentials, and settings are never touched." FontSize="11" Foreground="#D4D4D8" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>

                                <!-- Column 3: Post-Deletion Consequences -->
                                <Border Grid.Column="2" Background="#141416" BorderBrush="#27272A" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="6,0,0,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="POST-CLEANUP IMPACT" FontSize="10" FontWeight="Bold" Foreground="#FFB703" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategoryConsequences" Text="Explains whether files auto-regenerate or require network reload." FontSize="11" Foreground="#D4D4D8" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>
                            </Grid>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- TAB 2: DETAILED FILE INSPECTOR (C: JUNK FILES) -->
            <TabItem Header="  File Inspector (C: Junk Files)  ">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Selector Bar -->
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="280"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock Grid.Column="0" Text="Junk Category: " Foreground="#A1A1AA" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <ComboBox x:Name="CmbInspectTarget" Grid.Column="1" Height="28" Margin="0,0,8,0"/>
                        <Button x:Name="BtnRefreshInspectFiles" Grid.Column="2" Content="Load Files" Margin="0,0,12,0"/>
                        <TextBlock x:Name="TxtInspectSummary" Grid.Column="3" Text="Select a category and click Load Files to inspect individual files." Foreground="#2EC4B6" VerticalAlignment="Center" HorizontalAlignment="Right" FontWeight="SemiBold"/>
                    </Grid>

                    <!-- File Items Table -->
                    <DataGrid x:Name="GridInspectFiles" Grid.Row="1" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="250"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawBytes" SortDirection="Descending" Width="100" FontWeight="SemiBold" Foreground="#00B4D8"/>
                            <DataGridTextColumn Header="Full Path on C: Drive" Binding="{Binding FullPath}" Width="*"/>
                            <DataGridTextColumn Header="Last Modified" Binding="{Binding LastWriteTime}" Width="140"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Action Bar -->
                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock x:Name="TxtSelectedInspectFileInfo" Grid.Column="0" Text="Select a file to inspect or delete." Foreground="#A1A1AA" FontSize="11" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRevealInspectFileInExplorer" Grid.Column="1" Content="Reveal in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnDeleteSingleInspectFile" Grid.Column="2" Content="Delete File" Margin="0,0,8,0"/>
                        <Button x:Name="BtnPurgeAllInspectFiles" Grid.Column="3" Content="Clear All Files in Target" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- TAB 3: C: LARGE JUNK & INSTALLERS HUNTER -->
            <TabItem Header="  C: Large Files Hunter  ">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Filter Controls -->
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
                            <TextBlock Text="Min Size: " Foreground="#A1A1AA" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterSize" Width="100" Height="28" Margin="6,0,0,0"/>
                        </StackPanel>

                        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
                            <TextBlock Text="Category: " Foreground="#A1A1AA" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterCategory" Width="150" Height="28" Margin="6,0,0,0"/>
                        </StackPanel>

                        <Button x:Name="BtnStartHunterScan" Grid.Column="3" Content="Scan Large C: Files" Style="{StaticResource PrimaryActionBtn}"/>
                    </Grid>

                    <!-- Table -->
                    <DataGrid x:Name="GridLargeFiles" Grid.Row="1" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="240"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawSize" SortDirection="Descending" Width="100" FontWeight="Bold" Foreground="#00B4D8"/>
                            <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="140"/>
                            <DataGridTextColumn Header="Full Path on C: Drive" Binding="{Binding FullPath}" Width="*"/>
                            <DataGridTextColumn Header="Modified" Binding="{Binding LastWriteTime}" Width="130"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Action buttons -->
                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock x:Name="TxtSelectedFileInfo" Grid.Column="0" Text="Select a large file to perform action." Foreground="#A1A1AA" FontSize="11" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRevealInExplorer" Grid.Column="1" Content="Reveal in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnSendToTrash" Grid.Column="2" Content="Send to Recycle Bin" Margin="0,0,8,0"/>
                        <Button x:Name="BtnPermanentDelete" Grid.Column="3" Content="Permanent Delete" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- TAB 4: C: DRIVE DIRECTORY TREE EXPLORER -->
            <TabItem Header="  C: Directory Explorer  ">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Button x:Name="BtnFolderUp" Grid.Column="0" Content="Up Folder" Margin="0,0,8,0"/>
                        <TextBox x:Name="TxtCurrentPath" Grid.Column="1" Height="28" Background="#16161A" Foreground="#00B4D8" BorderBrush="#333338" Padding="8,4" IsReadOnly="True" VerticalContentAlignment="Center"/>
                        <Button x:Name="BtnScanCurrentDir" Grid.Column="2" Content="Scan Folder" Style="{StaticResource PrimaryActionBtn}" Margin="8,0,8,0"/>
                        <Button x:Name="BtnOpenCurrentInExplorer" Grid.Column="3" Content="Open in Explorer"/>
                    </Grid>

                    <DataGrid x:Name="GridDirectories" Grid.Row="1" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Folder / File Name" Binding="{Binding Name}" Width="280"/>
                            <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="60"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawSize" SortDirection="Descending" Width="100" FontWeight="SemiBold" Foreground="#00B4D8"/>
                            <DataGridTextColumn Header="% Parent" Binding="{Binding PercentStr}" Width="90"/>
                            <DataGridTextColumn Header="Items" Binding="{Binding ItemCount}" Width="85"/>
                            <DataGridTextColumn Header="Last Modified" Binding="{Binding LastModified}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Bottom Console / Output Terminal -->
        <GroupBox Grid.Row="2" Header="Activity &amp; Execution Log" Margin="0,10,0,0">
            <TextBox x:Name="TxtConsoleLog" Background="{StaticResource ConsoleBg}" Foreground="#2EC4B6" FontFamily="Consolas, monospace" FontSize="11" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </GroupBox>

        <!-- Status Bar -->
        <Grid Grid.Row="3" Margin="4,6,4,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock x:Name="TxtGlobalStatus" Grid.Column="0" Text="Ready | Diskman - C: Drive Trash &amp; Storage Cleaner" FontSize="11" Foreground="#71717A"/>
            <TextBlock Grid.Column="1" Text="Windows Storage Optimization Engine" FontSize="11" Foreground="#2EC4B6"/>
        </Grid>
    </Grid>
</Window>

'@

[xml]$xaml = $embeddedXaml
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
