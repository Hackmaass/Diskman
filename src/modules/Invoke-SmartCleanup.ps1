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
                    # Fast in-memory attribute check for reparse point (junction/symlink)
                    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        continue
                    }
                    # Skip symlinks, junctions, and unverified reparse points to avoid external traversal
                    $reparseCheck = Test-ReparsePoint -Path $sub.FullName
                    if (-not $reparseCheck.Success -or $reparseCheck.IsReparsePoint) {
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
        @{
            Id                = 'UserTemp'
            Group             = 'Windows & System'
            Category          = 'Windows User Temp'
            Icon              = '[TEMP]'
            Path              = $userTempPath
            Description       = 'Temporary application and cache files created by running user programs'
            WhatGetsDeleted   = 'Temporary session files, scratch buffers, installer extractors, and ephemeral .tmp files in %LOCALAPPDATA%\Temp.'
            SafetyExplanation = 'Safe: Temporary scratch space used by running programs. Files actively locked by open processes are automatically skipped. User documents, personal files, and program installations are never stored here.'
            Consequences      = 'None. Running applications will automatically create fresh temporary files during future sessions as needed.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SystemTemp'
            Group             = 'Windows & System'
            Category          = 'Windows System Temp'
            Icon              = '[SYS]'
            Path              = (Join-Path $sysRoot 'Temp')
            Description       = 'Operating system temporary cache files and service leftovers'
            WhatGetsDeleted   = 'Operating system service scratch files, driver extraction folders, and background installer leftovers in C:\Windows\Temp.'
            SafetyExplanation = 'Safe (Admin): Temporary files discarded by completed Windows updates and service installations. Active Windows kernel/service files are locked and skipped.'
            Consequences      = 'None. System services and installers generate new temporary files when required.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'WinUpdateCache'
            Group             = 'Windows & System'
            Category          = 'Windows Update Cache'
            Icon              = '[UPDATE]'
            Path              = (Join-Path $sysRoot 'SoftwareDistribution\Download')
            Description       = 'Advanced cleanup - Downloaded Windows Update packages and staging payloads'
            WhatGetsDeleted   = 'Downloaded Windows Update payload .cab archives, patch packages, and cumulative update staging files in C:\Windows\SoftwareDistribution\Download.'
            SafetyExplanation = 'Advanced (Admin): Only safe when Windows Update is idle. Diskman actively confirms Windows Update, BITS, and CBS are idle before proceeding. Parent metadata (DataStore) is strictly protected.'
            Consequences      = 'If an update was staged and pending restart, Windows Update will re-download the installation files from Microsoft servers during the next scan.'
            SafetyBadge       = 'ADVANCED'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Advanced'
            Recommended       = $false
            RequiresAdmin     = $true
        },
        @{
            Id                = 'DeliveryOpt'
            Group             = 'Windows & System'
            Category          = 'Delivery Optimization Files'
            Icon              = '[OPT]'
            Path              = (Join-Path $sysRoot 'SoftwareDistribution\DeliveryOptimization')
            Description       = 'Advanced cleanup - Cached Windows peer-to-peer delivery optimization chunks'
            WhatGetsDeleted   = 'Cached peer-to-peer Windows update chunk files and local network distribution bits in C:\Windows\SoftwareDistribution\DeliveryOptimization.'
            SafetyExplanation = 'Advanced (Admin): Cached chunks used solely to seed updates to other computers on your local network. Core OS files and update registries are not touched.'
            Consequences      = 'Future updates will download directly from Microsoft cloud CDNs rather than peer-to-peer cache.'
            SafetyBadge       = 'ADVANCED'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Advanced'
            Recommended       = $false
            RequiresAdmin     = $true
        },
        @{
            Id                = 'CrashDumps'
            Group             = 'Windows & System'
            Category          = 'Crash Dumps & Minidumps'
            Icon              = '[DUMP]'
            Path              = (Join-Path $localAppData 'CrashDumps')
            Description       = 'Application crash dumps (.dmp files) from previously crashed applications'
            WhatGetsDeleted   = 'Windows Error Reporting post-mortem memory dumps (.dmp) in %LOCALAPPDATA%\CrashDumps.'
            SafetyExplanation = 'Safe: Diagnostic crash memory snapshots captured after past application crashes. They are solely for developer debugging and have zero operational value.'
            Consequences      = 'None. Frees storage. A new dump will only be generated if a program crashes in the future.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'WERLogs'
            Group             = 'Windows & System'
            Category          = 'Windows Error Reports (WER)'
            Icon              = '[LOG]'
            Path              = (Join-Path $localAppData 'Microsoft\Windows\WER')
            Description       = 'Queued and archived Windows error reporting telemetry diagnostic data'
            WhatGetsDeleted   = 'Queued and archived Windows Error Reporting diagnostic reports in %LOCALAPPDATA%\Microsoft\Windows\WER.'
            SafetyExplanation = 'Safe: Telemetry and diagnostic queues waiting to be sent to Microsoft servers. Purging them removes accumulated telemetry without impacting any applications.'
            Consequences      = 'None. Diagnostic error queues are cleared.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'CbsLogs'
            Group             = 'Windows & System'
            Category          = 'Windows CBS & Component Logs'
            Icon              = '[LOG]'
            Path              = (Join-Path $sysRoot 'Logs\CBS')
            Description       = 'Historical Windows Component-Based Servicing installation log files'
            WhatGetsDeleted   = 'Historical Component-Based Servicing installation logs (CBS.log, CbsPersist_*.log/cab) in C:\Windows\Logs\CBS.'
            SafetyExplanation = 'Safe (Admin): Diagnostic text records from past Windows servicing and SFC commands. Active logs in use are skipped. Servicing state files and package manifests are strictly protected.'
            Consequences      = 'Historical installation text history is wiped; Windows CBS initiates a clean, fresh log upon the next servicing event.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'DismLogs'
            Group             = 'Windows & System'
            Category          = 'DISM & Servicing Logs'
            Icon              = '[LOG]'
            Path              = (Join-Path $sysRoot 'Logs\DISM')
            Description       = 'Deployment Image Servicing and Management log files'
            WhatGetsDeleted   = 'Diagnostic log files (dism.log) generated by Deployment Image Servicing and Management in C:\Windows\Logs\DISM.'
            SafetyExplanation = 'Safe (Admin): Historical servicing text logs from DISM operations.'
            Consequences      = 'None. Fresh logs are created when DISM is executed in the future.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'NvidiaDxCache'
            Group             = 'Gaming & GPU'
            Category          = 'NVIDIA DirectX Shader Cache (DXCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'NVIDIA\DXCache')
            Description       = 'Compiled DirectX game shader cache. Rebuilt dynamically by NVIDIA GPU driver.'
            WhatGetsDeleted   = 'Precompiled DirectX GPU shader pipeline binaries (.bin, .toc) in %LOCALAPPDATA%\NVIDIA\DXCache.'
            SafetyExplanation = 'Safe: Machine-code shaders compiled by the NVIDIA graphics driver. Clearing corrupt shaders resolves graphics glitches and game crashes. Game saves, profiles, and graphics settings are untouched.'
            Consequences      = 'Games may experience a brief one-time loading delay or minor stutter upon first launch while the GPU driver recompiles shaders.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NvidiaGlCache'
            Group             = 'Gaming & GPU'
            Category          = 'NVIDIA OpenGL/Vulkan Cache (GLCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'NVIDIA\GLCache')
            Description       = 'Compiled OpenGL and Vulkan game shader cache from NVIDIA GPU'
            WhatGetsDeleted   = 'Precompiled OpenGL and Vulkan GPU shader binaries in %LOCALAPPDATA%\NVIDIA\GLCache.'
            SafetyExplanation = 'Safe: Compiled graphics shaders. Game saves, user profiles, and driver configurations are never touched.'
            Consequences      = 'Rebuilt automatically by the NVIDIA graphics driver during gameplay.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'DirectXShaderCache'
            Group             = 'Gaming & GPU'
            Category          = 'Windows DirectX Shader Cache (D3DSCache)'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'D3DSCache')
            Description       = 'Global Windows DirectX shader cache shared across game titles'
            WhatGetsDeleted   = 'Global Windows Direct3D shader cache entries in %LOCALAPPDATA%\D3DSCache.'
            SafetyExplanation = 'Safe: Windows standard DirectX shader cache (equivalent to Windows Disk Cleanup cleanmgr.exe).'
            Consequences      = 'DirectX shaders will be recompiled dynamically by graphics drivers as 3D applications run.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'AmdDxCache'
            Group             = 'Gaming & GPU'
            Category          = 'AMD Radeon Shader Cache'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'AMD\DxCache')
            Description       = 'Compiled game shader cache for AMD Radeon graphics cards'
            WhatGetsDeleted   = 'Compiled DirectX graphics shaders for AMD Radeon GPUs in %LOCALAPPDATA%\AMD\DxCache.'
            SafetyExplanation = 'Safe: Machine-code shaders compiled by AMD Adrenalin. Game saves and driver settings are completely preserved.'
            Consequences      = 'Brief shader compilation upon first launch of 3D games.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'IntelShaderCache'
            Group             = 'Gaming & GPU'
            Category          = 'Intel Graphics Shader Cache'
            Icon              = '[GPU]'
            Path              = (Join-Path $localAppData 'Intel\ShaderCache')
            Description       = 'Compiled game shader cache for Intel Arc and Iris graphics'
            WhatGetsDeleted   = 'Precompiled shader binaries for Intel Arc and integrated GPUs in %LOCALAPPDATA%\Intel\ShaderCache.'
            SafetyExplanation = 'Safe: Rebuilt dynamically by Intel graphics drivers. User settings and profiles are untouched.'
            Consequences      = 'Brief one-time shader recompilation on initial game launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SteamWebCache'
            Group             = 'Gaming & GPU'
            Category          = 'Steam Web & HTTP Cache'
            Icon              = '[STEAM]'
            Path              = (Join-Path $localAppData 'Steam\htmlcache')
            Description       = 'Cached store web assets, media thumbnails, and browser cache in Steam'
            WhatGetsDeleted   = 'Embedded Chromium browser cache (store thumbnails, community images, web CSS) in %LOCALAPPDATA%\Steam\htmlcache.'
            SafetyExplanation = 'Safe: Only store and community browser graphics. Game files (steamapps), save games, and user credentials (config/) are strictly protected and never touched.'
            Consequences      = 'Steam store and community pages will re-fetch images and stylesheet assets from Steam servers upon browsing.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EpicGamesCache'
            Group             = 'Gaming & GPU'
            Category          = 'Epic Games Launcher Cache'
            Icon              = '[EPIC]'
            Path              = (Join-Path $localAppData 'EpicGamesLauncher\Saved\webcache')
            Description       = 'Cached store assets and web interface data in Epic Games Launcher'
            WhatGetsDeleted   = 'Storefront web assets, promotion graphics, and thumbnail caches in %LOCALAPPDATA%\EpicGamesLauncher\Saved\webcache.'
            SafetyExplanation = 'Safe: Only web interface cache. Installed game files, cloud saves, and login authentication tokens are completely untouched.'
            Consequences      = 'Store banners and thumbnails will re-download from Epic Games CDN when the launcher is opened.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EaAppCache'
            Group             = 'Gaming & GPU'
            Category          = 'EA Desktop / Origin Cache'
            Icon              = '[EA]'
            Path              = (Join-Path $localAppData 'Electronic Arts\EA Desktop\Cache')
            Description       = 'Cached game store artwork and web data in EA Desktop'
            WhatGetsDeleted   = 'Storefront graphics, web views, and interface cache in %LOCALAPPDATA%\Electronic Arts\EA Desktop\Cache.'
            SafetyExplanation = 'Safe: Launcher interface assets only. Installed games and local game saves remain completely untouched.'
            Consequences      = 'EA Desktop will re-cache store images upon launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UbisoftCache'
            Group             = 'Gaming & GPU'
            Category          = 'Ubisoft Connect Cache'
            Icon              = '[UBI]'
            Path              = (Join-Path $localAppData 'Ubisoft Game Launcher\cache')
            Description       = 'Cached client assets and avatars in Ubisoft Connect Launcher'
            WhatGetsDeleted   = 'Launcher avatars, news banners, and web UI cache in %LOCALAPPDATA%\Ubisoft Game Launcher\cache.'
            SafetyExplanation = 'Safe: Only UI cache. Installed games, save files, and login tokens are safely stored in separate folders and untouched.'
            Consequences      = 'Launcher will re-download store and avatar graphics when browsed.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'BattlenetCache'
            Group             = 'Gaming & GPU'
            Category          = 'Battle.net / Blizzard Agent Cache'
            Icon              = '[BNET]'
            Path              = (Join-Path $progData 'Battle.net\Agent\data\cache')
            Description       = 'Battle.net Agent patcher and installer cached metadata'
            WhatGetsDeleted   = 'Blizzard Agent patcher and installer cached metadata in %PROGRAMDATA%\Battle.net\Agent\data\cache.'
            SafetyExplanation = 'Safe (Admin): Ephemeral Blizzard agent patcher data. Game installations, save data, and user logins are preserved.'
            Consequences      = 'Battle.net Agent re-checks patch status from Blizzard servers when games are launched or updated.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $true
        },
        @{
            Id                = 'RiotClientLogs'
            Group             = 'Gaming & GPU'
            Category          = 'Riot Games Client Logs'
            Icon              = '[RIOT]'
            Path              = (Join-Path $localAppData 'Riot Games\Riot Client\Logs')
            Description       = 'Historical log dumps from Riot Client (League of Legends, Valorant)'
            WhatGetsDeleted   = 'Historical session text logs and crash traces in %LOCALAPPDATA%\Riot Games\Riot Client\Logs.'
            SafetyExplanation = 'Safe: Diagnostic text logs only. Vanguard anti-cheat, game files, and credentials are untouched.'
            Consequences      = 'None. Fresh session logs will begin on the next match.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UnrealEngineDdc'
            Group             = 'Gaming & GPU'
            Category          = 'Unreal Engine Derived Data Cache (DDC)'
            Icon              = '[UE]'
            Path              = (Join-Path $localAppData 'UnrealEngine\Common\DerivedDataCache')
            Description       = 'Derived data cache for Unreal Engine 4 and 5 game compilations'
            WhatGetsDeleted   = 'Derived Data Cache (cooked textures, audio, and compiled shaders) in %LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache.'
            SafetyExplanation = 'Optional: Safe to delete to free large disk space; project files and source code are completely untouched. However, recompilation requires significant CPU time.'
            Consequences      = 'Unreal Engine projects will take longer to load on the first open while the engine recompiles shaders and recooks assets.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'UnityCache'
            Group             = 'Gaming & GPU'
            Category          = 'Unity Editor & Asset Cache'
            Icon              = '[UNITY]'
            Path              = (Join-Path $localAppData 'Unity\cache')
            Description       = 'Downloaded package and asset store caches for Unity games'
            WhatGetsDeleted   = 'Downloaded Unity Asset Store packages and package manager tarballs in %LOCALAPPDATA%\Unity\cache.'
            SafetyExplanation = 'Optional: Safe duplicate archive of downloaded packages. Project source files are never touched.'
            Consequences      = 'Packages will re-download from the Unity Package Manager registry when opened in a project, requiring an active internet connection.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'PipCache'
            Group             = 'Developer Caches'
            Category          = 'Python Pip Wheel Cache'
            Icon              = '[PIP]'
            Path              = (Join-Path $localAppData 'pip\cache')
            Description       = 'Cached Python wheel binaries and download archives'
            WhatGetsDeleted   = 'Cached .whl binaries and source download tarballs in %LOCALAPPDATA%\pip\cache.'
            SafetyExplanation = 'Safe: Download copies of Python packages. Installed Python environments, virtual environments (venv), and scripts are NOT touched.'
            Consequences      = 'Subsequent pip install commands will fetch packages from PyPI instead of the local cache.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NpmCache'
            Group             = 'Developer Caches'
            Category          = 'Node.js NPM Cache'
            Icon              = '[NPM]'
            Path              = (Join-Path $appData 'npm-cache')
            Description       = 'Global Node Package Manager download cache'
            WhatGetsDeleted   = 'Global tarball archives cached by npm in %APPDATA%\npm-cache.'
            SafetyExplanation = 'Safe: Duplicate package download archives. Project node_modules, package.json, and global binaries are untouched.'
            Consequences      = 'Future npm install for previously cached packages will re-download tarballs from the npm registry.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'YarnCache'
            Group             = 'Developer Caches'
            Category          = 'Yarn Package Cache'
            Icon              = '[YARN]'
            Path              = (Join-Path $localAppData 'Yarn\Cache')
            Description       = 'Yarn package manager cached archives'
            WhatGetsDeleted   = 'Cached package archives in %LOCALAPPDATA%\Yarn\Cache.'
            SafetyExplanation = 'Safe: Duplicate package download archives. Project files, lockfiles, and application source code are untouched.'
            Consequences      = 'Packages will be re-downloaded from the registry if installed in new projects.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'NugetCache'
            Group             = 'Developer Caches'
            Category          = 'NuGet / .NET Cache'
            Icon              = '[NUGET]'
            Path              = (Join-Path $userProfile '.nuget\packages')
            Description       = 'Local cache of downloaded NuGet packages'
            WhatGetsDeleted   = 'Global cache of unpacked NuGet packages in %USERPROFILE%\.nuget\packages.'
            SafetyExplanation = 'Optional: Safe to delete to free massive space. Project source code and solution files are untouched.'
            Consequences      = 'The next dotnet build or Visual Studio build will automatically run dotnet restore to re-download required packages from nuget.org.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'GradleCache'
            Group             = 'Developer Caches'
            Category          = 'Gradle Build Cache'
            Icon              = '[GRADLE]'
            Path              = (Join-Path $userProfile '.gradle\caches')
            Description       = 'Downloaded jar artifacts and distribution zip caches in Gradle'
            WhatGetsDeleted   = 'Downloaded dependency JARs, wrapper distributions, and build outputs in %USERPROFILE%\.gradle\caches.'
            SafetyExplanation = 'Optional: Often consumes 10-50 GB. Safe to purge; project source code is completely untouched.'
            Consequences      = 'The next ./gradlew build will re-download project dependencies and plugins from Maven Central/Google repository.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'CargoCache'
            Group             = 'Developer Caches'
            Category          = 'Rust Cargo Registry Cache'
            Icon              = '[CARGO]'
            Path              = (Join-Path $userProfile '.cargo\registry\cache')
            Description       = 'Cached Rust crate archive files'
            WhatGetsDeleted   = 'Cached .crate download archives in %USERPROFILE%\.cargo\registry\cache.'
            SafetyExplanation = 'Optional: Download archives. Cargo source checkouts and compiled binaries in target/ are untouched.'
            Consequences      = 'Cargo will re-download .crate files from crates.io on the next build.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'ChromeCache'
            Group             = 'Browser & App Caches'
            Category          = 'Google Chrome Web Cache'
            Icon              = '[CHROME]'
            Path              = (Join-Path $localAppData 'Google\Chrome\User Data\Default\Cache')
            Description       = 'Cached web pages, images, and script assets in Google Chrome'
            WhatGetsDeleted   = 'Cached website images, scripts, stylesheets, and video buffers in %LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. PASSWORDS, LOGINS, BROWSING HISTORY, BOOKMARKS, COOKIES, AND EXTENSIONS ARE STRICTLY PROTECTED AND NEVER TOUCHED.'
            Consequences      = 'Websites will re-download images and stylesheet assets on the first visit, which may slightly increase initial page load time.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'EdgeCache'
            Group             = 'Browser & App Caches'
            Category          = 'Microsoft Edge Web Cache'
            Icon              = '[EDGE]'
            Path              = (Join-Path $localAppData 'Microsoft\Edge\User Data\Default\Cache')
            Description       = 'Cached media and webpage assets in Microsoft Edge'
            WhatGetsDeleted   = 'Cached media and webpage assets in %LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. Passwords, cookies, browsing history, bookmarks, and open tabs are strictly protected and never touched.'
            Consequences      = 'First page visits will re-fetch images and scripts from web servers.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'BraveCache'
            Group             = 'Browser & App Caches'
            Category          = 'Brave Browser Cache'
            Icon              = '[BRAVE]'
            Path              = (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
            Description       = 'Cached web data in Brave Browser'
            WhatGetsDeleted   = 'Web asset cache in %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache.'
            SafetyExplanation = 'Safe: Web media only. Crypto wallet keys, passwords, shields settings, and history are strictly protected and untouched.'
            Consequences      = 'Webpages re-cache static assets upon visit.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'DiscordCache'
            Group             = 'Browser & App Caches'
            Category          = 'Discord App Media Cache'
            Icon              = '[DISCORD]'
            Path              = (Join-Path $appData 'discord\Cache')
            Description       = 'Cached Discord media, avatars, and attachments'
            WhatGetsDeleted   = 'Cached Discord server avatars, emojis, stickers, and voice buffers in %APPDATA%\discord\Cache.'
            SafetyExplanation = 'Safe: Media buffer cache only. User logins, server lists, settings, and chats are in separate folders and untouched.'
            Consequences      = 'Server emojis and avatars re-download seamlessly in the background as you view channels.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'SpotifyCache'
            Group             = 'Browser & App Caches'
            Category          = 'Spotify Track Storage'
            Icon              = '[SPOTIFY]'
            Path              = (Join-Path $localAppData 'Spotify\Storage')
            Description       = 'Locally cached music streams and playback buffers in Spotify'
            WhatGetsDeleted   = 'Streamed track chunks and offline song storage in %LOCALAPPDATA%\Spotify\Storage.'
            SafetyExplanation = 'Optional: Safe to delete to free gigabytes. Cloud playlists, user account, and library are untouched.'
            Consequences      = 'Any songs previously downloaded for offline listening will need to be re-downloaded over Wi-Fi.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'VsCodeCache'
            Group             = 'Browser & App Caches'
            Category          = 'VS Code Editor Cache'
            Icon              = '[VSCODE]'
            Path              = (Join-Path $appData 'Code\Cache')
            Description       = 'VS Code editor cached runtime files and buffers'
            WhatGetsDeleted   = 'V8 code cache and Electron web view buffers in %APPDATA%\Code\Cache.'
            SafetyExplanation = 'Safe: Internal editor buffer cache. Extensions, user settings (settings.json), keybindings, and workspaces are completely untouched.'
            Consequences      = 'Rebuilt automatically on next VS Code launch.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'AdobeMediaCache'
            Group             = 'Browser & App Caches'
            Category          = 'Adobe Premiere Media Cache'
            Icon              = '[ADOBE]'
            Path              = (Join-Path $appData 'Adobe\Common\Media Cache Files')
            Description       = 'Cached video peak files, conformed audio, and render frames in Adobe CC'
            WhatGetsDeleted   = 'Conformed audio (.cfa), peak files (.pek), and video index frames in %APPDATA%\Adobe\Common\Media Cache Files.'
            SafetyExplanation = 'Safe: Scratch files generated when media is imported into timelines. Master media files and project files (.prproj, .aep) are NEVER touched.'
            Consequences      = 'The next time an Adobe project is opened, Premiere or After Effects will regenerate peak and audio waveform files in the background.'
            SafetyBadge       = 'SAFE'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
        },
        @{
            Id                = 'TelegramCache'
            Group             = 'Browser & App Caches'
            Category          = 'Telegram Desktop Media Cache'
            Icon              = '[TELEGRAM]'
            Path              = (Join-Path $appData 'Telegram Desktop\tdata\user_data\media_cache')
            Description       = 'Locally cached stickers, images, and voice notes in Telegram'
            WhatGetsDeleted   = 'Cached sticker packs, voice note buffers, and image thumbnails in %APPDATA%\Telegram Desktop\tdata\user_data\media_cache.'
            SafetyExplanation = 'Optional: Safe to delete. All media is safely retained in the Telegram cloud. Downloaded files in Downloads folder and account logins are untouched.'
            Consequences      = 'Stickers and photo previews will re-download from the Telegram cloud as you scroll through chats.'
            SafetyBadge       = 'OPTIONAL'
            Type              = 'DirectoryContents'
            SafetyLevel       = 'Optional'
            Recommended       = $false
            RequiresAdmin     = $false
        },
        @{
            Id                = 'RecycleBin'
            Group             = 'Recycle Bin'
            Category          = 'Windows Recycle Bin (C:)'
            Icon              = '[TRASH]'
            Path              = (Join-Path $sysDrive '`$Recycle.Bin')
            Description       = 'Deleted files and folders residing in the Windows Recycle Bin'
            WhatGetsDeleted   = 'Files and folders previously discarded into the Recycle Bin on drive C:.'
            SafetyExplanation = 'Safe (with confirmation): Permanently purges items that the user previously moved to the trash.'
            Consequences      = 'Purged items are permanently deleted and cannot be restored from the Recycle Bin.'
            SafetyBadge       = 'SAFE'
            Type              = 'RecycleBin'
            SafetyLevel       = 'Safe'
            Recommended       = $true
            RequiresAdmin     = $false
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
            Id                = $t.Id
            Group             = $t.Group
            CategoryName      = $t.Category
            Icon              = $t.Icon
            DisplayName       = $displayName
            Target            = $t.Path
            Type              = $t.Type
            SafetyLevel       = $t.SafetyLevel
            SafetyBadge       = $t.SafetyBadge
            WhatGetsDeleted   = $t.WhatGetsDeleted
            SafetyExplanation = $t.SafetyExplanation
            Consequences      = $t.Consequences
            RawBytes          = [long]$rawBytes
            DisplaySize       = $disp
            FileCount         = "$fileCount items"
            RawCount          = [int]$fileCount
            Description       = $t.Description
            Recommended       = [bool]$t.Recommended
            RequiresAdmin     = [bool]$t.RequiresAdmin
            IsSelected        = [bool]$isSelected
            PathExists        = [bool]$pathExists
        }
    }

    # Sort items by size descending: space-claiming items on top, 0-byte items at the end
    $sortedResults = @($results | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.CategoryName }; Descending = $false })
    return $sortedResults
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
            $targetSafety = Test-PathSafety -Path $target.Path
            if (-not $targetSafety.Safe) {
                return @()
            }

            # Queue-based safe traversal: never follow or recurse through reparse points
            $queue = New-Object System.Collections.Generic.Queue[string]
            $queue.Enqueue($target.Path)
            $maxInspectItems = 5000
            $inspectedCount = 0

            while ($queue.Count -gt 0 -and $inspectedCount -lt $maxInspectItems) {
                $current = $queue.Dequeue()
                try {
                    $dirInfo = New-Object System.IO.DirectoryInfo($current)

                    # Enumerate direct files in current directory
                    foreach ($f in $dirInfo.EnumerateFiles()) {
                        try {
                            $fileSafety = Test-PathSafety -Path $f.FullName
                            if (-not $fileSafety.Safe) { continue }

                            $fileList += [PSCustomObject]@{
                                Name          = $f.Name
                                FullPath      = $f.FullName
                                RawBytes      = [long]$f.Length
                                DisplaySize   = Format-Bytes -Bytes $f.Length
                                LastWriteTime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                                Extension     = $f.Extension
                            }
                            $inspectedCount++
                        } catch {}
                    }

                    # Enumerate direct subdirectories; skip all reparse points
                    foreach ($sub in $dirInfo.EnumerateDirectories()) {
                        $reparseCheck = Test-ReparsePoint -Path $sub.FullName
                        if (-not $reparseCheck.Success -or $reparseCheck.IsReparsePoint) {
                            # Skip reparse points and unverified directories
                            continue
                        }
                        $queue.Enqueue($sub.FullName)
                    }
                } catch {}
            }
        } catch {}
    }

    return @($fileList | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } | Select-Object -First $Limit)
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

                            # Detect Reparse Points / Junctions / Symbolic Links (Fail-Closed)
                            $reparseCheck = Test-ReparsePoint -Path $entry.FullName
                            if (-not $reparseCheck.Success) {
                                # Unknown reparse state = do not delete
                                $catSkippedCount++
                                if ($null -ne $OnProgress) {
                                    & $OnProgress "  [SAFETY GUARD] Skipped unverified reparse item: $($entry.Name) ($($reparseCheck.Reason))" "WARN"
                                }
                                continue
                            }

                            if ($reparseCheck.IsReparsePoint) {
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
