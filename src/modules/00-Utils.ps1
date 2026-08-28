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

function Test-PathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Safe = $false; Reason = "Path is empty or null." }
    }

    $normalized = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    # 1. Block Drive Roots (e.g., C:, C:\, D:\)
    if ($normalized -match '^[A-Za-z]:$') {
        return @{ Safe = $false; Reason = "Drive roots cannot be deleted." }
    }

    # 2. Block Critical Windows Operating System Roots
    $blockedExactRoots = @(
        "C:\Windows",
        "C:\Windows\System32",
        "C:\Windows\SysWOW64",
        "C:\Windows\WinSxS",
        "C:\Windows\SystemApps",
        "C:\Windows\Boot",
        "C:\Windows\inf",
        "C:\Windows\Fonts",
        "C:\Windows\assembly",
        "C:\Windows\Microsoft.NET",
        "C:\Program Files",
        "C:\Program Files (x86)",
        "C:\ProgramData",
        "C:\Users",
        "C:\Recovery",
        "C:\System Volume Information"
    )

    foreach ($blocked in $blockedExactRoots) {
        if ($normalized -ieq $blocked.TrimEnd('\')) {
            return @{ Safe = $false; Reason = "Path is a protected system root ($blocked)." }
        }
    }

    # 3. Block User Personal Data Folders (Desktop, Documents, Pictures, Videos, Music)
    $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $blockedUserFolders = @(
        $userProfile,
        (Join-Path $userProfile "Desktop"),
        (Join-Path $userProfile "Documents"),
        (Join-Path $userProfile "Pictures"),
        (Join-Path $userProfile "Videos"),
        (Join-Path $userProfile "Music"),
        (Join-Path $userProfile "Contacts"),
        (Join-Path $userProfile "Favorites"),
        (Join-Path $userProfile "Saved Games"),
        (Join-Path $userProfile "OneDrive")
    )

    foreach ($uFolder in $blockedUserFolders) {
        if ($normalized -ieq $uFolder) {
            return @{ Safe = $false; Reason = "Path is a protected user personal data directory ($uFolder)." }
        }
    }

    # 4. Block Critical System Boot & Virtual Memory Files
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

    if ($fileName -in $blockedSystemFiles) {
        return @{ Safe = $false; Reason = "Protected Windows system kernel/boot file ($fileName)." }
    }

    # 5. Block Browser Sensitive Files (Passwords, Cookies, History, Bookmarks)
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
        return @{ Safe = $false; Reason = "Protected user browser profile data ($fileName)." }
    }

    return @{ Safe = $true; Reason = "OK" }
}
