# Docker Desktop and WSL keep their data in virtual disks (.vhdx) that grow but never shrink on their own.
# Compacting returns what was deleted INSIDE the disk to C:. Disks are found only through how they are registered
# (Docker's fixed paths and each WSL distro's BasePath), never by searching for *.vhdx: other apps keep VM disks too.

function Get-CompactableDisks {
    [CmdletBinding()]
    param()

    $local = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $found = New-Object System.Collections.Generic.List[object]
    $add = {
        param($name, $path, $kind)
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $found.Add([PSCustomObject]@{ Name = $name; Path = [System.IO.Path]::GetFullPath($path); Bytes = [long](Get-Item -LiteralPath $path -Force).Length; Kind = $kind })
        }
    }

    & $add 'Docker Desktop data' "$local\Docker\wsl\disk\docker_data.vhdx" 'Docker'
    & $add 'Docker Desktop (main)' "$local\Docker\wsl\main\ext4.vhdx" 'Docker'
    & $add 'Docker Desktop (data)' "$local\Docker\wsl\data\ext4.vhdx" 'Docker'

    try {
        foreach ($key in (Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop)) {
            $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($p.BasePath -and $p.DistributionName -and $p.DistributionName -notlike 'docker-desktop*') {
                $base = ([string]$p.BasePath) -replace '^\\\\\?\\', ''
                & $add "WSL: $($p.DistributionName)" (Join-Path $base 'ext4.vhdx') 'WSL'
            }
        }
    } catch {}

    # The same file can be reached twice (Docker's own distro is also registered): keep one entry per path
    return @($found | Group-Object -Property { $_.Path.ToLowerInvariant() } | ForEach-Object { $_.Group[0] })
}

# Docker Desktop's engine pipe exists only while the engine runs (instant check, no process start)
function Test-DockerEngineRunning {
    [CmdletBinding()]
    param()
    return ((Test-Path -LiteralPath '\\.\pipe\dockerDesktopLinuxEngine') -or (Test-Path -LiteralPath '\\.\pipe\docker_engine'))
}

# The exact text handed to diskpart: nothing but the validated path is variable
function New-DiskpartCompactScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return "select vdisk file=`"$Path`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit`r`n"
}

# Best effort after every attempt: a failed compact must not leave the disk attached (Docker and WSL could not start)
function New-DiskpartDetachScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return "select vdisk file=`"$Path`"`r`ndetach vdisk noerr`r`nexit`r`n"
}

function Invoke-VhdCompact {
    [CmdletBinding()]
    param([string]$Path, [scriptblock]$OnLine = $null)

    $say = { param($t) if ($null -ne $OnLine) { & $OnLine $t } }

    $disk = @(Get-CompactableDisks | Where-Object { $_.Path -ieq $Path }) | Select-Object -First 1
    if (-not $disk) {
        & $say "Refused: '$Path' is not a registered Docker or WSL disk, so Diskman will not compact it."
        return -1
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        & $say "Skipped: compacting a virtual disk needs Administrator rights. Use Restart as Administrator."
        return -1
    }
    if ($env:DISKMAN_DRY_RUN -eq '1') {
        & $say "Dry run: would shut WSL down and compact '$($disk.Path)' with diskpart."
        return 0
    }
    if (Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue) {
        & $say "Skipped: Docker Desktop is still running. Quit Docker Desktop from its tray icon first, then try again."
        return -1
    }

    & $say "Shutting down WSL so the disk is not in use..."
    & wsl.exe --shutdown 2>&1 | ForEach-Object { & $say "$_" }
    Start-Sleep -Seconds 3

    try {
        $probe = [System.IO.File]::Open($disk.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
    } catch {
        & $say "Skipped: the disk is still in use by another program ($($_.Exception.Message)). Close anything using WSL or Docker and try again."
        return -1
    }

    $before = [long](Get-Item -LiteralPath $disk.Path -Force).Length
    $tmpDir = [System.IO.Path]::GetTempPath()
    $scriptFile = Join-Path $tmpDir ("diskman_compact_" + [guid]::NewGuid().ToString('N') + ".txt")
    $detachFile = Join-Path $tmpDir ("diskman_detach_" + [guid]::NewGuid().ToString('N') + ".txt")
    $failed = $false
    try {
        [System.IO.File]::WriteAllText($scriptFile, (New-DiskpartCompactScript -Path $disk.Path), [System.Text.Encoding]::ASCII)
        & $say "Compacting $($disk.Name) ($(Format-Bytes -Bytes $before)). This can take several minutes..."
        $output = @(& diskpart.exe /s $scriptFile 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
        foreach ($line in $output) { if ($line.Trim()) { & $say $line } }
        # The exit code decides (diskpart's messages are translated, so their text cannot be relied on)
        $failed = ($exit -ne 0)
    } finally {
        try {
            [System.IO.File]::WriteAllText($detachFile, (New-DiskpartDetachScript -Path $disk.Path), [System.Text.Encoding]::ASCII)
            & diskpart.exe /s $detachFile 2>&1 | Out-Null
        } catch {}
        Remove-Item -LiteralPath $scriptFile, $detachFile -Force -ErrorAction SilentlyContinue
    }
    if ($failed) {
        & $say "Compaction failed. The disk was detached again, so Docker and WSL can start normally. Details are in the lines above."
        return -1
    }
    $after = [long](Get-Item -LiteralPath $disk.Path -Force).Length
    & $say "Disk file went from $(Format-Bytes -Bytes $before) to $(Format-Bytes -Bytes $after) (freed $(Format-Bytes -Bytes ([math]::Max([long]0, $before - $after))))."
    return 0
}
