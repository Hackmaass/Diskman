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

        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
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
        [string]$Path
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

        foreach ($uFolder in $blockedUserFolders) {
            if (Test-IsSubpathOrEqual -Candidate $normalized -Parent $uFolder) {
                return @{ Safe = $false; Reason = "Path is a protected user personal data directory ($uFolder)." }
            }
        }

        # Passed all multi-layer safety barriers
        return @{ Safe = $true; Reason = "OK" }
    } catch {
        # Fail Closed on any unexpected error
        return @{ Safe = $false; Reason = "Safety evaluation exception: $($_.Exception.Message)" }
    }
}
