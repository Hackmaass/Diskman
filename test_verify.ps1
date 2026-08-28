$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. Test Modules
. (Join-Path $ScriptDir src\modules\00-Utils.ps1)
. (Join-Path $ScriptDir src\modules\Get-DriveMetrics.ps1)
. (Join-Path $ScriptDir src\modules\Start-FolderScan.ps1)
. (Join-Path $ScriptDir src\modules\Invoke-SmartCleanup.ps1)
. (Join-Path $ScriptDir src\modules\Find-LargeFiles.ps1)
. (Join-Path $ScriptDir src\modules\Invoke-ShellActions.ps1)

Write-Output --- Testing Drive Metrics Module ---
$drives = Get-DriveMetrics
Write-Output Found $(.Count) drives: $(.DriveLetter -join ', ')

Write-Output --- Testing Directory Scan on D:\ ---
$dScan = Start-FolderScan -DirectoryPath D:"
Write-Output Found $(.Count) items in D:"

Write-Output --- Testing Smart Cleaner Scanning ---
$targets = Scan-SmartCleanupItems
Write-Output Found $(.Count) cleanable categories.

# 2. Compile standalone
Write-Output --- Compiling standalone bundle ---
& (Join-Path $ScriptDir Compile.ps1)

# 3. Test Standalone AST Syntax
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptDir release\diskman.ps1), [ref]$tokens, [ref]$errors)

if ($errors.Count -eq 0) {
    Write-Output ALL TESTS PASSED! Standalone diskman.ps1 in D:\Projects\Diskman has 0 syntax errors.
} else {
    Write-Output PARSER ERRORS:
    $errors | ForEach-Object { Write-Output $_.Message }
}