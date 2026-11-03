<#
    trace_pdf_nets.ps1 -- recover "net name <-> FPGA ball" pairs from the vector
    dump produced by: python tools/pdf_text.py <pdf> -1 <out> --geom --quiet

    Method (pure geometry, no semantic guessing):
      * T records = text labels, kept as (x, y, text)
      * L records = line segments, kept as (x1,y1,x2,y2)
      * each label is snapped to its nearest segment endpoint (within -Tol)
      * segment endpoints closer than 0.6 units are unioned, so every wire that
        touches another wire ends up in one connected block
      * every block holding >= 2 labels is printed, which is exactly the
        "signal name -- wire -- ball name" pattern used in these schematics

    Example (Da Vinci lite sheet 5, FPGA Bank 34 region):
      powershell -ExecutionPolicy Bypass -File tools/trace_pdf_nets.ps1 `
          -Geom _lcd_work/board_geom_geom.txt -Page 5 `
          -XMin 80 -XMax 620 -YMin 300 -YMax 500

    NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
    unless there is a BOM, so non-ASCII comments can corrupt the parse.
#>
param(
    [Parameter(Mandatory=$true)][string]$Geom,
    [Parameter(Mandatory=$true)][int]$Page,
    [double]$XMin = -1e9,
    [double]$XMax = 1e9,
    [double]$YMin = -1e9,
    [double]$YMax = 1e9,
    [double]$Tol = 12.0,
    [string]$Only = "",
    [int]$MinMembers = 2
)

$ErrorActionPreference = "Stop"

$lines = @(Get-Content -LiteralPath $Geom -Encoding UTF8)

# --- 1. slice out the requested page -----------------------------------------
$start = -1
$stop = $lines.Count
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^===== PAGE (\d+)/') {
        if ($start -ge 0) { $stop = $i; break }
        if ([int]$Matches[1] -eq $Page) { $start = $i }
    }
}
if ($start -lt 0) { throw "page $Page not found in $Geom" }

# --- 2. collect labels and segments inside the window ------------------------
$labels = New-Object System.Collections.ArrayList
$segs   = New-Object System.Collections.ArrayList
for ($i = $start + 1; $i -lt $stop; $i++) {
    $f = $lines[$i] -split "`t"
    if ($f.Count -lt 4) { continue }
    if ($f[0] -eq 'T') {
        $x = [double]$f[1]
        $y = [double]$f[2]
        $t = $f[3]
        if ($x -lt $XMin -or $x -gt $XMax -or $y -lt $YMin -or $y -gt $YMax) { continue }
        if ($Only -ne "" -and $t -notmatch $Only) { continue }
        [void]$labels.Add([pscustomobject]@{ x = $x; y = $y; t = $t })
    }
    elseif ($f[0] -eq 'L' -and $f.Count -ge 5) {
        $x1 = [double]$f[1]; $y1 = [double]$f[2]
        $x2 = [double]$f[3]; $y2 = [double]$f[4]
        $mx = ($x1 + $x2) / 2.0
        $my = ($y1 + $y2) / 2.0
        if ($mx -lt ($XMin - 40) -or $mx -gt ($XMax + 40)) { continue }
        if ($my -lt ($YMin - 40) -or $my -gt ($YMax + 40)) { continue }
        [void]$segs.Add([pscustomobject]@{ x1 = $x1; y1 = $y1; x2 = $x2; y2 = $y2 })
    }
}
Write-Host ("page {0}: labels={1} segs={2}  X[{3},{4}] Y[{5},{6}] Only='{7}'" -f `
    $Page, $labels.Count, $segs.Count, $XMin, $XMax, $YMin, $YMax, $Only)

# --- 3. union-find over segment endpoints ------------------------------------
$parent = @{}
for ($i = 0; $i -lt $segs.Count; $i++) { $parent[$i] = $i }

function Get-Root([int]$a) {
    $r = $a
    while ($parent[$r] -ne $r) { $r = $parent[$r] }
    while ($parent[$a] -ne $r) { $n = $parent[$a]; $parent[$a] = $r; $a = $n }
    return $r
}
function Join-Seg([int]$a, [int]$b) {
    $ra = Get-Root $a
    $rb = Get-Root $b
    if ($ra -ne $rb) { $script:parent[$ra] = $rb }
}

$ends = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $segs.Count; $i++) {
    [void]$ends.Add([pscustomobject]@{ i = $i; x = $segs[$i].x1; y = $segs[$i].y1 })
    [void]$ends.Add([pscustomobject]@{ i = $i; x = $segs[$i].x2; y = $segs[$i].y2 })
}
$limit = 0.6 * 0.6
for ($a = 0; $a -lt $ends.Count; $a++) {
    for ($b = $a + 1; $b -lt $ends.Count; $b++) {
        if ($ends[$a].i -eq $ends[$b].i) { continue }
        $dx = $ends[$a].x - $ends[$b].x
        $dy = $ends[$a].y - $ends[$b].y
        if (($dx * $dx + $dy * $dy) -le $limit) { Join-Seg $ends[$a].i $ends[$b].i }
    }
}

# --- 4. snap each label to its nearest endpoint, group by block root ---------
$blocks = @{}
foreach ($lb in $labels) {
    $best = -1
    $bestd = $Tol + 1.0
    foreach ($e in $ends) {
        $dx = $e.x - $lb.x
        $dy = $e.y - $lb.y
        $d = [math]::Sqrt($dx * $dx + $dy * $dy)
        if ($d -lt $bestd) { $bestd = $d; $best = $e.i }
    }
    if ($best -lt 0) { continue }
    $r = Get-Root $best
    if (-not $blocks.ContainsKey($r)) {
        $blocks[$r] = New-Object System.Collections.ArrayList
    }
    [void]$blocks[$r].Add([pscustomobject]@{ d = $bestd; t = $lb.t; x = $lb.x; y = $lb.y })
}

# --- 5. print blocks ---------------------------------------------------------
$n = 0
foreach ($k in $blocks.Keys) {
    $members = @($blocks[$k] | Sort-Object x)
    if ($members.Count -lt $MinMembers) { continue }
    $n++
    $txt = (@($members | ForEach-Object { "[" + $_.t + "]" }) -join "  --  ")
    Write-Host ("net{0}: {1}" -f $n, $txt)
}
if ($n -eq 0) { Write-Host "(no block with >= $MinMembers labels; widen the window or raise -Tol)" }
