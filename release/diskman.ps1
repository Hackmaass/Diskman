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


# --- Module: Find-AppCaches.ps1 ---
# Finds regenerable cache folders of the apps installed for this user (every browser profile, Electron apps, VS Code family).
# Detection is by folder STRUCTURE, never by name alone: a bare "Cache" folder can be anything, but a folder that holds
# Cache_Data\index is a Chromium HTTP cache. Anything not matching a signature stays out of the list (Review in the explorer).

# Folders the detector must never offer, whatever their name
function Test-AppCacheExcluded {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$FixedTargetPaths = @())

    $p = $Path.TrimEnd('\')
    if ($p -match '\\Claude-Data(\\|$)') { return $true }                      # the Claude desktop app's own data
    if ($p -match '\\AppData\\Local\\Packages(\\|$)') { return $true }          # Store apps: not offered in this version
    if ($p -match '\\AppData\\Local\\Microsoft\\(Windows|WindowsApps)(\\|$)') { return $true }
    foreach ($fixed in $FixedTargetPaths) {
        if ($fixed -and (Test-IsSubpathOrEqual -Candidate $p -Parent $fixed)) { return $true }   # already a fixed target: never count twice
    }
    return $false
}

# Returns @{ Safety = 'Safe'|'Optional'; Kind = <text> } when the folder matches a known cache layout, else $null
function Get-AppCacheKind {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $leaf = Split-Path -Path $Path -Leaf
    $parent = Split-Path -Path $Path -Parent
    $has = { param($rel) Test-Path -LiteralPath (Join-Path $Path $rel) }

    switch -Regex ($leaf) {
        '^Cache$' {
            if ((& $has 'Cache_Data\index') -or ((& $has 'index') -and (& $has 'data_0'))) { return @{ Safety = 'Safe'; Kind = 'web cache' } }
            return $null
        }
        '^(GPUCache|GrShaderCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache)$' {
            if ((& $has 'index') -or (& $has 'data_0')) { return @{ Safety = 'Safe'; Kind = 'GPU/shader cache' } }
            return $null
        }
        '^Code Cache$' {
            if ((& $has 'js') -or (& $has 'wasm')) { return @{ Safety = 'Safe'; Kind = 'compiled script cache' } }
            return $null
        }
        '^CacheStorage$' {
            # Progressive web apps keep offline data here, so this one is Optional
            if ((Split-Path -Path $parent -Leaf) -eq 'Service Worker' -and (Test-Path -LiteralPath (Join-Path $parent 'Database'))) { return @{ Safety = 'Optional'; Kind = 'service worker cache' } }
            return $null
        }
        '^(component_crx_cache|extensions_crx_cache)$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'Local State')) { return @{ Safety = 'Optional'; Kind = 'extension download cache' } }
            return $null
        }
        '^Crashpad$' {
            if ((& $has 'reports') -or (& $has 'metadata')) { return @{ Safety = 'Safe'; Kind = 'crash report database' } }
            return $null
        }
        '^(CachedData|CachedProfilesData|logs)$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'User\settings.json')) { return @{ Safety = 'Safe'; Kind = 'editor cache/logs' } }
            return $null
        }
        '^CachedExtensionVSIXs$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'User\settings.json')) { return @{ Safety = 'Optional'; Kind = 'downloaded extension packages' } }
            return $null
        }
    }
    return $null
}

# One group (= one Cleaner row) per app: the first one or two folders below AppData\Local or AppData\Roaming
function Get-AppCacheGroupKey {
    [CmdletBinding()]
    param([string]$Path, [string]$LocalRoot, [string]$RoamingRoot)

    foreach ($root in $LocalRoot, $RoamingRoot) {
        if ($root -and $Path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $parts = $Path.Substring($root.Length + 1).Split('\')
            $takeTwo = $parts.Count -gt 2 -and $parts[0] -in @('Google', 'BraveSoftware', 'Microsoft', 'Mozilla', 'Programs', 'Opera Software', 'Vivaldi')
            return $(if ($takeTwo) { "$($parts[0])\$($parts[1])" } else { $parts[0] })
        }
    }
    return $null
}

function Find-AppCaches {
    [CmdletBinding()]
    # AppDataPath is a seam for tests: it replaces the user's AppData\Local and \Roaming as the place to search
    param([Parameter(Mandatory = $true)] $Root, [long]$MinBytes = 5MB, [string]$AppDataPath = $null)

    $profilePath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $searchRoot = "$profilePath\AppData"
    if ($AppDataPath) { $searchRoot = $AppDataPath.TrimEnd('\'); $local = $searchRoot; $roaming = $searchRoot }
    $appData = Find-TreeNode -Root $Root -Path $searchRoot
    if ($null -eq $appData) { return @() }

    $fixed = @(Get-CleanableTargets | ForEach-Object { $_.Path })
    $accepted = New-Object System.Collections.Generic.List[object]

    $visit = {
        param($node)
        foreach ($child in $node.Children) {
            if ($child.Bytes -lt $MinBytes) { continue }
            # Whole areas that are never offered: do not even walk into them
            if ($child.Path -match '\\Claude-Data$|\\AppData\\Local\\Packages$') { continue }
            $kind = Get-AppCacheKind -Path $child.Path
            if ($kind) {
                if (-not (Test-AppCacheExcluded -Path $child.Path -FixedTargetPaths $fixed)) {
                    $key = Get-AppCacheGroupKey -Path $child.Path -LocalRoot $local -RoamingRoot $roaming
                    if ($key) { $accepted.Add([PSCustomObject]@{ Node = $child; Kind = $kind.Kind; Safety = $kind.Safety; Key = $key }) }
                }
                continue            # the outermost match wins: never descend into a cache
            }
            & $visit $child
        }
    }
    & $visit $appData

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($accepted | Group-Object -Property Key)) {
        $nodes = @($group.Group)
        $bytes = [long](($nodes | ForEach-Object { $_.Node.Bytes } | Measure-Object -Sum).Sum)
        $files = [int](($nodes | ForEach-Object { $_.Node.Files } | Measure-Object -Sum).Sum)
        $level = if (@($nodes | Where-Object { $_.Safety -eq 'Optional' }).Count -gt 0) { 'Optional' } else { 'Safe' }
        $name = (Get-Culture).TextInfo.ToTitleCase((Split-Path -Path $group.Name -Leaf))
        $paths = @($nodes | ForEach-Object { $_.Node.Path })
        $kinds = (($nodes | ForEach-Object { $_.Kind } | Sort-Object -Unique) -join ', ')
        $isSelected = ($level -eq 'Safe' -and $bytes -gt 0)
        $items.Add([PSCustomObject]@{
            Id = "App:$($group.Name.ToLowerInvariant())"; Group = 'Browser & App Caches'; CategoryName = "$name caches (detected)"
            Icon = '[APP]'; DisplayName = "$name caches (detected)"; Target = $paths[0]; Targets = $paths; Type = 'DirectoryContents'
            SafetyLevel = $level; SafetyBadge = $level.ToUpper()
            WhatGetsDeleted = "Cache folders detected inside the $name app data ($kinds): " + (($paths | ForEach-Object { "$(Split-Path -Path (Split-Path -Path $_ -Parent) -Leaf)\$(Split-Path -Path $_ -Leaf)" }) -join '; ')
            SafetyExplanation = "$level`: Folders recognised by their contents as caches the app rebuilds itself. Logins, bookmarks, history, settings and documents are not in these folders. Close the app first; files in use are skipped."
            Consequences = $(if ($level -eq 'Optional') { 'The app may start a little slower once while it rebuilds. Offline data held by web apps (service worker caches) or downloaded extension packages is fetched again when needed.' } else { 'The app may start a little slower once while caches are rebuilt.' })
            RawBytes = $bytes; DisplaySize = (Format-Bytes -Bytes $bytes); FileCount = "$files items"; RawCount = $files
            Description = "Detected cache folders of $name ($kinds)"
            Recommended = ($level -eq 'Safe'); RequiresAdmin = $false; IsSelected = [bool]$isSelected; PathExists = $true
            CanSelect = $true; SelectTip = 'Include in Clean Selected'; Dynamic = $true
        })
    }
    return @($items | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true })
}

# Re-measure detected items after a clean (they are not in the fixed target list, so a normal rescan cannot do it)
function Update-DetectedItemSize {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Item)

    $bytes = [long]0; $files = 0
    foreach ($t in @($Item.Targets)) {
        $m = Get-FolderSizeFast -Path $t
        $bytes += [long]$m.RawBytes; $files += [int]$m.FileCount
    }
    $Item.RawBytes = $bytes; $Item.RawCount = $files; $Item.DisplaySize = Format-Bytes -Bytes $bytes; $Item.FileCount = "$files items"
    $Item.IsSelected = $false
    return $Item
}


# --- Module: Find-LargeFiles.ps1 ---
function Find-LargeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$TargetPath = $(if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') + '\' } else { 'C:\' }),

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
        $sysDriveRoot = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') + '\' } else { 'C:\' }
        $cDrive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $sysDriveRoot -and $_.IsReady } | Select-Object -First 1
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


# --- Module: Get-SpaceRules.ps1 ---
# What each big folder is and what to do about it. Rules match scanned folders by exact path only.
# Evidence rule: only paths verified on a real machine may be 'Clean'; everything else is Review/Uninstall/Command/System.

function Get-AllowedCommands {
    [CmdletBinding()]
    param()
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    # The UI never builds a command from scanned data: only these exact commands can run.
    return @{
        DockerPrune = @{
            Short = 'Prune Docker data'
            Exe = 'docker.exe'; Args = @('system', 'prune', '-f'); RequiresAdmin = $false
            Title = 'Prune unused Docker data'
            Consent = "This runs 'docker system prune -f'. Docker Desktop must be running. It removes stopped containers, unused networks and dangling images. Volumes are kept.`n`nIt frees space INSIDE Docker's virtual disk. The disk file on C: only shrinks after it is compacted (stop Docker Desktop, then use Compact). This cannot be undone."
        }
        CompactDisk = @{
            Short = 'Compact virtual disk'
            Exe = 'diskpart.exe'; Args = @('/s', '<generated script file>'); RequiresAdmin = $true
            Title = 'Compact a Docker or WSL virtual disk'
            Consent = "This shuts WSL down and runs diskpart to compact the virtual disk: select vdisk, attach it read-only, compact vdisk, detach.`n`nDocker Desktop must be quit first (Diskman refuses while it is running). Containers and images are not deleted; the disk file only gives back space that was already freed inside it, so run 'docker system prune' first to free more. It can take several minutes."
        }
        ComponentCleanup = @{
            Short = 'Component cleanup'
            Exe = 'Dism.exe'; Args = @('/Online', '/Cleanup-Image', '/StartComponentCleanup'); RequiresAdmin = $true
            Title = 'Clean up the Windows component store'
            Consent = "This runs 'Dism /Online /Cleanup-Image /StartComponentCleanup'. It removes superseded versions of Windows components from WinSxS.`n`nIt can take several minutes. Afterwards, already installed updates can no longer be uninstalled."
        }
        HibernateOff = @{
            Short = 'Turn hibernation off'
            Exe = 'powercfg.exe'; Args = @('/h', 'off'); RequiresAdmin = $true
            Title = 'Turn hibernation off'
            Consent = "This runs 'powercfg /h off'. It deletes hiberfil.sys and turns Hibernate OFF.`n`nIt also disables Fast Startup. You can turn it back on with 'powercfg /h on'."
        }
        ShadowDelete = @{
            Short = 'Delete oldest restore point'
            Exe = 'vssadmin.exe'; Args = @('delete', 'shadows', "/for=$sysDrive", '/oldest', '/quiet'); RequiresAdmin = $true
            Title = 'Delete the oldest shadow copy'
            Consent = "This runs 'vssadmin delete shadows /for=$sysDrive /oldest'. It deletes the OLDEST shadow copy, which removes a System Restore point and the file history stored in it.`n`nThis cannot be undone."
        }
    }
}

function Invoke-AllowedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DockerPrune', 'ComponentCleanup', 'HibernateOff', 'ShadowDelete', 'CompactDisk')]
        [string]$Id,

        [scriptblock]$OnLine = $null,

        # Only used by CompactDisk, and only accepted when it matches a registered Docker/WSL disk exactly
        [string]$Path = $null
    )

    if ($Id -eq 'CompactDisk') { return Invoke-VhdCompact -Path $Path -OnLine $OnLine }
    $cmd = (Get-AllowedCommands)[$Id]
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $say = { param($t) if ($null -ne $OnLine) { & $OnLine $t } }

    if ($cmd.RequiresAdmin -and -not $isAdmin) {
        & $say "Skipped: '$($cmd.Title)' needs Administrator rights. Use Restart as Administrator."
        return -1
    }
    if ($env:DISKMAN_DRY_RUN -eq '1') {
        # Test and demo switch: validation above still ran, but nothing is executed
        & $say "Dry run: would run $($cmd.Exe) $($cmd.Args -join ' ')"
        return 0
    }
    try {
        & $say "Running: $($cmd.Exe) $($cmd.Args -join ' ')"
        & $cmd.Exe @($cmd.Args) 2>&1 | ForEach-Object { & $say "$_" }
        return $LASTEXITCODE
    } catch {
        & $say "Could not run $($cmd.Exe): $($_.Exception.Message)"
        return -1
    }
}

function Get-SpaceRules {
    [CmdletBinding()]
    param()

    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $windows = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$drive\Windows" }
    $pf      = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$drive\Program Files" }
    $pd      = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$drive\ProgramData" }

    $rules = New-Object System.Collections.Generic.List[hashtable]
    $add = {
        param($path, $title, $what, $verdict, $safety, $extra)
        $r = @{ Path = $path; Title = $title; What = $what; Verdict = $verdict; Safety = $safety; TargetId = $null; CommandId = $null; Param = $null; Effect = $null; Uri = $null; RequiresAdmin = $false }
        if ($extra) { foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] } }
        $rules.Add($r)
    }

    # Every cleanup target is also a rule, so the Cleaner tab and the explorer never disagree
    foreach ($t in (Get-CleanableTargets)) {
        & $add $t.Path $t.Category $t.Description 'Clean' $t.SafetyLevel @{ TargetId = $t.Id; RequiresAdmin = [bool]$t.RequiresAdmin }
    }

    # Cache folders detected by structure (Find-AppCaches): each folder gets its own row of advice, cleaning is per app group
    foreach ($item in @($script:DetectedCacheItems)) {
        foreach ($t in @($item.Targets)) {
            & $add $t $item.CategoryName $item.Description 'Clean' $item.SafetyLevel @{ TargetId = $item.Id }
        }
    }

    # Virtual disks of Docker and WSL that can be compacted (found by registration, never by searching for *.vhdx)
    foreach ($disk in (Get-CompactableDisks)) {
        & $add (Split-Path -Path $disk.Path -Parent) "$($disk.Name) virtual disk" "A virtual disk file ($(Format-Bytes -Bytes $disk.Bytes)) that grows but never shrinks by itself. Compacting returns what was deleted inside it to C:." 'Command' 'Advanced' @{ CommandId = 'CompactDisk'; Param = $disk.Path; RequiresAdmin = $true; Effect = 'gives back only what Docker/WSL already freed inside the disk. Stop Docker Desktop first.' }
    }

    & $add "$local\Docker" 'Docker Desktop data' "Docker images, containers and volumes live in one virtual disk (docker_data.vhdx). Pruning frees space inside it; the file on C: only shrinks after compaction." 'Command' 'Advanced' @{ CommandId = 'DockerPrune'; Effect = 'frees space inside Docker, not on C:. C: only shrinks after the disk file is compacted.' }
    & $add "$local\Programs\DockerDesktop" 'Docker Desktop application' 'The Docker Desktop program files. Uninstall it from Settings if you no longer use Docker.' 'Uninstall' 'Review' @{ Effect = 'frees roughly the folder size once uninstalled.' }
    & $add "$pf\NVIDIA Corporation\RTX Remix" 'NVIDIA RTX Remix' 'An installed NVIDIA modding application. Uninstall it from Settings if you do not use it.' 'Uninstall' 'Review' $null
    & $add "$pd\NVIDIA Corporation\NVIDIA App\UpdateFramework" 'NVIDIA App update staging' 'Downloaded NVIDIA App update files. Not verified as safe to delete, so review it first.' 'Review' 'Review' $null
    & $add "$pd\NVIDIA\NGX\models" 'NVIDIA NGX models (DLSS)' 'AI models used by DLSS. The NVIDIA driver fetches them as needed, but this is not verified, so review it first.' 'Review' 'Review' $null
    & $add "$pd\NVIDIA\Streamline" 'NVIDIA Streamline' 'Shared NVIDIA graphics runtime files used by games.' 'Review' 'Review' $null
    & $add "$local\Claude-Data" 'Claude app data' 'Data of the Claude desktop app. Diskman never offers this for deletion.' 'Review' 'Review' $null
    & $add "$local\Arduino15\packages\esp32" 'Arduino ESP32 board package' 'ESP32 toolchains installed by the Arduino IDE. Remove them in Boards Manager if you no longer build for ESP32.' 'Review' 'Review' $null
    # Python installs from python.org / the Python install manager (any version)
    foreach ($d in (Get-ChildItem -Path "$local\Python" -Directory -Filter 'pythoncore-*' -ErrorAction SilentlyContinue)) {
        & $add $d.FullName "Python installation ($($d.Name))" 'A Python install. Most of its size is usually installed packages (for example torch). Remove packages you no longer need with pip uninstall.' 'Review' 'Review' $null
    }
    & $add "$roaming\Apple Computer\MobileSync\Backup" 'iPhone / iPad backups (iTunes)' 'Full device backups made by iTunes. Often 10-100 GB. Delete old ones from iTunes (Edit > Preferences > Devices), not by hand, and only if you no longer need to restore from them.' 'Review' 'Review' $null
    foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ } | Select-Object -Unique)) {
        & $add $od 'OneDrive folder' 'Files synced from OneDrive. To free space without losing them, right-click the folder in Explorer and choose Free up space (files stay online). Do not delete them: that deletes them from the cloud too.' 'Review' 'Review' $null
    }
    & $add "$pf\Microsoft Office" 'Microsoft Office' 'The installed Office applications. Uninstall from Settings only if you no longer use them.' 'Uninstall' 'Review' $null
    & $add "$local\hermes" 'hermes application data' 'Application data and runtimes of the hermes app. Review before removing.' 'Review' 'Review' $null
    & $add "$roaming\npm\node_modules" 'Global npm packages' 'Globally installed npm tools. They can be reinstalled with npm, but you may rely on them.' 'Review' 'Review' $null
    & $add "$windows\WinSxS" 'Windows component store (WinSxS)' 'Windows keeps component versions here, shared with System32 by hard links, so its real size is smaller than the number shown. Never delete it by hand; component cleanup is the safe way.' 'Command' 'Advanced' @{ CommandId = 'ComponentCleanup'; RequiresAdmin = $true; Effect = 'usually frees much less than the folder size shown, because most of it is shared with System32.' }
    & $add "$windows\System32" 'Windows system files' 'Core Windows files. Not reclaimable.' 'System' 'Review' $null
    & $add "$windows\Installer" 'Windows Installer cache' 'Needed to repair or uninstall programs. Deleting files here breaks them.' 'System' 'Review' $null
    & $add "$drive\hiberfil.sys" 'Hibernation file' 'Holds memory for hibernation and Fast Startup. Turning hibernation off deletes it.' 'Command' 'Advanced' @{ CommandId = 'HibernateOff'; RequiresAdmin = $true }
    & $add "$drive\Windows.old" 'Previous Windows installation' 'Left behind by a Windows upgrade. Remove it from Settings > Storage > Temporary files.' 'Uninstall' 'Review' @{ Uri = 'ms-settings:storagesense' }

    # Store Python keeps pip packages inside a package folder whose name carries a publisher suffix
    foreach ($d in (Get-ChildItem -Path "$local\Packages" -Directory -Filter 'PythonSoftwareFoundation.Python.*' -ErrorAction SilentlyContinue)) {
        & $add "$($d.FullName)\LocalCache\local-packages" 'Python packages (Microsoft Store Python)' 'Packages installed with pip for the Store version of Python. Review which projects need them.' 'Review' 'Review' $null
    }

    return $rules
}

$script:SpaceRuleIndex = $null
$script:DetectedCacheItems = @()

# Detected cache items become rules too; rebuilding the index makes the Overview and Explorer show advice for them
function Set-DetectedCacheItems {
    [CmdletBinding()]
    param($Items)
    $script:DetectedCacheItems = @($Items)
    $script:SpaceRuleIndex = $null
}

function Find-SpaceRule {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($null -eq $script:SpaceRuleIndex) {
        $script:SpaceRuleIndex = @{}
        foreach ($r in (Get-SpaceRules)) {
            try { $script:SpaceRuleIndex[[System.IO.Path]::GetFullPath($r.Path).TrimEnd('\').ToLowerInvariant()] = $r } catch {}
        }
    }
    $key = $Path.TrimEnd('\').ToLowerInvariant()
    return $script:SpaceRuleIndex[$key]
}

# Advice for folders no exact rule knows, from where the folder sits. Deliberately limited to Uninstall / Review / System:
# it can explain and point to Settings, but it can never offer Clean or Command, so a wrong guess cannot delete anything.
$script:AdviceContext = $null
function Get-GenericAdvice {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:?$') { return $null }   # a drive root has no leaf or parent to reason about
    $leaf = Split-Path -Path $p -Leaf
    $parent = (Split-Path -Path $p -Parent)
    if (-not $parent) { return $null }
    $parent = $parent.TrimEnd('\')

    # Known-folder lookups are slow and identical for every call, so they are read once per process
    if (-not $script:AdviceContext) {
        $profileDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
        $driveName = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
        $ownFolders = @()
        foreach ($f in 'Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic') {
            $kf = [System.Environment]::GetFolderPath($f); if ($kf) { $ownFolders += $kf.TrimEnd('\') }
        }
        $ownFolders += "$profileDir\Downloads"
        $script:AdviceContext = @{
            Profile = $profileDir
            Local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
            Roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
            Windows = $(if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$driveName\Windows" })
            Pf      = $(if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$driveName\Program Files" })
            Pf86    = $(if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\') } else { "$driveName\Program Files (x86)" })
            Pd      = $(if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$driveName\ProgramData" })
            Own     = $ownFolders
        }
    }
    $ctx = $script:AdviceContext
    $profilePath = $ctx.Profile; $local = $ctx.Local; $roaming = $ctx.Roaming; $windows = $ctx.Windows
    $pf = $ctx.Pf; $pf86 = $ctx.Pf86; $pd = $ctx.Pd

    $make = {
        param($verdict, $title, $what, $uri)
        @{ Path = $Path; Title = $title; What = $what; Verdict = $verdict; Safety = 'Review'; TargetId = $null; CommandId = $null; Param = $null; Effect = $null; Uri = $uri; RequiresAdmin = $false; Generic = $true }
    }
    $same = { param($a, $b) $a -ieq $b }

    # Installed programs. Windows components and hardware drivers are on a keep-list: never suggest uninstalling those.
    if ((& $same $parent $pf) -or (& $same $parent $pf86) -or (& $same $parent "$local\Programs")) {
        if ($leaf -match '^(Windows|Microsoft|Common Files|WindowsApps|ModifiableWindowsApps|Internet Explorer|Reference Assemblies|MSBuild|dotnet|WindowsPowerShell|PowerShell|Uninstall Information|NVIDIA|Intel|AMD|Advanced Micro Devices|Realtek|Qualcomm|Synaptics|Dolby|Waves|MediaTek)') {
            return & $make 'System' "$leaf (Windows or driver software)" 'Part of Windows or software that runs your hardware (drivers, graphics, audio). Keep it.' $null
        }
        return & $make 'Uninstall' "Installed program: $leaf" "A program installed on this PC. If you no longer use it, uninstall it from Settings > Apps. Do not delete the folder by hand: that leaves a broken entry behind." 'ms-settings:appsfeatures'
    }

    # Game libraries
    if ($p -match '\\steamapps\\common\\[^\\]+$') {
        return & $make 'Review' "Steam game: $leaf" 'A Steam game. Uninstall it from Steam (Library, right-click the game, Manage, Uninstall) so Steam stays consistent. Games are often the biggest items on a drive.' $null
    }
    if ($p -match '\\Epic Games\\[^\\]+$' -and $parent -match 'Epic Games$') {
        return & $make 'Review' "Epic Games game: $leaf" 'An Epic Games Store game. Uninstall it from the Epic Games Launcher library.' $null
    }
    if ($p -match '\\XboxGames\\[^\\]+$') {
        return & $make 'Uninstall' "Xbox / Store game: $leaf" 'A game installed through the Xbox app or Microsoft Store. Uninstall it from Settings > Apps.' 'ms-settings:appsfeatures'
    }

    # The user's own files (known folder locations, which can be renamed or redirected)
    foreach ($o in $ctx.Own) {
        if ((& $same $p $o) -or $p.StartsWith($o + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return & $make 'Review' "Your files: $leaf" 'Your own files. Diskman never deletes these in bulk. Use the Large Files tab to find the biggest ones, or move what you rarely open to another drive or cloud storage.' $null
        }
    }

    # Microsoft Store app data
    if ((& $same $parent "$local\Packages")) {
        return & $make 'Review' "Store app data: $leaf" 'Data of a Microsoft Store app. If you do not use the app, uninstall it from Settings > Apps; you can also reset it there (Advanced options) to clear its data.' 'ms-settings:appsfeatures'
    }

    # Tool folders in the user profile (.cargo, .gradle, .docker ...)
    if ((& $same $parent $profilePath) -and $leaf.StartsWith('.')) {
        return & $make 'Review' "Tool data: $leaf" 'Settings, caches and downloads of a developer or command-line tool. Some of it can be rebuilt, but it can also hold logins and project data, so check before removing anything.' $null
    }

    # Per-app data under AppData and ProgramData
    if ((& $same $parent $local) -or (& $same $parent $roaming)) {
        return & $make 'Review' "App data: $leaf" "Data of the app '$leaf'. It may hold caches, but also your settings and local files. Diskman only offers to clean folders it recognises; open this one to decide." $null
    }
    if ((& $same $parent $pd)) {
        return & $make 'Review' "Shared app data: $leaf" "Data shared by '$leaf' for all users on this PC (updates, caches, licences). Review before removing; uninstalling the program is usually the safe way to remove it." $null
    }

    if ($p.StartsWith($windows + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return & $make 'System' "Windows: $leaf" 'Part of Windows. Not reclaimable by hand.' $null
    }
    return $null
}


# --- Module: Get-SystemSpace.ps1 ---
# Space Windows manages itself, shown with plain-English notes so the numbers are not a mystery.

# Finds a folder in a scanned tree by walking path components (folders under 1 MB are not in the tree).
function Find-TreeNode {
    [CmdletBinding()]
    param($Root, [string]$Path)

    if ($null -eq $Root -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $node = $Root
    $rest = $Path.Substring([math]::Min($Path.Length, $Root.Path.TrimEnd('\').Length)).Trim('\')
    if ($rest -eq '') { return $node }
    foreach ($part in $rest.Split('\')) {
        $node = $node.Children | Where-Object { $_.Name -ieq $part } | Select-Object -First 1
        if ($null -eq $node) { return $null }
    }
    return $node
}

function Get-SystemSpace {
    [CmdletBinding()]
    param($Root = $null, [bool]$Elevated = $false)

    $drive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $rows = New-Object System.Collections.Generic.List[object]
    $row = { param($n, $b, $note, $admin, $cmd, $uri = $null) $rows.Add([PSCustomObject]@{ Name = $n; Bytes = $b; Note = $note; NeedsAdmin = $admin; CommandId = $cmd; Uri = $uri }) }

    # Locked system files are visible to DirectoryInfo even without administrator rights
    $rootDir = New-Object System.IO.DirectoryInfo "$drive\"
    $fileSize = { param($name) $f = $rootDir.EnumerateFiles($name) | Select-Object -First 1; if ($f) { [long]$f.Length } else { $null } }

    $swap = & $fileSize 'swapfile.sys'
    & $row 'swapfile.sys' $swap 'Used by Windows for modern apps. Windows manages it; small.' $false $null

    $pageNote = 'No paging file found.'
    try {
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)
        if ($pf.Count -gt 0) {
            $where = ($pf | ForEach-Object { "$($_.Name) ($([math]::Round($_.AllocatedBaseSize / 1024, 1)) GB)" }) -join ', '
            $onC = @($pf | Where-Object { $_.Name -like "$drive*" }).Count -gt 0
            $pageNote = if ($onC) { "Paging file on $drive`: $where. Windows manages it." } else { "Paging file is not on $drive`: $where. It does not use space on $drive." }
        }
    } catch {}
    $page = & $fileSize 'pagefile.sys'
    & $row 'Paging file' $page $pageNote $false $null

    $hiber = & $fileSize 'hiberfil.sys'
    if ($null -ne $hiber) {
        & $row 'Hibernation file (hiberfil.sys)' $hiber 'Used by Hibernate and Fast Startup. Turning hibernation off frees it.' $true 'HibernateOff'
    } else {
        & $row 'Hibernation file (hiberfil.sys)' 0 'Hibernation is off. Nothing to free here.' $false $null
    }

    if ($Elevated) {
        # Win32_ShadowStorage is language-independent (vssadmin text is not). It needs an elevated session; if it fails the size stays "not measured".
        $shadow = $null
        try {
            $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction Stop
            $used = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID } | ForEach-Object { [long]$_.UsedSpace })
            if ($used.Count -gt 0) { $shadow = [long]($used | Measure-Object -Sum).Sum }
        } catch {}
        & $row 'Shadow copies (restore points)' $shadow 'Restore points and file history snapshots. Deleting the oldest frees space but removes a restore point.' $false $(if ($shadow) { 'ShadowDelete' } else { $null })
    } else {
        & $row 'Shadow copies (restore points)' $null 'Needs administrator to measure. Often the biggest hidden item.' $true $null
    }

    $winsxs = Find-TreeNode -Root $Root -Path "$($env:SystemRoot)\WinSxS"
    & $row 'Windows component store (WinSxS)' $(if ($winsxs) { [long]$winsxs.Bytes } else { $null }) 'Shared with System32 by hard links, so the real size is smaller. Use component cleanup, never delete by hand.' $true 'ComponentCleanup'

    # A crash dump left by a Windows blue screen: very common, often several GB. Settings removes it safely.
    try {
        $dump = (New-Object System.IO.DirectoryInfo $env:SystemRoot).EnumerateFiles('MEMORY.DMP') | Select-Object -First 1
        if ($dump) { & $row 'System crash dump (MEMORY.DMP)' ([long]$dump.Length) "Left by a Windows crash; only useful for debugging it. Remove it in Settings > Storage > Temporary files (System error memory dump files)." $false $null 'ms-settings:storagesense' }
    } catch {}

    foreach ($name in 'Windows.old', '$Windows.~BT', '$WinREAgent') {
        $n = Find-TreeNode -Root $Root -Path "$drive\$name"
        if ($n) { & $row $name ([long]$n.Bytes) 'Left behind by a Windows upgrade or update. Remove it from Settings > Storage > Temporary files.' $false $null 'ms-settings:storagesense' }
    }
    return $rows.ToArray()
}


# --- Module: Invoke-DiskCompact.ps1 ---
# Docker Desktop and WSL keep their data in virtual disks (.vhdx) that grow but never shrink on their own.
# Compacting returns what was deleted INSIDE the disk to C:. Disks are found only through how they are registered
# (Docker's fixed paths and each WSL distro's BasePath), never by searching for *.vhdx: other apps keep VM disks too.

function Get-CompactableDisks {
    [CmdletBinding()]
    param()

    $local = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $found = New-Object System.Collections.Generic.List[object]
    $add = {
        param($name, $path, $kind)
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $found.Add([PSCustomObject]@{ Name = $name; Path = [System.IO.Path]::GetFullPath($path); Bytes = [long](Get-Item -LiteralPath $path -Force).Length; Kind = $kind })
        }
    }

    & $add 'Docker Desktop data' "$local\Docker\wsl\disk\docker_data.vhdx" 'Docker'
    & $add 'Docker Desktop (main)' "$local\Docker\wsl\main\ext4.vhdx" 'Docker'
    & $add 'Docker Desktop (data)' "$local\Docker\wsl\data\ext4.vhdx" 'Docker'

    try {
        foreach ($key in (Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop)) {
            $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($p.BasePath -and $p.DistributionName -and $p.DistributionName -notlike 'docker-desktop*') {
                $base = ([string]$p.BasePath) -replace '^\\\\\?\\', ''
                & $add "WSL: $($p.DistributionName)" (Join-Path $base 'ext4.vhdx') 'WSL'
            }
        }
    } catch {}

    # The same file can be reached twice (Docker's own distro is also registered): keep one entry per path
    return @($found | Group-Object -Property { $_.Path.ToLowerInvariant() } | ForEach-Object { $_.Group[0] })
}

# Docker Desktop's engine pipe exists only while the engine runs (instant check, no process start)
function Test-DockerEngineRunning {
    [CmdletBinding()]
    param()
    return ((Test-Path -LiteralPath '\\.\pipe\dockerDesktopLinuxEngine') -or (Test-Path -LiteralPath '\\.\pipe\docker_engine'))
}

# The exact text handed to diskpart: nothing but the validated path is variable
function New-DiskpartCompactScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return "select vdisk file=`"$Path`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit`r`n"
}

# Best effort after every attempt: a failed compact must not leave the disk attached (Docker and WSL could not start)
function New-DiskpartDetachScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return "select vdisk file=`"$Path`"`r`ndetach vdisk noerr`r`nexit`r`n"
}

function Invoke-VhdCompact {
    [CmdletBinding()]
    param([string]$Path, [scriptblock]$OnLine = $null)

    $say = { param($t) if ($null -ne $OnLine) { & $OnLine $t } }

    $disk = @(Get-CompactableDisks | Where-Object { $_.Path -ieq $Path }) | Select-Object -First 1
    if (-not $disk) {
        & $say "Refused: '$Path' is not a registered Docker or WSL disk, so Diskman will not compact it."
        return -1
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        & $say "Skipped: compacting a virtual disk needs Administrator rights. Use Restart as Administrator."
        return -1
    }
    if ($env:DISKMAN_DRY_RUN -eq '1') {
        & $say "Dry run: would shut WSL down and compact '$($disk.Path)' with diskpart."
        return 0
    }
    if (Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue) {
        & $say "Skipped: Docker Desktop is still running. Quit Docker Desktop from its tray icon first, then try again."
        return -1
    }

    & $say "Shutting down WSL so the disk is not in use..."
    & wsl.exe --shutdown 2>&1 | ForEach-Object { & $say "$_" }
    Start-Sleep -Seconds 3

    try {
        $probe = [System.IO.File]::Open($disk.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
    } catch {
        & $say "Skipped: the disk is still in use by another program ($($_.Exception.Message)). Close anything using WSL or Docker and try again."
        return -1
    }

    $before = [long](Get-Item -LiteralPath $disk.Path -Force).Length
    $tmpDir = [System.IO.Path]::GetTempPath()
    $scriptFile = Join-Path $tmpDir ("diskman_compact_" + [guid]::NewGuid().ToString('N') + ".txt")
    $detachFile = Join-Path $tmpDir ("diskman_detach_" + [guid]::NewGuid().ToString('N') + ".txt")
    $failed = $false
    try {
        [System.IO.File]::WriteAllText($scriptFile, (New-DiskpartCompactScript -Path $disk.Path), [System.Text.Encoding]::ASCII)
        & $say "Compacting $($disk.Name) ($(Format-Bytes -Bytes $before)). This can take several minutes..."
        $output = @(& diskpart.exe /s $scriptFile 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
        foreach ($line in $output) { if ($line.Trim()) { & $say $line } }
        # The exit code decides (diskpart's messages are translated, so their text cannot be relied on)
        $failed = ($exit -ne 0)
    } finally {
        try {
            [System.IO.File]::WriteAllText($detachFile, (New-DiskpartDetachScript -Path $disk.Path), [System.Text.Encoding]::ASCII)
            & diskpart.exe /s $detachFile 2>&1 | Out-Null
        } catch {}
        Remove-Item -LiteralPath $scriptFile, $detachFile -Force -ErrorAction SilentlyContinue
    }
    if ($failed) {
        & $say "Compaction failed. The disk was detached again, so Docker and WSL can start normally. Details are in the lines above."
        return -1
    }
    $after = [long](Get-Item -LiteralPath $disk.Path -Force).Length
    & $say "Disk file went from $(Format-Bytes -Bytes $before) to $(Format-Bytes -Bytes $after) (freed $(Format-Bytes -Bytes ([math]::Max([long]0, $before - $after))))."
    return 0
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
            SafetyExplanation = 'Safe: Temporary scratch space used by running programs. Files actively locked by open processes are automatically skipped, and anything changed in the last 24 hours is kept (an installer or app may still be using it). User documents, personal files, and program installations are never stored here.'
            Consequences      = 'None. Running applications will automatically create fresh temporary files during future sessions as needed.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            MinAgeHours       = 24
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
            SafetyExplanation = 'Safe (Admin): Temporary files discarded by completed Windows updates and service installations. Active Windows kernel/service files are locked and skipped, and anything changed in the last 24 hours is kept.'
            Consequences      = 'None. System services and installers generate new temporary files when required.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            MinAgeHours       = 24
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
            Path              = (Join-Path $localAppData 'npm-cache\_cacache')
            Description       = 'Global Node Package Manager download cache'
            WhatGetsDeleted   = 'Global tarball archives cached by npm in %LOCALAPPDATA%\npm-cache\_cacache.'
            SafetyExplanation = 'Safe: Duplicate package download archives. Project node_modules, package.json, and global binaries are untouched.'
            Consequences      = 'Future npm install for previously cached packages will re-download tarballs from the npm registry.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NpmNpxCache'
            Group             = 'Developer Caches'
            Category          = 'npx Package Cache'
            Icon              = '[NPX]'
            Path              = (Join-Path $localAppData 'npm-cache\_npx')
            Description       = 'Packages that npx downloaded to run (often MCP servers and CLI tools)'
            WhatGetsDeleted   = 'Packages npx installed to run commands, in %LOCALAPPDATA%\npm-cache\_npx.'
            SafetyExplanation = 'Optional: npx re-downloads what it needs. But tools started through npx (for example MCP servers) run their code from this folder, so close them first or they can fail until restarted.'
            Consequences      = 'The next npx command downloads its package again. A tool that is running right now may crash if its files disappear.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'ElectronCache'
            Group             = 'Developer Caches'
            Category          = 'Electron Download Cache'
            Icon              = '[ELECTRON]'
            Path              = (Join-Path $localAppData 'electron\Cache')
            Description       = 'Electron runtime downloads cached by npm tools that build desktop apps'
            WhatGetsDeleted   = 'Cached Electron binaries and checksums in %LOCALAPPDATA%\electron\Cache.'
            SafetyExplanation = 'Optional: Download copies. Installed apps and project files are not touched.'
            Consequences      = 'The next build that needs Electron downloads it again (about 100-130 MB per version).'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
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
            MinAgeHours       = [int]$t.MinAgeHours
            CanSelect         = [bool](-not $t.RequiresAdmin -or $isAdminCurrent)
            SelectTip         = if ($t.RequiresAdmin -and -not $isAdminCurrent) { 'Needs administrator. Use Restart as Administrator.' } else { 'Include in Clean Selected' }
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

        $targetPaths = if ($item.Targets) { @($item.Targets) } else { @($item.Target) }
        $multi = $targetPaths.Count -gt 1
        foreach ($targetPath in $targetPaths) {
            $label = if ($multi) { "$($item.CategoryName) ($(Split-Path -Path $targetPath -Leaf))" } else { $item.CategoryName }
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
                    $msg = "SKIPPED ${label}: $targetPath is a link to another location, so Diskman will not clean through it."
                    $logMessages += $msg
                    if ($null -ne $OnProgress) {
                        & $OnProgress "  [!] $msg" "WARN"
                    }
                    continue
                }

                # One target keeps the scan's size; several (a detected app's cache folders) are measured per folder
                $initialCategoryBytes = if ($multi) { [long](Get-FolderSizeFast -Path $targetPath).RawBytes } else { [long]$item.RawBytes }
                $catFreedBytes = [long]0
                $catDeletedCount = 0
                $catSkippedCount = 0
                $recentKept = 0
                $ageFloor = if ($item.MinAgeHours) { (Get-Date).AddHours(-[int]$item.MinAgeHours) } else { $null }

                try {
                    $itemsToClean = Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                    $totalInCat = ($itemsToClean | Measure-Object).Count

                    foreach ($entry in $itemsToClean) {
                        # Recently changed entries may still be in use by an installer or app: keep them (Disk Cleanup does the same)
                        if ($ageFloor -and $entry.LastWriteTime -gt $ageFloor) { $recentKept++; continue }

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
                    $msg = "Purged ${label}: Cleaned $catDeletedCount items (Freed $freedFormatted)"
                    if ($catSkippedCount -gt 0) {
                        if (-not $isAdmin) {
                            $msg += " [$catSkippedCount locked/in-use items skipped (run as Administrator to clean system items)]"
                        } else {
                            $msg += " [$catSkippedCount locked/protected items skipped]"
                        }
                    }

                    if ($recentKept -gt 0) { $msg += " [$recentKept items changed in the last $($item.MinAgeHours) h were kept]" }
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


# --- Module: Scan-DriveTree.ps1 ---
# One-pass directory size tree for the Overview and Space Explorer, plus the accounting that makes every byte of "used" visible.
# Compiled C# because a PowerShell loop over a million files is minutes slower. Loaded once per process.
if (-not ('Diskman.TreeScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace Diskman {
    // Invariant: Bytes == OwnBytes + sum(Children.Bytes). Folders under 1 MB are folded into the parent's OwnBytes.
    public sealed class Node {
        public string Path, Name;
        public long Bytes, OwnBytes, Files, ModifiedTicks;
        public bool Shared;
        public List<Node> Children = new List<Node>();
    }
    public static class TreeScan {
        public static volatile bool Cancel;
        public static int Parallelism = 8;   // lowered for spinning disks, where parallel seeks slow the scan down
        public static long ScannedFiles, ScannedBytes, Errors;
        public static volatile string Current = "";
        public static ConcurrentDictionary<string, long> Partial = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        const long MinChild = 1048576;
        const int PlaceholderAttrs = 0x1000 | 0x40000 | 0x400000; // Offline, RecallOnOpen, RecallOnDataAccess: cloud files that use no disk

        public static void Reset() { Cancel = false; ScannedFiles = 0; ScannedBytes = 0; Errors = 0; Current = ""; Partial.Clear(); }
        public static Node Scan(string root) { return Walk(new DirectoryInfo(root), 0); }

        static Node Walk(DirectoryInfo dir, int depth) {
            var node = new Node { Path = dir.FullName, Name = dir.Name };
            var subs = new List<DirectoryInfo>();
            try {
                foreach (var e in dir.EnumerateFileSystemInfos()) {
                    if (Cancel) break;
                    var d = e as DirectoryInfo;
                    if (d != null) {
                        if ((d.Attributes & FileAttributes.ReparsePoint) == 0) subs.Add(d);
                    } else {
                        try {
                            if (((int)e.Attributes & PlaceholderAttrs) != 0) continue;
                            long len = ((FileInfo)e).Length;
                            node.OwnBytes += len; node.Files++;
                            long t = e.LastWriteTimeUtc.Ticks; if (t > node.ModifiedTicks) node.ModifiedTicks = t;
                            Interlocked.Increment(ref ScannedFiles); Interlocked.Add(ref ScannedBytes, len);
                        } catch { Interlocked.Increment(ref Errors); }
                    }
                }
            } catch { Interlocked.Increment(ref Errors); }

            if (depth == 1) Current = dir.Name;
            var kids = new Node[subs.Count];
            if (depth <= 2 && subs.Count > 1) {
                Parallel.For(0, subs.Count, new ParallelOptions { MaxDegreeOfParallelism = Parallelism }, i => {
                    kids[i] = Walk(subs[i], depth + 1);
                    if (depth == 0) Partial[subs[i].FullName] = kids[i].Bytes;
                });
            } else {
                for (int i = 0; i < subs.Count && !Cancel; i++) {
                    kids[i] = Walk(subs[i], depth + 1);
                    if (depth == 0) Partial[subs[i].FullName] = kids[i].Bytes;
                }
            }
            foreach (var k in kids) {
                if (k == null) continue;
                node.Files += k.Files;
                if (k.ModifiedTicks > node.ModifiedTicks) node.ModifiedTicks = k.ModifiedTicks;
                if (k.Bytes >= MinChild) node.Children.Add(k); else node.OwnBytes += k.Bytes;
            }
            node.Children.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
            long total = node.OwnBytes; foreach (var c in node.Children) total += c.Bytes;
            node.Bytes = total;
            // WinSxS is hard-linked with System32 and friends: its file-size sum overstates real use
            node.Shared = node.Path.EndsWith("\\Windows\\WinSxS", StringComparison.OrdinalIgnoreCase);
            return node;
        }
    }
}
'@
}

# Spinning disks lose time to parallel seeks; SSD/NVMe benefit from many threads. Unknown stays in the middle.
function Get-ScanParallelism {
    [CmdletBinding()]
    param([string]$Root)
    try {
        $letter = ([System.IO.Path]::GetPathRoot($Root)).Substring(0, 1)
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $physical = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        switch ([string]$physical.MediaType) { 'HDD' { return 2 } 'SSD' { return 8 } 'SCM' { return 8 } default { return 4 } }
    } catch { return 4 }
}

function Scan-DriveTree {
    [CmdletBinding()]
    param([string]$Root = "$($env:SystemDrive)\")
    [Diskman.TreeScan]::Reset()
    [Diskman.TreeScan]::Parallelism = Get-ScanParallelism -Root $Root
    return [Diskman.TreeScan]::Scan($Root)
}

# Turns a scanned tree into rows that add up to exactly $UsedBytes: measured folders plus one labelled remainder.
function Get-SpaceAccounting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Root,
        [Parameter(Mandatory = $true)] [long]$UsedBytes,
        [bool]$Elevated = $false
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($child in $Root.Children) {
        $rows.Add([PSCustomObject]@{ Name = $child.Name; Path = $child.Path; Bytes = [long]$child.Bytes; Kind = 'Folder'; Node = $child })
    }
    if ($Root.OwnBytes -gt 0) {
        $rows.Add([PSCustomObject]@{ Name = "(files and small folders in $($Root.Path))"; Path = $Root.Path; Bytes = [long]$Root.OwnBytes; Kind = 'Folder'; Node = $null })
    }

    $remainder = $UsedBytes - [long]$Root.Bytes
    if ($remainder -gt 0) {
        $kind = if ($Elevated) { 'Unreadable' } else { 'Protected' }
        $name = if ($Elevated) { 'Unreadable or in use by Windows' } else { 'Protected areas (restart as administrator to break down)' }
        $rows.Add([PSCustomObject]@{ Name = $name; Path = $null; Bytes = $remainder; Kind = $kind; Node = $null })
    } elseif ($remainder -lt 0) {
        $rows.Add([PSCustomObject]@{ Name = 'Windows shared files (counted once)'; Path = $null; Bytes = $remainder; Kind = 'Shared'; Node = $null })
    }

    $denominator = [math]::Max([long]1, $UsedBytes)
    foreach ($r in $rows) { $r | Add-Member -NotePropertyName Percent -NotePropertyValue ([math]::Round(100.0 * $r.Bytes / $denominator, 1)) }
    return @($rows | Sort-Object -Property @{ Expression = { if ($_.Kind -in 'Protected', 'Unreadable', 'Shared') { 1 } else { 0 } } }, @{ Expression = { $_.Bytes }; Descending = $true })
}

# Category totals for the stacked bar. A folder's own files count toward its category; children inherit it unless a longer prefix matches.
function Get-SpaceCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Root)

    $profile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $windows = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$drive\Windows" }
    $pf      = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$drive\Program Files" }
    $pf86    = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\') } else { "$drive\Program Files (x86)" }
    $pd      = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$drive\ProgramData" }

    $prefixes = New-Object System.Collections.Generic.List[object]
    $add = { param($p, $c) if ($p) { $prefixes.Add(@($p.TrimEnd('\'), $c)) } }
    foreach ($f in 'Documents', 'Desktop', 'Downloads', 'Pictures', 'Videos', 'Music') { & $add "$profile\$f" 'Your files' }
    foreach ($p in $pf, $pf86, $pd, "$local\Programs", "$local\Packages", $roaming, $local) { & $add $p 'Apps and games' }
    foreach ($f in 'Docker', 'Arduino15', 'Android', 'Python') { & $add "$local\$f" 'Developer tools' }
    foreach ($f in 'npm', 'Code', 'Cursor', 'JetBrains', 'uv') { & $add "$roaming\$f" 'Developer tools' }
    foreach ($p in $windows, "$drive\`$WinREAgent", "$drive\Recovery", "$drive\System Volume Information", "$drive\`$Windows.~BT", "$drive\`$Windows.~WS") { & $add $p 'Windows and system' }
    foreach ($t in (Get-CleanableTargets)) { & $add $t.Path 'Caches and temp' }
    & $add "$windows\Temp" 'Caches and temp'
    & $add "$local\Temp" 'Caches and temp'

    $sorted = @($prefixes | Sort-Object { $_[0].Length } -Descending)
    $totals = @{ 'Apps and games' = 0L; 'Developer tools' = 0L; 'Windows and system' = 0L; 'Your files' = 0L; 'Caches and temp' = 0L; 'Other' = 0L }

    $walk = {
        param($node, $inherited)
        $cat = $inherited
        foreach ($p in $sorted) {
            if ($node.Path.Length -ge $p[0].Length -and $node.Path.StartsWith($p[0], [System.StringComparison]::OrdinalIgnoreCase) -and
                ($node.Path.Length -eq $p[0].Length -or $node.Path[$p[0].Length] -eq '\')) { $cat = $p[1]; break }
        }
        # Dot-folders in the profile (.gradle, .docker, .vscode, .codex ...) are developer tools
        if ($cat -eq 'Other' -and $node.Path.StartsWith("$profile\.", [System.StringComparison]::OrdinalIgnoreCase)) { $cat = 'Developer tools' }
        $totals[$cat] += [long]$node.OwnBytes
        foreach ($child in $node.Children) { & $walk $child $cat }
    }
    & $walk $Root 'Other'
    return $totals
}

# The folders worth looking at: stop at anything with a rule, step through plain containers (Users, AppData...), and
# drill into a dominant child (70%+) so the list names "UpdateFramework" rather than "ProgramData".
function Get-BiggestFolders {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Root, [int]$Max = 12, [long]$MinBytes = 100MB)

    $profile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $containers = @{}
    foreach ($c in @($Root.Path, "$drive\Users", $profile, "$profile\AppData", $local, "$local\Programs", "$local\Packages", $roaming,
                     "$profile\AppData\LocalLow", $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($c) { $containers[$c.TrimEnd('\').ToLowerInvariant()] = $true }
    }
    $usersPrefix = "$drive\Users\".ToLowerInvariant()

    $found = New-Object System.Collections.Generic.List[object]
    $visit = {
        param($node)
        $key = $node.Path.TrimEnd('\').ToLowerInvariant()
        if (Find-SpaceRule -Path $node.Path) { $found.Add($node); return }
        # Another user's profile folder (C:\Users\name) is a container too
        $isUserRoot = $key.StartsWith($usersPrefix) -and ($key.Substring($usersPrefix.Length) -notlike '*\*')
        if ($containers.ContainsKey($key) -or $isUserRoot) {
            foreach ($child in $node.Children) { & $visit $child }
            return
        }
        # No single dominant child, but a top child has a rule (ProgramData\NVIDIA: NGX and Streamline): show those
        if ($node.Children.Count -gt 1 -and $node.Children[0].Bytes -lt (0.7 * $node.Bytes) -and
            @($node.Children | Select-Object -First 3 | Where-Object { Find-SpaceRule -Path $_.Path }).Count -gt 0) {
            foreach ($child in $node.Children) { & $visit $child }
            return
        }
        $pick = $node
        while ($pick.Children.Count -gt 0 -and $pick.Children[0].Bytes -ge (0.7 * $pick.Bytes)) {
            $pick = $pick.Children[0]
            if (Find-SpaceRule -Path $pick.Path) { break }
        }
        $found.Add($pick)
    }
    & $visit $Root
    return @($found | Where-Object { $_.Bytes -ge $MinBytes } | Sort-Object -Property @{ Expression = { $_.Bytes }; Descending = $true } | Select-Object -First $Max)
}


$embeddedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diskman - drive space cleaner" 
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
        <SolidColorBrush x:Key="TextPrimary" Color="#EDEDED"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#A1A1AA"/>
        <SolidColorBrush x:Key="TextBody" Color="#D4D4D8"/>
        <SolidColorBrush x:Key="SurfaceBg" Color="#16161A"/>
        <SolidColorBrush x:Key="PanelBg" Color="#1C1C20"/>
        <SolidColorBrush x:Key="CardSurface" Color="#1B1B1F"/>
        <SolidColorBrush x:Key="Divider" Color="#27272A"/>
        <SolidColorBrush x:Key="AccentStrong" Color="#0077B6"/>
        <SolidColorBrush x:Key="InputBg" Color="#202026"/>
        <SolidColorBrush x:Key="OnAccent" Color="#FFFFFF"/>

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

        <!-- Dark scrollbars (the stock ones are light grey on this theme) -->
        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumbBorder" Background="#4A4A52" CornerRadius="4" Margin="2"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="thumbBorder" Property="Background" Value="#6B6B75"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="thumbBorder" Property="Background" Value="{StaticResource AccentCyan}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollPage" TargetType="RepeatButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="{StaticResource SurfaceBg}"/>
            <Setter Property="Width" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Border Background="{TemplateBinding Background}">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                            </Track>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="12"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Border Background="{TemplateBinding Background}">
                                    <Track x:Name="PART_Track" IsDirectionReversed="False">
                                        <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                                        <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                                        <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                                    </Track>
                                </Border>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Breadcrumb link button -->
        <Style x:Key="CrumbButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="crumbBorder" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="crumbBorder" Property="Background" Value="#25252C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Section label above a block of content -->
        <Style x:Key="SectionLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
            <Setter Property="Margin" Value="0,0,0,6"/>
        </Style>

        <!-- Standard Button Style -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2A2A30"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderMedium}"/>
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
                                <Setter TargetName="btnBorder" Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="{StaticResource PanelBg}"/>
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
            <Setter Property="Background" Value="{StaticResource AccentStrong}"/>
            <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
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
            <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
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
            <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderDark}"/>
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
                            <Border Grid.Row="0" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="12,6">
                                <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" SnapsToDevicePixels="True"/>
                            </Border>
                            <Border Grid.Row="1" Background="{StaticResource SurfaceBg}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="0,0,6,6" Padding="{TemplateBinding Padding}">
                                <ContentPresenter SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Flat Dark ProgressBar -->
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource WinDarkBg}"/>
            <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderDark}"/>
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
            <Setter Property="Background" Value="{StaticResource PanelBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="18,9"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="{TemplateBinding Padding}" Margin="0,0,4,0" SnapsToDevicePixels="True">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#28282E"/>
                                <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource SurfaceBg}"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
                                <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
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
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
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
                    <Setter Property="Background" Value="{StaticResource AccentStrong}"/>
                    <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- DataGrid Row Style -->
        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="{StaticResource SurfaceBg}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#25252C"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource AccentStrong}"/>
                    <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- DataGrid Style -->
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="{StaticResource SurfaceBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderDark}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="RowBackground" Value="{StaticResource SurfaceBg}"/>
            <Setter Property="AlternatingRowBackground" Value="{StaticResource PanelBg}"/>
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
            <Setter Property="Background" Value="{StaticResource InputBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderDark}"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>

        <!-- ComboBox Dark Style (full template: the stock one ignores Background and renders white) -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
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
                                <Setter TargetName="itemBorder" Property="Background" Value="{StaticResource AccentStrong}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource InputBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderMedium}"/>
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
                                                  Data="M0,0 L4,4 L8,0" Stroke="{StaticResource TextSecondary}" StrokeThickness="1.5"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                              Margin="10,3,28,3" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,2,0,0"
                                        Background="{StaticResource InputBg}" BorderBrush="{StaticResource BorderMedium}" BorderThickness="1" CornerRadius="5">
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
                    <TextBlock Text="Diskman" FontSize="20" FontWeight="Bold" Foreground="{StaticResource AccentCyan}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtBrandSub" Text="  |  Drive space cleaner" FontSize="13" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnRestartAdmin" Content="Restart as Administrator" Margin="0,0,8,0" ToolTip="Needed to measure and clean system areas such as shadow copies and the component store"/>
                    <Button x:Name="BtnTopQuickScan" Content="Rescan" Style="{StaticResource PrimaryActionBtn}" ToolTip="Scan the whole drive again"/>
                </StackPanel>
            </Grid>

            <!-- C: Drive Real-Time Metrics Strip -->
            <Border Grid.Row="1" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="6" Padding="14,10">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="140"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="190"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Margin="0,0,10,0">
                        <TextBlock Text="Total capacity" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveTotal" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="0,0,10,0">
                        <TextBlock Text="Used" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveUsed" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="{StaticResource AccentAmber}" Margin="0,2,0,0"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="0,0,10,0">
                        <TextBlock Text="Free" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                        <TextBlock x:Name="TxtCDriveFree" Text="Calculating..." FontSize="15" FontWeight="Bold" Foreground="{StaticResource AccentTeal}" Margin="0,2,0,0"/>
                    </StackPanel>

                    <!-- Drive Meter Bar -->
                    <StackPanel Grid.Column="3" VerticalAlignment="Center" Margin="10,0,20,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="TxtCBarStatus" Grid.Column="0" Text="Drive volume" FontSize="11" Foreground="{StaticResource TextSecondary}" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
                            <TextBlock x:Name="TxtCBarPercent" Grid.Column="1" Text="-- % used" FontSize="11" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                        </Grid>
                        <ProgressBar x:Name="ProgressCDrive" AutomationProperties.Name="Drive space used" Height="10" Value="50" Maximum="100"/>
                    </StackPanel>

                    <StackPanel Grid.Column="4" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <TextBlock Text="Found by the Cleaner" Foreground="{StaticResource TextSecondary}" FontSize="11" HorizontalAlignment="Right"/>
                        <TextBlock x:Name="TxtCReclaimable" Text="Scanning..." FontSize="16" FontWeight="Bold" Foreground="{StaticResource AccentCyan}" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Main TabControl -->
        <TabControl x:Name="MainTabControl" Grid.Row="1" Background="{StaticResource SurfaceBg}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1">

            <!-- OVERVIEW: why is my drive full, and what can I do now -->
            <TabItem x:Name="TabOverview" Header="Overview">
                <Grid Margin="12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="340"/>
                    </Grid.ColumnDefinitions>

                    <!-- Left: verdict, scan progress, where it went, biggest folders -->
                    <Grid Grid.Column="0" Margin="0,0,12,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Margin="0,0,0,8">
                            <TextBlock x:Name="TxtOverviewVerdict" Text="Reading your drive..." FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtOverviewSub" Text="" FontSize="11" Foreground="{StaticResource TextSecondary}" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
                        </StackPanel>

                        <Border x:Name="PanelScan" Grid.Row="1" Visibility="Collapsed" Background="{StaticResource CardSurface}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="TxtScanProgress" Grid.Column="0" Text="" Foreground="{StaticResource TextBody}" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                                <Button x:Name="BtnCancelScan" Grid.Column="1" Content="Cancel scan" Margin="12,0,0,0"/>
                            </Grid>
                        </Border>

                        <StackPanel Grid.Row="2" Margin="0,0,0,10">
                            <TextBlock Text="WHERE YOUR SPACE WENT" Style="{StaticResource SectionLabel}"/>
                            <Border CornerRadius="4" Background="#22222A" Height="16" ClipToBounds="True">
                                <Grid x:Name="BarCategories" AutomationProperties.Name="Space by category"/>
                            </Border>
                            <WrapPanel x:Name="PanelLegend" Margin="0,8,0,0"/>
                        </StackPanel>

                        <TextBlock Grid.Row="3" Text="BIGGEST FOLDERS" Style="{StaticResource SectionLabel}"/>

                        <Grid Grid.Row="4">
                            <DataGrid x:Name="GridTopFolders" AutoGenerateColumns="False" IsReadOnly="True" AutomationProperties.Name="Biggest folders">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Folder" Binding="{Binding Display}" Width="*" FontWeight="SemiBold">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="ToolTip" Value="{Binding Path}"/>
                                                <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="Bytes" Width="90" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                                    <DataGridTextColumn Header="% of drive" Binding="{Binding PctText}" SortMemberPath="PctValue" Width="70"/>
                                    <DataGridTextColumn Header="What to do" Binding="{Binding Insight}" Width="190"/>
                                </DataGrid.Columns>
                            </DataGrid>
                            <TextBlock x:Name="TxtEmptyTop" Text="Biggest folders appear here as the scan finds them." Foreground="{StaticResource TextSecondary}" FontSize="13" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
                        </Grid>

                        <Border Grid.Row="5" Margin="0,8,0,0" Background="{StaticResource CardSurface}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="6" Padding="10,6">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="TxtOverviewSelected" Grid.Column="0" Text="Select a folder to see what it is and what you can do about it." Foreground="{StaticResource TextBody}" FontSize="11" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="32" VerticalAlignment="Center"/>
                                <Button x:Name="BtnOverviewOpen" Grid.Column="1" Content="Open in Explorer" Margin="12,0,6,0" IsEnabled="False"/>
                                <Button x:Name="BtnOverviewAction" Grid.Column="2" Content="Action" Style="{StaticResource PrimaryActionBtn}" IsEnabled="False"/>
                            </Grid>
                        </Border>
                    </Grid>

                    <!-- Right: one-click win, ranked actions, Windows-managed space -->
                    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <Button x:Name="BtnFreeSafely" Content="Free space safely" Style="{StaticResource PrimaryActionBtn}" Padding="16,10" FontSize="14" IsEnabled="False"/>
                            <TextBlock x:Name="TxtFreeSafelyNote" Text="Waiting for the scan..." Foreground="{StaticResource TextSecondary}" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,8"/>
                            <TextBlock x:Name="TxtAdminHint" Text="" Visibility="Collapsed" Foreground="{StaticResource AccentAmber}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14"/>

                            <TextBlock Text="RECOMMENDED ACTIONS" Style="{StaticResource SectionLabel}"/>
                            <StackPanel x:Name="PanelActions" Margin="0,0,0,14"/>

                            <TextBlock Text="WINDOWS-MANAGED SPACE" Style="{StaticResource SectionLabel}"/>
                            <StackPanel x:Name="PanelSystemSpace"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>

            <!-- TAB 1: C: DRIVE JUNK CLEANER (PRIMARY VIEW) -->
            <TabItem x:Name="TabCleaner" Header="Cleaner">
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
                                <TextBlock x:Name="TxtCleanSelectedBadge" Text="Selected: 0 B (0 categories)" FontWeight="Bold" Foreground="{StaticResource AccentCyan}" VerticalAlignment="Center" Margin="0,0,12,0" FontSize="13"/>
                                <Button x:Name="BtnScanCleanable" Content="Scan Junk" Margin="0,0,8,0"/>
                                <Button x:Name="BtnRunCleanup" Content="Clean Selected Junk" Style="{StaticResource DangerActionBtn}"/>
                            </StackPanel>
                        </Grid>

                        <!-- Filter Chips (the active chip is highlighted from app.ps1) -->
                        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                            <TextBlock Text="Filter:" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" Margin="0,0,6,0" FontSize="11"/>
                            <Button x:Name="BtnFilterAll" Content="All" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterSystem" Content="System" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterGaming" Content="Gaming &amp; GPU" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterDev" Content="Developer" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                            <Button x:Name="BtnFilterBrowser" Content="Apps &amp; Web" Margin="0,0,4,0" Padding="9,5" FontSize="11"/>
                        </StackPanel>
                    </StackPanel>

                    <!-- Junk Categories DataGrid -->
                    <DataGrid x:Name="GridCleanableCategories" AutomationProperties.Name="Cleanup categories" Grid.Row="1" AutoGenerateColumns="False"
                              CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False"
                              VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.ScrollUnit="Pixel">
                        <DataGrid.Columns>
                            <!-- Template column: one click toggles the box (the stock checkbox column needs a select click first) -->
                            <DataGridTemplateColumn Header="Clean?" Width="55">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" ToolTip="{Binding SelectTip}" AutomationProperties.Name="Clean this category" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="Category" Binding="{Binding DisplayName}" Width="270" FontWeight="SemiBold"/>
                            <DataGridTextColumn Header="Group" Binding="{Binding Group}" Width="140"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawBytes" SortDirection="Descending" Width="105" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                            <DataGridTextColumn Header="Items" Binding="{Binding FileCount}" SortMemberPath="RawCount" Width="95"/>
                            <DataGridTextColumn Header="Safety" Binding="{Binding SafetyLevel}" Width="100"/>
                            <DataGridTextColumn Header="Path" Binding="{Binding Target}" Width="*"><DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding Target}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style></DataGridTextColumn.ElementStyle></DataGridTextColumn>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Category Safety & Deletion Details Card (Fixed Height = Zero Layout Shift) -->
                    <Border Grid.Row="2" Height="116" Background="{StaticResource CardSurface}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="6" Margin="0,10,0,0" Padding="12,10">
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
                                    <TextBlock x:Name="TxtSelectedCategoryTitle" Text="Category Details &amp; Safety Profile" FontWeight="Bold" FontSize="13" Foreground="{StaticResource TextPrimary}" VerticalAlignment="Center"/>
                                    <Border x:Name="BadgeSafetyLevel" Background="{StaticResource AccentTeal}" CornerRadius="3" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center" MinWidth="68">
                                        <TextBlock x:Name="TxtSelectedCategorySafetyBadge" Text="SAFE" FontSize="10" FontWeight="Bold" Foreground="{StaticResource WinDarkBg}" TextAlignment="Center" HorizontalAlignment="Center"/>
                                    </Border>
                                    <TextBlock x:Name="TxtSelectedCategorySizeInfo" Text="" Foreground="{StaticResource TextSecondary}" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button x:Name="BtnOpenCategoryInExplorer" Content="Open in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,6,0"/>
                                    <Button x:Name="BtnInspectCategoryFiles" Content="View Files in Inspector" Margin="0,0,6,0"/>
                                    <Button x:Name="BtnCleanSingleCategory" Content="Clean Category" Style="{StaticResource DangerActionBtn}"/>
                                </StackPanel>
                            </Grid>

                            <!-- Divider -->
                            <Rectangle Grid.Row="1" Height="1" Fill="{StaticResource Divider}" Margin="0,8,0,8"/>

                            <!-- 3-Column Explanations Grid: What Gets Deleted | Why It's Safe & Protected | Consequences & Rebuild -->
                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Column 1: What Gets Deleted -->
                                <Border Grid.Column="0" Background="{StaticResource WinDarkBg}" BorderBrush="{StaticResource Divider}" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,0,6,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="TARGET FILES &amp; DATA" FontSize="10" FontWeight="Bold" Foreground="{StaticResource AccentCyan}" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategoryWhatDeleted" Text="Select a category above to view specific target file types and paths." FontSize="11" Foreground="{StaticResource TextBody}" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>

                                <!-- Column 2: Why It's Safe & Protected Data -->
                                <Border Grid.Column="1" Background="{StaticResource WinDarkBg}" BorderBrush="{StaticResource Divider}" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="3,0,3,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="SAFETY &amp; PROTECTED DATA" FontSize="10" FontWeight="Bold" Foreground="{StaticResource AccentTeal}" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategorySafetyExp" Text="Personal documents, passwords, credentials, and settings are never touched." FontSize="11" Foreground="{StaticResource TextBody}" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>

                                <!-- Column 3: Post-Deletion Consequences -->
                                <Border Grid.Column="2" Background="{StaticResource WinDarkBg}" BorderBrush="{StaticResource Divider}" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="6,0,0,0">
                                    <DockPanel LastChildFill="True">
                                        <TextBlock DockPanel.Dock="Top" Text="POST-CLEANUP IMPACT" FontSize="10" FontWeight="Bold" Foreground="{StaticResource AccentAmber}" Margin="0,0,0,4"/>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent">
                                            <TextBlock x:Name="TxtCategoryConsequences" Text="Explains whether files auto-regenerate or require network reload." FontSize="11" Foreground="{StaticResource TextBody}" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>
                            </Grid>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- SPACE EXPLORER: drill down through the scanned tree -->
            <TabItem x:Name="TabExplorer" Header="Space Explorer">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BtnSpaceUp" Grid.Column="0" Content="Up" Margin="0,0,8,0" ToolTip="Go to the parent folder (Backspace)"/>
                        <WrapPanel x:Name="PanelCrumbs" Grid.Column="1" VerticalAlignment="Center" AutomationProperties.Name="Folder path"/>
                    </Grid>

                    <Grid Grid.Row="1">
                        <DataGrid x:Name="GridSpace" AutoGenerateColumns="False" IsReadOnly="True" AutomationProperties.Name="Folders and sizes">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*" FontWeight="SemiBold">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock">
                                            <Setter Property="ToolTip" Value="{Binding Path}"/>
                                            <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                                        </Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                                <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="Bytes" Width="90" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                                <DataGridTemplateColumn Header="Share of folder" Width="130" SortMemberPath="PctValue">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <ProgressBar Value="{Binding PctValue, Mode=OneWay}" Maximum="100" Height="8" Margin="4,0" AutomationProperties.Name="Share of parent folder"/>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="%" Binding="{Binding PctText}" SortMemberPath="PctValue" Width="60"/>
                                <DataGridTextColumn Header="Files" Binding="{Binding FilesText}" SortMemberPath="Files" Width="90"/>
                                <DataGridTextColumn Header="Newest change" Binding="{Binding Modified}" Width="110"/>
                                <DataGridTextColumn Header="What to do" Binding="{Binding Insight}" Width="190"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <TextBlock x:Name="TxtEmptyExplorer" Text="The folder tree appears here when the scan finishes." Foreground="{StaticResource TextSecondary}" FontSize="13" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
                    </Grid>

                    <Border Grid.Row="2" Margin="0,8,0,0" Background="{StaticResource CardSurface}" BorderBrush="{StaticResource BorderDark}" BorderThickness="1" CornerRadius="6" Padding="12,8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="TxtSpaceSelected" Grid.Column="0" Text="Select a row. Enter opens a folder, Backspace goes up." Foreground="{StaticResource TextBody}" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" MinHeight="34"/>
                            <Button x:Name="BtnSpaceOpen" Grid.Column="1" Content="Open in Explorer" Margin="12,0,6,0" IsEnabled="False"/>
                            <Button x:Name="BtnSpaceCopy" Grid.Column="2" Content="Copy path" Margin="0,0,6,0" IsEnabled="False"/>
                            <Button x:Name="BtnSpaceAction" Grid.Column="3" Content="Action" Style="{StaticResource PrimaryActionBtn}" IsEnabled="False"/>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- TAB 3: C: LARGE JUNK & INSTALLERS HUNTER -->
            <TabItem x:Name="TabHunter" Header="Large Files">
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
                            <TextBlock Text="Min Size: " Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterSize" AutomationProperties.Name="Minimum file size" Width="100" Height="28" Margin="6,0,0,0"/>
                        </StackPanel>

                        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
                            <TextBlock Text="Category: " Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterCategory" AutomationProperties.Name="File category" Width="150" Height="28" Margin="6,0,0,0"/>
                        </StackPanel>

                        <Button x:Name="BtnStartHunterScan" Grid.Column="3" Content="Scan Large Files" Style="{StaticResource PrimaryActionBtn}"/>
                    </Grid>

                    <!-- Table -->
                    <Grid Grid.Row="1">
                    <DataGrid x:Name="GridLargeFiles" AutomationProperties.Name="Large files" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="240"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawSize" SortDirection="Descending" Width="100" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                            <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="140"/>
                            <DataGridTextColumn Header="Full path" Binding="{Binding FullPath}" Width="*"><DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding FullPath}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style></DataGridTextColumn.ElementStyle></DataGridTextColumn>
                            <DataGridTextColumn Header="Modified" Binding="{Binding LastWriteTime}" Width="130"/>
                        </DataGrid.Columns>
                    </DataGrid>
                        <TextBlock x:Name="TxtEmptyHunter" Text="Choose a minimum size and click Scan Large Files. Files in Downloads, Videos and Documents are included. Installed apps, game libraries and virtual machines are never listed." Foreground="{StaticResource TextSecondary}" FontSize="13" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="460" IsHitTestVisible="False"/>
                    </Grid>

                    <!-- Action buttons -->
                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock x:Name="TxtSelectedFileInfo" Grid.Column="0" Text="Select a large file to perform action." Foreground="{StaticResource TextSecondary}" FontSize="11" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRevealInExplorer" Grid.Column="1" Content="Reveal in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnSendToTrash" Grid.Column="2" Content="Send to Recycle Bin" Margin="0,0,8,0"/>
                        <Button x:Name="BtnPermanentDelete" Grid.Column="3" Content="Permanent Delete" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- TAB 2: DETAILED FILE INSPECTOR (C: JUNK FILES) -->
            <TabItem x:Name="TabInspector" Header="File Inspector">
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

                        <TextBlock Grid.Column="0" Text="Junk Category: " Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <ComboBox x:Name="CmbInspectTarget" AutomationProperties.Name="Junk category" Grid.Column="1" Height="28" Margin="0,0,8,0"/>
                        <Button x:Name="BtnRefreshInspectFiles" Grid.Column="2" Content="Load Files" Margin="0,0,12,0"/>
                        <TextBlock x:Name="TxtInspectSummary" Grid.Column="3" Text="Select a category and click Load Files to inspect individual files." Foreground="{StaticResource AccentTeal}" VerticalAlignment="Center" HorizontalAlignment="Right" FontWeight="SemiBold"/>
                    </Grid>

                    <!-- File Items Table -->
                    <Grid Grid.Row="1">
                    <DataGrid x:Name="GridInspectFiles" AutomationProperties.Name="Files in the selected category" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="250"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" SortMemberPath="RawBytes" SortDirection="Descending" Width="100" FontWeight="SemiBold" Foreground="{StaticResource AccentCyan}"/>
                            <DataGridTextColumn Header="Full path" Binding="{Binding FullPath}" Width="*"><DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding FullPath}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style></DataGridTextColumn.ElementStyle></DataGridTextColumn>
                            <DataGridTextColumn Header="Last Modified" Binding="{Binding LastWriteTime}" Width="140"/>
                        </DataGrid.Columns>
                    </DataGrid>
                        <TextBlock x:Name="TxtEmptyInspector" Text="Pick a category above and click Load Files to list its biggest files." Foreground="{StaticResource TextSecondary}" FontSize="13" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="460" IsHitTestVisible="False"/>
                    </Grid>

                    <!-- Action Bar -->
                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock x:Name="TxtSelectedInspectFileInfo" Grid.Column="0" Text="Select a file to inspect or delete." Foreground="{StaticResource TextSecondary}" FontSize="11" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRevealInspectFileInExplorer" Grid.Column="1" Content="Reveal in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnDeleteSingleInspectFile" Grid.Column="2" Content="Delete File" Margin="0,0,8,0"/>
                        <Button x:Name="BtnPurgeAllInspectFiles" Grid.Column="3" Content="Clear All Files in Target" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
                </Grid>
            </TabItem>







        </TabControl>

        <!-- Bottom Console / Output Terminal -->
        <GroupBox Grid.Row="2" Header="Activity &amp; Execution Log" Margin="0,10,0,0">
            <TextBox x:Name="TxtConsoleLog" AutomationProperties.Name="Activity log" Background="{StaticResource ConsoleBg}" Foreground="{StaticResource AccentTeal}" FontFamily="Consolas, monospace" FontSize="11" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </GroupBox>

        <!-- Status Bar -->
        <Grid Grid.Row="3" Margin="4,6,4,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock x:Name="TxtGlobalStatus" Grid.Column="0" Text="Ready" FontSize="11" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <Button x:Name="BtnCancelAction" Grid.Column="1" Content="Cancel" Padding="10,2" FontSize="11" Margin="8,0,16,0" Visibility="Collapsed" ToolTip="Stop the running operation"/>
            <TextBlock x:Name="TxtLogLocation" Grid.Column="2" VerticalAlignment="Center" Text="" FontSize="11" Foreground="{StaticResource TextSecondary}" ToolTip="Every action is written to this folder"/>
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

# Audit trail: every log line is also appended to a daily file, so there is a record after the window closes
$global:AuditLogDir = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Diskman\logs'
function Write-AuditLog {
    param([string]$Line)
    try {
        if (-not (Test-Path -LiteralPath $global:AuditLogDir)) { New-Item -ItemType Directory -Path $global:AuditLogDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $global:AuditLogDir ("diskman-{0:yyyyMMdd}.log" -f (Get-Date))) -Value $Line -Encoding UTF8
    } catch {}
}

# Live log (terminal + in-app box + audit file). Only ever called on the UI thread.
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
    Write-AuditLog ("{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $prefix, $Message)
}

# Control References
$txtConsoleLog             = Find-Control "TxtConsoleLog"
$txtGlobalStat             = Find-Control "TxtGlobalStatus"
$txtLogLocation            = Find-Control "TxtLogLocation"
$btnCancelAction           = Find-Control "BtnCancelAction"
$mainTabControl            = Find-Control "MainTabControl"
$tabOverview               = Find-Control "TabOverview"
$tabCleaner                = Find-Control "TabCleaner"
$tabExplorer               = Find-Control "TabExplorer"
$tabHunter                 = Find-Control "TabHunter"
$tabInspector              = Find-Control "TabInspector"

# Drive strip
$txtCDriveTotal            = Find-Control "TxtCDriveTotal"
$txtCDriveUsed             = Find-Control "TxtCDriveUsed"
$txtCDriveFree             = Find-Control "TxtCDriveFree"
$progressCDrive            = Find-Control "ProgressCDrive"
$txtCBarPercent            = Find-Control "TxtCBarPercent"
$txtCBarStatus             = Find-Control "TxtCBarStatus"
$txtCReclaimable           = Find-Control "TxtCReclaimable"
$btnRestartAdmin           = Find-Control "BtnRestartAdmin"
$btnTopQuickScan           = Find-Control "BtnTopQuickScan"

# Overview
$txtOverviewVerdict        = Find-Control "TxtOverviewVerdict"
$txtOverviewSub            = Find-Control "TxtOverviewSub"
$panelScan                 = Find-Control "PanelScan"
$txtScanProgress           = Find-Control "TxtScanProgress"
$btnCancelScan             = Find-Control "BtnCancelScan"
$barCategories             = Find-Control "BarCategories"
$panelLegend               = Find-Control "PanelLegend"
$gridTopFolders            = Find-Control "GridTopFolders"
$txtEmptyTop               = Find-Control "TxtEmptyTop"
$txtOverviewSelected       = Find-Control "TxtOverviewSelected"
$btnOverviewOpen           = Find-Control "BtnOverviewOpen"
$btnOverviewAction         = Find-Control "BtnOverviewAction"
$btnFreeSafely             = Find-Control "BtnFreeSafely"
$txtFreeSafelyNote         = Find-Control "TxtFreeSafelyNote"
$txtAdminHint              = Find-Control "TxtAdminHint"
$panelActions              = Find-Control "PanelActions"
$panelSystemSpace          = Find-Control "PanelSystemSpace"

# Space Explorer
$btnSpaceUp                = Find-Control "BtnSpaceUp"
$panelCrumbs               = Find-Control "PanelCrumbs"
$gridSpace                 = Find-Control "GridSpace"
$txtEmptyExplorer          = Find-Control "TxtEmptyExplorer"
$txtSpaceSelected          = Find-Control "TxtSpaceSelected"
$btnSpaceOpen              = Find-Control "BtnSpaceOpen"
$btnSpaceCopy              = Find-Control "BtnSpaceCopy"
$btnSpaceAction            = Find-Control "BtnSpaceAction"

# Cleaner
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

# File Inspector
$cmbInspectTarget          = Find-Control "CmbInspectTarget"
$btnRefreshInspectFiles    = Find-Control "BtnRefreshInspectFiles"
$txtInspectSummary         = Find-Control "TxtInspectSummary"
$gridInspectFiles          = Find-Control "GridInspectFiles"
$txtEmptyInspector         = Find-Control "TxtEmptyInspector"
$txtSelectedInspectInfo    = Find-Control "TxtSelectedInspectFileInfo"
$btnRevealInspectFile       = Find-Control "BtnRevealInspectFileInExplorer"
$btnDeleteSingleInspectFile = Find-Control "BtnDeleteSingleInspectFile"
$btnPurgeAllInspect         = Find-Control "BtnPurgeAllInspectFiles"

# Large Files
$cmbHuntSize               = Find-Control "CmbHunterSize"
$cmbHuntCat                = Find-Control "CmbHunterCategory"
$btnHuntScan               = Find-Control "BtnStartHunterScan"
$gridLargeFiles            = Find-Control "GridLargeFiles"
$txtEmptyHunter            = Find-Control "TxtEmptyHunter"
$txtSelectedLargeFile      = Find-Control "TxtSelectedFileInfo"
$btnRevealLargeFile        = Find-Control "BtnRevealInExplorer"
$btnTrashLargeFile         = Find-Control "BtnSendToTrash"
$btnPermDeleteLargeFile    = Find-Control "BtnPermanentDelete"

# Internal State
$global:ScannedCleanupItems = [System.Collections.ArrayList]@()
$global:CurrentFilterGroup  = "All"
$global:Jobs                = @{ action = $null; scan = $null }
$global:SpaceTree           = $null
$global:SpaceStack          = New-Object System.Collections.ArrayList
$global:ScanPartial         = $false
$global:TickCount           = 0
$global:RescanPending       = $false

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$brushConverter = New-Object System.Windows.Media.BrushConverter
$releaseUrl = 'https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1'
$driveRoot = if ($env:SystemDrive) { "$($env:SystemDrive.TrimEnd('\'))\" } else { 'C:\' }
$driveLetter = $driveRoot.Substring(0, 2)   # "C:" on most PCs; the Windows drive is not always C:

# ---------------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------------

# Every destructive confirmation defaults to No, so pressing Enter never deletes
function Confirm-Action {
    param([string]$Message, [string]$Title = 'Diskman', [string]$Icon = 'Warning')
    $answer = [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::$Icon, [System.Windows.MessageBoxResult]::No)
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-Info {
    param([string]$Message, [string]$Title = 'Diskman', [string]$Icon = 'Information')
    [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::$Icon) | Out-Null
}

# Empty-state text is visible only while the grid has nothing to show
function Set-Empty {
    param($TextBlock, $Items)
    $TextBlock.Visibility = if (@($Items).Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Format-Count { param([long]$N) return $N.ToString('N0') }

# ---------------------------------------------------------------------------
# Background work: two slots share one runspace-per-job design.
#   action: scans of cleanup targets, cleaning, hunting, commands (one at a time; disables action buttons)
#   scan:   the whole-drive tree scan (read-only; can run while an action runs; cancellable)
# The worker pushes log lines onto a queue; a DispatcherTimer on the UI thread drains it.
# ---------------------------------------------------------------------------

# Functions copied into the worker by definition, so this works uncompiled and in the single-file release
$workerFunctions = @(
    'Format-Bytes', 'Test-IsSubpathOrEqual', 'Test-ReparsePoint', 'Test-WindowsServicingActive', 'Test-PathSafety',
    'Get-FolderSizeFast', 'Get-CleanableTargets', 'Scan-SmartCleanupItems', 'Get-CleanableCategoryFiles',
    'Invoke-ExecuteCleanup', 'Invoke-ExecuteCategoryCleanup', 'Find-LargeFiles', 'Scan-DriveTree',
    'Get-AllowedCommands', 'Invoke-AllowedCommand', 'Invoke-VhdCompact', 'Get-CompactableDisks', 'New-DiskpartCompactScript', 'New-DiskpartDetachScript',
    'Get-ScanParallelism', 'Find-TreeNode', 'Find-AppCaches', 'Test-AppCacheExcluded', 'Get-AppCacheKind', 'Get-AppCacheGroupKey', 'Get-SpaceCategory'
)

# Everything that must not be clicked while an action job runs
$actionControls = @(
    $btnSelectRec, $btnSelectAll, $btnClearSel, $btnScanClean, $btnRunCleanup, $btnCleanSingleCategory,
    $btnRefreshInspectFiles, $btnDeleteSingleInspectFile, $btnPurgeAllInspect,
    $btnHuntScan, $btnTrashLargeFile, $btnPermDeleteLargeFile, $btnFreeSafely
)

function Update-BusyState {
    $actionBusy = [bool]$global:Jobs.action
    $scanBusy   = [bool]$global:Jobs.scan
    foreach ($c in $actionControls) { $c.IsEnabled = -not $actionBusy }
    $btnTopQuickScan.IsEnabled = -not ($scanBusy -or $actionBusy)
    $btnCancelAction.Visibility = if ($actionBusy) { 'Visible' } else { 'Collapsed' }
    $panelScan.Visibility = if ($scanBusy) { 'Visible' } else { 'Collapsed' }
    Show-OverviewSelection
    Show-SpaceSelection
    if (-not $actionBusy) { Update-FreeSafely }
}

function Stop-BackgroundJob {
    param([string]$Slot)
    $job = $global:Jobs[$Slot]
    if (-not $job) { return }
    $job.Context['Cancelled'] = $true
    if ($Slot -eq 'scan') {
        # The walker checks this flag and returns the partial tree normally
        [Diskman.TreeScan]::Cancel = $true
    } else {
        $null = $job.Ps.BeginStop($null, $null)
    }
    Log-Console "Cancelling: $($job.Status)..." "WARN"
}

$jobTimer = New-Object System.Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$jobTimer.add_Tick({
    $global:TickCount++
    foreach ($slot in @('action', 'scan')) {
        $job = $global:Jobs[$slot]
        if (-not $job) { continue }

        $msg = $null
        while ($job.Queue.TryDequeue([ref]$msg)) { Log-Console $msg[0] $msg[1] }
        $elapsed = [int]((Get-Date) - $job.Started).TotalSeconds
        if ($slot -eq 'action') {
            $txtGlobalStat.Text = "$($job.Status)... $($elapsed)s"
        } else {
            Update-ScanProgress -Elapsed $elapsed
        }
        if (-not $job.Async.IsCompleted) { continue }

        $output = @()
        $failure = $null
        try { $output = @($job.Ps.EndInvoke($job.Async)) } catch { $failure = $_ }
        $job.Ps.Dispose()
        $job.Runspace.Dispose()
        $global:Jobs[$slot] = $null
        Update-BusyState
        Update-CDriveMetricsDisplay -Quiet

        if ($failure) {
            if ($job.Context['Cancelled']) {
                Log-Console "$($job.Status) was cancelled." "WARN"
                if ($job.Context['Ids']) { Start-ScanCJunk -Id $job.Context['Ids'] }
            } else {
                Log-Console "$($job.Status) failed: $failure" "ERROR"
            }
        } else {
            & $job.OnDone $output $job.Context
        }
    }
    if (-not $global:Jobs.action -and -not $global:Jobs.scan) { $jobTimer.Stop() }
})

function Start-BackgroundJob {
    param(
        [ValidateSet('action', 'scan')][string]$Slot = 'action',
        [string]$Status,
        [scriptblock]$Work,
        [hashtable]$Vars = @{},
        [hashtable]$Context = @{},
        [scriptblock]$OnDone
    )

    if ($global:Jobs[$Slot]) {
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

    $global:Jobs[$Slot] = @{
        Status = $Status; Ps = $ps; Runspace = $rs; Queue = $queue; OnDone = $OnDone; Context = $Context
        Started = Get-Date; Async = $ps.BeginInvoke()
    }
    Update-BusyState
    Log-Console "$Status..."
    $jobTimer.Start()
}

# ---------------------------------------------------------------------------
# Drive strip and Overview
# ---------------------------------------------------------------------------

function Get-DriveState {
    $d = [System.IO.DriveInfo]::new($driveRoot)
    return [PSCustomObject]@{ Total = [long]$d.TotalSize; Free = [long]$d.AvailableFreeSpace; Used = [long]($d.TotalSize - $d.AvailableFreeSpace) }
}

function Update-CDriveMetricsDisplay {
    param([switch]$Quiet)
    $cMetrics = Get-CDriveMetrics
    if ($cMetrics) {
        $txtCDriveTotal.Text = "$($cMetrics.TotalGB) GB"
        $txtCDriveUsed.Text  = "$($cMetrics.UsedGB) GB"
        $txtCDriveFree.Text  = "$($cMetrics.FreeGB) GB"
        $progressCDrive.Value = $cMetrics.UsedPercent
        $txtCBarPercent.Text = "$($cMetrics.UsedPercent)% used - $($cMetrics.StatusText)"
        $txtCBarStatus.Text  = "Drive $driveLetter [$($cMetrics.VolumeLabel)] ($($cMetrics.FileSystem))"
        if (-not $global:Jobs.action) { $txtGlobalStat.Text = "$driveLetter $($cMetrics.FreeGB) GB free of $($cMetrics.TotalGB) GB ($($cMetrics.StatusText))" }
        if (-not $Quiet) {
            Log-Console "$driveLetter drive status: $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)"
        }
    }
    Update-OverviewVerdict
}

# Safe-tier categories the user can clean right now (the one-click win)
function Get-SafeCleanItems {
    return @($global:ScannedCleanupItems | Where-Object { $_.SafetyLevel -eq 'Safe' -and $_.Recommended -and $_.RawBytes -gt 0 -and $_.CanSelect -and $_.Type -ne 'RecycleBin' })
}

function Update-OverviewVerdict {
    $drive = Get-DriveState
    $pct = if ($drive.Total -gt 0) { 100.0 * $drive.Free / $drive.Total } else { 100 }
    $level = if ($drive.Free -lt 2GB -or $pct -lt 5) { 'Critically low' } elseif ($pct -lt 10) { 'Low' } else { 'Healthy' }
    $color = switch ($level) { 'Critically low' { '#FF6B6B' } 'Low' { '#FFB703' } default { '#2EC4B6' } }
    $safe = Get-SafeCleanItems
    $safeBytes = [long](($safe | Measure-Object -Property RawBytes -Sum).Sum)

    $text = "$(Format-Bytes $drive.Free) free of $(Format-Bytes $drive.Total). $level."
    if ($safeBytes -gt 50MB) { $text += " About $(Format-Bytes $safeBytes) can be freed safely right now." }
    elseif ($global:ScannedCleanupItems.Count -gt 0 -and $level -eq 'Healthy') { $text += " Nothing large to clean." }
    $txtOverviewVerdict.Text = $text
    $txtOverviewVerdict.Foreground = $brushConverter.ConvertFromString($color)

    if ($global:Jobs.scan) {
        $txtOverviewSub.Text = "Scanning the whole drive to show where the rest went. Results appear as they are found."
    } elseif ($global:SpaceTree) {
        $scanned = [long]$global:SpaceTree.Bytes
        $share = if ($drive.Used -gt 0) { [math]::Min(100, [math]::Round(100.0 * $scanned / $drive.Used)) } else { 100 }
        $gap = $drive.Used - $scanned
        if ($global:ScanPartial) {
            $txtOverviewSub.Text = "Partial result: the scan was cancelled, so these numbers are incomplete. Click Rescan for the full picture."
        } elseif ($gap -gt 0) {
            $txtOverviewSub.Text = if ($isAdmin) { "Accounted for $share% of used space. $(Format-Bytes $gap) could not be read (in use by Windows or protected)." }
                                   else { "Accounted for $share% of used space. $(Format-Bytes $gap) sits in protected areas (such as shadow copies). Restart as Administrator to break it down." }
        } else {
            $txtOverviewSub.Text = "Accounted for all of the used space. Some Windows files are shared, so folder sizes can add up to slightly more than the drive reports."
        }
    } else {
        $txtOverviewSub.Text = ''
    }
    $txtOverviewSub.ToolTip = $txtOverviewSub.Text
    Update-AdminHint
}

# What administrator rights would unlock, so the Restart button has a reason attached
function Update-AdminHint {
    if ($isAdmin) { $txtAdminHint.Visibility = 'Collapsed'; return }
    $locked = [long](($global:ScannedCleanupItems | Where-Object { $_.RequiresAdmin -and $_.Type -ne 'RecycleBin' } | Measure-Object -Property RawBytes -Sum).Sum)
    $gap = if ($global:SpaceTree -and -not $global:ScanPartial) { [math]::Max([long]0, (Get-DriveState).Used - [long]$global:SpaceTree.Bytes) } else { [long]0 }
    if ($locked -lt 50MB -and $gap -lt 500MB) { $txtAdminHint.Visibility = 'Collapsed'; return }
    $parts = @()
    if ($locked -ge 50MB) { $parts += "about $(Format-Bytes $locked) of system caches that are skipped now" }
    if ($gap -ge 500MB) { $parts += "a look inside $(Format-Bytes $gap) of protected space (shadow copies, system files)" }
    $txtAdminHint.Text = "As administrator you would also unlock " + ($parts -join ' and ') + ". Use Restart as Administrator."
    $txtAdminHint.Visibility = 'Visible'
}

# One-click win: Safe-tier categories only, one confirmation
function Update-FreeSafely {
    $safe = Get-SafeCleanItems
    $bytes = [long](($safe | Measure-Object -Property RawBytes -Sum).Sum)
    if ($safe.Count -gt 0 -and $bytes -gt 50MB) {
        $btnFreeSafely.Content = "Free $(Format-Bytes $bytes) safely"
        $btnFreeSafely.IsEnabled = -not $global:Jobs.action
        $txtFreeSafelyNote.Text = "Cleans only Safe categories: " + (($safe | Select-Object -First 4 | ForEach-Object { $_.CategoryName }) -join ', ') + $(if ($safe.Count -gt 4) { " and $($safe.Count - 4) more" } else { '' }) + ". You confirm first."
    } else {
        $btnFreeSafely.Content = "Nothing safe to free right now"
        $btnFreeSafely.IsEnabled = $false
        $txtFreeSafelyNote.Text = if ($global:ScannedCleanupItems.Count -eq 0) { "Waiting for the cleanup scan..." } else { "The Safe categories are already small. See the recommended actions below for bigger items." }
    }
}

$categoryColors = [ordered]@{
    'Apps and games' = '#00B4D8'; 'Developer tools' = '#8B7CF6'; 'Windows and system' = '#6B7B8C'
    'Your files' = '#2EC4B6'; 'Caches and temp' = '#FFB703'; 'Other' = '#A1A1AA'; 'Protected or unreadable' = '#52525B'
}

function Show-CategoryBar {
    param($Cats, [long]$GapBytes)
    $cats = $Cats
    $segments = New-Object System.Collections.ArrayList
    foreach ($name in $categoryColors.Keys) {
        $bytes = if ($name -eq 'Protected or unreadable') { [math]::Max([long]0, $GapBytes) } else { [long]$cats[$name] }
        if ($bytes -gt 0) { [void]$segments.Add([PSCustomObject]@{ Name = $name; Bytes = $bytes; Color = $categoryColors[$name] }) }
    }
    $total = [long](($segments | Measure-Object -Property Bytes -Sum).Sum)
    $barCategories.Children.Clear(); $barCategories.ColumnDefinitions.Clear(); $panelLegend.Children.Clear()
    $i = 0
    foreach ($seg in $segments) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = New-Object System.Windows.GridLength ([double]$seg.Bytes), ([System.Windows.GridUnitType]::Star)
        $barCategories.ColumnDefinitions.Add($col)
        $pct = [math]::Round(100.0 * $seg.Bytes / [math]::Max([long]1, $total), 1)
        $b = New-Object System.Windows.Controls.Border
        $b.Background = $brushConverter.ConvertFromString($seg.Color)
        $b.ToolTip = "$($seg.Name): $(Format-Bytes $seg.Bytes) ($pct%)"
        $b.BorderThickness = New-Object System.Windows.Thickness 0, 0, 1, 0
        $b.BorderBrush = $brushConverter.ConvertFromString('#16161A')
        [System.Windows.Controls.Grid]::SetColumn($b, $i)
        [void]$barCategories.Children.Add($b)

        $item = New-Object System.Windows.Controls.StackPanel
        $item.Orientation = 'Horizontal'; $item.Margin = New-Object System.Windows.Thickness 0, 0, 12, 2
        $sw = New-Object System.Windows.Shapes.Rectangle
        $sw.Width = 10; $sw.Height = 10; $sw.RadiusX = 2; $sw.RadiusY = 2; $sw.VerticalAlignment = 'Center'
        $sw.Fill = $brushConverter.ConvertFromString($seg.Color); $sw.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "$($seg.Name)  $(Format-Bytes $seg.Bytes) ($pct%)"; $lbl.FontSize = 10.5
        $lbl.Foreground = $brushConverter.ConvertFromString('#D4D4D8')
        [void]$item.Children.Add($sw); [void]$item.Children.Add($lbl); [void]$panelLegend.Children.Add($item)
        $i++
    }
}

function Get-InsightText {
    param($Rule)
    if (-not $Rule) { return 'Review in Explorer' }
    switch ($Rule.Verdict) {
        'Clean'     { return "Clean ($($Rule.Safety))" }
        'Command'   { return (Get-AllowedCommands)[$Rule.CommandId].Short }
        'Uninstall' { return 'Uninstall in Settings' }
        'System'    { return 'Windows-managed' }
        default     { return 'Review' }
    }
}

function New-SpaceRow {
    param($Node, [long]$ParentBytes, [string]$Name = $null, [string]$Display = $null)
    $rule = if ($Node) { Find-SpaceRule -Path $Node.Path } else { $null }
    if (-not $rule -and $Node) { $rule = Get-GenericAdvice -Path $Node.Path }
    $pct = if ($ParentBytes -gt 0) { 100.0 * $Node.Bytes / $ParentBytes } else { 0 }
    $modified = if ($Node.ModifiedTicks -gt 0) { ([datetime]::new($Node.ModifiedTicks, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd') } else { '' }
    $profilePath = [System.Environment]::GetFolderPath('UserProfile')
    $shown = if ($Display) { $Display } elseif ($Node.Path.StartsWith($profilePath, [System.StringComparison]::OrdinalIgnoreCase)) { '~' + $Node.Path.Substring($profilePath.Length) } else { $Node.Path }
    return [PSCustomObject]@{
        Name = if ($Name) { $Name } else { $Node.Name }; Display = $shown; Path = $Node.Path
        Bytes = [long]$Node.Bytes; DisplaySize = Format-Bytes $Node.Bytes
        PctValue = [math]::Round($pct, 1); PctText = $(if ($pct -ge 0.1) { "$([math]::Round($pct, 1))%" } else { '<0.1%' })
        Files = [long]$Node.Files; FilesText = Format-Count $Node.Files; Modified = $modified
        Insight = Get-InsightText $rule; Rule = $rule; Node = $Node
    }
}

# While the scan runs: top-level folders appear as soon as each finishes
function Show-PartialRows {
    $drive = Get-DriveState
    $rows = @([Diskman.TreeScan]::Partial.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 12 | ForEach-Object {
        $b = [long]$_.Value
        [PSCustomObject]@{ Name = $_.Key; Display = $_.Key; Path = $_.Key; Bytes = $b; DisplaySize = Format-Bytes $b
            PctValue = 0; PctText = "$([math]::Round(100.0 * $b / [math]::Max([long]1, $drive.Used), 1))%"; Insight = 'scanning...'; Rule = $null; Node = $null }
    })
    $gridTopFolders.ItemsSource = $rows
    Set-Empty $txtEmptyTop $rows
}

function Update-ScanProgress {
    param([int]$Elapsed)
    $files = [Diskman.TreeScan]::ScannedFiles
    $bytes = [Diskman.TreeScan]::ScannedBytes
    $cur = [Diskman.TreeScan]::Current
    $txtScanProgress.Text = "Scanning $driveLetter   $(Format-Count $files) files   |   $(Format-Bytes $bytes)   |   now in $cur   |   $([TimeSpan]::FromSeconds($Elapsed).ToString('m\:ss'))"
    if (($global:TickCount % 5) -eq 0) { Show-PartialRows }
}

# App caches found by structure join the Cleaner list and the rules (so the Overview and Explorer advise on them)
function Merge-DetectedCaches {
    param($Items)
    $kept = @($global:ScannedCleanupItems | Where-Object { -not $_.Dynamic })
    $all = @($kept + @($Items)) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    Set-ScanResults -Items $all -Quiet
}

# The scan worker already did the heavy work (tree, detected caches, category totals): this only renders them
function Show-ScanResults {
    param($Bundle, [bool]$Partial)
    $prepared = [System.Diagnostics.Stopwatch]::StartNew()
    $Tree = $Bundle.Tree
    $global:SpaceTree = $Tree
    $global:ScanPartial = $Partial
    $detected = @($Bundle.Detected)
    Set-DetectedCacheItems -Items $detected
    Merge-DetectedCaches -Items $detected
    if ($detected.Count -gt 0) {
        Log-Console "Detected $($detected.Count) apps with cache folders: $(Format-Bytes ([long](($detected | Measure-Object -Property RawBytes -Sum).Sum))) in total." "SUCCESS"
    }
    $drive = Get-DriveState
    $rows = Get-SpaceAccounting -Root $Tree -UsedBytes $drive.Used -Elevated $isAdmin
    $gap = [long](($rows | Where-Object { $_.Kind -in 'Protected', 'Unreadable' } | Measure-Object -Property Bytes -Sum).Sum)

    Show-CategoryBar -Cats $Bundle.Categories -GapBytes $gap

    $top = @(Get-BiggestFolders -Root $Tree -Max 12 | ForEach-Object { New-SpaceRow -Node $_ -ParentBytes $drive.Used })
    $gridTopFolders.ItemsSource = $top
    Set-Empty $txtEmptyTop $top
    if ($top.Count -eq 0) { $txtEmptyTop.Text = 'No folder over 100 MB was found.' }

    Show-SystemSpace
    Set-SpaceNode -Node $Tree -Reset
    Update-ActionCards
    Update-OverviewVerdict
    $covered = @($top | Where-Object { $_.Rule -and -not $_.Rule.Generic }).Count
    $general = @($top | Where-Object { $_.Rule -and $_.Rule.Generic }).Count
    Log-Console "Drive scan complete: $(Format-Bytes $Tree.Bytes) in $(Format-Count $Tree.Files) files, $($rows.Count) accounting rows, $covered of $($top.Count) biggest folders have specific advice and $general general guidance (results prepared in $($prepared.ElapsedMilliseconds) ms)." "SUCCESS"
}

function Show-SystemSpace {
    $panelSystemSpace.Children.Clear()
    foreach ($r in (Get-SystemSpace -Root $global:SpaceTree -Elevated $isAdmin)) {
        $card = New-Object System.Windows.Controls.StackPanel
        $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
        $head = New-Object System.Windows.Controls.DockPanel
        $size = New-Object System.Windows.Controls.TextBlock
        $size.Text = if ($null -ne $r.Bytes) { Format-Bytes $r.Bytes } elseif ($r.NeedsAdmin -and -not $isAdmin) { 'needs administrator' } else { 'not measured' }
        $size.FontWeight = 'Bold'; $size.Foreground = $brushConverter.ConvertFromString('#00B4D8'); $size.FontSize = 12
        [System.Windows.Controls.DockPanel]::SetDock($size, 'Right')
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $r.Name; $name.FontWeight = 'SemiBold'; $name.FontSize = 12; $name.TextTrimming = 'CharacterEllipsis'
        $name.Foreground = $brushConverter.ConvertFromString('#EDEDED')
        [void]$head.Children.Add($size); [void]$head.Children.Add($name)
        $note = New-Object System.Windows.Controls.TextBlock
        $note.Text = $r.Note; $note.TextWrapping = 'Wrap'; $note.FontSize = 11; $note.Foreground = $brushConverter.ConvertFromString('#A1A1AA')
        [void]$card.Children.Add($head); [void]$card.Children.Add($note)
        if ($r.CommandId -and ($null -ne $r.Bytes -or $r.NeedsAdmin)) {
            $cmd = (Get-AllowedCommands)[$r.CommandId]
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = if ($cmd.RequiresAdmin -and -not $isAdmin) { 'Restart as Administrator to run' } else { $cmd.Title }
            $btn.FontSize = 11; $btn.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4; $btn.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
            $btn.HorizontalAlignment = 'Left'; $btn.Tag = $r.CommandId
            $btn.add_Click({ param($s, $e) Invoke-CommandAction -Id $s.Tag })
            [void]$card.Children.Add($btn)
        }
        if ($r.Uri) {
            $open = New-Object System.Windows.Controls.Button
            $open.Content = 'Open Settings'; $open.FontSize = 11; $open.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
            $open.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0; $open.HorizontalAlignment = 'Left'; $open.Tag = $r.Uri
            $open.add_Click({ param($s, $e) Start-Process $s.Tag })
            [void]$card.Children.Add($open)
        }
        [void]$panelSystemSpace.Children.Add($card)
    }
}

# Recommended actions: biggest safe wins first, then commands and uninstalls
function Update-ActionCards {
    $panelActions.Children.Clear()
    $cands = New-Object System.Collections.ArrayList

    foreach ($item in ($global:ScannedCleanupItems | Where-Object { $_.RawBytes -ge 100MB -and $_.Type -ne 'RecycleBin' })) {
        $order = switch ($item.SafetyLevel) { 'Safe' { 0 } 'Optional' { 1 } default { 3 } }
        [void]$cands.Add([PSCustomObject]@{ Order = $order; Bytes = [long]$item.RawBytes; Title = $item.CategoryName; Safety = $item.SafetyLevel; Why = $item.Description
            Label = $(if ($item.CanSelect) { 'Clean...' } else { 'Needs administrator' }); Kind = 'Clean'; Item = $item; Rule = $null; Path = $item.Target })
    }
    if ($global:SpaceTree) {
        foreach ($node in (Get-BiggestFolders -Root $global:SpaceTree -Max 20 -MinBytes 500MB)) {
            $rule = Find-SpaceRule -Path $node.Path
            if ($rule -and $rule.Verdict -in 'Command', 'Uninstall') {
                $label = if ($rule.Verdict -eq 'Command') { (Get-AllowedCommands)[$rule.CommandId].Short } else { 'Open Settings' }
                if ($rule.CommandId -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) { $label = 'Start Docker to prune' }
                if ($rule.RequiresAdmin -and -not $isAdmin) { $label = 'Needs administrator' }
                [void]$cands.Add([PSCustomObject]@{ Order = $(if ($rule.Verdict -eq 'Command') { 2 } else { 4 }); Bytes = [long]$node.Bytes; Title = $rule.Title; Safety = $rule.Safety
                    Why = $(if ($rule.Effect) { "$($rule.What)`nEffect: $($rule.Effect)" } else { $rule.What }); Label = $label; Kind = $rule.Verdict; Item = $null; Rule = $rule; Path = $node.Path })
            }
        }
    }

    # Docker / WSL virtual disks that can give space back (found by registration, never by searching for .vhdx)
    foreach ($disk in (Get-CompactableDisks | Where-Object { $_.Bytes -ge 500MB })) {
        $drule = Find-SpaceRule -Path (Split-Path -Path $disk.Path -Parent)
        if ($drule) {
            [void]$cands.Add([PSCustomObject]@{ Order = 2; Bytes = [long]$disk.Bytes; Title = "Compact: $($disk.Name)"; Safety = 'Advanced'
                Why = "$($drule.What)`nEffect: $($drule.Effect)"; Label = $(if ($isAdmin) { 'Compact...' } else { 'Needs administrator' }); Kind = 'Command'; Item = $null; Rule = $drule; Path = $disk.Path })
        }
    }

    # Safe cleans first, but the biggest commands/uninstalls always get a place: they are often the largest lever
    $ranked = @($cands | Sort-Object -Property @{ Expression = { $_.Order } }, @{ Expression = { $_.Bytes }; Descending = $true })
    $lead = @($ranked | Select-Object -First 5)
    $bigActions = @($ranked | Where-Object { $_.Kind -ne 'Clean' -and $_ -notin $lead } | Sort-Object -Property Bytes -Descending | Select-Object -First 3)
    $top = @($lead + $bigActions)
    if ($top.Count -eq 0) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = if ($global:Jobs.scan -or $global:Jobs.action) { 'Recommendations appear when the scans finish.' } else { 'Nothing large to act on.' }
        $t.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $t.FontSize = 12; $t.TextWrapping = 'Wrap'
        [void]$panelActions.Children.Add($t)
        return
    }
    foreach ($c in $top) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = $brushConverter.ConvertFromString('#1B1B1F'); $card.BorderBrush = $brushConverter.ConvertFromString('#333338')
        $card.BorderThickness = New-Object System.Windows.Thickness 1; $card.CornerRadius = New-Object System.Windows.CornerRadius 6
        $card.Padding = New-Object System.Windows.Thickness 10, 8, 10, 8; $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.DockPanel
        $size = New-Object System.Windows.Controls.TextBlock
        $size.Text = if ($c.Kind -eq 'Clean') { Format-Bytes $c.Bytes } elseif ($c.Rule -and $c.Rule.CommandId -eq 'CompactDisk') { "File: $(Format-Bytes $c.Bytes)" } else { "Folder: $(Format-Bytes $c.Bytes)" }
        $size.FontWeight = 'Bold'; $size.Foreground = $brushConverter.ConvertFromString('#00B4D8')
        [System.Windows.Controls.DockPanel]::SetDock($size, 'Right')
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $c.Title; $title.FontWeight = 'SemiBold'; $title.TextTrimming = 'CharacterEllipsis'; $title.Foreground = $brushConverter.ConvertFromString('#EDEDED')
        [void]$head.Children.Add($size); [void]$head.Children.Add($title)
        $why = New-Object System.Windows.Controls.TextBlock
        $why.Text = $c.Why; $why.TextWrapping = 'Wrap'; $why.FontSize = 11; $why.MaxHeight = 62; $why.TextTrimming = 'CharacterEllipsis'
        $why.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $why.Margin = New-Object System.Windows.Thickness 0, 3, 0, 6
        $why.ToolTip = $c.Why
        $foot = New-Object System.Windows.Controls.DockPanel
        $badge = New-Object System.Windows.Controls.TextBlock
        $badge.Text = $c.Safety.ToUpper(); $badge.FontSize = 10; $badge.FontWeight = 'Bold'; $badge.VerticalAlignment = 'Center'
        $badge.Foreground = $brushConverter.ConvertFromString($(switch ($c.Safety) { 'Safe' { '#2EC4B6' } 'Optional' { '#FFB703' } 'Advanced' { '#FF8A80' } default { '#A1A1AA' } }))
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $c.Label; $btn.FontSize = 11; $btn.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4; $btn.Tag = $c
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        $btn.add_Click({ param($s, $e) Invoke-ActionCard $s.Tag })
        [void]$foot.Children.Add($btn); [void]$foot.Children.Add($badge)
        [void]$stack.Children.Add($head); [void]$stack.Children.Add($why); [void]$stack.Children.Add($foot)
        $card.Child = $stack
        [void]$panelActions.Children.Add($card)
    }
}

function Invoke-ActionCard {
    param($Card)
    if ($Card.Label -eq 'Needs administrator') { Restart-AsAdministrator; return }
    switch ($Card.Kind) {
        'Clean'     { Start-CleanCategory -Item $Card.Item }
        'Command'   { Invoke-CommandAction -Id $Card.Rule.CommandId -Param $Card.Rule.Param }
        'Uninstall' { Open-Settings -Rule $Card.Rule }
    }
}

function Open-Settings {
    param($Rule)
    $uri = if ($Rule.Uri) { $Rule.Uri } else { 'ms-settings:appsfeatures' }
    Start-Process $uri
    Log-Console "Opened Windows Settings for $($Rule.Title)." "SUCCESS"
}

# ---------------------------------------------------------------------------
# Admin: restart elevated, and run allow-listed commands
# ---------------------------------------------------------------------------

function Restart-AsAdministrator {
    if ($global:Jobs.action -or $global:Jobs.scan) {
        Show-Info "Wait for the running operation to finish (or cancel it), then restart as administrator."
        return
    }
    try {
        if ($PSCommandPath) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        } else {
            # Started from the web: there is no local file to relaunch, so the current release is fetched again
            if (-not (Confirm-Action "Diskman was started from the web, so there is no local file to relaunch.`n`nIt will download and run the current release from GitHub again, as administrator:`n$releaseUrl`n`nContinue?" 'Restart as Administrator' 'Question')) { return }
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', "irm '$releaseUrl' | iex")
        }
        Log-Console "Restarting as administrator..." "WARN"
        $window.Close()
    } catch {
        Log-Console "Administrator restart was cancelled or failed: $($_.Exception.Message)" "WARN"
    }
}

function Invoke-CommandAction {
    param([string]$Id, [string]$Param = $null)
    $cmd = (Get-AllowedCommands)[$Id]
    if (-not $cmd) { return }
    if ($Id -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) {
        Show-Info "Docker Desktop is not running, so there is nothing to prune yet.`n`nStart Docker Desktop, wait until its engine is running, then try again. To shrink the disk file itself, quit Docker Desktop and use Compact instead."
        return
    }
    if ($cmd.RequiresAdmin -and -not $isAdmin) { Restart-AsAdministrator; return }
    $detail = if ($Param) { "`n`nDisk: $Param" } else { '' }
    if (-not (Confirm-Action "$($cmd.Consent)$detail`n`nRun it now?" $cmd.Title 'Warning')) { return }
    Log-Console "Command approved by user: $($cmd.Title) ($($cmd.Exe) $($cmd.Args -join ' '))$(if ($Param) { " on $Param" })" "WARN"
    Start-BackgroundJob -Status $cmd.Title `
        -Vars @{ CmdId = $Id; CmdPath = $Param } `
        -Context @{ FreeBefore = (Get-DriveState).Free } `
        -Work { Invoke-AllowedCommand -Id $CmdId -Path $CmdPath -OnLine { param($t) $LogQueue.Enqueue(@($t, 'INFO')) } } `
        -OnDone {
            param($out, $ctx)
            $code = @($out) | Where-Object { $_ -is [int] } | Select-Object -Last 1
            Log-Console "Command finished (exit code $code). $driveLetter free space went from $(Format-Bytes $ctx.FreeBefore) to $(Format-Bytes (Get-DriveState).Free). Rescanning to show the new sizes." $(if ($code -eq 0) { 'SUCCESS' } else { 'WARN' })
            Start-SpaceScan
        }
}

# ---------------------------------------------------------------------------
# Selected-row action bar, shared by Overview and Space Explorer
# ---------------------------------------------------------------------------

function Set-ActionBar {
    param($Row, $Text, $OpenBtn, $ActionBtn, $CopyBtn = $null)
    $busy = [bool]$global:Jobs.action
    if (-not $Row) {
        $OpenBtn.IsEnabled = $false; $ActionBtn.IsEnabled = $false; $ActionBtn.Content = 'Action'
        if ($CopyBtn) { $CopyBtn.IsEnabled = $false }
        return
    }
    $rule = $Row.Rule
    $hasPath = [bool]$Row.Path -and (Test-Path -LiteralPath $Row.Path)
    $OpenBtn.IsEnabled = $hasPath
    if ($CopyBtn) { $CopyBtn.IsEnabled = [bool]$Row.Path }
    $what = if ($rule) { "$($rule.Title): $($rule.What)" } else { 'Not recognised. Open it in Explorer to decide; Diskman only offers deletion for folders it knows are safe.' }
    $Text.Text = "$($Row.Path)  -  $($Row.DisplaySize)`n$what"
    $Text.ToolTip = $Text.Text
    $label = 'Review only'; $enabled = $false
    if ($rule) {
        switch ($rule.Verdict) {
            'Clean'     { $label = 'Clean...'; $enabled = $true }
            'Command'   {
                $label = (Get-AllowedCommands)[$rule.CommandId].Short; $enabled = $true
                if ($rule.CommandId -eq 'DockerPrune' -and -not (Test-DockerEngineRunning)) { $label = 'Start Docker to prune' }
            }
            'Uninstall' { $label = 'Open Settings'; $enabled = $true }
            'System'    { $label = 'Windows-managed' }
        }
        if ($enabled -and $rule.RequiresAdmin -and -not $isAdmin) { $label = 'Needs administrator' }
    }
    $ActionBtn.Content = $label
    $ActionBtn.IsEnabled = $enabled -and -not $busy
}

function Show-OverviewSelection { Set-ActionBar -Row $gridTopFolders.SelectedItem -Text $txtOverviewSelected -OpenBtn $btnOverviewOpen -ActionBtn $btnOverviewAction }
function Show-SpaceSelection { Set-ActionBar -Row $gridSpace.SelectedItem -Text $txtSpaceSelected -OpenBtn $btnSpaceOpen -ActionBtn $btnSpaceAction -CopyBtn $btnSpaceCopy }

function Invoke-RowAction {
    param($Row)
    if (-not $Row -or -not $Row.Rule) { return }
    $rule = $Row.Rule
    if ($rule.RequiresAdmin -and -not $isAdmin) { Restart-AsAdministrator; return }
    switch ($rule.Verdict) {
        'Clean' {
            $item = $global:ScannedCleanupItems | Where-Object { $_.Id -eq $rule.TargetId } | Select-Object -First 1
            if ($item) { Start-CleanCategory -Item $item } else { Log-Console "Run Rescan first: the cleanup scan has no entry for $($rule.Title)." "WARN" }
        }
        'Command'   { Invoke-CommandAction -Id $rule.CommandId -Param $rule.Param }
        'Uninstall' { Open-Settings -Rule $rule }
    }
}

function Open-RowInExplorer {
    param($Row)
    if ($Row -and $Row.Path) {
        if (Test-Path -LiteralPath $Row.Path -PathType Leaf) { Show-ItemInExplorer -Path $Row.Path | Out-Null } else { Open-FolderInExplorer -Path $Row.Path | Out-Null }
        Log-Console "Opened in File Explorer: $($Row.Path)" "SUCCESS"
    }
}

# ---------------------------------------------------------------------------
# Space Explorer
# ---------------------------------------------------------------------------

function Set-SpaceNode {
    param($Node, [switch]$Reset)
    if ($Reset) { $global:SpaceStack.Clear() }
    [void]$global:SpaceStack.Add($Node)

    $panelCrumbs.Children.Clear()
    for ($i = 0; $i -lt $global:SpaceStack.Count; $i++) {
        $n = $global:SpaceStack[$i]
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = if ($i -eq 0) { $n.Path } else { $n.Name }
        $btn.Style = $window.FindResource('CrumbButton'); $btn.Tag = $i
        $btn.add_Click({ param($s, $e) Move-SpaceUp -ToIndex ([int]$s.Tag) })
        [void]$panelCrumbs.Children.Add($btn)
        if ($i -lt $global:SpaceStack.Count - 1) {
            $sep = New-Object System.Windows.Controls.TextBlock
            $sep.Text = '>'; $sep.Foreground = $brushConverter.ConvertFromString('#A1A1AA'); $sep.VerticalAlignment = 'Center'
            [void]$panelCrumbs.Children.Add($sep)
        }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($child in $Node.Children) { [void]$rows.Add((New-SpaceRow -Node $child -ParentBytes $Node.Bytes)) }
    if ($Node.OwnBytes -gt 0) {
        $own = [PSCustomObject]@{ Path = $Node.Path; Bytes = [long]$Node.OwnBytes; Files = [long]0; ModifiedTicks = 0 }
        $row = New-SpaceRow -Node $own -ParentBytes $Node.Bytes -Name '(files and small folders here)' -Display $Node.Path
        $row.Insight = ''; $row.FilesText = ''; $row.Rule = $null; $row.Node = $null
        [void]$rows.Add($row)
    }
    $gridSpace.ItemsSource = $rows
    Set-Empty $txtEmptyExplorer $rows
    if ($rows.Count -eq 0) { $txtEmptyExplorer.Text = 'This folder has nothing over 1 MB.' }
    $btnSpaceUp.IsEnabled = $global:SpaceStack.Count -gt 1
    if ($rows.Count -gt 0) { $gridSpace.SelectedIndex = 0 }
    Show-SpaceSelection
}

function Move-SpaceUp {
    param([int]$ToIndex = -1)
    if ($global:SpaceStack.Count -le 1) { return }
    if ($ToIndex -lt 0) { $ToIndex = $global:SpaceStack.Count - 2 }
    while ($global:SpaceStack.Count -gt $ToIndex + 1) { $global:SpaceStack.RemoveAt($global:SpaceStack.Count - 1) }
    $target = $global:SpaceStack[$global:SpaceStack.Count - 1]
    $global:SpaceStack.RemoveAt($global:SpaceStack.Count - 1)
    Set-SpaceNode -Node $target
}

function Enter-SpaceRow {
    $row = $gridSpace.SelectedItem
    if ($row -and $row.Node -is [Diskman.Node]) { Set-SpaceNode -Node $row.Node }
}

# ---------------------------------------------------------------------------
# Scans
# ---------------------------------------------------------------------------

function Start-SpaceScan {
    # A scan that is already running would show sizes from before the change that asked for a new one: queue exactly one more
    if ($global:Jobs.scan) {
        $global:RescanPending = $true
        Log-Console "A drive scan is already running; another will start when it finishes so the sizes are current." "WARN"
        return
    }
    Start-BackgroundJob -Slot scan -Status "Scanning the whole $driveLetter drive" `
        -Context @{} `
        -Work {
            $tree = Scan-DriveTree -Root "$($env:SystemDrive)\"
            # Everything that only reads the finished tree runs here, so the window never freezes at the end of a scan
            [PSCustomObject]@{ Tree = $tree; Detected = @(Find-AppCaches -Root $tree); Categories = (Get-SpaceCategory -Root $tree) }
        } `
        -OnDone {
            param($out, $ctx)
            $bundle = @($out) | Where-Object { $_.PSObject.Properties['Tree'] } | Select-Object -Last 1
            if ($bundle) { Show-ScanResults -Bundle $bundle -Partial ([bool]$ctx['Cancelled']) } else { Log-Console "The drive scan returned no data." "ERROR" }
            $again = $global:RescanPending -and -not $ctx['Cancelled']
            $global:RescanPending = $false
            if ($again) { Start-SpaceScan }
        }
}

# ---------------------------------------------------------------------------
# Cleaner tab
# ---------------------------------------------------------------------------

function Update-SelectedCleanupBadge {
    $totalSelectedBytes = 0
    $selectedCount = 0
    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.IsSelected -eq $true) { $totalSelectedBytes += $item.RawBytes; $selectedCount++ }
    }
    $txtCleanBadge.Text = "Selected: $(Format-Bytes -Bytes $totalSelectedBytes) ($selectedCount categories)"
}

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
    if ($gridCleanCategories.Items.Count -gt 0) { $gridCleanCategories.SelectedIndex = 0 }
}

# Full scan replaces the list; a partial scan (after cleaning) replaces only those rows.
function Set-ScanResults {
    param($Items, [switch]$Merge, [switch]$Quiet)

    $items = @($Items | Where-Object { $_ -and $_.Id })
    if ($Merge) {
        $ids = @($items | ForEach-Object { $_.Id })
        $kept = @($global:ScannedCleanupItems | Where-Object { $_.Id -notin $ids })
        $items = @($kept + $items) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    }
    if (-not $Merge -and -not $Quiet) {
        # A fresh scan of the fixed categories must not forget the app caches detected by the drive scan
        $items = @($items + @($global:ScannedCleanupItems | Where-Object { $_.Dynamic })) | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false }
    }
    $global:ScannedCleanupItems = [System.Collections.ArrayList]@($items)
    Apply-CleanupFilter $global:CurrentFilterGroup

    $previousId = if ($cmbInspectTarget.SelectedItem) { ($cmbInspectTarget.SelectedItem -split " - ")[0].Trim() } else { $null }
    $cmbInspectTarget.Items.Clear()
    $totalReclaimable = 0
    foreach ($item in $items) {
        $totalReclaimable += $item.RawBytes
        $dispLabel = if ($item.RawBytes -gt 0) { "$($item.Id) - $($item.CategoryName) ($($item.DisplaySize))" } else { "$($item.Id) - $($item.CategoryName)" }
        if (-not $item.Dynamic) { $cmbInspectTarget.Items.Add($dispLabel) | Out-Null }
        if (-not $Merge -and -not $Quiet -and $item.RawBytes -gt 0) {
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
    Update-FreeSafely
    Update-ActionCards
    Update-OverviewVerdict
    if (-not $Merge -and -not $Quiet) {
        Log-Console "Cleaner scan complete: $(Format-Bytes -Bytes $totalReclaimable) found across cleanup categories." "SUCCESS"
    }
}

function Start-ScanCJunk {
    param([string[]]$Id)
    Start-BackgroundJob -Status "Scanning cleanup categories" `
        -Vars @{ Ids = $Id } `
        -Context @{ Merge = [bool]$Id } `
        -Work { if ($Ids) { Scan-SmartCleanupItems -Id $Ids } else { Scan-SmartCleanupItems } } `
        -OnDone { param($out, $ctx) Set-ScanResults -Items $out -Merge:$ctx.Merge }
}

# Full rescan of everything: cleanup categories (action slot) and the whole-drive tree (scan slot)
function Start-FullRescan {
    Update-CDriveMetricsDisplay
    Start-ScanCJunk
    Start-SpaceScan
}

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
    $delta = if ($ctx.FreeBefore) { "$driveLetter free space went from $(Format-Bytes $ctx.FreeBefore) to $(Format-Bytes (Get-DriveState).Free)." } else { '' }
    Log-Console "CLEANUP FINISHED! Total space freed: $freed ($purged items purged). $delta" "SUCCESS"
    Show-Info "$($ctx.Title) complete.`n`nFreed space: $freed`nPurged items: $purged`n$delta`n`nThe Activity log (and the audit file in $global:AuditLogDir) lists anything that was skipped."
    # Detected app caches are not in the fixed list, so they are re-measured directly; fixed categories are rescanned by id
    foreach ($id in @($ctx.Ids | Where-Object { $_ -like 'App:*' })) {
        $item = $global:ScannedCleanupItems | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($item) { [void](Update-DetectedItemSize -Item $item) }
    }
    $fixedIds = @($ctx.Ids | Where-Object { $_ -notlike 'App:*' })
    if ($fixedIds.Count -gt 0) { Start-ScanCJunk -Id $fixedIds }
    else { Set-ScanResults -Items @($global:ScannedCleanupItems) -Quiet }
    if ($global:SpaceTree) { Start-SpaceScan }
}

function Start-BulkClean {
    param($Targets)
    $targetsToClean = @($Targets)
    $totalCleanBytes = [int64](($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum)
    if ($targetsToClean.Count -eq 0) {
        Show-Info "No items are selected for cleanup.`n`nTick the boxes next to the categories you want to clean."
        return
    }

    $safeCount = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Safe' }).Count
    $optCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Optional' }).Count
    $advCount  = @($targetsToClean | Where-Object { $_.SafetyLevel -eq 'Advanced' }).Count

    $breakdown = "Selected: $safeCount Safe, $optCount Optional, $advCount Advanced."
    if ($advCount -gt 0) { $breakdown += "`n`n[ADVANCED] Windows Update and servicing caches are selected. Diskman skips them while Windows Update, BITS or servicing reports activity or a pending reboot." }
    if ($optCount -gt 0) { $breakdown += "`n`n[OPTIONAL] Developer, offline media or Recycle Bin items are selected. Caches are re-downloaded on demand." }
    if (@($targetsToClean | Where-Object { $_.Type -eq 'RecycleBin' }).Count -gt 0) {
        $breakdown += "`n`n[RECYCLE BIN] Everything currently in the Recycle Bin will be permanently deleted. It cannot be restored."
    }

    $bullet = [char]0x2022
    $largest = ($targetsToClean | Sort-Object -Property RawBytes -Descending | Select-Object -First 10 | ForEach-Object { "$bullet $($_.CategoryName): $($_.DisplaySize)" }) -join "`n"
    if ($targetsToClean.Count -gt 10) { $largest += "`n$bullet ... and $($targetsToClean.Count - 10) more" }
    $confirmMsg = "Clean $(Format-Bytes -Bytes $totalCleanBytes) across $($targetsToClean.Count) categories on ${driveLetter}?`n`nLargest:`n$largest`n`n$breakdown`n`n" +
                  "What Diskman will and will not touch:`n" +
                  "$bullet Only the folders listed in the table are cleaned. Deleted files do NOT go to the Recycle Bin.`n" +
                  "$bullet Documents, Desktop, Downloads, Pictures, Music, Videos and OneDrive are blocked from bulk cleanup.`n" +
                  "$bullet Browser passwords, cookies, history and bookmarks are never deleted.`n" +
                  "$bullet Files that are in use are skipped and reported in the log.`n`n" +
                  "Clean now?"
    if (-not (Confirm-Action $confirmMsg "Confirm $driveLetter drive cleanup")) { return }

    Log-Console "=========================================================="
    Log-Console "Cleaning approved by user: $(Format-Bytes -Bytes $totalCleanBytes) in $($targetsToClean.Count) categories ($safeCount Safe, $optCount Optional, $advCount Advanced)"
    if (@($targetsToClean | Where-Object { $_.RequiresAdmin -eq $true }).Count -gt 0 -and -not $isAdmin) {
        Log-Console "Notice: Selected system items require Administrator rights and will be skipped." "WARN"
    }

    Start-BackgroundJob -Status "Cleaning $driveLetter drive" `
        -Vars @{ Items = $targetsToClean; TargetId = $null } `
        -Context @{ Title = "$driveLetter drive cleanup"; Ids = @($targetsToClean | ForEach-Object { $_.Id }); FreeBefore = (Get-DriveState).Free } `
        -Work $cleanupWork -OnDone $cleanupDone
}

function Start-CleanCategory {
    param($Item)
    if (-not $Item) { return }
    if ($Item.RawBytes -le 0) { Show-Info "The selected category ($($Item.CategoryName)) is already empty."; return }
    if (-not $Item.CanSelect) { Restart-AsAdministrator; return }

    $safetyText = if ($Item.SafetyExplanation) { $Item.SafetyExplanation } else { "Safe to delete. User files and credentials are untouched." }
    $deletedText = if ($Item.WhatGetsDeleted) { $Item.WhatGetsDeleted } else { $Item.Description }
    $consequencesText = if ($Item.Consequences) { $Item.Consequences } else { "Files auto-regenerate on next launch." }
    $badgeText = if ($Item.SafetyBadge) { $Item.SafetyBadge } else { $Item.SafetyLevel.ToUpper() }

    $dialogMsg = "Category: $($Item.CategoryName) [$badgeText]`n" +
                 "Size: $($Item.DisplaySize) ($($Item.FileCount))`n" +
                 "Path: $($Item.Target)`n`n" +
                 "[WHAT GETS DELETED]`n$deletedText`n`n" +
                 "[SAFETY & PROTECTED DATA]`n$safetyText`n`n" +
                 "[CONSEQUENCES & REBUILD]`n$consequencesText`n`n" +
                 "Deleted files do not go to the Recycle Bin. Proceed?"
    if (-not (Confirm-Action $dialogMsg "Confirm cleanup - $($Item.CategoryName)" 'Question')) { return }

    Log-Console "Cleaning approved by user: $($Item.CategoryName) ($($Item.DisplaySize)) at $(@($Item.Targets + $Item.Target | Where-Object { $_ } | Select-Object -Unique) -join '; ')" "WARN"
    # Every item goes through Invoke-ExecuteCleanup (detected ones are not known to Invoke-ExecuteCategoryCleanup)
    $Item.IsSelected = $true
    Start-BackgroundJob -Status "Purging $($Item.CategoryName)" `
        -Vars @{ Items = @($Item); TargetId = $null } `
        -Context @{ Title = $Item.CategoryName; Ids = @($Item.Id); FreeBefore = (Get-DriveState).Free } `
        -Work $cleanupWork -OnDone $cleanupDone
}

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------

$btnSelectRec.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        if (-not $item.CanSelect) { $item.IsSelected = $false }
        else { $item.IsSelected = ($item.Recommended -and $item.SafetyLevel -ne 'Advanced' -and $item.RawBytes -gt 0) }
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Applied recommended cleanup selection preset (Advanced and Optional targets excluded by default)."
})
$btnSelectAll.add_Click({
    foreach ($item in $global:ScannedCleanupItems) { $item.IsSelected = ($item.RawBytes -gt 0 -and $item.CanSelect) }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Selected all available junk categories."
})
$btnClearSel.add_Click({
    foreach ($item in $global:ScannedCleanupItems) { $item.IsSelected = $false }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Cleared all selections."
})
$gridCleanCategories.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ Update-SelectedCleanupBadge })

$btnFilterAll.add_Click({ Apply-CleanupFilter "All" })
$btnFilterSys.add_Click({ Apply-CleanupFilter "Windows & System" })
$btnFilterGaming.add_Click({ Apply-CleanupFilter "Gaming" })
$btnFilterDev.add_Click({ Apply-CleanupFilter "Developer" })
$btnFilterBrowser.add_Click({ Apply-CleanupFilter "Browser" })

$gridCleanCategories.add_SelectionChanged({
    $sel = $gridCleanCategories.SelectedItem
    if ($sel) {
        $txtSelectedCatTitle.Text = "$($sel.DisplayName)"
        $bullet = [char]0x2022
        $txtSelectedCatSizeInfo.Text = "$bullet Size: $($sel.DisplaySize) ($($sel.FileCount))"
        $txtSelectedCatSafetyBadge.Text = if ($sel.SafetyBadge) { $sel.SafetyBadge } else { $sel.SafetyLevel.ToUpper() }
        $badgeColor = switch ($sel.SafetyLevel) { 'Advanced' { "#C1121F" } 'Optional' { "#FFB703" } default { "#2EC4B6" } }
        $badgeSafetyLevel.Background = $brushConverter.ConvertFromString($badgeColor)
        $txtSelectedCatSafetyBadge.Foreground = $brushConverter.ConvertFromString($(if ($sel.SafetyLevel -eq 'Advanced') { '#FFFFFF' } else { '#141416' }))
        $txtCategoryWhatDeleted.Text = if ($sel.WhatGetsDeleted) { $sel.WhatGetsDeleted } else { $sel.Description }
        $txtCategorySafetyExp.Text = if ($sel.SafetyExplanation) { $sel.SafetyExplanation } else { "Safe to delete. User documents and credentials are untouched." }
        $txtCategoryConsequences.Text = if ($sel.Consequences) { $sel.Consequences } else { "Files will be regenerated or re-downloaded as needed." }
    }
})

$btnOpenCatInExplorer.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to open in File Explorer."; return }
    if ($sel.Type -eq "RecycleBin") {
        Start-Process "explorer.exe" -ArgumentList "shell:RecycleBinFolder"
        Log-Console "Opened Windows Recycle Bin in File Explorer." "SUCCESS"
    } elseif (Open-FolderInExplorer -Path $sel.Target) {
        Log-Console "Opened in File Explorer: $($sel.Target)" "SUCCESS"
    } else {
        Log-Console "Folder does not exist or is currently empty: $($sel.Target)" "WARN"
        Show-Info "The target folder ($($sel.Target)) does not exist or has no files."
    }
})

$btnInspectCatFiles.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to inspect its files."; return }
    if ($sel.Dynamic) {
        # Detected app caches are not in the Inspector's list: show the first folder in Explorer instead of loading some other category
        Open-FolderInExplorer -Path $sel.Target | Out-Null
        Log-Console "Opened $($sel.Target) in File Explorer (detected caches are not listed in the File Inspector)." "SUCCESS"
        return
    }
    for ($i = 0; $i -lt $cmbInspectTarget.Items.Count; $i++) {
        if ($cmbInspectTarget.Items[$i] -like "$($sel.Id) - *") { $cmbInspectTarget.SelectedIndex = $i; break }
    }
    $mainTabControl.SelectedItem = $tabInspector
    $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

$btnRunCleanup.add_Click({ Start-BulkClean -Targets @($global:ScannedCleanupItems | Where-Object { $_.IsSelected -eq $true -and $_.RawBytes -gt 0 }) })
$btnCleanSingleCategory.add_Click({
    $sel = $gridCleanCategories.SelectedItem
    if (-not $sel) { Show-Info "Select a category to clean."; return }
    Start-CleanCategory -Item $sel
})
$btnFreeSafely.add_Click({ Start-BulkClean -Targets (Get-SafeCleanItems) })

# File Inspector
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
            Set-Empty $txtEmptyInspector $files
            if ($files.Count -eq 0) { $txtEmptyInspector.Text = 'No files found in this category.' }
            $totalInspectBytes = [int64](($files | Measure-Object -Property RawBytes -Sum).Sum)
            $txtInspectSummary.Text = "Loaded $($files.Count) files (Total: $(Format-Bytes -Bytes $totalInspectBytes))"
            Log-Console "Loaded $($files.Count) files for $($ctx.TargetId) ($(Format-Bytes -Bytes $totalInspectBytes))" "SUCCESS"
        }
})
$gridInspectFiles.add_SelectionChanged({
    $sel = $gridInspectFiles.SelectedItem
    $txtSelectedInspectInfo.Text = if ($sel) { "$($sel.Name) ($($sel.DisplaySize)) - Path: $($sel.FullPath)" } else { "Select a file to inspect or delete." }
})
$btnRevealInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed in File Explorer: $($sel.FullPath)" "SUCCESS"
    } else { Show-Info "Select a valid file to reveal." }
})
$btnDeleteSingleInspectFile.add_Click({
    $sel = $gridInspectFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        if (Confirm-Action "Permanently delete file '$($sel.Name)' ($($sel.DisplaySize))?`n`nPath: $($sel.FullPath)" "Confirm file delete" 'Question') {
            $res = Remove-ItemPermanently -Path $sel.FullPath
            if ($res.Success) {
                Log-Console "Deleted file: $($sel.FullPath)" "SUCCESS"
                $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Failed to delete file: $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Error'
            }
        }
    }
})
$btnPurgeAllInspect.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    $targetId = ($selTargetStr -split " - ")[0].Trim()
    if (-not (Confirm-Action "Delete EVERYTHING in '$selTargetStr'?`n`nThis cleans the whole category, not only the files listed in this table. Deleted files do not go to the Recycle Bin." "Confirm clear all")) { return }
    Log-Console "Whole-category cleaning approved by user: $selTargetStr" "WARN"
    Start-BackgroundJob -Status "Purging $targetId" `
        -Vars @{ Items = $null; TargetId = $targetId } `
        -Context @{ Title = $targetId; Ids = @($targetId) } `
        -Work $cleanupWork -OnDone {
            param($out, $ctx)
            & $cleanupDone $out $ctx
            $gridInspectFiles.ItemsSource = @()
            Set-Empty $txtEmptyInspector @()
            $txtInspectSummary.Text = "Pick a category and click Load Files to list its biggest files."
        }
})

# Large Files
$cmbHuntSize.Items.Add("> 100 MB") | Out-Null
$cmbHuntSize.Items.Add("> 500 MB") | Out-Null
$cmbHuntSize.Items.Add("> 1 GB")   | Out-Null
$cmbHuntSize.Items.Add("> 5 GB")   | Out-Null
$cmbHuntSize.SelectedIndex = 0
foreach ($c in 'All Categories', 'Installer / Package', 'Disk Image / ISO', 'Archive / Zip', 'Video / Media', 'Log / Dump File', 'AI Model / Weights', 'Incomplete / Temp Download') { $cmbHuntCat.Items.Add($c) | Out-Null }
$cmbHuntCat.SelectedIndex = 0

$btnHuntScan.add_Click({
    $sizeMap = @{ "> 100 MB" = 100MB; "> 500 MB" = 500MB; "> 1 GB" = 1GB; "> 5 GB" = 5GB }
    $minSize = $sizeMap[$cmbHuntSize.SelectedItem]
    if (-not $minSize) { $minSize = 100MB }
    $cat = $cmbHuntCat.SelectedItem
    Start-BackgroundJob -Status "Hunting large files on $driveRoot ($($cmbHuntSize.SelectedItem) | $cat)" `
        -Vars @{ MinSize = $minSize; Cat = $cat; Root = $driveRoot } `
        -Work { Find-LargeFiles -TargetPath $Root -MinSizeBytes $MinSize -CategoryFilter $Cat -Limit 100 } `
        -OnDone {
            param($out)
            $files = @($out)
            $gridLargeFiles.ItemsSource = $files
            Set-Empty $txtEmptyHunter $files
            if ($files.Count -eq 0) { $txtEmptyHunter.Text = 'No matching files found. Try a lower minimum size or All Categories.' }
            Log-Console "Discovered $($files.Count) large files on the $driveLetter drive." "SUCCESS"
        }
})
$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    $txtSelectedLargeFile.Text = if ($sel) { "$($sel.Name) ($($sel.DisplaySize)) - $($sel.FullPath)" } else { "Select a large file to perform action." }
})
function Remove-HunterRow {
    param([string]$FullPath)
    $remaining = @($gridLargeFiles.ItemsSource | Where-Object { $_.FullPath -ne $FullPath })
    $gridLargeFiles.ItemsSource = $remaining
    Set-Empty $txtEmptyHunter $remaining
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
        if (Confirm-Action "Move this file to the Recycle Bin?`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)" "Move to Recycle Bin" 'Question') {
            $res = Send-ItemToRecycleBin -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Recycled file: $($sel.FullPath)" "SUCCESS"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not recycle $($sel.FullPath): $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Warning'
            }
        }
    }
})
$btnPermDeleteLargeFile.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        $diskImageNote = if ($sel.Category -eq 'Disk Image / ISO') { "`n`nDisk images can hold a whole virtual machine or OS install. Make sure you do not need it." } else { "" }
        if (Confirm-Action "PERMANENT DELETE`n`nThis cannot be undone and skips the Recycle Bin.`n`nFile: $($sel.FullPath)`nSize: $($sel.DisplaySize)`nType: $($sel.Category)$diskImageNote`n`nDelete it?" "Permanent delete") {
            $res = Remove-ItemPermanently -Path $sel.FullPath -SingleFile
            if ($res.Success) {
                Log-Console "Deleted file permanently: $($sel.FullPath)" "WARN"
                Remove-HunterRow $sel.FullPath
                Update-CDriveMetricsDisplay
            } else {
                Log-Console "Could not delete $($sel.FullPath): $($res.Message)" "ERROR"
                Show-Info $res.Message 'Diskman' 'Warning'
            }
        }
    }
})

# Overview and Space Explorer
$gridTopFolders.add_SelectionChanged({ Show-OverviewSelection })
$btnOverviewOpen.add_Click({ Open-RowInExplorer $gridTopFolders.SelectedItem })
$btnOverviewAction.add_Click({ Invoke-RowAction $gridTopFolders.SelectedItem })
$gridSpace.add_SelectionChanged({ Show-SpaceSelection })
$gridSpace.add_MouseDoubleClick({ Enter-SpaceRow })
$gridSpace.add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { Enter-SpaceRow; $e.Handled = $true }
    elseif ($e.Key -eq 'Back') { Move-SpaceUp; $e.Handled = $true }
})
$btnSpaceUp.add_Click({ Move-SpaceUp })
$btnSpaceOpen.add_Click({ Open-RowInExplorer $gridSpace.SelectedItem })
$btnSpaceCopy.add_Click({
    $row = $gridSpace.SelectedItem
    if ($row -and $row.Path) { [System.Windows.Clipboard]::SetText($row.Path); Log-Console "Copied path: $($row.Path)" "SUCCESS" }
})
$btnSpaceAction.add_Click({ Invoke-RowAction $gridSpace.SelectedItem })

# Header and status bar
$btnTopQuickScan.add_Click({ Start-FullRescan })
$btnScanClean.add_Click({ Start-ScanCJunk })
$btnCancelScan.add_Click({ Stop-BackgroundJob -Slot scan })
$btnCancelAction.add_Click({ Stop-BackgroundJob -Slot action })
$btnRestartAdmin.add_Click({ Restart-AsAdministrator })
$btnRestartAdmin.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
$txtLogLocation.Text = "Audit log: $global:AuditLogDir"

# Startup banner
Log-Console "=========================================================="
Log-Console "DISKMAN - DRIVE SPACE CLEANER ($driveLetter)"
Log-Console "Every action is logged here and in $global:AuditLogDir"
if ($isAdmin) {
    Log-Console "Elevated Administrator mode: system areas can be measured and cleaned." "SUCCESS"
} else {
    Log-Console "Standard mode: some system areas are skipped. Use Restart as Administrator for the full picture." "WARN"
}
Log-Console "=========================================================="

Apply-CleanupFilter "All"
Set-Empty $txtEmptyHunter @()
Set-Empty $txtEmptyInspector @()
Set-Empty $txtEmptyExplorer @()
Set-Empty $txtEmptyTop @()
$window.Title = "Diskman - $driveLetter drive space cleaner"
(Find-Control 'TxtBrandSub').Text = "  |  $driveLetter drive space cleaner"
Update-CDriveMetricsDisplay
Update-FreeSafely
Update-ActionCards

# Render the window immediately, then scan in the background
$window.add_ContentRendered({
    if (-not $global:ScanStarted) {
        $global:ScanStarted = $true
        Start-ScanCJunk
        Start-SpaceScan
    }
})

# Do not let the window close in the middle of a delete without asking
$window.add_Closing({
    param($sender, $e)
    if ($global:Jobs.action -or $global:Jobs.scan) {
        if (-not (Confirm-Action "An operation is still running. Closing now stops it part-way.`n`nClose anyway?" "Diskman")) { $e.Cancel = $true }
    }
})

# Show Window
$window.ShowDialog() | Out-Null
