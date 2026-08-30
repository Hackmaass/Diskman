# Add VisualBasic assembly for native Windows Recycle Bin operations
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue

function Show-ItemInExplorer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$Path`""
        return $true
    } elseif (Test-Path -LiteralPath (Split-Path -Parent $Path)) {
        Start-Process "explorer.exe" -ArgumentList "`"$(Split-Path -Parent $Path)`""
        return $true
    } else {
        return $false
    }
}

function Open-FolderInExplorer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Start-Process "explorer.exe" -ArgumentList "`"$Path`""
        return $true
    } else {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
            Start-Process "explorer.exe" -ArgumentList "`"$parent`""
            return $true
        }
        return $false
    }
}

function Send-ItemToRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Strict multi-layer safety check
    $safety = Test-PathSafety -Path $Path
    if (-not $safety.Safe) {
        return @{ Success = $false; Message = "Protected Path: $($safety.Reason)" }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
        return @{ Success = $true; Message = "Item moved to Recycle Bin safely." }
    } catch {
        return @{ Success = $false; Message = "Failed to recycle: $($_.Exception.Message)" }
    }
}

function Remove-ItemPermanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Success = $false; Message = "File does not exist." }
    }

    # Strict multi-layer safety check
    $safety = Test-PathSafety -Path $Path
    if (-not $safety.Safe) {
        return @{ Success = $false; Message = "Action Blocked: $($safety.Reason)" }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $isReparse = Test-ReparsePoint -Path $Path
            if ($isReparse) {
                [System.IO.Directory]::Delete($Path, $false)
            } else {
                [System.IO.Directory]::Delete($Path, $true)
            }
        } else {
            [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($Path)
        }
        return @{ Success = $true; Message = "Item permanently deleted." }
    } catch {
        return @{ Success = $false; Message = "Delete failed: $($_.Exception.Message)" }
    }
}
