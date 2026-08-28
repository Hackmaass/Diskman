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

    # Safety checks - Never allow deleting system roots
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows|^[A-Za-z]:\\Program Files') {
        return @{ Success = $false; Message = "Protected system paths cannot be deleted." }
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
        return @{ Success = $false; Message = "Failed to recycle: $_" }
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

    # Safety checks
    if ($Path -match '^[A-Za-z]:\\$|^[A-Za-z]:\\Windows|^[A-Za-z]:\\Program Files') {
        return @{ Success = $false; Message = "Protected system paths cannot be deleted." }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return @{ Success = $true; Message = "Item permanently deleted." }
    } catch {
        return @{ Success = $false; Message = "Delete failed: $_" }
    }
}
