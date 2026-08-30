function Get-FolderSizeFast {
    param(
        [string]$Path,
        [int]$MaxItems = 25000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ RawBytes = [long]0; FileCount = 0; Exists = $false }
    }

    try {
        $totalBytes = [long]0
        $count = 0
        $queue = New-Object System.Collections.Generic.Queue[string]
        $queue.Enqueue($Path)

        while ($queue.Count -gt 0 -and $count -lt $MaxItems) {
            $current = $queue.Dequeue()
            try {
                $dirInfo = New-Object System.IO.DirectoryInfo($current)
                foreach ($file in $dirInfo.EnumerateFiles()) {
                    try {
                        $totalBytes += $file.Length
                        $count++
                        if ($count -ge $MaxItems) { break }
                    } catch {}
                }
                foreach ($sub in $dirInfo.EnumerateDirectories()) {
                    # Skip symlinks and junctions to avoid infinite loops and external traversal
                    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        continue
                    }
                    $queue.Enqueue($sub.FullName)
                }
            } catch {}
        }
        return @{ RawBytes = $totalBytes; FileCount = $count; Exists = $true }
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
        # ==========================================
        # 1. WINDOWS & SYSTEM TARGETS
        # ==========================================
        @{
            Id          = 'UserTemp'
            Group       = 'Windows & System'
            Category    = 'Windows User Temp'
            Icon        = '[TEMP]'
            Path        = $userTempPath
            Description = 'Temporary application and cache files created by running user programs'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'SystemTemp'
            Group       = 'Windows & System'
            Category    = 'Windows System Temp'
            Icon        = '[SYS]'
            Path        = (Join-Path $sysRoot 'Temp')
            Description = 'Operating system temporary cache files'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'WinUpdateCache'
            Group       = 'Windows & System'
            Category    = 'Windows Update Cache'
            Icon        = '[UPDATE]'
            Path        = (Join-Path $sysRoot 'SoftwareDistribution\Download')
            Description = 'Advanced cleanup — Downloaded Windows Update packages. Windows may need to re-download update files if updates are in progress.'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Advanced'
            Recommended = $false
            RequiresAdmin = $true
        },
        @{
            Id          = 'DeliveryOpt'
            Group       = 'Windows & System'
            Category    = 'Delivery Optimization Files'
            Icon        = '[OPT]'
            Path        = (Join-Path $sysRoot 'SoftwareDistribution\DeliveryOptimization')
            Description = 'Advanced cleanup — Cached Windows peer-to-peer delivery optimization chunks.'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Advanced'
            Recommended = $false
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
            SafetyLevel = 'Safe'
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
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'CbsLogs'
            Group       = 'Windows & System'
            Category    = 'Windows CBS & Component Logs'
            Icon        = '[LOG]'
            Path        = (Join-Path $sysRoot 'Logs\CBS')
            Description = 'Historical Windows Component-Based Servicing installation log files'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'DismLogs'
            Group       = 'Windows & System'
            Category    = 'DISM & Servicing Logs'
            Icon        = '[LOG]'
            Path        = (Join-Path $sysRoot 'Logs\DISM')
            Description = 'Deployment Image Servicing and Management log files'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $true
        },

        # ==========================================
        # 2. GAMING & GPU SHADER CACHES
        # ==========================================
        @{
            Id          = 'NvidiaDxCache'
            Group       = 'Gaming & GPU'
            Category    = 'NVIDIA DirectX Shader Cache (DXCache)'
            Icon        = '[GPU]'
            Path        = (Join-Path $localAppData 'NVIDIA\DXCache')
            Description = 'Compiled DirectX game shader cache. Rebuilt dynamically by NVIDIA GPU driver.'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'NvidiaGlCache'
            Group       = 'Gaming & GPU'
            Category    = 'NVIDIA OpenGL/Vulkan Cache (GLCache)'
            Icon        = '[GPU]'
            Path        = (Join-Path $localAppData 'NVIDIA\GLCache')
            Description = 'Compiled OpenGL and Vulkan game shader cache from NVIDIA GPU'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'DirectXShaderCache'
            Group       = 'Gaming & GPU'
            Category    = 'Windows DirectX Shader Cache (D3DSCache)'
            Icon        = '[GPU]'
            Path        = (Join-Path $localAppData 'D3DSCache')
            Description = 'Global Windows DirectX shader cache shared across game titles'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'AmdDxCache'
            Group       = 'Gaming & GPU'
            Category    = 'AMD Radeon Shader Cache'
            Icon        = '[GPU]'
            Path        = (Join-Path $localAppData 'AMD\DxCache')
            Description = 'Compiled game shader cache for AMD Radeon graphics cards'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'IntelShaderCache'
            Group       = 'Gaming & GPU'
            Category    = 'Intel Graphics Shader Cache'
            Icon        = '[GPU]'
            Path        = (Join-Path $localAppData 'Intel\ShaderCache')
            Description = 'Compiled game shader cache for Intel Arc and Iris graphics'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'SteamWebCache'
            Group       = 'Gaming & GPU'
            Category    = 'Steam Web & HTTP Cache'
            Icon        = '[STEAM]'
            Path        = (Join-Path $localAppData 'Steam\htmlcache')
            Description = 'Cached store web assets, media thumbnails, and browser cache in Steam'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'EpicGamesCache'
            Group       = 'Gaming & GPU'
            Category    = 'Epic Games Launcher Cache'
            Icon        = '[EPIC]'
            Path        = (Join-Path $localAppData 'EpicGamesLauncher\Saved\webcache')
            Description = 'Cached store assets and web interface data in Epic Games Launcher'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'EaAppCache'
            Group       = 'Gaming & GPU'
            Category    = 'EA Desktop / Origin Cache'
            Icon        = '[EA]'
            Path        = (Join-Path $localAppData 'Electronic Arts\EA Desktop\Cache')
            Description = 'Cached game store artwork and web data in EA Desktop'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'UbisoftCache'
            Group       = 'Gaming & GPU'
            Category    = 'Ubisoft Connect Cache'
            Icon        = '[UBI]'
            Path        = (Join-Path $localAppData 'Ubisoft Game Launcher\cache')
            Description = 'Cached client assets and avatars in Ubisoft Connect Launcher'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'BattlenetCache'
            Group       = 'Gaming & GPU'
            Category    = 'Battle.net / Blizzard Agent Cache'
            Icon        = '[BNET]'
            Path        = (Join-Path $progData 'Battle.net\Agent\data\cache')
            Description = 'Battle.net Agent patcher and installer cached metadata'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $true
        },
        @{
            Id          = 'RiotClientLogs'
            Group       = 'Gaming & GPU'
            Category    = 'Riot Games Client Logs'
            Icon        = '[RIOT]'
            Path        = (Join-Path $localAppData 'Riot Games\Riot Client\Logs')
            Description = 'Historical log dumps from Riot Client (League of Legends, Valorant)'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'UnrealEngineDdc'
            Group       = 'Gaming & GPU'
            Category    = 'Unreal Engine Derived Data Cache (DDC)'
            Icon        = '[UE]'
            Path        = (Join-Path $localAppData 'UnrealEngine\Common\DerivedDataCache')
            Description = 'Derived data cache for Unreal Engine 4 and 5 game compilations'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $false
            RequiresAdmin = $false
        },
        @{
            Id          = 'UnityCache'
            Group       = 'Gaming & GPU'
            Category    = 'Unity Editor & Asset Cache'
            Icon        = '[UNITY]'
            Path        = (Join-Path $localAppData 'Unity\cache')
            Description = 'Downloaded package and asset store caches for Unity games'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $false
            RequiresAdmin = $false
        },

        # ==========================================
        # 3. DEVELOPER CACHES
        # ==========================================
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
            Id          = 'GradleCache'
            Group       = 'Developer Caches'
            Category    = 'Gradle Build Cache'
            Icon        = '[GRADLE]'
            Path        = (Join-Path $userProfile '.gradle\caches')
            Description = 'Downloaded jar artifacts and distribution zip caches in Gradle'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Optional'
            Recommended = $false
            RequiresAdmin = $false
        },
        @{
            Id          = 'CargoCache'
            Group       = 'Developer Caches'
            Category    = 'Rust Cargo Registry Cache'
            Icon        = '[CARGO]'
            Path        = (Join-Path $userProfile '.cargo\registry\cache')
            Description = 'Cached Rust crate archive files'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Optional'
            Recommended = $false
            RequiresAdmin = $false
        },

        # ==========================================
        # 4. BROWSER & MEDIA APPLICATION CACHES
        # ==========================================
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
            Category    = 'Discord App Media Cache'
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
            SafetyLevel = 'Optional'
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
            Id          = 'AdobeMediaCache'
            Group       = 'Browser & App Caches'
            Category    = 'Adobe Premiere Media Cache'
            Icon        = '[ADOBE]'
            Path        = (Join-Path $appData 'Adobe\Common\Media Cache Files')
            Description = 'Cached video peak files, conformed audio, and render frames in Adobe CC'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Safe'
            Recommended = $true
            RequiresAdmin = $false
        },
        @{
            Id          = 'TelegramCache'
            Group       = 'Browser & App Caches'
            Category    = 'Telegram Desktop Media Cache'
            Icon        = '[TELEGRAM]'
            Path        = (Join-Path $appData 'Telegram Desktop\tdata\user_data\media_cache')
            Description = 'Locally cached stickers, images, and voice notes in Telegram'
            Type        = 'DirectoryContents'
            SafetyLevel = 'Optional'
            Recommended = $false
            RequiresAdmin = $false
        },

        # ==========================================
        # 5. RECYCLE BIN
        # ==========================================
        @{
            Id          = 'RecycleBin'
            Group       = 'Recycle Bin'
            Category    = 'Windows Recycle Bin (C:)'
            Icon        = '[TRASH]'
            Path        = (Join-Path $sysDrive '`$Recycle.Bin')
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
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', '/') } else { "C:" }

    foreach ($t in $targets) {
        $rawBytes = [long]0
        $fileCount = 0
        $pathExists = $false

        if ($t.Type -eq 'RecycleBin') {
            $recyclePath = "$sysDrive\`$Recycle.Bin"
            $stats = Get-FolderSizeFast -Path $recyclePath
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
        $isAdminCurrent = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $isSelected = ($t.Recommended -and $rawBytes -gt 0 -and (-not $t.RequiresAdmin -or $isAdminCurrent))
        $displayName = if ($t.RequiresAdmin -and -not $isAdminCurrent) { "$($t.Category) [Admin Required]" } else { $t.Category }

        $results += [PSCustomObject]@{
            Id            = $t.Id
            Group         = $t.Group
            CategoryName  = $t.Category
            Icon          = $t.Icon
            DisplayName   = $displayName
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

            $initialCategoryBytes = $item.RawBytes
            $catFreedBytes = [long]0
            $catDeletedCount = 0
            $catSkippedCount = 0

            try {
                $itemsToClean = Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $totalInCat = ($itemsToClean | Measure-Object).Count

                foreach ($entry in $itemsToClean) {
                    # Rigorous safety validation on every single child item
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

                            # Detect Reparse Points / Junctions / Symbolic Links
                            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
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
                            $entryBytes = [long]$entry.Length

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

                if ($catFreedBytes -le 0 -and $catDeletedCount -gt 0) {
                    $catFreedBytes = $initialCategoryBytes
                }

                $totalFreedBytes += $catFreedBytes
                $totalDeletedCount += $catDeletedCount

                $freedFormatted = Format-Bytes -Bytes $catFreedBytes
                $msg = "Purged $($item.CategoryName): Cleaned $catDeletedCount items (Freed $freedFormatted)"
                if ($catSkippedCount -gt 0) {
                    if (-not $isAdmin) {
                        $msg += " [$catSkippedCount locked/in-use items skipped (run as Administrator to clean system items)]"
                    } else {
                        $msg += " [$catSkippedCount locked/protected items skipped]"
                    }
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
