# Diskman - Build and Packaging Compiler
# Compiles modular source files and XAML into a single monolithic standalone `release/diskman.ps1`

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseDir = Join-Path $ScriptDir "release"
if (-not (Test-Path $ReleaseDir)) {
    New-Item -Path $ReleaseDir -ItemType Directory -Force | Out-Null
}

$OutputFile = Join-Path $ReleaseDir "diskman.ps1"
Write-Host "Building Diskman standalone distribution: $OutputFile" -ForegroundColor Cyan

$sb = New-Object System.Text.StringBuilder

# Header
$null = $sb.AppendLine('# =====================================================================')
$null = $sb.AppendLine('# Diskman - Windows Storage Analyzer & Smart Storage Cleaner')
$null = $sb.AppendLine('# Distributed via PowerShell + WPF (Zero Dependencies)')
$null = $sb.AppendLine('# =====================================================================')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {')
$null = $sb.AppendLine('    Write-Host "Restarting Diskman in STA apartment mode for WPF..." -ForegroundColor Cyan')
$null = $sb.AppendLine('    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "& { `$script = [System.IO.File]::ReadAllText(''$PSCommandPath''); Invoke-Expression `$script }"')
$null = $sb.AppendLine('    return')
$null = $sb.AppendLine('}')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, Microsoft.VisualBasic -ErrorAction SilentlyContinue')
$null = $sb.AppendLine('')

# 1. Append Modules
$modulesDir = Join-Path $ScriptDir "src\modules"
if (Test-Path $modulesDir) {
    Write-Host "Inlining module functions..." -ForegroundColor Yellow
    Get-ChildItem -Path $modulesDir -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
        $null = $sb.AppendLine("# --- Module: $($_.Name) ---")
        $moduleContent = Get-Content -Path $_.FullName -Raw
        $null = $sb.AppendLine($moduleContent)
        $null = $sb.AppendLine("")
    }
}

# 2. Embed MainWindow.xaml as string
$xamlFile = Join-Path $ScriptDir "src\xaml\MainWindow.xaml"
if (Test-Path $xamlFile) {
    Write-Host "Embedding XAML UI markup..." -ForegroundColor Yellow
    $xamlRaw = Get-Content -Path $xamlFile -Raw
    
    $null = $sb.AppendLine('$embeddedXaml = @''')
    $null = $sb.AppendLine($xamlRaw)
    $null = $sb.AppendLine('''@')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('[xml]$xaml = $embeddedXaml')
    $null = $sb.AppendLine('$reader = New-Object System.Xml.XmlNodeReader $xaml')
    $null = $sb.AppendLine('$window = [System.Windows.Markup.XamlReader]::Load($reader)')
    $null = $sb.AppendLine('')
}

# 3. Read Controller logic from app.ps1 starting after XAML loading
$appFile = Join-Path $ScriptDir "src\app.ps1"
if (Test-Path $appFile) {
    Write-Host "Embedding UI Controller logic..." -ForegroundColor Yellow
    $lines = Get-Content -Path $appFile
    $collect = $false
    foreach ($line in $lines) {
        if ($line -match '^# Helper to find XAML controls') {
            $collect = $true
        }
        if ($collect) {
            $null = $sb.AppendLine($line)
        }
    }
}

[System.IO.File]::WriteAllText($OutputFile, $sb.ToString(), [System.Text.Encoding]::UTF8)

$fileInfo = Get-Item $OutputFile
Write-Host "Successfully built: $($fileInfo.FullName)" -ForegroundColor Green
Write-Host "Standalone Size: $([math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor Green
