#=============================================================================
# tools/run_sim_disp.ps1 —— 显示屏本机 UI（disp/）专用 xsim 回归
#
#   为什么单独一个脚本，而不是并进 tools/run_sim.ps1：
#     1) tools/run_sim.ps1 只编译 rtl/*.v；而 disp/ 的测试台还要 disp/*.v。
#        把 disp 的测试台放进 sim/ 会让那份「PASS 21/21」的编码器基线
#        全部变成 BUILD-ERR（模块找不到）。
#     2) xsim 在本机必须把 TEMP/TMP 钉进工作区，否则报
#        ERROR: [XSIM 43-3409] Failed to compile generated C file
#                              xsim.dir/<tb>/obj/xsim_1.c
#        （2026-10-15 实测。与 tools/run_vivado.ps1 处理 HOME/APPDATA 同因：
#          沙箱只允许写工作区，而 xsim 要往 %TEMP% 落 C 代码。）
#
#   源文件 = rtl/*.v + disp/*.v + sim/xilinx_prims_stub.v
#   测试台 = disp/tb_*.v       （一个测试台一个独立工作目录）
#
# 用法（Windows PowerShell 5.1 或 pwsh 7 均可）:
#   pwsh -File tools\run_sim_disp.ps1
#   pwsh -File tools\run_sim_disp.ps1 -Only tb_freq_meter
#   pwsh -File tools\run_sim_disp.ps1 -Define ENC_DISP_TAP
#   pwsh -File tools\run_sim_disp.ps1 -Rebuild
#
# 退出码: 0 = 全部 PASS；1 = 存在 FAIL 或编译/精化错误。
#=============================================================================
[CmdletBinding()]
param(
    [string[]] $Only   = @(),
    [switch]   $Rebuild,
    [string[]] $Define = @()
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$RtlDir    = Join-Path $Root 'rtl'
$DispDir   = Join-Path $Root 'disp'
$SimDir    = Join-Path $Root 'sim'
$LogDir    = Join-Path $DispDir 'logs'
$WorkRoot  = Join-Path $Root '_disp_work\sim_disp'

# ---- Vivado 环境 ----
$VivadoBin = 'D:\Vivado\2026.1\Vivado\bin'
if (-not (Test-Path (Join-Path $VivadoBin 'xvlog.bat'))) {
    throw "找不到 Vivado: $VivadoBin\xvlog.bat"
}
$env:Path = "$VivadoBin;$env:Path"

# ---- ★ 把 TEMP/TMP 钉进工作区（否则 xsim 无法编译生成的 C 代码）----
$TmpDir = Join-Path $Root '_disp_work\tmp'
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$env:TEMP = $TmpDir
$env:TMP  = $TmpDir

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding           = $Utf8NoBom

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

# ---- 收集源文件 ----
$SrcFiles = @()
foreach ($f in (Get-ChildItem (Join-Path $RtlDir  '*.v') | Sort-Object Name)) { $SrcFiles += $f.FullName }
foreach ($f in (Get-ChildItem (Join-Path $DispDir '*.v') | Sort-Object Name)) {
    if ($f.Name -like 'tb_*') { continue }          # 测试台不进源集合
    $SrcFiles += $f.FullName
}
$PrimStub = Join-Path $SimDir 'xilinx_prims_stub.v'
if (Test-Path $PrimStub) { $SrcFiles += (Resolve-Path $PrimStub).Path }

# ---- 收集测试台 ----
$AllTbs = @()
foreach ($f in (Get-ChildItem (Join-Path $DispDir 'tb_*.v') | Sort-Object Name)) {
    if ($Only.Count -gt 0) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($Only -notcontains $n) { continue }
    }
    $AllTbs += $f
}
if ($AllTbs.Count -eq 0) { throw "disp/ 下没有匹配的测试台" }

$DefArgs = @()
foreach ($d in $Define) { $DefArgs += '-d'; $DefArgs += $d }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " disp/ xsim 回归:  $($AllTbs.Count) 个测试台 / $($SrcFiles.Count) 个源文件"
Write-Host " 工作目录: $WorkRoot"
Write-Host " TEMP    : $TmpDir"
Write-Host "================================================================" -ForegroundColor Cyan

$ColorMap = @{ 'PASS'='Green'; 'FAIL'='Red'; 'BUILD-ERR'='Magenta'; 'NO-VERDICT'='DarkYellow' }
$results  = @()

foreach ($tb in $AllTbs) {
    $tbName = [System.IO.Path]::GetFileNameWithoutExtension($tb.Name)
    $tbWork = Join-Path $WorkRoot $tbName
    $log    = Join-Path $LogDir "$tbName.log"

    Write-Host ""
    Write-Host "--- $tbName " -ForegroundColor Yellow -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Rebuild -and (Test-Path $tbWork)) { Remove-Item $tbWork -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tbWork | Out-Null

    $lines = New-Object System.Collections.Generic.List[string]
    $ok    = $false
    $stage = 'xvlog'

    Push-Location $tbWork
    $xvlogArgs = @('--sv') + $DefArgs + $SrcFiles + @($tb.FullName)
    $o = & xvlog @xvlogArgs 2>&1
    $lines.Add("###### xvlog ######"); $lines.AddRange([string[]]$o)
    if ($LASTEXITCODE -ne 0) {
        $lines.Add("xvlog FAILED (exit $LASTEXITCODE)")
        Write-Host "[xvlog 分析失败]" -ForegroundColor Red
    } else {
        $stage = 'xelab'
        $o = & xelab -debug typical $tbName -s "${tbName}_sim" 2>&1
        $lines.Add("###### xelab ######"); $lines.AddRange([string[]]$o)
        if ($LASTEXITCODE -ne 0) {
            $lines.Add("xelab FAILED (exit $LASTEXITCODE)")
            Write-Host "[xelab 精化失败]" -ForegroundColor Red
        } else {
            $stage = 'xsim'
            $o = & xsim "${tbName}_sim" -runall 2>&1
            $lines.Add("###### xsim ######"); $lines.AddRange([string[]]$o)
            $ok = $true
        }
    }
    Pop-Location
    $sw.Stop()

    $text = ($lines -join "`n")
    [System.IO.File]::WriteAllText($log, $text, (New-Object System.Text.UTF8Encoding($true)))

    $passed = $text -match 'TEST PASSED'
    $failed = $text -match 'TEST FAILED'
    if (-not $ok)                                    { $verdict = 'BUILD-ERR' }
    elseif ($passed -and (-not $failed))             { $verdict = 'PASS' }
    elseif ($failed)                                 { $verdict = 'FAIL' }
    else                                             { $verdict = 'NO-VERDICT' }

    $errCount = '?'
    if ($text -match 'TEST FAILED \((\d+) errors\)') { $errCount = $Matches[1] }
    elseif ($passed)                                 { $errCount = '0' }

    Write-Host "$verdict  stage=$stage  errors=$errCount  $([int]$sw.Elapsed.TotalSeconds)s" `
        -ForegroundColor $ColorMap[$verdict]

    $results += [pscustomobject]@{
        Testbench = $tbName; Verdict = $verdict; Errors = $errCount
        Seconds   = [int]$sw.Elapsed.TotalSeconds; Log = $log
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " disp/ 回归汇总"
Write-Host "================================================================" -ForegroundColor Cyan
$results | Select-Object Testbench, Verdict, Errors, Seconds |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$nPass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$nBad  = @($results | Where-Object { $_.Verdict -ne 'PASS' }).Count
$c = 'Green'; if ($nBad -ne 0) { $c = 'Red' }
Write-Host (" PASS {0} / 共 {1} ；非 PASS {2}" -f $nPass, $results.Count, $nBad) -ForegroundColor $c

$summaryPath = Join-Path $LogDir 'SUMMARY.md'
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# disp/ xsim 回归汇总")
$md.Add("")
$md.Add("- 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- 结果: **PASS $nPass / $($results.Count)**")
$md.Add("")
$md.Add("| 测试台 | 结果 | 错误数 | 耗时(s) | 日志 |")
$md.Add("|---|---|---|---|---|")
foreach ($r in $results) {
    $md.Add("| ``$($r.Testbench)`` | $($r.Verdict) | $($r.Errors) | $($r.Seconds) | [log](logs/$($r.Testbench).log) |")
}
[System.IO.File]::WriteAllText($summaryPath, ($md -join "`n"), $Utf8NoBom)
Write-Host " 汇总写入: $summaryPath"

if ($nBad -gt 0) { exit 1 }
exit 0
