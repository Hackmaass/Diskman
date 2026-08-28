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
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $false)]
        [long]$MinSizeBytes = 100MB,

        [Parameter(Mandatory = $false)]
        [string]$CategoryFilter = "All Categories",

        [Parameter(Mandatory = $false)]
        [int]$Limit = 60
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return @()
    }

    $results = @()

    $videoExt = @(".mp4", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv", ".m4v", ".ts")
    $archiveExt = @(".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz")
    $aiExt = @(".bin", ".safetensors", ".gguf", ".pt", ".pth", ".onnx", ".model", ".h5", ".ckpt")
    $diskExt = @(".iso", ".vhd", ".vhdx", ".img", ".vmdk", ".qcow2")
    $installerExt = @(".exe", ".msi", ".pkg", ".appinstaller")
    $dataExt = @(".csv", ".parquet", ".db", ".sqlite", ".sql", ".bak")

    $dirQueue = New-Object System.Collections.Generic.Queue[string]
    $dirQueue.Enqueue($TargetPath)

    $scannedFolders = 0
    $maxFolders = 2000 # safeguard against infinite loops or slow drives

    while ($dirQueue.Count -gt 0 -and $scannedFolders -lt $maxFolders) {
        $currentDir = $dirQueue.Dequeue()
        $scannedFolders++

        # Skip system protected folders
        if ($currentDir -match '\\\$RECYCLE\.BIN|\\System Volume Information|\\AppData\\Local\\Application Data') {
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

                    if ($ext -in $videoExt) { $cat = "Video / Media" }
                    elseif ($ext -in $archiveExt) { $cat = "Archive / Zip" }
                    elseif ($ext -in $aiExt) { $cat = "AI Model / Weights" }
                    elseif ($ext -in $diskExt) { $cat = "Disk Image / ISO" }
                    elseif ($ext -in $installerExt) { $cat = "Executable / Installer" }
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
        $statusText = if ($usedPercent -ge 90) { "⚠️ Critical (Low Space)" } elseif ($usedPercent -ge 75) { "⚡ High Usage" } else { "✅ Healthy" }

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
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows|^[A-Za-z]:\\Program Files') {
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
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows|^[A-Za-z]:\\Program Files') {
        return @{ Success = $false; Message = "Protected system paths cannot be deleted." }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return @{ Success = $true; Message = "Item permanently deleted." }
    } catch {
        return @{ Success = $false; Message = "Delete failed: $_" }
    }
}


# --- Module: Invoke-SmartCleanup.ps1 ---
function Get-CleanableTargets {
    [CmdletBinding()]
    param()

    $targets = @(
        @{
            Id          = "UserTemp"
            Category    = "Windows User Temp"
            Path        = $env:TEMP
            Description = "Temporary files created by running apps ($env:TEMP)"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "SystemTemp"
            Category    = "Windows System Temp"
            Path        = "C:\Windows\Temp"
            Description = "Operating system temporary cache (C:\Windows\Temp)"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "PipCache"
            Category    = "Python Pip Cache"
            Path        = "$env:LOCALAPPDATA\pip\cache"
            Description = "Cached Python wheels and tarballs ($env:LOCALAPPDATA\pip\cache)"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "PipCustomCache"
            Category    = "Python Pip D: Drive Cache"
            Path        = "D:\tmp\pip-cache"
            Description = "Custom secondary pip cache on D: drive"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "NpmCache"
            Category    = "Node.js NPM Cache"
            Path        = "$env:APPDATA\npm-cache"
            Description = "Global NPM package download cache"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "CrashDumps"
            Category    = "Crash Dumps & Minidumps"
            Path        = "$env:LOCALAPPDATA\CrashDumps"
            Description = "Application crash dumps (.dmp files)"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "WERLogs"
            Category    = "Windows Error Reports"
            Path        = "$env:LOCALAPPDATA\Microsoft\Windows\WER"
            Description = "Windows error reporting archives and queues"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "ChromeCache"
            Category    = "Google Chrome Web Cache"
            Path        = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\Cache_Data"
            Description = "Cached images and web assets"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "EdgeCache"
            Category    = "Microsoft Edge Web Cache"
            Path        = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\Cache_Data"
            Description = "Edge browser media and webpage cache"
            Type        = "DirectoryContents"
            Safe        = $true
        },
        @{
            Id          = "RecycleBin"
            Category    = "Windows Recycle Bin"
            Path        = "All Drives"
            Description = "Deleted items in Recycle Bin across all drives"
            Type        = "RecycleBin"
            Safe        = $true
        }
    )

    return $targets
}

function Scan-SmartCleanupItems {
    [CmdletBinding()]
    param()

    $targets = Get-CleanableTargets
    $results = @()
    $fso = New-Object -ComObject Scripting.FileSystemObject

    foreach ($t in $targets) {
        $rawBytes = 0
        $fileCount = 0

        if ($t.Type -eq "RecycleBin") {
            try {
                $shell = New-Object -ComObject Shell.Application
                $bin = $shell.Namespace(0xA) # ssfBITBUCKET
                $binCount = $bin.Items().Count
                $binSize = 0
                foreach ($item in $bin.Items()) {
                    $binSize += $item.Size
                }
                $rawBytes = $binSize
                $fileCount = $binCount
            } catch {
                $rawBytes = 0
                $fileCount = 0
            }
        } else {
            if (Test-Path -LiteralPath $t.Path) {
                try {
                    $folder = $fso.GetFolder($t.Path)
                    $rawBytes = $folder.Size
                    $fileCount = $folder.Files.Count + $folder.SubFolders.Count
                } catch {
                    # Fallback
                    try {
                        $files = Get-ChildItem -LiteralPath $t.Path -Recurse -File -Force -ErrorAction SilentlyContinue
                        $rawBytes = ($files | Measure-Object -Property Length -Sum).Sum
                        $fileCount = ($files | Measure-Object).Count
                    } catch {}
                }
            }
        }

        $disp = Format-Bytes -Bytes $rawBytes
        $isSelected = ($rawBytes -gt 0)

        $results += [PSCustomObject]@{
            Id           = $t.Id
            CategoryName = $t.Category
            Target       = $t.Path
            Type         = $t.Type
            RawBytes     = [long]$rawBytes
            DisplaySize  = $disp
            FileCount    = "$fileCount items"
            Description  = $t.Description
            IsSelected   = [bool]$isSelected
        }
    }

    return $results
}

function Invoke-ExecuteCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$SelectedItems
    )

    $freedBytes = 0
    $deletedCount = 0
    $logMessages = @()

    foreach ($item in $SelectedItems) {
        if (-not $item.IsSelected) { continue }

        if ($item.Type -eq "RecycleBin") {
            try {
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                $freedBytes += $item.RawBytes
                $logMessages += "Emptied Recycle Bin (Freed $(Format-Bytes -Bytes $item.RawBytes))"
            } catch {
                $logMessages += "Failed to empty Recycle Bin: $_"
            }
            continue
        }

        $targetPath = $item.Target
        if (Test-Path -LiteralPath $targetPath) {
            $initialSize = $item.RawBytes
            try {
                # Delete files inside directory without deleting root directory itself
                Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        if ($_.PSIsContainer) {
                            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        } else {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                        $deletedCount++
                    } catch {}
                }
                $freedBytes += $initialSize
                $logMessages += "Cleaned $($item.CategoryName) (Freed $(Format-Bytes -Bytes $initialSize))"
            } catch {
                $logMessages += "Error cleaning $($item.CategoryName): $_"
            }
        }
    }

    return [PSCustomObject]@{
        TotalFreedBytes = $freedBytes
        DisplayFreed    = Format-Bytes -Bytes $freedBytes
        DeletedCount    = $deletedCount
        Logs            = $logMessages
    }
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
        Title="Diskman - Windows Storage Utility" 
        Height="750" Width="1080" 
        MinHeight="600" MinWidth="850"
        WindowStartupLocation="CenterScreen"
        Background="#202020"
        Foreground="#FFFFFF"
        FontFamily="Segoe UI, Tahoma, sans-serif">

    <Window.Resources>
        <!-- WinUtil Classic Dark Palette -->
        <SolidColorBrush x:Key="WinDarkBg" Color="#202020"/>
        <SolidColorBrush x:Key="TabHeaderBg" Color="#2D2D30"/>
        <SolidColorBrush x:Key="TabSelectedBg" Color="#3E3E42"/>
        <SolidColorBrush x:Key="GroupBoxBg" Color="#27272A"/>
        <SolidColorBrush x:Key="BorderDark" Color="#3F3F46"/>
        <SolidColorBrush x:Key="AccentCyan" Color="#00B4D8"/>
        <SolidColorBrush x:Key="AccentGreen" Color="#2EC4B6"/>
        <SolidColorBrush x:Key="AccentRed" Color="#E63946"/>
        <SolidColorBrush x:Key="ConsoleBg" Color="#18181B"/>

        <!-- WinUtil Style Buttons -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#333338"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#4F4F56"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#44444C"/>
                                <Setter Property="BorderBrush" Value="#00B4D8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#1E1E22"/>
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
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#0096C7"/>
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
            <Setter Property="BorderBrush" Value="#D00000"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#DC2F02"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- WinUtil GroupBox Style -->
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#00B4D8"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12"/>
            <Setter Property="Margin" Value="6"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>

        <!-- WinUtil CheckBox Style -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E4E4E7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <!-- TabItem WinUtil Style -->
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#A1A1AA"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="#3F3F46" BorderThickness="1,1,1,0" CornerRadius="4,4,0,0" Padding="{TemplateBinding Padding}" Margin="0,0,4,0">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#3A3A40"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#202020"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#00B4D8"/>
                                <Setter Property="Foreground" Value="#00B4D8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- DataGrid Style -->
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#18181B"/>
            <Setter Property="Foreground" Value="#FAFAFA"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="RowBackground" Value="#18181B"/>
            <Setter Property="AlternatingRowBackground" Value="#202024"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#2D2D32"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="SelectionMode" Value="Single"/>
            <Setter Property="RowHeight" Value="28"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#27272A"/>
            <Setter Property="Foreground" Value="#A1A1AA"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="140"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Top Header Bar -->
        <Grid Grid.Row="0" Margin="4,0,4,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Diskman" FontSize="18" FontWeight="Bold" Foreground="#00B4D8" VerticalAlignment="Center"/>
                <TextBlock Text=" - Windows Storage Analyzer &amp; Cleaner" FontSize="14" Foreground="#A1A1AA" VerticalAlignment="Center"/>
            </StackPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnTopRefresh" Content="🔄 Refresh All" Margin="0,0,8,0"/>
                <Button x:Name="BtnTopQuickScan" Content="⚡ Quick Clean" Style="{StaticResource PrimaryActionBtn}"/>
            </StackPanel>
        </Grid>

        <!-- WinUtil Main TabControl -->
        <TabControl Grid.Row="1" Background="#202020" BorderBrush="#3F3F46" BorderThickness="1">

            <!-- TAB 1: DRIVES OVERVIEW -->
            <TabItem Header="  📊 Drives Overview  ">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10">
                    <StackPanel>
                        <!-- Container for dynamic drive cards -->
                        <WrapPanel x:Name="PanelDriveCards" Margin="0,0,0,12"/>

                        <!-- System Storage Summary -->
                        <GroupBox Header="Total System Storage Summary">
                            <Grid Margin="4,6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="Total Storage Capacity:" Foreground="#A1A1AA" FontSize="11"/>
                                    <TextBlock x:Name="TxtTotalSystemStorage" Text="Calculating..." FontSize="16" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,2"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1">
                                    <TextBlock Text="Total Free Space Available:" Foreground="#A1A1AA" FontSize="11"/>
                                    <TextBlock x:Name="TxtTotalSystemFree" Text="Calculating..." FontSize="16" FontWeight="Bold" Foreground="#2EC4B6" Margin="0,2"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="Estimated Reclaimable Junk:" Foreground="#A1A1AA" FontSize="11"/>
                                    <TextBlock x:Name="TxtEstimatedReclaimable" Text="~15+ GB" FontSize="16" FontWeight="Bold" Foreground="#00B4D8" Margin="0,2"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- TAB 2: STORAGE CLEANUP (WINUTIL STYLE TWEAKS/CLEANUP) -->
            <TabItem Header="  🧹 Storage Cleanup  ">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Top Action Presets Bar -->
                    <Grid Grid.Row="0" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="BtnSelectRecommended" Content="Select Recommended" Margin="0,0,6,0"/>
                            <Button x:Name="BtnSelectAll" Content="Select All" Margin="0,0,6,0"/>
                            <Button x:Name="BtnClearSelection" Content="Clear All"/>
                        </StackPanel>

                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock x:Name="TxtCleanTotalBadge" Text="Selected: 0.00 GB" FontWeight="Bold" Foreground="#00B4D8" VerticalAlignment="Center" Margin="0,0,12,0"/>
                            <Button x:Name="BtnScanCleanable" Content="🔍 Analyze Junk" Margin="0,0,6,0"/>
                            <Button x:Name="BtnRunCleanup" Content="🧹 Run Cleanup" Style="{StaticResource DangerActionBtn}"/>
                        </StackPanel>
                    </Grid>

                    <!-- GroupBoxes 2x2 Layout -->
                    <Grid Grid.Row="1">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <!-- Box 1: Windows & System Temp -->
                        <GroupBox Grid.Row="0" Grid.Column="0" Header="Windows &amp; System Caches">
                            <StackPanel>
                                <CheckBox x:Name="ChkUserTemp" Content="Windows User Temp (%TEMP%)" IsChecked="True"/>
                                <CheckBox x:Name="ChkSysTemp" Content="Windows System Temp (C:\Windows\Temp)" IsChecked="True"/>
                                <CheckBox x:Name="ChkCrashDumps" Content="Application Crash Dumps (%LOCALAPPDATA%\CrashDumps)" IsChecked="True"/>
                                <CheckBox x:Name="ChkWerLogs" Content="Windows Error Reporting (WER Logs)" IsChecked="True"/>
                            </StackPanel>
                        </GroupBox>

                        <!-- Box 2: Developer Caches -->
                        <GroupBox Grid.Row="0" Grid.Column="1" Header="Developer &amp; Package Caches">
                            <StackPanel>
                                <CheckBox x:Name="ChkPipCache" Content="Python Pip Cache (%LOCALAPPDATA%\pip\cache)" IsChecked="True"/>
                                <CheckBox x:Name="ChkPipDCache" Content="Python D: Drive Pip Cache (D:\tmp\pip-cache)" IsChecked="True"/>
                                <CheckBox x:Name="ChkNpmCache" Content="Node.js NPM Cache (%APPDATA%\npm-cache)" IsChecked="True"/>
                                <CheckBox x:Name="ChkPyCache" Content="Python Bytecode (__pycache__)" IsChecked="True"/>
                            </StackPanel>
                        </GroupBox>

                        <!-- Box 3: Browser & Web Caches -->
                        <GroupBox Grid.Row="1" Grid.Column="0" Header="Browser &amp; Application Caches">
                            <StackPanel>
                                <CheckBox x:Name="ChkChromeCache" Content="Google Chrome Web Cache" IsChecked="True"/>
                                <CheckBox x:Name="ChkEdgeCache" Content="Microsoft Edge Web Cache" IsChecked="True"/>
                                <CheckBox x:Name="ChkBraveCache" Content="Brave Browser Web Cache" IsChecked="False"/>
                            </StackPanel>
                        </GroupBox>

                        <!-- Box 4: Recycle Bin & Misc -->
                        <GroupBox Grid.Row="1" Grid.Column="1" Header="Recycle Bin &amp; Deletions">
                            <StackPanel>
                                <CheckBox x:Name="ChkRecycleBin" Content="Empty Recycle Bin (All Drives)" IsChecked="True"/>
                                <CheckBox x:Name="ChkOldDownloads" Content="Cleanup Download Temp Files" IsChecked="False"/>
                            </StackPanel>
                        </GroupBox>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- TAB 3: LARGE FILE HUNTER -->
            <TabItem Header="  🎯 Large File Hunter  ">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Filter Controls -->
                    <Grid Grid.Row="0" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="0,0,10,0" VerticalAlignment="Center">
                            <TextBlock Text="Drive: " Foreground="#A1A1AA" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterDrive" Width="70" Height="26" Margin="4,0,0,0" Background="#27272A" Foreground="#FFFFFF"/>
                        </StackPanel>

                        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,10,0" VerticalAlignment="Center">
                            <TextBlock Text="Min Size: " Foreground="#A1A1AA" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterSize" Width="90" Height="26" Margin="4,0,0,0" Background="#27272A" Foreground="#FFFFFF"/>
                        </StackPanel>

                        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,10,0" VerticalAlignment="Center">
                            <TextBlock Text="Type: " Foreground="#A1A1AA" VerticalAlignment="Center"/>
                            <ComboBox x:Name="CmbHunterCategory" Width="110" Height="26" Margin="4,0,0,0" Background="#27272A" Foreground="#FFFFFF"/>
                        </StackPanel>

                        <Button x:Name="BtnStartHunterScan" Grid.Column="4" Content="🎯 Scan Large Files" Style="{StaticResource PrimaryActionBtn}"/>
                    </Grid>

                    <!-- Table -->
                    <DataGrid x:Name="GridLargeFiles" Grid.Row="1">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="240"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" Width="90"/>
                            <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="130"/>
                            <DataGridTextColumn Header="Full Path" Binding="{Binding FullPath}" Width="*"/>
                            <DataGridTextColumn Header="Modified" Binding="{Binding LastWriteTime}" Width="130"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <!-- Action buttons -->
                    <Grid Grid.Row="2" Margin="0,8,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <TextBlock x:Name="TxtSelectedFileInfo" Grid.Column="0" Text="Select a file to perform action." Foreground="#A1A1AA" FontSize="11" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRevealInExplorer" Grid.Column="1" Content="📂 Open in Explorer" Margin="0,0,6,0"/>
                        <Button x:Name="BtnSendToTrash" Grid.Column="2" Content="🗑️ Send to Trash" Margin="0,0,6,0"/>
                        <Button x:Name="BtnPermanentDelete" Grid.Column="3" Content="⚡ Delete" Style="{StaticResource DangerActionBtn}"/>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- TAB 4: DIRECTORY EXPLORER -->
            <TabItem Header="  📂 Directory Explorer  ">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <ComboBox x:Name="CmbExplorerDrive" Grid.Column="0" Width="80" Height="26" Margin="0,0,6,0" Background="#27272A" Foreground="#FFFFFF"/>
                        <Button x:Name="BtnFolderUp" Grid.Column="1" Content="⬆️ Up" Margin="0,0,6,0"/>
                        <TextBox x:Name="TxtCurrentPath" Grid.Column="2" Height="26" Background="#18181B" Foreground="#00B4D8" BorderBrush="#3F3F46" Padding="6,3" IsReadOnly="True" VerticalContentAlignment="Center"/>
                        <Button x:Name="BtnScanCurrentDir" Grid.Column="3" Content="🔍 Scan" Style="{StaticResource PrimaryActionBtn}" Margin="6,0,0,0"/>
                    </Grid>

                    <DataGrid x:Name="GridDirectories" Grid.Row="1">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="260"/>
                            <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="60"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding DisplaySize}" Width="100"/>
                            <DataGridTextColumn Header="% Parent" Binding="{Binding PercentStr}" Width="90"/>
                            <DataGridTextColumn Header="Items" Binding="{Binding ItemCount}" Width="80"/>
                            <DataGridTextColumn Header="Last Modified" Binding="{Binding LastModified}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Bottom WinUtil Console / Output Terminal -->
        <GroupBox Grid.Row="2" Header="Activity &amp; Execution Log" Margin="0,8,0,0">
            <TextBox x:Name="TxtConsoleLog" Background="{StaticResource ConsoleBg}" Foreground="#2EC4B6" FontFamily="Consolas, monospace" FontSize="11" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </GroupBox>

        <!-- Status Bar -->
        <Grid Grid.Row="3" Margin="4,6,4,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock x:Name="TxtGlobalStatus" Grid.Column="0" Text="Ready | Diskman v1.0.0 (WinUtil-style Engine)" FontSize="11" Foreground="#71717A"/>
            <TextBlock Grid.Column="1" Text="Elevated Administrator Mode" FontSize="11" Foreground="#2EC4B6"/>
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

# Console Logger Function
function Log-Console {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = "[+]"
    if ($Level -eq "SUCCESS") { $prefix = "[OK]" }
    elseif ($Level -eq "WARN") { $prefix = "[!]" }
    elseif ($Level -eq "ERROR") { $prefix = "[X]" }
    
    $logLine = "$timestamp $prefix $Message`r`n"
    
    $txtConsole = Find-Control "TxtConsoleLog"
    if ($txtConsole) {
        $txtConsole.AppendText($logLine)
        $txtConsole.ScrollToEnd()
    }
}

# Core Controls
$txtConsoleLog   = Find-Control "TxtConsoleLog"
$txtGlobalStat   = Find-Control "TxtGlobalStatus"
$panelCards      = Find-Control "PanelDriveCards"
$txtTotalStorage = Find-Control "TxtTotalSystemStorage"
$txtTotalFree    = Find-Control "TxtTotalSystemFree"
$txtReclaimable  = Find-Control "TxtEstimatedReclaimable"

$btnTopRefresh   = Find-Control "BtnTopRefresh"
$btnTopQuickScan = Find-Control "BtnTopQuickScan"

# Cleanup Controls
$btnSelectRec    = Find-Control "BtnSelectRecommended"
$btnSelectAll    = Find-Control "BtnSelectAll"
$btnClearSel     = Find-Control "BtnClearSelection"
$txtCleanBadge   = Find-Control "TxtCleanTotalBadge"
$btnScanClean    = Find-Control "BtnScanCleanable"
$btnRunCleanup   = Find-Control "BtnRunCleanup"

$chkUserTemp     = Find-Control "ChkUserTemp"
$chkSysTemp      = Find-Control "ChkSysTemp"
$chkCrashDumps   = Find-Control "ChkCrashDumps"
$chkWerLogs      = Find-Control "ChkWerLogs"
$chkPipCache     = Find-Control "ChkPipCache"
$chkPipDCache    = Find-Control "ChkPipDCache"
$chkNpmCache     = Find-Control "ChkNpmCache"
$chkPyCache      = Find-Control "ChkPyCache"
$chkChromeCache  = Find-Control "ChkChromeCache"
$chkEdgeCache    = Find-Control "ChkEdgeCache"
$chkBraveCache   = Find-Control "ChkBraveCache"
$chkRecycleBin   = Find-Control "ChkRecycleBin"
$chkOldDownloads = Find-Control "ChkOldDownloads"

# Hunter Controls
$cmbHuntDrive    = Find-Control "CmbHunterDrive"
$cmbHuntSize     = Find-Control "CmbHunterSize"
$cmbHuntCat      = Find-Control "CmbHunterCategory"
$btnHuntScan     = Find-Control "BtnStartHunterScan"
$gridLargeFiles  = Find-Control "GridLargeFiles"
$txtSelected     = Find-Control "TxtSelectedFileInfo"
$btnReveal       = Find-Control "BtnRevealInExplorer"
$btnTrash        = Find-Control "BtnSendToTrash"
$btnPermDelete   = Find-Control "BtnPermanentDelete"

# Explorer Controls
$cmbExpDrive     = Find-Control "CmbExplorerDrive"
$btnFolderUp     = Find-Control "BtnFolderUp"
$txtPath         = Find-Control "TxtCurrentPath"
$btnScanDir      = Find-Control "BtnScanCurrentDir"
$gridDir         = Find-Control "GridDirectories"

# State
$global:CurrentExplorerPath = "C:\"
$global:ScannedCleanableTargets = @{}

# Load Drives
function Load-DrivesOverview {
    Log-Console "Enumerating physical and logical storage volumes..."
    $panelCards.Children.Clear()
    $cmbExpDrive.Items.Clear()
    $cmbHuntDrive.Items.Clear()

    $metrics = Get-DriveMetrics
    $totalSysBytes = 0
    $totalFreeBytes = 0

    foreach ($m in $metrics) {
        $totalSysBytes += $m.RawTotal
        $totalFreeBytes += $m.RawFree

        $cmbExpDrive.Items.Add("$($m.DriveLetter)\") | Out-Null
        $cmbHuntDrive.Items.Add("$($m.DriveLetter)\") | Out-Null

        # Build clean WinUtil style Drive GroupBox
        $cardXaml = @"
        <GroupBox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                  Header="$($m.DisplayName)" Width="310" Height="170" Margin="4" Foreground="#00B4D8" BorderBrush="#3F3F46" Background="#27272A">
            <Grid Margin="6,4">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0">
                    <TextBlock Text="File System: $($m.FileSystem)" FontSize="11" Foreground="#A1A1AA" HorizontalAlignment="Left"/>
                    <TextBlock Text="$($m.StatusText)" FontSize="11" FontWeight="Bold" Foreground="$($m.StatusColor)" HorizontalAlignment="Right"/>
                </Grid>

                <StackPanel Grid.Row="1" Margin="0,8,0,0">
                    <Grid>
                        <TextBlock Text="$($m.UsedGB) GB used ($($m.UsedPercent)%)" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Left"/>
                        <TextBlock Text="$($m.FreeGB) GB free" FontSize="11" Foreground="#2EC4B6" HorizontalAlignment="Right"/>
                    </Grid>
                    <ProgressBar Height="8" Margin="0,4,0,0" Value="$($m.UsedPercent)" Maximum="100" Background="#18181B" Foreground="$($m.StatusColor)" BorderThickness="0"/>
                </StackPanel>

                <Grid Grid.Row="3" Margin="0,8,0,0">
                    <Button Tag="$($m.DriveLetter)\" Content="Inspect in Explorer" Height="26" FontSize="11" Background="#333338" Foreground="#00B4D8" BorderBrush="#4F4F56" Cursor="Hand"/>
                </Grid>
            </Grid>
        </GroupBox>
"@
        $cardReader = New-Object System.Xml.XmlNodeReader ([xml]$cardXaml)
        $cardElement = [System.Windows.Markup.XamlReader]::Load($cardReader)

        $btnInspect = $cardElement.Content.Children[2].Children[0]
        $btnInspect.add_Click({
            param($sender, $e)
            $global:CurrentExplorerPath = $sender.Tag
            $cmbExpDrive.SelectedItem = $sender.Tag
            Load-Directory $global:CurrentExplorerPath
            # Switch to explorer tab
            $tabCtrl = $window.Content.Children[1]
            $tabCtrl.SelectedIndex = 3
        })

        $panelCards.Children.Add($cardElement) | Out-Null
        Log-Console "Discovered Drive $($m.DriveLetter) [$($m.VolumeLabel)]: $($m.UsedGB) GB / $($m.TotalGB) GB ($($m.FreeGB) GB free)"
    }

    $txtTotalStorage.Text = Format-Bytes -Bytes $totalSysBytes
    $txtTotalFree.Text    = Format-Bytes -Bytes $totalFreeBytes

    if ($cmbExpDrive.Items.Count -gt 0) { $cmbExpDrive.SelectedIndex = 0 }
    if ($cmbHuntDrive.Items.Count -gt 0) { $cmbHuntDrive.SelectedIndex = 0 }

    $txtGlobalStat.Text = "Ready | Discovered $($metrics.Count) mounted partitions."
}

# Explorer: Load Directory
function Load-Directory {
    param([string]$Path)
    Log-Console "Scanning folder: $Path"
    $txtPath.Text = $Path
    $global:CurrentExplorerPath = $Path

    $items = Start-FolderScan -DirectoryPath $Path
    $gridDir.ItemsSource = $items
    Log-Console "Loaded $($items.Count) items in $Path" "SUCCESS"
}

# Cleanup: Checkbox Selection helpers
$btnSelectRec.add_Click({
    $chkUserTemp.IsChecked = $true
    $chkSysTemp.IsChecked = $true
    $chkCrashDumps.IsChecked = $true
    $chkWerLogs.IsChecked = $true
    $chkPipCache.IsChecked = $true
    $chkPipDCache.IsChecked = $true
    $chkNpmCache.IsChecked = $true
    $chkPyCache.IsChecked = $true
    $chkChromeCache.IsChecked = $true
    $chkEdgeCache.IsChecked = $true
    $chkBraveCache.IsChecked = $false
    $chkRecycleBin.IsChecked = $true
    $chkOldDownloads.IsChecked = $false
    Log-Console "Applied recommended cleanup presets."
})

$btnSelectAll.add_Click({
    $chkUserTemp.IsChecked = $true
    $chkSysTemp.IsChecked = $true
    $chkCrashDumps.IsChecked = $true
    $chkWerLogs.IsChecked = $true
    $chkPipCache.IsChecked = $true
    $chkPipDCache.IsChecked = $true
    $chkNpmCache.IsChecked = $true
    $chkPyCache.IsChecked = $true
    $chkChromeCache.IsChecked = $true
    $chkEdgeCache.IsChecked = $true
    $chkBraveCache.IsChecked = $true
    $chkRecycleBin.IsChecked = $true
    $chkOldDownloads.IsChecked = $true
    Log-Console "Selected all cleanup items."
})

$btnClearSel.add_Click({
    $chkUserTemp.IsChecked = $false
    $chkSysTemp.IsChecked = $false
    $chkCrashDumps.IsChecked = $false
    $chkWerLogs.IsChecked = $false
    $chkPipCache.IsChecked = $false
    $chkPipDCache.IsChecked = $false
    $chkNpmCache.IsChecked = $false
    $chkPyCache.IsChecked = $false
    $chkChromeCache.IsChecked = $false
    $chkEdgeCache.IsChecked = $false
    $chkBraveCache.IsChecked = $false
    $chkRecycleBin.IsChecked = $false
    $chkOldDownloads.IsChecked = $false
    Log-Console "Cleared cleanup selection."
})

# Scan Cleanable Items
function Start-AnalyzeStorageJunk {
    Log-Console "Starting deep storage cleanup scan across all drives..."
    $items = Scan-SmartCleanupItems
    
    $totalFound = 0
    foreach ($item in $items) {
        $global:ScannedCleanableTargets[$item.Id] = $item
        $totalFound += $item.RawBytes
        if ($item.RawBytes -gt 0) {
            Log-Console "Found $($item.CategoryName): $($item.DisplaySize) ($($item.FileCount))"
        }
    }

    $txtCleanBadge.Text = "Reclaimable: $(Format-Bytes -Bytes $totalFound)"
    $txtReclaimable.Text = "~$(Format-Bytes -Bytes $totalFound)"
    Log-Console "Storage analysis complete. Total reclaimable: $(Format-Bytes -Bytes $totalFound)" "SUCCESS"
}

$btnScanClean.add_Click({ Start-AnalyzeStorageJunk })

# Run Cleanup
$btnRunCleanup.add_Click({
    $targetsToClean = @()
    $allItems = Scan-SmartCleanupItems

    $checkboxMap = @{
        "UserTemp"        = $chkUserTemp.IsChecked
        "SystemTemp"      = $chkSysTemp.IsChecked
        "CrashDumps"      = $chkCrashDumps.IsChecked
        "WERLogs"         = $chkWerLogs.IsChecked
        "PipCache"        = $chkPipCache.IsChecked
        "PipCustomCache"  = $chkPipDCache.IsChecked
        "NpmCache"        = $chkNpmCache.IsChecked
        "ChromeCache"     = $chkChromeCache.IsChecked
        "EdgeCache"       = $chkEdgeCache.IsChecked
        "RecycleBin"      = $chkRecycleBin.IsChecked
    }

    foreach ($item in $allItems) {
        if ($checkboxMap[$item.Id] -eq $true) {
            $item.IsSelected = $true
            $targetsToClean += $item
        }
    }

    if ($targetsToClean.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Please select at least one item to clean.", "Diskman", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }

    $totalBytes = ($targetsToClean | Measure-Object -Property RawBytes -Sum).Sum
    $confirm = [System.Windows.MessageBox]::Show(
        "Proceed with cleaning $(Format-Bytes -Bytes $totalBytes) across $($targetsToClean.Count) selected categories?",
        "Confirm WinUtil Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        Log-Console "Executing cleanup sequence..."
        $res = Invoke-ExecuteCleanup -SelectedItems $targetsToClean
        foreach ($log in $res.Logs) {
            Log-Console $log "SUCCESS"
        }
        Log-Console "Cleanup finished! Total space freed: $($res.DisplayFreed) ($($res.DeletedCount) items purged)" "SUCCESS"
        
        [System.Windows.MessageBox]::Show(
            "Cleanup Complete!`n`nFreed Space: $($res.DisplayFreed)`nPurged Items: $($res.DeletedCount)",
            "Diskman - Storage Cleaned",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )

        Load-DrivesOverview
        Start-AnalyzeStorageJunk
    }
})

# Large File Hunter Setup
$cmbHuntSize.Items.Add("> 100 MB") | Out-Null
$cmbHuntSize.Items.Add("> 500 MB") | Out-Null
$cmbHuntSize.Items.Add("> 1 GB")   | Out-Null
$cmbHuntSize.Items.Add("> 5 GB")   | Out-Null
$cmbHuntSize.SelectedIndex = 0

$cmbHuntCat.Items.Add("All Categories") | Out-Null
$cmbHuntCat.Items.Add("Video")          | Out-Null
$cmbHuntCat.Items.Add("Archive")        | Out-Null
$cmbHuntCat.Items.Add("AI Model")       | Out-Null
$cmbHuntCat.Items.Add("Disk Image")     | Out-Null
$cmbHuntCat.Items.Add("Executable")     | Out-Null
$cmbHuntCat.Items.Add("Dataset")        | Out-Null
$cmbHuntCat.SelectedIndex = 0

$btnHuntScan.add_Click({
    $drive = $cmbHuntDrive.SelectedItem
    if (-not $drive) { $drive = "C:\" }

    $sizeMap = @{
        "> 100 MB" = 100MB
        "> 500 MB" = 500MB
        "> 1 GB"   = 1GB
        "> 5 GB"   = 5GB
    }
    $minSize = $sizeMap[$cmbHuntSize.SelectedItem]
    if (-not $minSize) { $minSize = 100MB }

    $cat = $cmbHuntCat.SelectedItem
    Log-Console "Scanning for large files in $drive ($($cmbHuntSize.SelectedItem) | $cat)..."

    $files = Find-LargeFiles -TargetPath $drive -MinSizeBytes $minSize -CategoryFilter $cat -Limit 60
    $gridLargeFiles.ItemsSource = $files
    Log-Console "Found $($files.Count) matching large files in $drive." "SUCCESS"
})

$gridLargeFiles.add_SelectionChanged({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel) {
        $txtSelected.Text = "$($sel.Name) ($($sel.DisplaySize))"
    } else {
        $txtSelected.Text = "Select a file to perform action."
    }
})

$btnReveal.add_Click({
    $sel = $gridLargeFiles.SelectedItem
    if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
        Show-ItemInExplorer -Path $sel.FullPath
        Log-Console "Revealed file in Windows Explorer: $($sel.FullPath)"
    }
})

$btnTrash.add_Click({
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
        }
    }
})

$btnPermDelete.add_Click({
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
        }
    }
})

# Explorer Events
$btnTopRefresh.add_Click({ Load-DrivesOverview })
$btnTopQuickScan.add_Click({
    $tabCtrl = $window.Content.Children[1]
    $tabCtrl.SelectedIndex = 1
    Start-AnalyzeStorageJunk
})

$btnScanDir.add_Click({ Load-Directory $txtPath.Text })
$cmbExpDrive.add_SelectionChanged({
    if ($cmbExpDrive.SelectedItem) {
        Load-Directory $cmbExpDrive.SelectedItem
    }
})
$btnFolderUp.add_Click({
    $parent = Split-Path -Parent $global:CurrentExplorerPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Load-Directory $parent
    }
})
$gridDir.add_MouseDoubleClick({
    $selected = $gridDir.SelectedItem
    if ($selected -and $selected.IsFolder -and (Test-Path -LiteralPath $selected.FullPath)) {
        Load-Directory $selected.FullPath
    }
})

# Initial Startup
Log-Console "================================================="
Log-Console "Diskman Windows Storage Utility initialized."
Log-Console "Inspired by ChrisTitusTech/winutil architecture."
Log-Console "================================================="

Load-DrivesOverview
Load-Directory "C:\"

# Show Window
$window.ShowDialog() | Out-Null
