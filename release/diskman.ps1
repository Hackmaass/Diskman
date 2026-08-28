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
        [int]$Limit = 100
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return @()
    }

    $results = @()

    $installerExt = @(".exe", ".msi", ".pkg", ".appinstaller", ".cab")
    $diskExt      = @(".iso", ".vhd", ".vhdx", ".img", ".vmdk", ".qcow2")
    $archiveExt   = @(".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz")
    $videoExt     = @(".mp4", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv", ".m4v", ".ts")
    $aiExt        = @(".bin", ".safetensors", ".gguf", ".pt", ".pth", ".onnx", ".model", ".h5", ".ckpt")
    $logExt       = @(".log", ".dmp", ".trace", ".etl", ".bak", ".old")
    $dataExt      = @(".csv", ".parquet", ".db", ".sqlite", ".sql")

    $dirQueue = New-Object System.Collections.Generic.Queue[string]
    $dirQueue.Enqueue($TargetPath)

    $scannedFolders = 0
    $maxFolders = 2500 # safeguard against infinite loops or slow drives

    while ($dirQueue.Count -gt 0 -and $scannedFolders -lt $maxFolders) {
        $currentDir = $dirQueue.Dequeue()
        $scannedFolders++

        # Skip system protected folders
        if ($currentDir -match '\\\$RECYCLE\.BIN|\\System Volume Information|\\AppData\\Local\\Application Data|\\Windows\\WinSxS|\\Windows\\System32') {
            continue
        }

        try {
            $dInfo = New-Object System.IO.DirectoryInfo($currentDir)
            
            # Check direct files
            $files = $dInfo.GetFiles()
            foreach ($f in $files) {
                if ($f.Length -ge $MinSizeBytes) {
                    $ext = $f.Extension.ToLower()
                    $cat = "Other File"

                    if ($ext -in $installerExt) { $cat = "Installer / Package" }
                    elseif ($ext -in $diskExt) { $cat = "Disk Image / ISO" }
                    elseif ($ext -in $archiveExt) { $cat = "Archive / Zip" }
                    elseif ($ext -in $videoExt) { $cat = "Video / Media" }
                    elseif ($ext -in $logExt) { $cat = "Log / Dump File" }
                    elseif ($ext -in $aiExt) { $cat = "AI Model / Weights" }
                    elseif ($ext -in $dataExt) { $cat = "Dataset / Database" }

                    if ($CategoryFilter -eq "All Categories" -or $cat -like "*$CategoryFilter*") {
                        $results += [PSCustomObject]@{
                            Name          = $f.Name
                            FullPath      = $f.FullName
                            RawSize       = $f.Length
                            DisplaySize   = Format-Bytes -Bytes $f.Length
                            Category      = $cat
                            LastWriteTime = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                            Extension     = $ext
                        }
                    }
                }
            }

            # Enqueue subdirectories
            foreach ($sub in $dInfo.GetDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    continue # Skip symlinks/junctions
                }
                $dirQueue.Enqueue($sub.FullName)
            }
        } catch {
            # Skip unauthorized folders quietly
            continue
        }

        if ($results.Count -ge ($Limit * 2)) {
            break
        }
    }

    return ($results | Sort-Object RawSize -Descending | Select-Object -First $Limit)
}


# --- Module: Get-DriveMetrics.ps1 ---
function Get-DriveMetrics {
    [CmdletBinding()]
    param()

    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable) }
    $metrics = @()

    foreach ($d in $drives) {
        $totalGB = [math]::Round($d.TotalSize / 1GB, 2)
        $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 2)
        $usedGB = [math]::Round(($d.TotalSize - $d.AvailableFreeSpace) / 1GB, 2)
        $usedPercent = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 1) } else { 0 }
        $freePercent = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }

        $volLabel = if ([string]::IsNullOrWhiteSpace($d.VolumeLabel)) { "Local Disk" } else { $d.VolumeLabel }
        $letter = $d.Name.TrimEnd('\')

        # Status color
        $statusColor = if ($usedPercent -ge 90) { "#FF4D6D" } elseif ($usedPercent -ge 75) { "#FFB703" } else { "#00F5A0" }
        $statusText = if ($usedPercent -ge 90) { "Critical (Low Space)" } elseif ($usedPercent -ge 75) { "High Usage" } else { "Healthy" }

        $metrics += [PSCustomObject]@{
            DriveLetter   = $letter
            RootPath      = $d.Name
            VolumeLabel   = $volLabel
            DisplayName   = "$volLabel ($letter)"
            FileSystem    = $d.DriveFormat
            TotalGB       = $totalGB
            UsedGB        = $usedGB
            FreeGB        = $freeGB
            UsedPercent   = $usedPercent
            FreePercent   = $freePercent
            StatusColor   = $statusColor
            StatusText    = $statusText
            RawTotal      = $d.TotalSize
            RawFree       = $d.AvailableFreeSpace
            RawUsed       = ($d.TotalSize - $d.AvailableFreeSpace)
        }
    }

    return $metrics
}

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
            $freePercent = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }

            $statusColor = if ($usedPercent -ge 90) { "#FF4D6D" } elseif ($usedPercent -ge 75) { "#FFB703" } else { "#00F5A0" }
            $statusText = if ($usedPercent -ge 90) { "Critical (Low Space)" } elseif ($usedPercent -ge 75) { "High Usage" } else { "Healthy" }

            return [PSCustomObject]@{
                DriveLetter   = "C:"
                RootPath      = "C:\"
                VolumeLabel   = if ([string]::IsNullOrWhiteSpace($cDrive.VolumeLabel)) { "Local Disk" } else { $cDrive.VolumeLabel }
                FileSystem    = $cDrive.DriveFormat
                TotalGB       = $totalGB
                UsedGB        = $usedGB
                FreeGB        = $freeGB
                UsedPercent   = $usedPercent
                FreePercent   = $freePercent
                StatusColor   = $statusColor
                StatusText    = $statusText
                RawTotal      = $cDrive.TotalSize
                RawFree       = $cDrive.AvailableFreeSpace
                RawUsed       = ($cDrive.TotalSize - $cDrive.AvailableFreeSpace)
                DisplayTotal  = Format-Bytes -Bytes $cDrive.TotalSize
                DisplayFree   = Format-Bytes -Bytes $cDrive.AvailableFreeSpace
                DisplayUsed   = Format-Bytes -Bytes ($cDrive.TotalSize - $cDrive.AvailableFreeSpace)
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
        # If folder doesn't exist yet, try opening parent folder
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
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Safety checks - Never allow deleting system roots
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows(\\|$)|^[A-Za-z]:\\Program Files(\\|$)|^[A-Za-z]:\\Program Files \(x86\)(\\|$)|^[A-Za-z]:\\Users$') {
        return @{ Success = $false; Message = "Protected system paths cannot be deleted." }
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
        return @{ Success = $false; Message = "Failed to recycle: $_" }
    }
}

function Remove-ItemPermanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Safety checks
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows(\\|$)|^[A-Za-z]:\\Program Files(\\|$)|^[A-Za-z]:\\Program Files \(x86\)(\\|$)|^[A-Za-z]:\\Users$') {
        return @{ Success = $false; Message = "Protected system paths cannot be deleted." }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return @{ Success = $true; Message = "Item permanently deleted." }
    } catch {
        return @{ Success = $false; Message = "Delete failed: $_" }
    }
}


# --- Module: Invoke-SmartCleanup.ps1 ---
function Get-FolderSizeFast {
    param(
        [string]$Path,
        [int]$MaxItems = 15000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ RawBytes = [long]0; FileCount = 0; Exists = $false }
    }

    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $folder = $fso.GetFolder($Path)
        $totalBytes = [long]$folder.Size
        $count = $folder.Files.Count + $folder.SubFolders.Count
        return @{ RawBytes = $totalBytes; FileCount = $count; Exists = $true }
    } catch {
        # High speed .NET EnumerateFiles fallback
        try {
            $totalBytes = [long]0
            $count = 0
            $dirInfo = New-Object System.IO.DirectoryInfo($Path)
            $files = $dirInfo.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)
            foreach ($f in $files) {
                $totalBytes += $f.Length
                $count++
                if ($count -ge $MaxItems) { break }
            }
            return @{ RawBytes = $totalBytes; FileCount = $count; Exists = $true }
        } catch {
            return @{ RawBytes = [long]0; FileCount = 0; Exists = $true }
        }
    }
}

function Get-CleanableTargets {
    [CmdletBinding()]
    param()

    $userTempPath = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    $appData      = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData)
    $userProfile  = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)

    $targets = @(
        @{
            Id          = 'UserTemp'
            Group       = 'Windows & System'
            Category    = 'Windows User Temp'
            Icon        = '[TEMP]'
            Path        = $userTempPath
            Description = 'Temporary application and cache files created by running user programs'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'SystemTemp'
            Group       = 'Windows & System'
            Category    = 'Windows System Temp'
            Icon        = '[SYS]'
            Path        = 'C:\Windows\Temp'
            Description = 'Operating system temporary cache files (C:\Windows\Temp)'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'WinUpdateCache'
            Group       = 'Windows & System'
            Category    = 'Windows Update Cache'
            Icon        = '[UPDATE]'
            Path        = 'C:\Windows\SoftwareDistribution\Download'
            Description = 'Already-downloaded and applied Windows Update installation payloads'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'DeliveryOpt'
            Group       = 'Windows & System'
            Category    = 'Delivery Optimization Files'
            Icon        = '[OPT]'
            Path        = 'C:\Windows\SoftwareDistribution\DeliveryOptimization'
            Description = 'Cached Windows peer-to-peer delivery optimization chunks'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'CrashDumps'
            Group       = 'Windows & System'
            Category    = 'Crash Dumps & Minidumps'
            Icon        = '[DUMP]'
            Path        = (Join-Path $localAppData 'CrashDumps')
            Description = 'Application crash dumps (.dmp files) from previously crashed applications'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'WERLogs'
            Group       = 'Windows & System'
            Category    = 'Windows Error Reports (WER)'
            Icon        = '[LOG]'
            Path        = (Join-Path $localAppData 'Microsoft\Windows\WER')
            Description = 'Queued and archived Windows error reporting telemetry data'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'CbsLogs'
            Group       = 'Windows & System'
            Category    = 'Windows CBS & Component Logs'
            Icon        = '[LOG]'
            Path        = 'C:\Windows\Logs\CBS'
            Description = 'Old Windows Component-Based Servicing installation log files'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'DismLogs'
            Group       = 'Windows & System'
            Category    = 'DISM & Servicing Logs'
            Icon        = '[LOG]'
            Path        = 'C:\Windows\Logs\DISM'
            Description = 'Deployment Image Servicing and Management log files'
            Type        = 'DirectoryContents'
            SafetyLevel = '100% Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'PipCache'
            Group       = 'Developer Caches'
            Category    = 'Python Pip Wheel Cache'
            Icon        = '[PIP]'
            Path        = (Join-Path $localAppData 'pip\cache')
            Description = 'Cached Python wheel binaries and download archives'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'NpmCache'
            Group       = 'Developer Caches'
            Category    = 'Node.js NPM Cache'
            Icon        = '[NPM]'
            Path        = (Join-Path $appData 'npm-cache')
            Description = 'Global Node Package Manager download cache'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'YarnCache'
            Group       = 'Developer Caches'
            Category    = 'Yarn Package Cache'
            Icon        = '[YARN]'
            Path        = (Join-Path $localAppData 'Yarn\Cache')
            Description = 'Yarn package manager cached archives'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'NugetCache'
            Group       = 'Developer Caches'
            Category    = 'NuGet / .NET Cache'
            Icon        = '[NUGET]'
            Path        = (Join-Path $userProfile '.nuget\packages')
            Description = 'Local cache of downloaded NuGet packages'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Optional'
            Recommended = $false
            RequiresAdmin = $false
        },
        @{
            Id          = 'ChromeCache'
            Group       = 'Browser & App Caches'
            Category    = 'Google Chrome Web Cache'
            Icon        = '[CHROME]'
            Path        = (Join-Path $localAppData 'Google\Chrome\User Data\Default\Cache')
            Description = 'Cached web pages, images, and script assets in Google Chrome'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'EdgeCache'
            Group       = 'Browser & App Caches'
            Category    = 'Microsoft Edge Web Cache'
            Icon        = '[EDGE]'
            Path        = (Join-Path $localAppData 'Microsoft\Edge\User Data\Default\Cache')
            Description = 'Cached media and webpage assets in Microsoft Edge'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'BraveCache'
            Group       = 'Browser & App Caches'
            Category    = 'Brave Browser Cache'
            Icon        = '[BRAVE]'
            Path        = (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
            Description = 'Cached web data in Brave Browser'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $false
            RequiresAdmin = $false
        },
        @{
            Id          = 'DiscordCache'
            Group       = 'Browser & App Caches'
            Category    = 'Discord App Cache'
            Icon        = '[DISCORD]'
            Path        = (Join-Path $appData 'discord\Cache')
            Description = 'Cached Discord media, avatars, and attachments'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'SpotifyCache'
            Group       = 'Browser & App Caches'
            Category    = 'Spotify Track Storage'
            Icon        = '[SPOTIFY]'
            Path        = (Join-Path $localAppData 'Spotify\Storage')
            Description = 'Locally cached music streams and playback buffers in Spotify'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $false
            RequiresAdmin = $false
        },
        @{
            Id          = 'VsCodeCache'
            Group       = 'Browser & App Caches'
            Category    = 'VS Code Editor Cache'
            Icon        = '[VSCODE]'
            Path        = (Join-Path $appData 'Code\Cache')
            Description = 'VS Code editor cached runtime files and buffers'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'RecycleBin'
            Group       = 'Recycle Bin'
            Category    = 'Windows Recycle Bin (C:)'
            Icon        = '[TRASH]'
            Path        = 'C:\$Recycle.Bin'
            Description = 'Deleted files and folders residing in the Windows Recycle Bin'
            Type        = 'RecycleBin'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        }
    )

    return $targets
}

function Scan-SmartCleanupItems {
    [CmdletBinding()]
    param()

    $targets = Get-CleanableTargets
    $results = @()

    foreach ($t in $targets) {
        $rawBytes = [long]0
        $fileCount = 0
        $pathExists = $false

        if ($t.Type -eq 'RecycleBin') {
            $stats = Get-FolderSizeFast -Path 'C:\$Recycle.Bin'
            $rawBytes = $stats.RawBytes
            $fileCount = $stats.FileCount
            $pathExists = $stats.Exists
        } else {
            $stats = Get-FolderSizeFast -Path $t.Path
            $rawBytes = $stats.RawBytes
            $fileCount = $stats.FileCount
            $pathExists = $stats.Exists
        }

        $disp = Format-Bytes -Bytes $rawBytes
        $isSelected = ($t.Recommended -and $rawBytes -gt 0)

        $results += [PSCustomObject]@{
            Id            = $t.Id
            Group         = $t.Group
            CategoryName  = $t.Category
            Icon          = $t.Icon
            DisplayName   = $t.Category
            Target        = $t.Path
            Type          = $t.Type
            SafetyLevel   = $t.SafetyLevel
            RawBytes      = [long]$rawBytes
            DisplaySize   = $disp
            FileCount     = "$fileCount items"
            RawCount      = [int]$fileCount
            Description   = $t.Description
            Recommended   = [bool]$t.Recommended
            RequiresAdmin = [bool]$t.RequiresAdmin
            IsSelected    = [bool]$isSelected
            PathExists    = [bool]$pathExists
        }
    }

    return $results
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

    $fileList = @()

    if (Test-Path -LiteralPath $target.Path) {
        try {
            $dirInfo = New-Object System.IO.DirectoryInfo($target.Path)
            $files = $dirInfo.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)
            $count = 0
            foreach ($f in $files) {
                if ($count -ge $Limit) { break }
                $fileList += [PSCustomObject]@{
                    Name          = $f.Name
                    FullPath      = $f.FullName
                    RawBytes      = [long]$f.Length
                    DisplaySize   = Format-Bytes -Bytes $f.Length
                    LastWriteTime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    Extension     = $f.Extension
                }
                $count++
            }
        } catch {}
    }

    return ($fileList | Sort-Object RawBytes -Descending)
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

    foreach ($item in $SelectedItems) {
        if (-not $item.IsSelected) { continue }

        if ($null -ne $OnProgress) {
            & $OnProgress "Starting purge of $($item.CategoryName) ($($item.DisplaySize))..." "INFO"
        }

        # Handle Windows Services file locks
        $restartedServices = @()
        if ($item.Id -eq 'WinUpdateCache') {
            if ($null -ne $OnProgress) {
                & $OnProgress "  -> Temporarily releasing Windows Update service lock (wuauserv)..." "INFO"
            }
            try {
                Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
                $restartedServices += "wuauserv"
            } catch {}
            try {
                Stop-Service -Name "bits" -Force -ErrorAction SilentlyContinue
                $restartedServices += "bits"
            } catch {}
        } elseif ($item.Id -eq 'DeliveryOpt') {
            try {
                Stop-Service -Name "DoSvc" -Force -ErrorAction SilentlyContinue
                $restartedServices += "DoSvc"
            } catch {}
        }

        if ($item.Type -eq 'RecycleBin') {
            try {
                if ($null -ne $OnProgress) {
                    & $OnProgress "Clearing Windows Recycle Bin..." "INFO"
                }
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                $totalFreedBytes += $item.RawBytes
                $totalDeletedCount += $item.RawCount
                $msg = "Emptied Recycle Bin (Freed $(Format-Bytes -Bytes $item.RawBytes))"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "SUCCESS"
                }
            } catch {
                $msg = "Notice: Recycle Bin purge completed with warnings: $_"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "WARN"
                }
            }
            continue
        }

        $targetPath = $item.Target
        if (Test-Path -LiteralPath $targetPath) {
            $initialCategoryBytes = $item.RawBytes
            $catFreedBytes = [long]0
            $catDeletedCount = 0
            $catSkippedCount = 0

            try {
                $itemsToClean = Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $totalInCat = ($itemsToClean | Measure-Object).Count

                foreach ($entry in $itemsToClean) {
                    $entryBytes = [long]0
                    $entryDeleted = $false

                    try {
                        if ($entry.PSIsContainer) {
                            $entryBytes = (Get-FolderSizeFast -Path $entry.FullName).RawBytes
                            
                            # Remove readonly attributes if present
                            try {
                                $attr = [System.IO.File]::GetAttributes($entry.FullName)
                                if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
                                    [System.IO.File]::SetAttributes($entry.FullName, [System.IO.FileAttributes]::Normal)
                                }
                            } catch {}

                            try {
                                [System.IO.Directory]::Delete($entry.FullName, $true)
                                $entryDeleted = $true
                            } catch {
                                # Fallback 1: cmd rmdir
                                try {
                                    cmd.exe /c "rmdir /s /q `"$($entry.FullName)`"" 2>$null
                                    if (-not (Test-Path -LiteralPath $entry.FullName)) {
                                        $entryDeleted = $true
                                    }
                                } catch {}

                                # Fallback 2: PowerShell Remove-Item
                                if (-not $entryDeleted) {
                                    try {
                                        Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
                                        $entryDeleted = $true
                                    } catch {}
                                }
                            }
                        } else {
                            $entryBytes = [long]$entry.Length
                            
                            try {
                                [System.IO.File]::SetAttributes($entry.FullName, [System.IO.FileAttributes]::Normal)
                            } catch {}

                            try {
                                [System.IO.File]::Delete($entry.FullName)
                                $entryDeleted = $true
                            } catch {
                                try {
                                    Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
                                    $entryDeleted = $true
                                } catch {}
                            }
                        }

                        if ($entryDeleted) {
                            $catDeletedCount++
                            $catFreedBytes += $entryBytes

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

                    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
                }

                # Restart services if stopped
                foreach ($svc in $restartedServices) {
                    try {
                        Start-Service -Name $svc -ErrorAction SilentlyContinue
                        if ($null -ne $OnProgress) {
                            & $OnProgress "  -> Restored service $svc" "INFO"
                        }
                    } catch {}
                }

                # If individual sizes couldn't be measured individually but items were removed, fall back
                if ($catFreedBytes -le 0 -and $catDeletedCount -gt 0) {
                    $catFreedBytes = $initialCategoryBytes
                }

                $totalFreedBytes += $catFreedBytes
                $totalDeletedCount += $catDeletedCount

                $freedFormatted = Format-Bytes -Bytes $catFreedBytes
                $msg = "Purged $($item.CategoryName): Cleaned $catDeletedCount items (Freed $freedFormatted)"
                if ($catSkippedCount -gt 0) {
                    $msg += " [$catSkippedCount locked items skipped]"
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

    $targets = Scan-SmartCleanupItems
    $item = $targets | Where-Object { $_.Id -eq $TargetId } | Select-Object -First 1
    if (-not $item) {
        return @{ Success = $false; Message = 'Target category not found.' }
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
        MinHeight="650" MinWidth="950"
        WindowStartupLocation="CenterScreen"
        Background="#141416"
        Foreground="#EDEDED"
        FontFamily="Segoe UI, -apple-system, BlinkMacSystemFont, Roboto, sans-serif"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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

        <!-- ComboBox Dark Style -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#202026"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="145"/>
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
                            <TextBlock x:Name="TxtCBarStatus" Text="Drive C: Volume" FontSize="11" Foreground="#A1A1AA" HorizontalAlignment="Left"/>
                            <TextBlock x:Name="TxtCBarPercent" Text="-- % Used" FontSize="11" FontWeight="Bold" Foreground="#00B4D8" HorizontalAlignment="Right"/>
                        </Grid>
                        <ProgressBar x:Name="ProgressCDrive" Height="10" Value="50" Maximum="100"/>
                    </StackPanel>

                    <StackPanel Grid.Column="4" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <TextBlock Text="Reclaimable Junk on C:" Foreground="#A1A1AA" FontSize="11" HorizontalAlignment="Right"/>
                        <TextBlock x:Name="TxtCReclaimable" Text="~0.00 GB" FontSize="16" FontWeight="Bold" Foreground="#00B4D8" HorizontalAlignment="Right" Margin="0,2,0,0"/>
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

                    <!-- Presets & Actions Toolbar -->
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <!-- Selection Presets -->
                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="BtnSelectRecommended" Content="Select Recommended" Margin="0,0,6,0"/>
                            <Button x:Name="BtnSelectAll" Content="Select All" Margin="0,0,6,0"/>
                            <Button x:Name="BtnClearSelection" Content="Clear All" Margin="0,0,16,0"/>

                            <!-- Filter Chips -->
                            <TextBlock Text="Filter:" Foreground="#71717A" VerticalAlignment="Center" Margin="0,0,6,0" FontSize="11"/>
                            <Button x:Name="BtnFilterAll" Content="All" Margin="0,0,4,0" Padding="10,5" FontSize="11"/>
                            <Button x:Name="BtnFilterSystem" Content="System &amp; Temp" Margin="0,0,4,0" Padding="10,5" FontSize="11"/>
                            <Button x:Name="BtnFilterDev" Content="Developer" Margin="0,0,4,0" Padding="10,5" FontSize="11"/>
                            <Button x:Name="BtnFilterBrowser" Content="Browser &amp; Apps" Margin="0,0,4,0" Padding="10,5" FontSize="11"/>
                        </StackPanel>

                        <!-- Right Scan & Clean Buttons -->
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock x:Name="TxtCleanSelectedBadge" Text="Selected: 0.00 GB" FontWeight="Bold" Foreground="#00B4D8" VerticalAlignment="Center" Margin="0,0,12,0" FontSize="13"/>
                            <Button x:Name="BtnScanCleanable" Content="Scan Junk" Margin="0,0,8,0"/>
                            <Button x:Name="BtnRunCleanup" Content="Clean Selected Junk" Style="{StaticResource DangerActionBtn}"/>
                        </StackPanel>
                    </Grid>

                    <!-- Junk Categories DataGrid -->
                    <DataGrid x:Name="GridCleanableCategories" Grid.Row="1" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="Clean?" Binding="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" Width="55"/>
                            <DataGridTextColumn Header="Category" Binding="{Binding DisplayName}" Width="240" FontWeight="SemiBold"/>
                            <DataGridTextColumn Header="Group" Binding="{Binding Group}" Width="140"/>
                            <DataGridTextColumn Header="Size on C:" Binding="{Binding DisplaySize}" Width="105" FontWeight="Bold" Foreground="#00B4D8"/>
                            <DataGridTextColumn Header="Items" Binding="{Binding FileCount}" Width="95"/>
                            <DataGridTextColumn Header="Safety" Binding="{Binding SafetyLevel}" Width="100"/>
                            <DataGridTextColumn Header="Path on C: Drive" Binding="{Binding Target}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Bottom Action Controls for Selected Category -->
                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock x:Name="TxtSelectedCategoryInfo" Text="Select a category above to view files in File Explorer or clean individually." Foreground="#A1A1AA" FontSize="12"/>
                            <TextBlock x:Name="TxtSelectedCategoryDesc" Text="" Foreground="#71717A" FontSize="11" Margin="0,2,0,0"/>
                        </StackPanel>

                        <!-- Step 1: Open in Explorer (User requirement) -->
                        <Button x:Name="BtnOpenCategoryInExplorer" Grid.Column="1" Content="Open in File Explorer" Style="{StaticResource PrimaryActionBtn}" Margin="0,0,8,0"/>
                        <!-- Step 2: In-app File Inspector -->
                        <Button x:Name="BtnInspectCategoryFiles" Grid.Column="2" Content="View Files in Inspector" Margin="0,0,8,0"/>
                        <!-- Step 3: Clean Single Category -->
                        <Button x:Name="BtnCleanSingleCategory" Grid.Column="3" Content="Clean Category" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
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
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" Width="100" FontWeight="SemiBold" Foreground="#00B4D8"/>
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
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" Width="100" FontWeight="Bold" Foreground="#00B4D8"/>
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
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" Width="100" FontWeight="SemiBold" Foreground="#00B4D8"/>
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

# Live Console Logger Function (Streams to Terminal + GUI + Pumps Dispatcher)
function Log-Console {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = "[+]"
    $hostColor = "Cyan"
    if ($Level -eq "SUCCESS") { $prefix = "[OK]"; $hostColor = "Green" }
    elseif ($Level -eq "WARN") { $prefix = "[!]"; $hostColor = "Yellow" }
    elseif ($Level -eq "ERROR") { $prefix = "[X]"; $hostColor = "Red" }
    
    $logLine = "$timestamp $prefix $Message"
    
    # 1. Real-time stream to Terminal console
    try {
        Write-Host "$timestamp " -NoNewline -ForegroundColor DarkGray
        Write-Host "$prefix " -NoNewline -ForegroundColor $hostColor
        Write-Host $Message -ForegroundColor White
    } catch {}
    
    # 2. Append to in-app WPF Console Box
    $txtConsole = Find-Control "TxtConsoleLog"
    if ($txtConsole) {
        $txtConsole.AppendText("$logLine`r`n")
        $txtConsole.ScrollToEnd()
    }

    # 3. Message pump to keep WPF UI responsive and prevent freezing
    try {
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
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
$btnFilterDev              = Find-Control "BtnFilterDev"
$btnFilterBrowser          = Find-Control "BtnFilterBrowser"
$txtCleanBadge             = Find-Control "TxtCleanSelectedBadge"
$btnScanClean              = Find-Control "BtnScanCleanable"
$btnRunCleanup             = Find-Control "BtnRunCleanup"
$gridCleanCategories       = Find-Control "GridCleanableCategories"
$txtSelectedCatInfo        = Find-Control "TxtSelectedCategoryInfo"
$txtSelectedCatDesc        = Find-Control "TxtSelectedCategoryDesc"
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
$global:ScannedCleanupItems = [System.Collections.ArrayList]@()
$global:CurrentFilterGroup  = "All"

# Function: Update C: Drive Metrics Display
function Update-CDriveMetricsDisplay {
    $cMetrics = Get-CDriveMetrics
    if ($cMetrics) {
        $txtCDriveTotal.Text = "$($cMetrics.TotalGB) GB"
        $txtCDriveUsed.Text  = "$($cMetrics.UsedGB) GB"
        $txtCDriveFree.Text  = "$($cMetrics.FreeGB) GB"
        $progressCDrive.Value = $cMetrics.UsedPercent
        $txtCBarPercent.Text = "$($cMetrics.UsedPercent)% Used ($($cMetrics.StatusText))"
        $txtCBarStatus.Text  = "Drive C: [$($cMetrics.VolumeLabel)] ($($cMetrics.FileSystem))"
        
        $txtGlobalStat.Text  = "C: Drive Status: $($cMetrics.FreeGB) GB Free of $($cMetrics.TotalGB) GB ($($cMetrics.StatusText))"
        Log-Console "C: Drive Status: $($cMetrics.UsedGB) GB used / $($cMetrics.TotalGB) GB total ($($cMetrics.FreeGB) GB free)"
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

# Function: Apply Filter on Cleanable Grid
function Apply-CleanupFilter {
    param([string]$Group)
    $global:CurrentFilterGroup = $Group
    
    if ($Group -eq "All") {
        $gridCleanCategories.ItemsSource = $global:ScannedCleanupItems
    } else {
        $filtered = $global:ScannedCleanupItems | Where-Object { $_.Group -like "*$Group*" }
        $gridCleanCategories.ItemsSource = [System.Collections.ArrayList]@($filtered)
    }
}

# Function: Scan C: Drive Junk
function Start-ScanCJunk {
    Log-Console "Scanning C: drive for unnecessary files, caches, logs, and trash..."
    $items = Scan-SmartCleanupItems
    
    $global:ScannedCleanupItems = [System.Collections.ArrayList]@($items)
    Apply-CleanupFilter $global:CurrentFilterGroup
    
    # Update Inspect dropdown
    $cmbInspectTarget.Items.Clear()
    $totalReclaimable = 0
    
    foreach ($item in $items) {
        $totalReclaimable += $item.RawBytes
        $cmbInspectTarget.Items.Add("$($item.Id) - $($item.CategoryName)") | Out-Null
        
        if ($item.RawBytes -gt 0) {
            Log-Console "Detected $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount)) at $($item.Target)"
        }
    }
    
    if ($cmbInspectTarget.Items.Count -gt 0) {
        $cmbInspectTarget.SelectedIndex = 0
    }
    
    $txtCReclaimable.Text = "~$(Format-Bytes -Bytes $totalReclaimable)"
    Update-SelectedCleanupBadge
    Log-Console "Scan complete! Total reclaimable junk on C: drive: $(Format-Bytes -Bytes $totalReclaimable)" "SUCCESS"
}

# Selection Presets
$btnSelectRec.add_Click({
    foreach ($item in $global:ScannedCleanupItems) {
        $item.IsSelected = ($item.Recommended -and $item.RawBytes -gt 0)
    }
    $gridCleanCategories.Items.Refresh()
    Update-SelectedCleanupBadge
    Log-Console "Applied recommended cleanup selection preset."
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

# Filter Chips
$btnFilterAll.add_Click({ Apply-CleanupFilter "All" })
$btnFilterSys.add_Click({ Apply-CleanupFilter "Windows & System" })
$btnFilterDev.add_Click({ Apply-CleanupFilter "Developer" })
$btnFilterBrowser.add_Click({ Apply-CleanupFilter "Browser" })

# Category Selection Changed in Grid
$gridCleanCategories.add_SelectionChanged({
    $sel = $gridCleanCategories.SelectedItem
    if ($sel) {
        $txtSelectedCatInfo.Text = "$($sel.DisplayName) - Size: $($sel.DisplaySize) ($($sel.FileCount))"
        $txtSelectedCatDesc.Text = "$($sel.Description)"
        Update-SelectedCleanupBadge
    }
})

# 1. Action: Open in File Explorer (User Key Requirement)
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
        if ($cmbInspectTarget.Items[$i] -like "$($sel.Id)*") {
            $cmbInspectTarget.SelectedIndex = $i
            break
        }
    }
    
    $mainTabControl.SelectedIndex = 1
    $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

# 3. Action: Clean Selected Junk (Bulk with Live Streaming Progress)
$btnRunCleanup.add_Click({
    $targetsToClean = @()
    foreach ($item in $global:ScannedCleanupItems) {
        if ($item.IsSelected -eq $true -and $item.RawBytes -gt 0) {
            $targetsToClean += $item
        }
    }

    if ($targetsToClean.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No items are selected for cleanup.`n`nPlease check the boxes next to the categories you want to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $totalBytes = ($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum
    $confirm = [System.Windows.MessageBox]::Show(
        "Proceed with cleaning $(Format-Bytes -Bytes $totalBytes) across $($targetsToClean.Count) selected C: drive junk categories?`n`nDiskman will safely remove unnecessary cache files and purge trash.`n`nReal-time deletion progress will stream live to the terminal window and activity log.",
        "Confirm C: Drive Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "=========================================================="
        Log-Console "EXECUTING C: DRIVE CLEANUP PIPELINE"
        Log-Console "Total Selected Space: $(Format-Bytes -Bytes $totalBytes) ($($targetsToClean.Count) categories)"
        
        $hasAdminTargets = ($targetsToClean | Where-Object { $_.RequiresAdmin -eq $true }).Count -gt 0
        if ($hasAdminTargets -and -not $isAdmin) {
            Log-Console "Notice: Selected system items require Administrator rights. Run via run.bat (Admin) if locked items are skipped." "WARN"
        }
        Log-Console "=========================================================="
        
        $btnRunCleanup.IsEnabled = $false
        $txtGlobalStat.Text = "Cleaning C: Drive in progress... (Live logs in terminal)"
        
        $res = Invoke-ExecuteCleanup -SelectedItems $targetsToClean -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        
        $btnRunCleanup.IsEnabled = $true
        Log-Console "==========================================================" "SUCCESS"
        Log-Console "CLEANUP FINISHED! Total space freed: $($res.DisplayFreed) ($($res.DeletedCount) items purged)" "SUCCESS"
        Log-Console "==========================================================" "SUCCESS"
        
        [System.Windows.MessageBox]::Show(
            "C: Drive Cleanup Complete!`n`nFreed Space: $($res.DisplayFreed)`nPurged Items: $($res.DeletedCount)`n`nSee Terminal window for full execution logs.",
            "Diskman - C: Drive Cleaned",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )

        Update-CDriveMetricsDisplay
        Start-ScanCJunk
    }
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

    $confirm = [System.Windows.MessageBox]::Show(
        "Clean all files in '$($sel.CategoryName)' ($($sel.DisplaySize))?`n`nLocation: $($sel.Target)",
        "Confirm Category Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "Purging single category: $($sel.CategoryName)..."
        $btnCleanSingleCategory.IsEnabled = $false
        
        $res = Invoke-ExecuteCategoryCleanup -TargetId $sel.Id -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        
        $btnCleanSingleCategory.IsEnabled = $true
        [System.Windows.MessageBox]::Show(
            "Category Cleaned: $($sel.CategoryName)`nFreed Space: $($res.DisplayFreed)",
            "Diskman",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        Update-CDriveMetricsDisplay
        Start-ScanCJunk
    }
})

# Tab 2: File Inspector Logic
$btnRefreshInspectFiles.add_Click({
    $selTargetStr = $cmbInspectTarget.SelectedItem
    if (-not $selTargetStr) { return }
    
    $targetId = ($selTargetStr -split " - ")[0].Trim()
    Log-Console "Loading file list for $targetId..."
    
    $files = Get-CleanableCategoryFiles -TargetId $targetId -Limit 250
    $gridInspectFiles.ItemsSource = $files
    
    $totalInspectBytes = ($files | Measure-Object -Property RawBytes -Sum).Sum
    if (-not $totalInspectBytes) { $totalInspectBytes = 0 }
    
    $txtInspectSummary.Text = "Loaded $($files.Count) files (Total: $(Format-Bytes -Bytes $totalInspectBytes))"
    Log-Console "Loaded $($files.Count) files for $targetId ($(Format-Bytes -Bytes $totalInspectBytes))" "SUCCESS"
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
            "Delete file '$($sel.Name)' ($($sel.DisplaySize))?`n`nPath: $($sel.FullPath)",
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
    
    $confirm = [System.Windows.MessageBox]::Show(
        "Clear all files currently inspected in '$selTargetStr'?",
        "Confirm Clear All",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        $res = Invoke-ExecuteCategoryCleanup -TargetId $targetId -OnProgress {
            param($msg, $level)
            Log-Console $msg $level
        }
        Log-Console "Cleared category: $targetId (Freed: $($res.DisplayFreed))" "SUCCESS"
        $btnRefreshInspectFiles.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Update-CDriveMetricsDisplay
        Start-ScanCJunk
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
$cmbHuntCat.Items.Add("AI Model / Weights")    | Out-Null
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
    Log-Console "Hunting large unnecessary files in C:\ ($($cmbHuntSize.SelectedItem) | $cat)..."

    $files = Find-LargeFiles -TargetPath "C:\" -MinSizeBytes $minSize -CategoryFilter $cat -Limit 100
    $gridLargeFiles.ItemsSource = $files
    Log-Console "Discovered $($files.Count) large files on C: drive." "SUCCESS"
})

$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel) {
        $txtSelectedLargeFile.Text = "$($sel.Name) ($($sel.DisplaySize))"
    } else {
        $txtSelectedLargeFile.Text = "Select a large file to perform action."
    }
})

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
            Update-CDriveMetricsDisplay
        }
    }
})

$btnPermDeleteLargeFile.add_Click({
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
            Update-CDriveMetricsDisplay
        }
    }
})

# Tab 4: Directory Explorer Setup
function Load-Directory {
    param([string]$Path)
    Log-Console "Scanning C: directory: $Path"
    $txtPath.Text = $Path
    $global:CurrentExplorerPath = $Path

    $items = Start-FolderScan -DirectoryPath $Path
    $gridDir.ItemsSource = $items
    Log-Console "Loaded $($items.Count) items in $Path" "SUCCESS"
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
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Log-Console "=========================================================="
Log-Console "DISKMAN - C: DRIVE STORAGE CLEANER & JUNK PURGER"
Log-Console "Real-time activity and deletion logs will stream live below."
if ($isAdmin) {
    Log-Console "Elevated Administrator Mode active [Full Access]" "SUCCESS"
} else {
    Log-Console "Standard Mode: Run as Administrator to purge Windows Update & System Cache" "WARN"
}
Log-Console "=========================================================="

Update-CDriveMetricsDisplay
Start-ScanCJunk
Load-Directory "C:\"

# Show Window
$window.ShowDialog() | Out-Null
