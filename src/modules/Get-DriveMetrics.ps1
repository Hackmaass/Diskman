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
