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
