# Developer tool: WCAG contrast ratios for every text/background pair the UI uses (update the list when colours change).
# Usage: powershell -NoProfile -File tools\Measure-Contrast.ps1   (exit code 1 if any pair is below 4.5:1)
param([switch]$Quiet)

function Get-Luminance([string]$Hex) {
    $h = $Hex.TrimStart('#')
    $c = 0, 2, 4 | ForEach-Object { [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0 }
    $lin = $c | ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } }
    return 0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}
function Get-Ratio([string]$Fg, [string]$Bg) {
    $a = Get-Luminance $Fg; $b = Get-Luminance $Bg
    return ([math]::Max($a, $b) + 0.05) / ([math]::Min($a, $b) + 0.05)
}

$pairs = @(
    @('Body text on surface',            '#EDEDED', '#16161A'),
    @('Secondary text on surface',       '#A1A1AA', '#16161A'),
    @('Secondary text on card',          '#A1A1AA', '#1B1B1F'),
    @('Status bar text on window',       '#A1A1AA', '#141416'),
    @('Body text on card',               '#D4D4D8', '#1B1B1F'),
    @('Accent (sizes, links) on surface','#00B4D8', '#16161A'),
    @('Accent on card',                  '#00B4D8', '#1B1B1F'),
    @('Verdict: critically low',         '#FF6B6B', '#16161A'),
    @('Verdict: low',                    '#FFB703', '#16161A'),
    @('Verdict: healthy',                '#2EC4B6', '#16161A'),
    @('Card label: SAFE',                '#2EC4B6', '#1B1B1F'),
    @('Card label: OPTIONAL',            '#FFB703', '#1B1B1F'),
    @('Card label: ADVANCED',            '#FF8A80', '#1B1B1F'),
    @('Card label: REVIEW',              '#A1A1AA', '#1B1B1F'),
    @('Badge SAFE',                      '#141416', '#2EC4B6'),
    @('Badge OPTIONAL',                  '#141416', '#FFB703'),
    @('Badge ADVANCED',                  '#FFFFFF', '#C1121F'),
    @('Selected row / primary button',   '#FFFFFF', '#0077B6'),
    @('Danger button',                   '#FFFFFF', '#9D0208'),
    @('Log text on console',             '#2EC4B6', '#0D0D0F'),
    @('Tab (inactive) text',             '#A1A1AA', '#1C1C20')
)

$failures = 0
$rows = foreach ($p in $pairs) {
    $r = Get-Ratio $p[1] $p[2]
    $ok = $r -ge 4.5
    if (-not $ok) { $failures++ }
    [PSCustomObject]@{ Pair = $p[0]; Foreground = $p[1]; Background = $p[2]; Ratio = [math]::Round($r, 2); Result = $(if ($ok) { 'pass' } else { 'FAIL (<4.5)' }) }
}
if (-not $Quiet) { $rows | Format-Table -AutoSize | Out-String | Write-Host }
if ($Quiet) { return $rows }
exit $(if ($failures -eq 0) { 0 } else { 1 })
