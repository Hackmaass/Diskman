# Space Windows manages itself, shown with plain-English notes so the numbers are not a mystery.

# Finds a folder in a scanned tree by walking path components (folders under 1 MB are not in the tree).
function Find-TreeNode {
    [CmdletBinding()]
    param($Root, [string]$Path)

    if ($null -eq $Root -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $node = $Root
    $rest = $Path.Substring([math]::Min($Path.Length, $Root.Path.TrimEnd('\').Length)).Trim('\')
    if ($rest -eq '') { return $node }
    foreach ($part in $rest.Split('\')) {
        $node = $node.Children | Where-Object { $_.Name -ieq $part } | Select-Object -First 1
        if ($null -eq $node) { return $null }
    }
    return $node
}

function Get-SystemSpace {
    [CmdletBinding()]
    param($Root = $null, [bool]$Elevated = $false)

    $drive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $rows = New-Object System.Collections.Generic.List[object]
    $row = { param($n, $b, $note, $admin, $cmd, $uri = $null) $rows.Add([PSCustomObject]@{ Name = $n; Bytes = $b; Note = $note; NeedsAdmin = $admin; CommandId = $cmd; Uri = $uri }) }

    # Locked system files are visible to DirectoryInfo even without administrator rights
    $rootDir = New-Object System.IO.DirectoryInfo "$drive\"
    $fileSize = { param($name) $f = $rootDir.EnumerateFiles($name) | Select-Object -First 1; if ($f) { [long]$f.Length } else { $null } }

    $swap = & $fileSize 'swapfile.sys'
    & $row 'swapfile.sys' $swap 'Used by Windows for modern apps. Windows manages it; small.' $false $null

    $pageNote = 'No paging file found.'
    try {
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)
        if ($pf.Count -gt 0) {
            $where = ($pf | ForEach-Object { "$($_.Name) ($([math]::Round($_.AllocatedBaseSize / 1024, 1)) GB)" }) -join ', '
            $onC = @($pf | Where-Object { $_.Name -like "$drive*" }).Count -gt 0
            $pageNote = if ($onC) { "Paging file on $drive`: $where. Windows manages it." } else { "Paging file is not on $drive`: $where. It does not use space on $drive." }
        }
    } catch {}
    $page = & $fileSize 'pagefile.sys'
    & $row 'Paging file' $page $pageNote $false $null

    $hiber = & $fileSize 'hiberfil.sys'
    if ($null -ne $hiber) {
        & $row 'Hibernation file (hiberfil.sys)' $hiber 'Used by Hibernate and Fast Startup. Turning hibernation off frees it.' $true 'HibernateOff'
    } else {
        & $row 'Hibernation file (hiberfil.sys)' 0 'Hibernation is off. Nothing to free here.' $false $null
    }

    if ($Elevated) {
        # Win32_ShadowStorage is language-independent (vssadmin text is not). It needs an elevated session; if it fails the size stays "not measured".
        $shadow = $null
        try {
            $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction Stop
            $used = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID } | ForEach-Object { [long]$_.UsedSpace })
            if ($used.Count -gt 0) { $shadow = [long]($used | Measure-Object -Sum).Sum }
        } catch {}
        & $row 'Shadow copies (restore points)' $shadow 'Restore points and file history snapshots. Deleting the oldest frees space but removes a restore point.' $false $(if ($shadow) { 'ShadowDelete' } else { $null })
    } else {
        & $row 'Shadow copies (restore points)' $null 'Needs administrator to measure. Often the biggest hidden item.' $true $null
    }

    $winsxs = Find-TreeNode -Root $Root -Path "$($env:SystemRoot)\WinSxS"
    & $row 'Windows component store (WinSxS)' $(if ($winsxs) { [long]$winsxs.Bytes } else { $null }) 'Shared with System32 by hard links, so the real size is smaller. Use component cleanup, never delete by hand.' $true 'ComponentCleanup'

    # A crash dump left by a Windows blue screen: very common, often several GB. Settings removes it safely.
    try {
        $dump = (New-Object System.IO.DirectoryInfo $env:SystemRoot).EnumerateFiles('MEMORY.DMP') | Select-Object -First 1
        if ($dump) { & $row 'System crash dump (MEMORY.DMP)' ([long]$dump.Length) "Left by a Windows crash; only useful for debugging it. Remove it in Settings > Storage > Temporary files (System error memory dump files)." $false $null 'ms-settings:storagesense' }
    } catch {}

    foreach ($name in 'Windows.old', '$Windows.~BT', '$WinREAgent') {
        $n = Find-TreeNode -Root $Root -Path "$drive\$name"
        if ($n) { & $row $name ([long]$n.Bytes) 'Left behind by a Windows upgrade or update. Remove it from Settings > Storage > Temporary files.' $false $null 'ms-settings:storagesense' }
    }
    return $rows.ToArray()
}
