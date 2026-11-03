#=============================================================================
# tools/run_sim.ps1 —— Vivado xsim 批量回归脚本
#
#   编译 rtl/*.v + sim/<tb>.v -> xelab -> xsim -runall
#   自动判定 TEST PASSED / TEST FAILED，输出汇总表，日志写入 sim/logs/
#
# 用法（Windows PowerShell 5.1 或 pwsh 7 均可）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only tb_abz_gen,tb_uvw_gen
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Rebuild
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Define XILINX_SIM
#
# 说明:
#   * .v 统一用 SystemVerilog 模式分析（xvlog --sv），与 sim/README.md 一致。
#   * 每个测试台在独立目录 _sim_work/<tb>/ 里编译+精化+仿真，互不干扰。
#   * 退出码: 0 = 全部 PASS；1 = 存在 FAIL 或编译/精化错误。
#=============================================================================
[CmdletBinding()]
param(
    [string[]] $Only     = @(),
    [switch]   $Rebuild,
    [string[]] $Define   = @(),
    [string]   $WorkRoot = '',
    [string]   $RtlDir   = '',          # 变体 RTL 目录（如 _synth_work_lowsig/rtl_lowsig）；默认 rtl/
    [switch]   $NoAutoWorkRoot
)

$ErrorActionPreference = 'Stop'

# ---- 定位工程根目录（本脚本在 tools/ 下）----
$Root     = Split-Path -Parent $PSScriptRoot
$SimDir   = Join-Path $Root 'sim'
if ($RtlDir) {
    if (-not (Test-Path $RtlDir)) { throw "RtlDir 不存在: $RtlDir" }
    $RtlDir = (Resolve-Path $RtlDir).Path
} else {
    $RtlDir = Join-Path $Root 'rtl'
}
$LogDir   = Join-Path $SimDir 'logs'

# ---- Vivado 环境 ----
$VivadoBin = 'D:\Vivado\2026.1\Vivado\bin'
if (-not (Test-Path (Join-Path $VivadoBin 'xvlog.bat'))) {
    throw "找不到 Vivado: $VivadoBin\xvlog.bat"
}
$env:Path = "$VivadoBin;$env:Path"

# 让 xsim 的中文输出正确落进 UTF-8 日志
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding           = $Utf8NoBom

# ============================================================================
# ★ 工作目录选择：xsim 在"沙箱工作区目录内"会崩溃，必须能挪到工作区外
# ----------------------------------------------------------------------------
# 现象（2026-10-09 实测，重启后仍复现，与工程/RTL 无关）：
#     任何设计（含 3 行 hello world）在 工作区根目录 之下运行 xsim 都崩：
#         Could not open file mapping object (2).
#         Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)
#     同一份设计放在工作区外（D:\...、C:\probeB、%TEMP%）则一切正常。
#     逐点二分结果：非 ASCII 路径、长路径、文件系统、TEMP/TMP、多线程、
#     -autoloadwcfg、残留进程/文件、重启 —— 全部排除；唯一相关变量是
#     "是否位于工作区根目录 `$Root` 之下"（该目录被沙箱加了 Deny ACE）。
# 因此：默认优先用 `_sim_work`（工作区内，行为与以前一致）；只有当探测
# 发现 xsim 在该目录下起不来时，才自动退到工作区外的临时目录。
# 探测用的是一份 3 行 hello world，不碰任何工程源文件。
# ============================================================================
function Test-XsimRunsIn([string] $dir) {
    $probe = Join-Path $dir '.xsim_probe'
    Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    Set-Content -Path (Join-Path $probe 'probe.v') -Encoding ASCII `
        -Value 'module probe; initial begin $display("XSIM_PROBE_OK"); $finish; end endmodule'
    Push-Location $probe
    try {
        & xvlog probe.v *> $null
        & xelab -debug typical probe -s p *> $null
        $out = (& xsim p -runall *>&1 | Out-String)
        return ($out -match 'XSIM_PROBE_OK')
    } finally {
        Pop-Location
        Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($WorkRoot -eq '') {
    $candidate = Join-Path $Root '_sim_work'
    if ($NoAutoWorkRoot -or (Test-XsimRunsIn $candidate)) {
        $WorkRoot = $candidate
    } else {
        Write-Host '[!] xsim 在工程目录内无法启动（沙箱工作区限制），自动改用工作区外目录' -ForegroundColor Yellow
        $WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'fpga_sim_work'
        Write-Host "    工作目录: $WorkRoot" -ForegroundColor Yellow
    }
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

# ---- 收集 RTL 源文件 ----
$RtlFiles = @()
foreach ($f in (Get-ChildItem (Join-Path $RtlDir '*.v') | Sort-Object Name)) {
    $RtlFiles += $f.FullName
}
# 以太网子目录（B2）：rtl/eth/*.v。放在 rtl/*.v 之后，模块间无同名。
$EthDir = Join-Path $RtlDir 'eth'
if (Test-Path $EthDir) {
    foreach ($f in (Get-ChildItem (Join-Path $EthDir '*.v') | Sort-Object Name)) {
        $RtlFiles += $f.FullName
    }
}
# DDR3 引擎（B4）：rtl/ddr3/ddr3_ring.v 单独进回归。
# 顶层 ddr3_top*.v 例化 MIG（几十个 .v），不进回归；ddr3_ring 只依赖 async_fifo，
# 与其余模块无同名，加入全部测试台都安全。
$Ddr3Ring = Join-Path $RtlDir 'ddr3\ddr3_ring.v'
if (Test-Path $Ddr3Ring) { $RtlFiles += (Resolve-Path $Ddr3Ring).Path }

if ($RtlFiles.Count -eq 0) { throw "rtl/ 下没有 .v 文件" }

# ---- Xilinx 原语的仿真桩 ----
#   rtl/enc_top.v 例化了 BUFG 与 ODDR 两个 Xilinx 原语（第 94 行、第 119 行）。
#   本机没有预编译的 unisims 仿真库（Vivado 2026.1 未随装 compile_simlib 脚本），
#   所以仿真时用 sim/xilinx_prims_stub.v 提供功能等价的行为模型。
#   它只定义 BUFG / ODDR，不与任何 rtl 模块重名，加入全部测试台都安全；
#   综合时 Vivado 解析真实 unisims_ver 原语，与本桩无关（本文件不进综合源集）。
$PrimStub = Join-Path $SimDir 'xilinx_prims_stub.v'
if (Test-Path $PrimStub) { $RtlFiles += (Resolve-Path $PrimStub).Path }

# ---- DDR3 MIG UI 行为模型（tb_ddr3_ring / tb_ddr3_full 共用）----
#   以前这个 module 写在 sim/tb_ddr3_ring.v 里面，而每个测试台是单独 xelab 的，
#   tb_ddr3_full.v 里 `mig_ui_model u_model` 因此永远找不到定义：
#       ERROR: [VRFC 10-2063] Module <mig_ui_model> not found while
#       processing module instance <u_model> [sim/tb_ddr3_full.v:122]
#   全量回归里 tb_ddr3_full 一直是 BUILD-ERR（DDR3 未进 v60 位流，容易漏看）。
#   提取成独立文件后统一分析；不实例化它的测试台不受影响。
$MigModel = Join-Path $SimDir 'mig_ui_model.v'
if (Test-Path $MigModel) { $RtlFiles += (Resolve-Path $MigModel).Path }

# ---- 收集测试台 ----
$AllTbs = @()
foreach ($f in (Get-ChildItem (Join-Path $SimDir 'tb_*.v') | Sort-Object Name)) {
    if ($Only.Count -gt 0) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($Only -notcontains $n) { continue }
    }
    $AllTbs += $f
}
if ($AllTbs.Count -eq 0) { throw "没有匹配的测试台" }

$DefArgs = @()
foreach ($d in $Define) { $DefArgs += '-d'; $DefArgs += $d }

$ColorMap = @{
    'PASS'       = 'Green'
    'FAIL'       = 'Red'
    'BUILD-ERR'  = 'Magenta'
    'NO-VERDICT' = 'DarkYellow'
}

$results = @()

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Vivado xsim 回归:  $($AllTbs.Count) 个测试台 / $($RtlFiles.Count) 个 RTL 源文件"
Write-Host " 工作目录: $WorkRoot"
Write-Host "================================================================" -ForegroundColor Cyan

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

    # ---- 1. xvlog: 分析全部 RTL + 本测试台 ----
    # 显示子系统（disp/*.v）默认不进源集：只有 tb_disp* 需要，且必须带 ENC_DISP_TAP/ENC_V69_CPR2048，
    # 否则 enc_top 不会有 DISP_TAP 端口。2026-11-02 补（审计 B2：显示零覆盖）。
    $tbSrc  = $RtlFiles
    $tbDefs = $DefArgs
    if ($tbName -like 'tb_disp*') {
        $dispFiles = @()
        foreach ($f in (Get-ChildItem (Join-Path $Root 'disp\*.v') | Sort-Object Name)) {
            if ($f.Name -like 'tb_*') { continue }
            $dispFiles += $f.FullName
        }
        $tbSrc  = $RtlFiles + $dispFiles
        $tbDefs = $DefArgs + @('-d', 'ENC_DISP_TAP', '-d', 'ENC_V69_CPR2048')
    }
    $xvlogArgs = @('--sv') + $tbDefs + $tbSrc + @($tb.FullName)
    $o = & xvlog @xvlogArgs 2>&1
    $lines.Add("###### xvlog ######")
    $lines.AddRange([string[]]$o)
    if ($LASTEXITCODE -ne 0) {
        $lines.Add("xvlog FAILED (exit $LASTEXITCODE)")
        Write-Host "[xvlog 分析失败]" -ForegroundColor Red
    } else {

        # ---- 2. xelab ----
        $stage = 'xelab'
        $o = & xelab -debug typical $tbName -s "${tbName}_sim" 2>&1
        $lines.Add("###### xelab ######")
        $lines.AddRange([string[]]$o)
        if ($LASTEXITCODE -ne 0) {
            $lines.Add("xelab FAILED (exit $LASTEXITCODE)")
            Write-Host "[xelab 精化失败]" -ForegroundColor Red
        } else {

            # ---- 3. xsim -runall ----
            $stage = 'xsim'
            $o = & xsim "${tbName}_sim" -runall 2>&1
            $lines.Add("###### xsim ######")
            $lines.AddRange([string[]]$o)
            $ok = $true
        }
    }

    Pop-Location
    $sw.Stop()

    $text = ($lines -join "`n")
    # 带 BOM 写出：Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI(GBK) 解码，
    # 导致中文日志乱码（同理，脚本自身也必须带 BOM 才能被 powershell.exe 正确解析）。
    [System.IO.File]::WriteAllText($log, $text, (New-Object System.Text.UTF8Encoding($true)))

    # ---- 判定 ----
    $passed = $text -match 'TEST PASSED'
    $failed = $text -match 'TEST FAILED'

    if (-not $ok) {
        $verdict = 'BUILD-ERR'
    } elseif ($passed -and (-not $failed)) {
        $verdict = 'PASS'
    } elseif ($failed) {
        $verdict = 'FAIL'
    } else {
        $verdict = 'NO-VERDICT'
    }

    $errCount = '?'
    if ($text -match 'TEST FAILED \((\d+) errors\)') { $errCount = $Matches[1] }
    elseif ($passed)                                 { $errCount = '0' }

    Write-Host "$verdict  stage=$stage  errors=$errCount  $([int]$sw.Elapsed.TotalSeconds)s" `
        -ForegroundColor $ColorMap[$verdict]

    $results += [pscustomobject]@{
        Testbench = $tbName
        Verdict   = $verdict
        Errors    = $errCount
        Seconds   = [int]$sw.Elapsed.TotalSeconds
        Log       = $log
    }
}

# ---- 汇总 ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " 回归汇总"
Write-Host "================================================================" -ForegroundColor Cyan
$results | Select-Object Testbench, Verdict, Errors, Seconds |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$nPass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$nBad  = @($results | Where-Object { $_.Verdict -ne 'PASS' }).Count
$c     = 'Green'
if ($nBad -ne 0) { $c = 'Red' }
Write-Host (" PASS {0} / 共 {1} ；非 PASS {2}" -f $nPass, $results.Count, $nBad) -ForegroundColor $c

$summaryPath = Join-Path $LogDir 'SUMMARY.md'
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Vivado xsim 回归汇总")
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
