# Finds regenerable cache folders of the apps installed for this user (every browser profile, Electron apps, VS Code family).
# Detection is by folder STRUCTURE, never by name alone: a bare "Cache" folder can be anything, but a folder that holds
# Cache_Data\index is a Chromium HTTP cache. Anything not matching a signature stays out of the list (Review in the explorer).

# Folders the detector must never offer, whatever their name
function Test-AppCacheExcluded {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$FixedTargetPaths = @())

    $p = $Path.TrimEnd('\')
    if ($p -match '\\Claude-Data(\\|$)') { return $true }                      # the Claude desktop app's own data
    if ($p -match '\\AppData\\Local\\Packages(\\|$)') { return $true }          # Store apps: not offered in this version
    if ($p -match '\\AppData\\Local\\Microsoft\\(Windows|WindowsApps)(\\|$)') { return $true }
    foreach ($fixed in $FixedTargetPaths) {
        if ($fixed -and (Test-IsSubpathOrEqual -Candidate $p -Parent $fixed)) { return $true }   # already a fixed target: never count twice
    }
    return $false
}

# Returns @{ Safety = 'Safe'|'Optional'; Kind = <text> } when the folder matches a known cache layout, else $null
function Get-AppCacheKind {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $leaf = Split-Path -Path $Path -Leaf
    $parent = Split-Path -Path $Path -Parent
    $has = { param($rel) Test-Path -LiteralPath (Join-Path $Path $rel) }

    switch -Regex ($leaf) {
        '^Cache$' {
            if ((& $has 'Cache_Data\index') -or ((& $has 'index') -and (& $has 'data_0'))) { return @{ Safety = 'Safe'; Kind = 'web cache' } }
            return $null
        }
        '^(GPUCache|GrShaderCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache)$' {
            if ((& $has 'index') -or (& $has 'data_0')) { return @{ Safety = 'Safe'; Kind = 'GPU/shader cache' } }
            return $null
        }
        '^Code Cache$' {
            if ((& $has 'js') -or (& $has 'wasm')) { return @{ Safety = 'Safe'; Kind = 'compiled script cache' } }
            return $null
        }
        '^CacheStorage$' {
            # Progressive web apps keep offline data here, so this one is Optional
            if ((Split-Path -Path $parent -Leaf) -eq 'Service Worker' -and (Test-Path -LiteralPath (Join-Path $parent 'Database'))) { return @{ Safety = 'Optional'; Kind = 'service worker cache' } }
            return $null
        }
        '^(component_crx_cache|extensions_crx_cache)$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'Local State')) { return @{ Safety = 'Optional'; Kind = 'extension download cache' } }
            return $null
        }
        '^Crashpad$' {
            if ((& $has 'reports') -or (& $has 'metadata')) { return @{ Safety = 'Safe'; Kind = 'crash report database' } }
            return $null
        }
        '^(CachedData|CachedProfilesData|logs)$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'User\settings.json')) { return @{ Safety = 'Safe'; Kind = 'editor cache/logs' } }
            return $null
        }
        '^CachedExtensionVSIXs$' {
            if (Test-Path -LiteralPath (Join-Path $parent 'User\settings.json')) { return @{ Safety = 'Optional'; Kind = 'downloaded extension packages' } }
            return $null
        }
    }
    return $null
}

# One group (= one Cleaner row) per app: the first one or two folders below AppData\Local or AppData\Roaming
function Get-AppCacheGroupKey {
    [CmdletBinding()]
    param([string]$Path, [string]$LocalRoot, [string]$RoamingRoot)

    foreach ($root in $LocalRoot, $RoamingRoot) {
        if ($root -and $Path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $parts = $Path.Substring($root.Length + 1).Split('\')
            $takeTwo = $parts.Count -gt 2 -and $parts[0] -in @('Google', 'BraveSoftware', 'Microsoft', 'Mozilla', 'Programs', 'Opera Software', 'Vivaldi')
            return $(if ($takeTwo) { "$($parts[0])\$($parts[1])" } else { $parts[0] })
        }
    }
    return $null
}

function Find-AppCaches {
    [CmdletBinding()]
    # AppDataPath is a seam for tests: it replaces the user's AppData\Local and \Roaming as the place to search
    param([Parameter(Mandatory = $true)] $Root, [long]$MinBytes = 5MB, [string]$AppDataPath = $null)

    $profilePath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $searchRoot = "$profilePath\AppData"
    if ($AppDataPath) { $searchRoot = $AppDataPath.TrimEnd('\'); $local = $searchRoot; $roaming = $searchRoot }
    $appData = Find-TreeNode -Root $Root -Path $searchRoot
    if ($null -eq $appData) { return @() }

    $fixed = @(Get-CleanableTargets | ForEach-Object { $_.Path })
    $accepted = New-Object System.Collections.Generic.List[object]

    $visit = {
        param($node)
        foreach ($child in $node.Children) {
            if ($child.Bytes -lt $MinBytes) { continue }
            # Whole areas that are never offered: do not even walk into them
            if ($child.Path -match '\\Claude-Data$|\\AppData\\Local\\Packages$') { continue }
            $kind = Get-AppCacheKind -Path $child.Path
            if ($kind) {
                if (-not (Test-AppCacheExcluded -Path $child.Path -FixedTargetPaths $fixed)) {
                    $key = Get-AppCacheGroupKey -Path $child.Path -LocalRoot $local -RoamingRoot $roaming
                    if ($key) { $accepted.Add([PSCustomObject]@{ Node = $child; Kind = $kind.Kind; Safety = $kind.Safety; Key = $key }) }
                }
                continue            # the outermost match wins: never descend into a cache
            }
            & $visit $child
        }
    }
    & $visit $appData

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($accepted | Group-Object -Property Key)) {
        $nodes = @($group.Group)
        $bytes = [long](($nodes | ForEach-Object { $_.Node.Bytes } | Measure-Object -Sum).Sum)
        $files = [int](($nodes | ForEach-Object { $_.Node.Files } | Measure-Object -Sum).Sum)
        $level = if (@($nodes | Where-Object { $_.Safety -eq 'Optional' }).Count -gt 0) { 'Optional' } else { 'Safe' }
        $name = (Get-Culture).TextInfo.ToTitleCase((Split-Path -Path $group.Name -Leaf))
        $paths = @($nodes | ForEach-Object { $_.Node.Path })
        $kinds = (($nodes | ForEach-Object { $_.Kind } | Sort-Object -Unique) -join ', ')
        $isSelected = ($level -eq 'Safe' -and $bytes -gt 0)
        $items.Add([PSCustomObject]@{
            Id = "App:$($group.Name.ToLowerInvariant())"; Group = 'Browser & App Caches'; CategoryName = "$name caches (detected)"
            Icon = '[APP]'; DisplayName = "$name caches (detected)"; Target = $paths[0]; Targets = $paths; Type = 'DirectoryContents'
            SafetyLevel = $level; SafetyBadge = $level.ToUpper()
            WhatGetsDeleted = "Cache folders detected inside the $name app data ($kinds): " + (($paths | ForEach-Object { "$(Split-Path -Path (Split-Path -Path $_ -Parent) -Leaf)\$(Split-Path -Path $_ -Leaf)" }) -join '; ')
            SafetyExplanation = "$level`: Folders recognised by their contents as caches the app rebuilds itself. Logins, bookmarks, history, settings and documents are not in these folders. Close the app first; files in use are skipped."
            Consequences = $(if ($level -eq 'Optional') { 'The app may start a little slower once while it rebuilds. Offline data held by web apps (service worker caches) or downloaded extension packages is fetched again when needed.' } else { 'The app may start a little slower once while caches are rebuilt.' })
            RawBytes = $bytes; DisplaySize = (Format-Bytes -Bytes $bytes); FileCount = "$files items"; RawCount = $files
            Description = "Detected cache folders of $name ($kinds)"
            Recommended = ($level -eq 'Safe'); RequiresAdmin = $false; IsSelected = [bool]$isSelected; PathExists = $true
            CanSelect = $true; SelectTip = 'Include in Clean Selected'; Dynamic = $true
        })
    }
    return @($items | Sort-Object -Property @{ Expression = { $_.RawBytes }; Descending = $true })
}

# Re-measure detected items after a clean (they are not in the fixed target list, so a normal rescan cannot do it)
function Update-DetectedItemSize {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Item)

    $bytes = [long]0; $files = 0
    foreach ($t in @($Item.Targets)) {
        $m = Get-FolderSizeFast -Path $t
        $bytes += [long]$m.RawBytes; $files += [int]$m.FileCount
    }
    $Item.RawBytes = $bytes; $Item.RawCount = $files; $Item.DisplaySize = Format-Bytes -Bytes $bytes; $Item.FileCount = "$files items"
    $Item.IsSelected = $false
    return $Item
}
