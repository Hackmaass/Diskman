# One-pass directory size tree for the Overview and Space Explorer, plus the accounting that makes every byte of "used" visible.
# Compiled C# because a PowerShell loop over a million files is minutes slower. Loaded once per process.
if (-not ('Diskman.TreeScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace Diskman {
    // Invariant: Bytes == OwnBytes + sum(Children.Bytes). Folders under 1 MB are folded into the parent's OwnBytes.
    public sealed class Node {
        public string Path, Name;
        public long Bytes, OwnBytes, Files, ModifiedTicks;
        public bool Shared;
        public List<Node> Children = new List<Node>();
    }
    public static class TreeScan {
        public static volatile bool Cancel;
        public static int Parallelism = 8;   // lowered for spinning disks, where parallel seeks slow the scan down
        public static long ScannedFiles, ScannedBytes, Errors;
        public static volatile string Current = "";
        public static ConcurrentDictionary<string, long> Partial = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        const long MinChild = 1048576;
        const int PlaceholderAttrs = 0x1000 | 0x40000 | 0x400000; // Offline, RecallOnOpen, RecallOnDataAccess: cloud files that use no disk

        public static void Reset() { Cancel = false; ScannedFiles = 0; ScannedBytes = 0; Errors = 0; Current = ""; Partial.Clear(); }
        public static Node Scan(string root) { return Walk(new DirectoryInfo(root), 0); }

        static Node Walk(DirectoryInfo dir, int depth) {
            var node = new Node { Path = dir.FullName, Name = dir.Name };
            var subs = new List<DirectoryInfo>();
            try {
                foreach (var e in dir.EnumerateFileSystemInfos()) {
                    if (Cancel) break;
                    var d = e as DirectoryInfo;
                    if (d != null) {
                        if ((d.Attributes & FileAttributes.ReparsePoint) == 0) subs.Add(d);
                    } else {
                        try {
                            if (((int)e.Attributes & PlaceholderAttrs) != 0) continue;
                            long len = ((FileInfo)e).Length;
                            node.OwnBytes += len; node.Files++;
                            long t = e.LastWriteTimeUtc.Ticks; if (t > node.ModifiedTicks) node.ModifiedTicks = t;
                            Interlocked.Increment(ref ScannedFiles); Interlocked.Add(ref ScannedBytes, len);
                        } catch { Interlocked.Increment(ref Errors); }
                    }
                }
            } catch { Interlocked.Increment(ref Errors); }

            if (depth == 1) Current = dir.Name;
            var kids = new Node[subs.Count];
            if (depth <= 2 && subs.Count > 1) {
                Parallel.For(0, subs.Count, new ParallelOptions { MaxDegreeOfParallelism = Parallelism }, i => {
                    kids[i] = Walk(subs[i], depth + 1);
                    if (depth == 0) Partial[subs[i].FullName] = kids[i].Bytes;
                });
            } else {
                for (int i = 0; i < subs.Count && !Cancel; i++) {
                    kids[i] = Walk(subs[i], depth + 1);
                    if (depth == 0) Partial[subs[i].FullName] = kids[i].Bytes;
                }
            }
            foreach (var k in kids) {
                if (k == null) continue;
                node.Files += k.Files;
                if (k.ModifiedTicks > node.ModifiedTicks) node.ModifiedTicks = k.ModifiedTicks;
                if (k.Bytes >= MinChild) node.Children.Add(k); else node.OwnBytes += k.Bytes;
            }
            node.Children.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
            long total = node.OwnBytes; foreach (var c in node.Children) total += c.Bytes;
            node.Bytes = total;
            // WinSxS is hard-linked with System32 and friends: its file-size sum overstates real use
            node.Shared = node.Path.EndsWith("\\Windows\\WinSxS", StringComparison.OrdinalIgnoreCase);
            return node;
        }
    }
}
'@
}

# Spinning disks lose time to parallel seeks; SSD/NVMe benefit from many threads. Unknown stays in the middle.
function Get-ScanParallelism {
    [CmdletBinding()]
    param([string]$Root)
    try {
        $letter = ([System.IO.Path]::GetPathRoot($Root)).Substring(0, 1)
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $physical = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        switch ([string]$physical.MediaType) { 'HDD' { return 2 } 'SSD' { return 8 } 'SCM' { return 8 } default { return 4 } }
    } catch { return 4 }
}

function Scan-DriveTree {
    [CmdletBinding()]
    param([string]$Root = "$($env:SystemDrive)\")
    [Diskman.TreeScan]::Reset()
    [Diskman.TreeScan]::Parallelism = Get-ScanParallelism -Root $Root
    return [Diskman.TreeScan]::Scan($Root)
}

# Turns a scanned tree into rows that add up to exactly $UsedBytes: measured folders plus one labelled remainder.
function Get-SpaceAccounting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Root,
        [Parameter(Mandatory = $true)] [long]$UsedBytes,
        [bool]$Elevated = $false
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($child in $Root.Children) {
        $rows.Add([PSCustomObject]@{ Name = $child.Name; Path = $child.Path; Bytes = [long]$child.Bytes; Kind = 'Folder'; Node = $child })
    }
    if ($Root.OwnBytes -gt 0) {
        $rows.Add([PSCustomObject]@{ Name = "(files and small folders in $($Root.Path))"; Path = $Root.Path; Bytes = [long]$Root.OwnBytes; Kind = 'Folder'; Node = $null })
    }

    $remainder = $UsedBytes - [long]$Root.Bytes
    if ($remainder -gt 0) {
        $kind = if ($Elevated) { 'Unreadable' } else { 'Protected' }
        $name = if ($Elevated) { 'Unreadable or in use by Windows' } else { 'Protected areas (restart as administrator to break down)' }
        $rows.Add([PSCustomObject]@{ Name = $name; Path = $null; Bytes = $remainder; Kind = $kind; Node = $null })
    } elseif ($remainder -lt 0) {
        $rows.Add([PSCustomObject]@{ Name = 'Windows shared files (counted once)'; Path = $null; Bytes = $remainder; Kind = 'Shared'; Node = $null })
    }

    $denominator = [math]::Max([long]1, $UsedBytes)
    foreach ($r in $rows) { $r | Add-Member -NotePropertyName Percent -NotePropertyValue ([math]::Round(100.0 * $r.Bytes / $denominator, 1)) }
    return @($rows | Sort-Object -Property @{ Expression = { if ($_.Kind -in 'Protected', 'Unreadable', 'Shared') { 1 } else { 0 } } }, @{ Expression = { $_.Bytes }; Descending = $true })
}

# Category totals for the stacked bar. A folder's own files count toward its category; children inherit it unless a longer prefix matches.
function Get-SpaceCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Root)

    $profile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $windows = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { "$drive\Windows" }
    $pf      = if ($env:ProgramFiles) { $env:ProgramFiles.TrimEnd('\') } else { "$drive\Program Files" }
    $pf86    = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\') } else { "$drive\Program Files (x86)" }
    $pd      = if ($env:ProgramData) { $env:ProgramData.TrimEnd('\') } else { "$drive\ProgramData" }

    $prefixes = New-Object System.Collections.Generic.List[object]
    $add = { param($p, $c) if ($p) { $prefixes.Add(@($p.TrimEnd('\'), $c)) } }
    foreach ($f in 'Documents', 'Desktop', 'Downloads', 'Pictures', 'Videos', 'Music') { & $add "$profile\$f" 'Your files' }
    foreach ($p in $pf, $pf86, $pd, "$local\Programs", "$local\Packages", $roaming, $local) { & $add $p 'Apps and games' }
    foreach ($f in 'Docker', 'Arduino15', 'Android', 'Python') { & $add "$local\$f" 'Developer tools' }
    foreach ($f in 'npm', 'Code', 'Cursor', 'JetBrains', 'uv') { & $add "$roaming\$f" 'Developer tools' }
    foreach ($p in $windows, "$drive\`$WinREAgent", "$drive\Recovery", "$drive\System Volume Information", "$drive\`$Windows.~BT", "$drive\`$Windows.~WS") { & $add $p 'Windows and system' }
    foreach ($t in (Get-CleanableTargets)) { & $add $t.Path 'Caches and temp' }
    & $add "$windows\Temp" 'Caches and temp'
    & $add "$local\Temp" 'Caches and temp'

    $sorted = @($prefixes | Sort-Object { $_[0].Length } -Descending)
    $totals = @{ 'Apps and games' = 0L; 'Developer tools' = 0L; 'Windows and system' = 0L; 'Your files' = 0L; 'Caches and temp' = 0L; 'Other' = 0L }

    $walk = {
        param($node, $inherited)
        $cat = $inherited
        foreach ($p in $sorted) {
            if ($node.Path.Length -ge $p[0].Length -and $node.Path.StartsWith($p[0], [System.StringComparison]::OrdinalIgnoreCase) -and
                ($node.Path.Length -eq $p[0].Length -or $node.Path[$p[0].Length] -eq '\')) { $cat = $p[1]; break }
        }
        # Dot-folders in the profile (.gradle, .docker, .vscode, .codex ...) are developer tools
        if ($cat -eq 'Other' -and $node.Path.StartsWith("$profile\.", [System.StringComparison]::OrdinalIgnoreCase)) { $cat = 'Developer tools' }
        $totals[$cat] += [long]$node.OwnBytes
        foreach ($child in $node.Children) { & $walk $child $cat }
    }
    & $walk $Root 'Other'
    return $totals
}

# The folders worth looking at: stop at anything with a rule, step through plain containers (Users, AppData...), and
# drill into a dominant child (70%+) so the list names "UpdateFramework" rather than "ProgramData".
function Get-BiggestFolders {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Root, [int]$Max = 12, [long]$MinBytes = 100MB)

    $profile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    $local   = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData).TrimEnd('\')
    $roaming = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData).TrimEnd('\')
    $drive   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $containers = @{}
    foreach ($c in @($Root.Path, "$drive\Users", $profile, "$profile\AppData", $local, "$local\Programs", "$local\Packages", $roaming,
                     "$profile\AppData\LocalLow", $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($c) { $containers[$c.TrimEnd('\').ToLowerInvariant()] = $true }
    }
    $usersPrefix = "$drive\Users\".ToLowerInvariant()

    $found = New-Object System.Collections.Generic.List[object]
    $visit = {
        param($node)
        $key = $node.Path.TrimEnd('\').ToLowerInvariant()
        if (Find-SpaceRule -Path $node.Path) { $found.Add($node); return }
        # Another user's profile folder (C:\Users\name) is a container too
        $isUserRoot = $key.StartsWith($usersPrefix) -and ($key.Substring($usersPrefix.Length) -notlike '*\*')
        if ($containers.ContainsKey($key) -or $isUserRoot) {
            foreach ($child in $node.Children) { & $visit $child }
            return
        }
        # No single dominant child, but a top child has a rule (ProgramData\NVIDIA: NGX and Streamline): show those
        if ($node.Children.Count -gt 1 -and $node.Children[0].Bytes -lt (0.7 * $node.Bytes) -and
            @($node.Children | Select-Object -First 3 | Where-Object { Find-SpaceRule -Path $_.Path }).Count -gt 0) {
            foreach ($child in $node.Children) { & $visit $child }
            return
        }
        $pick = $node
        while ($pick.Children.Count -gt 0 -and $pick.Children[0].Bytes -ge (0.7 * $pick.Bytes)) {
            $pick = $pick.Children[0]
            if (Find-SpaceRule -Path $pick.Path) { break }
        }
        $found.Add($pick)
    }
    & $visit $Root
    return @($found | Where-Object { $_.Bytes -ge $MinBytes } | Sort-Object -Property @{ Expression = { $_.Bytes }; Descending = $true } | Select-Object -First $Max)
}
