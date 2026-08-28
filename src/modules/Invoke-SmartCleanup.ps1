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
