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
