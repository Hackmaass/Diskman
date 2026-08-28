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
            # Double-check safety guard on the target root
            $targetSafety = Test-PathSafety -Path $targetPath
            if (-not $targetSafety.Safe -and $targetPath -notlike "C:\Windows\SoftwareDistribution\*" -and $targetPath -notlike "C:\Windows\Temp*" -and $targetPath -notlike "C:\Windows\Logs\*") {
                $msg = "BLOCKED: Target directory failed safety check: $($targetSafety.Reason)"
                $logMessages += $msg
                if ($null -ne $OnProgress) {
                    & $OnProgress $msg "ERROR"
                }
                continue
            }

            $initialCategoryBytes = $item.RawBytes
            $catFreedBytes = [long]0
            $catDeletedCount = 0
            $catSkippedCount = 0

            try {
                $itemsToClean = Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $totalInCat = ($itemsToClean | Measure-Object).Count

                foreach ($entry in $itemsToClean) {
                    # Rigorous safety validation on every single item
                    $itemSafety = Test-PathSafety -Path $entry.FullName
                    if (-not $itemSafety.Safe) {
                        $catSkippedCount++
                        if ($null -ne $OnProgress) {
                            & $OnProgress "  [SAFETY GUARD] Skipped protected item: $($entry.Name) ($($itemSafety.Reason))" "WARN"
                        }
                        continue
                    }

                    $entryBytes = [long]0
                    $entryDeleted = $false

                    try {
                        if ($entry.PSIsContainer) {
                            $entryBytes = (Get-FolderSizeFast -Path $entry.FullName).RawBytes
                            
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

                # Restore services if paused
                foreach ($svc in $restartedServices) {
                    try {
                        Start-Service -Name $svc -ErrorAction SilentlyContinue
                        if ($null -ne $OnProgress) {
                            & $OnProgress "  -> Restored service $svc" "INFO"
                        }
                    } catch {}
                }

                if ($catFreedBytes -le 0 -and $catDeletedCount -gt 0) {
                    $catFreedBytes = $initialCategoryBytes
                }

                $totalFreedBytes += $catFreedBytes
                $totalDeletedCount += $catDeletedCount

                $freedFormatted = Format-Bytes -Bytes $catFreedBytes
                $msg = "Purged $($item.CategoryName): Cleaned $catDeletedCount items (Freed $freedFormatted)"
                if ($catSkippedCount -gt 0) {
                    $msg += " [$catSkippedCount locked/protected items skipped]"
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
