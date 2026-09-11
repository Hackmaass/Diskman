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

    $results = @()

    $installerExt = @(".exe", ".msi", ".pkg", ".appinstaller", ".cab", ".msu")
    $diskExt      = @(".iso", ".vhd", ".vhdx", ".img", ".vmdk", ".qcow2", ".wim")
    $archiveExt   = @(".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz", ".zst", ".tgz")
    $videoExt     = @(".mp4", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv", ".m4v", ".ts")
    $aiExt        = @(".bin", ".safetensors", ".gguf", ".pt", ".pth", ".onnx", ".model", ".h5", ".ckpt", ".weight", ".weights", ".safetensor")
    $logExt       = @(".log", ".dmp", ".trace", ".etl", ".bak", ".old")
    $dataExt      = @(".csv", ".parquet", ".db", ".sqlite", ".sql")
    $partExt      = @(".part", ".crdownload", ".download", ".partial")

    $sysRoot = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\', '/') } else { "C:\Windows" }
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

        if ($currentDir -match '\\\$RECYCLE\.BIN|\\System Volume Information|\\AppData\\Local\\Application Data|\\assembly') {
            continue
        }

        try {
            $dInfo = New-Object System.IO.DirectoryInfo($currentDir)
            
            # Check direct files
            foreach ($f in $dInfo.EnumerateFiles()) {
                if ($f.Length -ge $MinSizeBytes) {
                    # Safety check on file: block critical OS files
                    $safety = Test-PathSafety -Path $f.FullName
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

        if ($results.Count -ge ($Limit * 2)) {
            break
        }
    }

    return @($results | Sort-Object RawSize -Descending | Select-Object -First $Limit)
}
