# What each big folder is and what to do about it. Rules match scanned folders by exact path only.
# Evidence rule: only paths verified on a real machine may be 'Clean'; everything else is Review/Uninstall/Command/System.

function Get-AllowedCommands {
    [CmdletBinding()]
    param()
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    # The UI never builds a command from scanned data: only these exact commands can run.
    return @{
        DockerPrune = @{
            Short = 'Prune Docker data'
            Exe = 'docker.exe'; Args = @('system', 'prune', '-f'); RequiresAdmin = $false
            Title = 'Prune unused Docker data'
            Consent = "This runs 'docker system prune -f'. Docker Desktop must be running. It removes stopped containers, unused networks and dangling images. Volumes are kept.`n`nIt frees space INSIDE Docker's virtual disk. The disk file on C: only shrinks after it is compacted (stop Docker Desktop, then use Compact). This cannot be undone."
        }
        CompactDisk = @{
            Short = 'Compact virtual disk'
            Exe = 'diskpart.exe'; Args = @('/s', '<generated script file>'); RequiresAdmin = $true
            Title = 'Compact a Docker or WSL virtual disk'
            Consent = "This shuts WSL down and runs diskpart to compact the virtual disk: select vdisk, attach it read-only, compact vdisk, detach.`n`nDocker Desktop must be quit first (Diskman refuses while it is running). Containers and images are not deleted; the disk file only gives back space that was already freed inside it, so run 'docker system prune' first to free more. It can take several minutes."
        }
        ComponentCleanup = @{
            Short = 'Component cleanup'
            Exe = 'Dism.exe'; Args = @('/Online', '/Cleanup-Image', '/StartComponentCleanup'); RequiresAdmin = $true
            Title = 'Clean up the Windows component store'
            Consent = "This runs 'Dism /Online /Cleanup-Image /StartComponentCleanup'. It removes superseded versions of Windows components from WinSxS.`n`nIt can take several minutes. Afterwards, already installed updates can no longer be uninstalled."
        }
        HibernateOff = @{
            Short = 'Turn hibernation off'
            Exe = 'powercfg.exe'; Args = @('/h', 'off'); RequiresAdmin = $true
            Title = 'Turn hibernation off'
            Consent = "This runs 'powercfg /h off'. It deletes hiberfil.sys and turns Hibernate OFF.`n`nIt also disables Fast Startup. You can turn it back on with 'powercfg /h on'."
        }
        ShadowDelete = @{
            Short = 'Delete oldest restore point'
            Exe = 'vssadmin.exe'; Args = @('delete', 'shadows', "/for=$sysDrive", '/oldest', '/quiet'); RequiresAdmin = $true
            Title = 'Delete the oldest shadow copy'
            Consent = "This runs 'vssadmin delete shadows /for=$sysDrive /oldest'. It deletes the OLDEST shadow copy, which removes a System Restore point and the file history stored in it.`n`nThis cannot be undone."
        }
    }
}

function Invoke-AllowedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DockerPrune', 'ComponentCleanup', 'HibernateOff', 'ShadowDelete', 'CompactDisk')]
        [string]$Id,

        [scriptblock]$OnLine = $null,

        # Only used by CompactDisk, and only accepted when it matches a registered Docker/WSL disk exactly
        [string]$Path = $null
    )

    if ($Id -eq 'CompactDisk') { return Invoke-VhdCompact -Path $Path -OnLine $OnLine }
    $cmd = (Get-AllowedCommands)[$Id]
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $say = { param($t) if ($null -ne $OnLine) { & $OnLine $t } }

    if ($cmd.RequiresAdmin -and -not $isAdmin) {
        & $say "Skipped: '$($cmd.Title)' needs Administrator rights. Use Restart as Administrator."
        return -1
    }
    if ($env:DISKMAN_DRY_RUN -eq '1') {
        # Test and demo switch: validation above still ran, but nothing is executed
        & $say "Dry run: would run $($cmd.Exe) $($cmd.Args -join ' ')"
        return 0
    }
    try {
        & $say "Running: $($cmd.Exe) $($cmd.Args -join ' ')"
        & $cmd.Exe @($cmd.Args) 2>&1 | ForEach-Object { & $say "$_" }
        return $LASTEXITCODE
    } catch {
        & $say "Could not run $($cmd.Exe): $($_.Exception.Message)"
        return -1
    }
}

function Get-SpaceRules {
    [CmdletBinding()]
    param()

    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $windows = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$drive\Windows" }
    $pf      = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$drive\Program Files" }
    $pd      = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$drive\ProgramData" }

    $rules = New-Object System.Collections.Generic.List[hashtable]
    $add = {
        param($path, $title, $what, $verdict, $safety, $extra)
        $r = @{ Path = $path; Title = $title; What = $what; Verdict = $verdict; Safety = $safety; TargetId = $null; CommandId = $null; Param = $null; Effect = $null; Uri = $null; RequiresAdmin = $false }
        if ($extra) { foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] } }
        $rules.Add($r)
    }

    # Every cleanup target is also a rule, so the Cleaner tab and the explorer never disagree
    foreach ($t in (Get-CleanableTargets)) {
        & $add $t.Path $t.Category $t.Description 'Clean' $t.SafetyLevel @{ TargetId = $t.Id; RequiresAdmin = [bool]$t.RequiresAdmin }
    }

    # Cache folders detected by structure (Find-AppCaches): each folder gets its own row of advice, cleaning is per app group
    foreach ($item in @($script:DetectedCacheItems)) {
        foreach ($t in @($item.Targets)) {
            & $add $t $item.CategoryName $item.Description 'Clean' $item.SafetyLevel @{ TargetId = $item.Id }
        }
    }

    # Virtual disks of Docker and WSL that can be compacted (found by registration, never by searching for *.vhdx)
    foreach ($disk in (Get-CompactableDisks)) {
        & $add (Split-Path -Path $disk.Path -Parent) "$($disk.Name) virtual disk" "A virtual disk file ($(Format-Bytes -Bytes $disk.Bytes)) that grows but never shrinks by itself. Compacting returns what was deleted inside it to C:." 'Command' 'Advanced' @{ CommandId = 'CompactDisk'; Param = $disk.Path; RequiresAdmin = $true; Effect = 'gives back only what Docker/WSL already freed inside the disk. Stop Docker Desktop first.' }
    }

    & $add "$local\Docker" 'Docker Desktop data' "Docker images, containers and volumes live in one virtual disk (docker_data.vhdx). Pruning frees space inside it; the file on C: only shrinks after compaction." 'Command' 'Advanced' @{ CommandId = 'DockerPrune'; Effect = 'frees space inside Docker, not on C:. C: only shrinks after the disk file is compacted.' }
    & $add "$local\Programs\DockerDesktop" 'Docker Desktop application' 'The Docker Desktop program files. Uninstall it from Settings if you no longer use Docker.' 'Uninstall' 'Review' @{ Effect = 'frees roughly the folder size once uninstalled.' }
    & $add "$pf\NVIDIA Corporation\RTX Remix" 'NVIDIA RTX Remix' 'An installed NVIDIA modding application. Uninstall it from Settings if you do not use it.' 'Uninstall' 'Review' $null
    & $add "$pd\NVIDIA Corporation\NVIDIA App\UpdateFramework" 'NVIDIA App update staging' 'Downloaded NVIDIA App update files. Not verified as safe to delete, so review it first.' 'Review' 'Review' $null
    & $add "$pd\NVIDIA\NGX\models" 'NVIDIA NGX models (DLSS)' 'AI models used by DLSS. The NVIDIA driver fetches them as needed, but this is not verified, so review it first.' 'Review' 'Review' $null
    & $add "$pd\NVIDIA\Streamline" 'NVIDIA Streamline' 'Shared NVIDIA graphics runtime files used by games.' 'Review' 'Review' $null
    & $add "$local\Claude-Data" 'Claude app data' 'Data of the Claude desktop app. Diskman never offers this for deletion.' 'Review' 'Review' $null
    & $add "$local\Arduino15\packages\esp32" 'Arduino ESP32 board package' 'ESP32 toolchains installed by the Arduino IDE. Remove them in Boards Manager if you no longer build for ESP32.' 'Review' 'Review' $null
    # Python installs from python.org / the Python install manager (any version)
    foreach ($d in (Get-ChildItem -Path "$local\Python" -Directory -Filter 'pythoncore-*' -ErrorAction SilentlyContinue)) {
        & $add $d.FullName "Python installation ($($d.Name))" 'A Python install. Most of its size is usually installed packages (for example torch). Remove packages you no longer need with pip uninstall.' 'Review' 'Review' $null
    }
    & $add "$roaming\Apple Computer\MobileSync\Backup" 'iPhone / iPad backups (iTunes)' 'Full device backups made by iTunes. Often 10-100 GB. Delete old ones from iTunes (Edit > Preferences > Devices), not by hand, and only if you no longer need to restore from them.' 'Review' 'Review' $null
    foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ } | Select-Object -Unique)) {
        & $add $od 'OneDrive folder' 'Files synced from OneDrive. To free space without losing them, right-click the folder in Explorer and choose Free up space (files stay online). Do not delete them: that deletes them from the cloud too.' 'Review' 'Review' $null
    }
    & $add "$pf\Microsoft Office" 'Microsoft Office' 'The installed Office applications. Uninstall from Settings only if you no longer use them.' 'Uninstall' 'Review' $null
    & $add "$local\hermes" 'hermes application data' 'Application data and runtimes of the hermes app. Review before removing.' 'Review' 'Review' $null
    & $add "$roaming\npm\node_modules" 'Global npm packages' 'Globally installed npm tools. They can be reinstalled with npm, but you may rely on them.' 'Review' 'Review' $null
    & $add "$windows\WinSxS" 'Windows component store (WinSxS)' 'Windows keeps component versions here, shared with System32 by hard links, so its real size is smaller than the number shown. Never delete it by hand; component cleanup is the safe way.' 'Command' 'Advanced' @{ CommandId = 'ComponentCleanup'; RequiresAdmin = $true; Effect = 'usually frees much less than the folder size shown, because most of it is shared with System32.' }
    & $add "$windows\System32" 'Windows system files' 'Core Windows files. Not reclaimable.' 'System' 'Review' $null
    & $add "$windows\Installer" 'Windows Installer cache' 'Needed to repair or uninstall programs. Deleting files here breaks them.' 'System' 'Review' $null
    & $add "$drive\hiberfil.sys" 'Hibernation file' 'Holds memory for hibernation and Fast Startup. Turning hibernation off deletes it.' 'Command' 'Advanced' @{ CommandId = 'HibernateOff'; RequiresAdmin = $true }
    & $add "$drive\Windows.old" 'Previous Windows installation' 'Left behind by a Windows upgrade. Remove it from Settings > Storage > Temporary files.' 'Uninstall' 'Review' @{ Uri = 'ms-settings:storagesense' }

    # Store Python keeps pip packages inside a package folder whose name carries a publisher suffix
    foreach ($d in (Get-ChildItem -Path "$local\Packages" -Directory -Filter 'PythonSoftwareFoundation.Python.*' -ErrorAction SilentlyContinue)) {
        & $add "$($d.FullName)\LocalCache\local-packages" 'Python packages (Microsoft Store Python)' 'Packages installed with pip for the Store version of Python. Review which projects need them.' 'Review' 'Review' $null
    }

    return $rules
}

$script:SpaceRuleIndex = $null
$script:DetectedCacheItems = @()

# Detected cache items become rules too; rebuilding the index makes the Overview and Explorer show advice for them
function Set-DetectedCacheItems {
    [CmdletBinding()]
    param($Items)
    $script:DetectedCacheItems = @($Items)
    $script:SpaceRuleIndex = $null
}

function Find-SpaceRule {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($null -eq $script:SpaceRuleIndex) {
        $script:SpaceRuleIndex = @{}
        foreach ($r in (Get-SpaceRules)) {
            try { $script:SpaceRuleIndex[[System.IO.Path]::GetFullPath($r.Path).TrimEnd('\').ToLowerInvariant()] = $r } catch {}
        }
    }
    $key = $Path.TrimEnd('\').ToLowerInvariant()
    return $script:SpaceRuleIndex[$key]
}

# Advice for folders no exact rule knows, from where the folder sits. Deliberately limited to Uninstall / Review / System:
# it can explain and point to Settings, but it can never offer Clean or Command, so a wrong guess cannot delete anything.
$script:AdviceContext = $null
function Get-GenericAdvice {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:?$') { return $null }   # a drive root has no leaf or parent to reason about
    $leaf = Split-Path -Path $p -Leaf
    $parent = (Split-Path -Path $p -Parent)
    if (-not $parent) { return $null }
    $parent = $parent.TrimEnd('\')

    # Known-folder lookups are slow and identical for every call, so they are read once per process
    if (-not $script:AdviceContext) {
        $profileDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
        $driveName = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
        $ownFolders = @()
        foreach ($f in 'Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic') {
            $kf = [System.Environment]::GetFolderPath($f); if ($kf) { $ownFolders += $kf.TrimEnd('\') }
        }
        $ownFolders += "$profileDir\Downloads"
        $script:AdviceContext = @{
            Profile = $profileDir
            Local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
            Roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
            Windows = $(if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$driveName\Windows" })
            Pf      = $(if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$driveName\Program Files" })
            Pf86    = $(if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\') } else { "$driveName\Program Files (x86)" })
            Pd      = $(if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$driveName\ProgramData" })
            Own     = $ownFolders
        }
    }
    $ctx = $script:AdviceContext
    $profilePath = $ctx.Profile; $local = $ctx.Local; $roaming = $ctx.Roaming; $windows = $ctx.Windows
    $pf = $ctx.Pf; $pf86 = $ctx.Pf86; $pd = $ctx.Pd

    $make = {
        param($verdict, $title, $what, $uri)
        @{ Path = $Path; Title = $title; What = $what; Verdict = $verdict; Safety = 'Review'; TargetId = $null; CommandId = $null; Param = $null; Effect = $null; Uri = $uri; RequiresAdmin = $false; Generic = $true }
    }
    $same = { param($a, $b) $a -ieq $b }

    # Installed programs. Windows components and hardware drivers are on a keep-list: never suggest uninstalling those.
    if ((& $same $parent $pf) -or (& $same $parent $pf86) -or (& $same $parent "$local\Programs")) {
        if ($leaf -match '^(Windows|Microsoft|Common Files|WindowsApps|ModifiableWindowsApps|Internet Explorer|Reference Assemblies|MSBuild|dotnet|WindowsPowerShell|PowerShell|Uninstall Information|NVIDIA|Intel|AMD|Advanced Micro Devices|Realtek|Qualcomm|Synaptics|Dolby|Waves|MediaTek)') {
            return & $make 'System' "$leaf (Windows or driver software)" 'Part of Windows or software that runs your hardware (drivers, graphics, audio). Keep it.' $null
        }
        return & $make 'Uninstall' "Installed program: $leaf" "A program installed on this PC. If you no longer use it, uninstall it from Settings > Apps. Do not delete the folder by hand: that leaves a broken entry behind." 'ms-settings:appsfeatures'
    }

    # Game libraries
    if ($p -match '\\steamapps\\common\\[^\\]+$') {
        return & $make 'Review' "Steam game: $leaf" 'A Steam game. Uninstall it from Steam (Library, right-click the game, Manage, Uninstall) so Steam stays consistent. Games are often the biggest items on a drive.' $null
    }
    if ($p -match '\\Epic Games\\[^\\]+$' -and $parent -match 'Epic Games$') {
        return & $make 'Review' "Epic Games game: $leaf" 'An Epic Games Store game. Uninstall it from the Epic Games Launcher library.' $null
    }
    if ($p -match '\\XboxGames\\[^\\]+$') {
        return & $make 'Uninstall' "Xbox / Store game: $leaf" 'A game installed through the Xbox app or Microsoft Store. Uninstall it from Settings > Apps.' 'ms-settings:appsfeatures'
    }

    # The user's own files (known folder locations, which can be renamed or redirected)
    foreach ($o in $ctx.Own) {
        if ((& $same $p $o) -or $p.StartsWith($o + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return & $make 'Review' "Your files: $leaf" 'Your own files. Diskman never deletes these in bulk. Use the Large Files tab to find the biggest ones, or move what you rarely open to another drive or cloud storage.' $null
        }
    }

    # Microsoft Store app data
    if ((& $same $parent "$local\Packages")) {
        return & $make 'Review' "Store app data: $leaf" 'Data of a Microsoft Store app. If you do not use the app, uninstall it from Settings > Apps; you can also reset it there (Advanced options) to clear its data.' 'ms-settings:appsfeatures'
    }

    # Tool folders in the user profile (.cargo, .gradle, .docker ...)
    if ((& $same $parent $profilePath) -and $leaf.StartsWith('.')) {
        return & $make 'Review' "Tool data: $leaf" 'Settings, caches and downloads of a developer or command-line tool. Some of it can be rebuilt, but it can also hold logins and project data, so check before removing anything.' $null
    }

    # Per-app data under AppData and ProgramData
    if ((& $same $parent $local) -or (& $same $parent $roaming)) {
        return & $make 'Review' "App data: $leaf" "Data of the app '$leaf'. It may hold caches, but also your settings and local files. Diskman only offers to clean folders it recognises; open this one to decide." $null
    }
    if ((& $same $parent $pd)) {
        return & $make 'Review' "Shared app data: $leaf" "Data shared by '$leaf' for all users on this PC (updates, caches, licences). Review before removing; uninstalling the program is usually the safe way to remove it." $null
    }

    if ($p.StartsWith($windows + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return & $make 'System' "Windows: $leaf" 'Part of Windows. Not reclaimable by hand.' $null
    }
    return $null
}
