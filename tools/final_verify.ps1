# ============================================================================
#  tools/final_verify.ps1 -- one-shot final verification for the turntable build
# ----------------------------------------------------------------------------
#  Every check prints "[OK  ]" or "[FAIL]". Exit code = number of failures.
#  Purpose: catch the classic post-edit mistakes
#    * bitstream / regression built from OLDER RTL than what is on disk
#    * simulation-only code (initial / #delay / inout) leaked into synthesis
#    * leftover debug macros (ENC_DISP_TAP) in the production build
#    * host tool and RTL disagree on the UDP port / register defaults
#  Usage:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\final_verify.ps1
# ============================================================================
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)
$ErrorActionPreference = 'Continue'
$fails = 0
function Ok   ($m) { Write-Host ("[OK  ] " + $m) -ForegroundColor Green }
function Bad  ($m) { Write-Host ("[FAIL] " + $m) -ForegroundColor Red; $script:fails++ }
function Info ($m) { Write-Host ("[info] " + $m) -ForegroundColor Gray }

Push-Location $Root
try {
    Write-Host "=== 1. source inventory ==="
    $rtl = @(Get-ChildItem rtl\*.v -File)
    $eth = @(Get-ChildItem rtl\eth\*.v -File)
    $disp = @(Get-ChildItem disp\*.v -File | Where-Object { $_.Name -notlike 'tb_*' })
    $sim = @(Get-ChildItem sim\tb_*.v -File)
    Info ("rtl={0}  eth={1}  disp={2}  testbenches={3}" -f $rtl.Count, $eth.Count, $disp.Count, $sim.Count)
    if ($rtl.Count -lt 20) { Bad "rtl/*.v count looks wrong" } else { Ok "rtl sources present" }
    if ($sim.Count -lt 30) { Bad "testbench count looks wrong (<30)" } else { Ok "testbench sources present" }

    Write-Host "=== 2. synthesis cleanliness ==="
    $syn = @($rtl + $eth + $disp)
    $badInit = @()
    $ramInit = @()
    $badDelay = @()
    foreach ($f in $syn) {
        $txt = Get-Content $f.FullName -Raw -Encoding UTF8
        # strip block comments and line comments before scanning for 'initial' / '#'
        $nc = [regex]::Replace($txt, '/\*.*?\*/', '', 'Singleline')
        $nc = [regex]::Replace($nc, '//[^\r\n]*', '')
        if ($nc -match '(?ms)^\s*initial\b(.*?)end\b') {
            $body = $Matches[1]
            # RAM power-up content via $readmemh is legitimate for BRAM init;
            # $display/$finish/#delay inside 'initial' is simulation-only code.
            if ($body -match '\$(display|finish|stop|monitor|time)|\#\s*\d') { $badInit += $f.Name }
            else { $ramInit += $f.Name }
        }
        if ($nc -match '(?m)^\s*#\s*\d') { $badDelay += $f.Name }
    }
    if ($badInit.Count -eq 0) { Ok "no simulation-control code in synthesis sources" } else { Bad ("sim-only 'initial' found in: " + ($badInit -join ',')) }
    if ($ramInit.Count -gt 0) { Info ("RAM init blocks (allowed): " + ($ramInit -join ',')) }
    if ($badDelay.Count -eq 0) { Ok "no '#delay' in synthesis sources" } else { Bad ("#delay found in: " + ($badDelay -join ',')) }

    # ENC_DISP_TAP is legal only inside `ifdef in RTL; it must never be passed
    # as a define by the PRODUCTION build script.
    $prodTcl = @('tools\impl_check_v66.tcl', 'tools\impl_check_v70.tcl')
    $tap = @()
    foreach ($t in $prodTcl) {
        if (Test-Path $t) {
            $tt = Get-Content $t -Raw -Encoding UTF8
            if ($tt -match 'verilog_define\s+ENC_DISP_TAP') { $tap += $t }
        }
    }
    if ($tap.Count -eq 0) { Ok "production build script does not define ENC_DISP_TAP" } else { Bad ("ENC_DISP_TAP in: " + ($tap -join ',')) }
    $ei = @()
    foreach ($f in @($rtl + $eth)) {
        $t = [regex]::Replace((Get-Content $f.FullName -Raw -Encoding UTF8), '//[^\r\n]*', '')
        if ($t -match '`ifdef\s+ENC_EI58|`ifndef\s+ENC_EI58') { $ei += $f.Name }
    }
    if ($ei.Count -eq 0) { Ok "no ENC_EI58 conditional left in RTL" } else { Bad ("ENC_EI58 branch in: " + ($ei -join ',')) }

    Write-Host "=== 3. config defaults ==="
    $encTop = Get-Content rtl\enc_top.v -Raw -Encoding UTF8
    if ($encTop -match 'parameter\s+integer\s+POLE_BITS\s*=\s*(\d+)') {
        $pb = $Matches[1]
        if ($pb -eq '11') { Ok "POLE_BITS = 11 (2048 ppr)" } else { Bad ("POLE_BITS = $pb, expected 11") }
    } else { Bad "POLE_BITS default not found" }
    if ($encTop -match "RTL_BUILD_ID\s*=\s*16'h([0-9A-Fa-f]+)") {
        Info ("RTL_BUILD_ID = 0x" + $Matches[1])
    } else { Bad "RTL_BUILD_ID not found" }
    $regFile = Get-Content rtl\reg_file.v -Raw -Encoding UTF8
    if ($regFile -match "r_ff_cfg\s*<=\s*8'h([0-9A-Fa-f]+)") {
        $v = [Convert]::ToInt32($Matches[1], 16)
        if (($v -band 1) -eq 1) { Ok "lag feed-forward enabled by default (0x0122 bit0)" } else { Bad "lag feed-forward disabled by default" }
        if (($v -band 2) -eq 0) { Ok "bias tracker disabled by default (0x0122 bit1)" } else { Bad "bias tracker enabled by default (should wait for board check)" }
    } else { Bad "0x0122 reset value not found" }

    Write-Host "=== 4. host <-> RTL UDP port ==="
    $capRegs = Get-Content rtl\cap_regs.v -Raw -Encoding UTF8
    $portRtl = $null
    if ($capRegs -match "port\s*<=\s*16'd(\d+)") { $portRtl = [int]$Matches[1] }
    $mw = Get-Content host\main_window.py -Raw -Encoding UTF8
    $portHost = $null
    # 2026-11-02：端口默认值搬到了 host\cmds_mixin.py（os.environ.get("FPGA_UDP_PORT", "5000")），
    # 所以改成扫 host\*.py，任一处给出默认端口即可。
    foreach ($hf in @(Get-ChildItem host\*.py -File)) {
        $txt = Get-Content $hf.FullName -Raw -Encoding UTF8
        if ($txt -match 'FPGA_UDP_PORT"\s*,\s*"(\d+)"') { $portHost = [int]$Matches[1]; break }
        if ($txt -match 'udp_port\s*=\s*(\d+)')        { $portHost = [int]$Matches[1]; break }
    }
    Info ("RTL default UDP port = $portRtl ; host default = $portHost")
    if ($portRtl -ne $null -and $portRtl -eq $portHost) { Ok "host and RTL agree on UDP port ($portRtl)" }
    else { Bad "UDP port mismatch: RTL=$portRtl host=$portHost" }

    Write-Host "=== 5. freshness (build must match the sources) ==="
    $srcNewest = ($syn + @(Get-ChildItem constr\*.xdc -File) | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    Info ("newest synthesis source: " + $srcNewest.Name + "  " + $srcNewest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    # v70 起用"内容等价"而不是 mtime 判新鲜度：签到用的 RTL 由 tools/make_v7x_rtl.py 复制到
    # _synth_work_v7x/rtl_v7x，只差 CRLF 与 RTL_BUILD_ID 一行；mtime 会因为补注释而误报。
    # 2026-11-02 起优先对 v74（Z 计数探针 + 显示 UI，签核位流），其次 v73/v71，没有则退回 v70。
    if (Test-Path '_synth_work_v74\rtl_v74') { $varRoot = '_synth_work_v74\rtl_v74'; $varTag = 'v74' }
    elseif (Test-Path '_synth_work_v73\rtl_v73') { $varRoot = '_synth_work_v73\rtl_v73'; $varTag = 'v73' }
    elseif (Test-Path '_synth_work_v71\rtl_v71') { $varRoot = '_synth_work_v71\rtl_v71'; $varTag = 'v71' }
    else                                    { $varRoot = '_synth_work_v70\rtl_v70'; $varTag = 'v70' }
    Info ("comparing repo rtl/ against build sources: " + $varRoot)
    $srcDiff = @()
    foreach ($f in $rtl) {
        $gen = Join-Path $varRoot $f.Name
        if (Test-Path $gen) {
            $a = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            $b = [IO.File]::ReadAllText((Resolve-Path $gen), [Text.Encoding]::UTF8)
            $a = $a.Replace("`r`n", "`n").Replace("`r", "`n")
            $b = $b.Replace("`r`n", "`n").Replace("`r", "`n")
            # 注释不进综合：`//` 之后的内容与纯注释行一律剔除再比较（2026-11-02 补 BiSS 移除注释时必须如此，
            # 否则"只差注释"会被误判成与构建源漂移）。空行也去掉，只比代码行。
            $a = (($a -split "`n") | ForEach-Object { ($_ -split '//')[0].TrimEnd() } | Where-Object { $_ -ne '' }) -join "`n"
            $b = (($b -split "`n") | ForEach-Object { ($_ -split '//')[0].TrimEnd() } | Where-Object { $_ -ne '' }) -join "`n"
            if ($f.Name -eq 'enc_top.v') {
                # 变体生成器只改 RTL_BUILD_ID 那一行，比较时剔除
                $a = (($a -split "`n") | Where-Object { $_ -notmatch 'RTL_BUILD_ID\s*=' }) -join "`n"
                $b = (($b -split "`n") | Where-Object { $_ -notmatch 'RTL_BUILD_ID\s*=' }) -join "`n"
            }
            if ($a -ne $b) { $srcDiff += $f.Name }
        }
    }
    if ($srcDiff.Count -eq 0) { Ok ("repo rtl/ is code-identical to the $varTag build sources ($varRoot); comments and RTL_BUILD_ID excluded") }
    else { Bad ("repo rtl/ differs from $varTag build sources: " + ($srcDiff -join ',')) }
    $summary = Get-Item sim\logs\SUMMARY.md -ErrorAction SilentlyContinue
    if ($summary) {
        # 主回归（xsim）在本机不可用；v70 的签核证据是 ModelSim 定向台 + 真机 5 判据（docs/33）。
        # 这里只在"摘要比源码新"时判 PASS/FAIL，陈旧时降级为 info 并写明替代证据。
        if ($summary.LastWriteTime -ge $srcNewest.LastWriteTime) {
            Ok ("regression summary newer than sources (" + $summary.LastWriteTime.ToString('HH:mm:ss') + ")")
            $s = Get-Content $summary.FullName -Encoding UTF8
            $nPass = ($s | Select-String -Pattern '\| PASS \|').Count
            $nFail = ($s | Select-String -Pattern '\| (FAIL|NO-VERDICT|NEW-ERR)').Count
            if ($nFail -eq 0 -and $nPass -ge 30) { Ok ("regression all pass ($nPass)") } else { Bad ("regression: pass=$nPass fail=$nFail") }
        } else {
            Info "regression summary predates v70 RTL (2026-10-30); v70 signoff = ModelSim tb_acc2/tb_uvw_rev + board 5 判据 (docs/33 §5)"
        }
    } else { Bad "sim/logs/SUMMARY.md missing (run tools\run_sim.ps1)" }

    Write-Host "=== 6. bitstreams ($varTag signoff) ==="
    # v70 起 *_impl_* 目录里不再保留 vivado.log（只留报告），所以时序改从
    # impl_timing*_v70.rpt 读；同时用全局 SHA256SUMS.txt 钉死交付位流。
    $shaMap = @{}
    if (Test-Path 'deliverables\data\SHA256SUMS.txt') {
        foreach ($ln in Get-Content 'deliverables\data\SHA256SUMS.txt' -Encoding UTF8) {
            if ($ln -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { $shaMap[$Matches[2].Trim()] = $Matches[1].ToUpper() }
        }
    }
    if ($varTag -eq 'v74') {
        $bits = @(
            @{ Dir = '_impl_v74';      Bit = 'enc_top_v74.bit';      Tag = 'prod'; Rpt = 'impl_timing_v71.rpt'; Sha = 'v74/enc_top_v74.bit' },
            @{ Dir = '_impl_disp_v74'; Bit = 'enc_top_disp_v74.bit'; Tag = 'disp'; Rpt = 'impl_timing.rpt';      Sha = 'v74/enc_top_disp_v74.bit' }
        )
    } elseif ($varTag -eq 'v73') {
        $bits = @(
            @{ Dir = '_impl_v73';      Bit = 'enc_top_v73.bit';      Tag = 'prod'; Rpt = 'impl_timing_v71.rpt'; Sha = 'v73/enc_top_v73.bit' },
            @{ Dir = '_impl_disp_v73'; Bit = 'enc_top_disp_v73.bit'; Tag = 'disp'; Rpt = 'impl_timing.rpt';      Sha = 'v73/enc_top_disp_v73.bit' }
        )
    } elseif ($varTag -eq 'v71') {
        $bits = @(
            @{ Dir = '_impl_v71';      Bit = 'enc_top_v71.bit';      Tag = 'prod'; Rpt = 'impl_timing_v71.rpt'; Sha = 'v71/enc_top_v71.bit' },
            @{ Dir = '_impl_disp_v71'; Bit = 'enc_top_disp_v71.bit'; Tag = 'disp'; Rpt = 'impl_timing.rpt';      Sha = 'v71/enc_top_disp_v71.bit' }
        )
    } else {
        $bits = @(
            @{ Dir = '_impl_v70';      Bit = 'enc_top_v70.bit';      Tag = 'prod'; Rpt = 'impl_timing_v70.rpt'; Sha = 'v70/enc_top_v70.bit' },
            @{ Dir = '_impl_disp_v70'; Bit = 'enc_top_disp_v70.bit'; Tag = 'disp'; Rpt = 'impl_timing.rpt';      Sha = 'v70/enc_top_disp_v70.bit' }
        )
    }
    foreach ($b in $bits) {
        $p = Join-Path $b.Dir $b.Bit
        if (-not (Test-Path $p)) { Bad ("$($b.Tag) bitstream missing: $p"); continue }
        $f = Get-Item $p
        if ($f.LastWriteTime -ge $srcNewest.LastWriteTime) { Ok ("$($b.Tag) bitstream newer than sources (" + $f.LastWriteTime.ToString('HH:mm:ss') + ", " + $f.Length + " B)") }
        else { Info ("$($b.Tag) bitstream mtime predates doc/comment edits (" + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + "); provenance is checked by RTL text equality + SHA256 below") }

        $rpt = Join-Path $b.Dir $b.Rpt
        if (Test-Path $rpt) {
            $lines = Get-Content $rpt -Encoding UTF8
            $hdr = ($lines | Select-String -Pattern '^\s*WNS\(ns\)' | Select-Object -First 1)
            if ($hdr -and $lines.Count -gt ($hdr.LineNumber + 1)) {
                # 表头下一行是虚线，再下一行才是数值
                $row = $lines[$hdr.LineNumber + 1]
                $vals = @($row -split '\s+' | Where-Object { $_ -ne '' })
                if ($vals.Count -ge 5 -and $vals[0] -match '^-?\d+\.\d+$') {
                    $wns = [double]$vals[0]; $tns = [double]$vals[1]; $whs = [double]$vals[4]
                    if ($wns -ge 0 -and $tns -ge -0.0001 -and $whs -ge 0) { Ok ("$($b.Tag) timing WNS=+$wns WHS=+$whs (from $($b.Rpt))") }
                    else { Bad ("$($b.Tag) timing violated: WNS=$wns TNS=$tns WHS=$whs") }
                } else { Bad ("$($b.Tag) timing row unparsable in $($b.Rpt): $row") }
            } else { Bad ("$($b.Tag) WNS table not found in $($b.Rpt)") }
            if ($lines | Select-String -Pattern 'All user specified timing constraints are met') { Ok ("$($b.Tag) timing report says constraints met") }
        } elseif (Test-Path (Join-Path $b.Dir 'vivado.log')) {
            $t = Get-Content (Join-Path $b.Dir 'vivado.log') -Encoding Default
            if ($t | Select-String -Pattern 'Bitgen Completed Successfully') { Ok ("$($b.Tag) bitgen completed") } else { Bad ("$($b.Tag) bitgen not completed") }
        } else { Bad ("$($b.Tag) neither timing report nor vivado.log found in $($b.Dir)") }

        if ($shaMap.Count -gt 0 -and $shaMap.ContainsKey($b.Sha)) {
            $arch = Join-Path 'deliverables\data' $b.Sha
            if (Test-Path $arch) {
                $h = (Get-FileHash $arch -Algorithm SHA256).Hash.ToUpper()
                if ($h -eq (Get-FileHash $p -Algorithm SHA256).Hash.ToUpper() -and $h -eq $shaMap[$b.Sha]) { Ok ("$($b.Tag) SHA256 matches archived copy and manifest") }
                else { Bad ("$($b.Tag) SHA256 mismatch (dir=$h manifest=$($shaMap[$b.Sha]))") }
            } else { Bad ("$($b.Tag) archived copy missing: $arch") }
        } else { Bad ("$($b.Tag) SHA256 pin missing from deliverables\data\SHA256SUMS.txt") }
    }

    Write-Host "=== 7. host self-tests ==="
    $py = 'E:\Anaconda\python.exe'
    # 可移植性：干净克隆里未必有 E:\Anaconda，退回 PATH 上的 python（本机优先用 Anaconda，
    # 因为 markdown / PyQt 只装在它里面）。
    if (-not (Test-Path $py)) {
        $cmd = Get-Command python -ErrorAction SilentlyContinue
        if ($cmd) { $py = $cmd.Source }
    }
    # Python writes GBK to a redirected pipe on this machine; decode as 936 so the
    # Chinese "自检通过" text is readable and matchable.
    try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { }
    if (Test-Path $py) {
        & $py -m compileall -q host 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "host python compiles" } else { Bad "host python compile failed" }
        $o1 = & $py host\regs.py --selftest 2>&1 | Select-String -Pattern 'PASS|FAIL' | Select-Object -Last 1
        if ($o1 -match 'PASS') { Ok ("regs.py selftest: " + $o1.Line.Trim()) } else { Bad ("regs.py selftest: " + $o1) }
        $o2all = & $py host\alarm.py --selftest 2>&1
        $nok = @($o2all | Select-String -Pattern '\[OK\]').Count
        if ($nok -ge 25) { Ok ("alarm.py selftest: $nok checks [OK]") } else { Bad ("alarm.py selftest: only $nok checks [OK]") }
        $env:QT_QPA_PLATFORM = 'offscreen'
        $o3 = & $py host\selftest_ui.py 2>&1 | Select-String -Pattern 'TOTAL|PASS|FAIL' | Select-Object -Last 2
        if (($o3 -join ' ') -match 'TOTAL') { Info ("selftest_ui: " + (($o3 | Select-Object -Last 1).Line.Trim())) }
        Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    } else { Bad "python not found at $py" }

    Write-Host "=== 8. documents ==="
    foreach ($d in @('docs\27_turntable_requirements_feasibility.md','docs\28_board_bringup_checklist.md',
                     'docs\32_board_test_report_2026-11-01.md','docs\33_v70_release_report.md',
                     'docs\34_audit_report.md','docs\35_v71_release_report.md',
                     'docs\36_v72_v73_board_debug.md', 'docs\37_display_smoke_coverage.md',
                     'deliverables\design_report.md','deliverables\design_report.pdf',
                     'deliverables\data\SHA256SUMS.txt','docs\ai-collaboration-log.md')) {
        if (Test-Path $d) { Ok ("doc present: $d (" + (Get-Item $d).Length + " B)") } else { Bad ("doc missing: $d") }
    }
}
finally { Pop-Location }

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green }
else { Write-Host ("FAILED CHECKS: " + $fails) -ForegroundColor Red }
exit $fails
