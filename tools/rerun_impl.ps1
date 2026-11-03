# 生产版 + ILA 版实现重跑（后台一键）
#
# ★ 可选参数 -WaitPid <pid>：先等指定进程结束再开工。用于"当前已有一轮实现在跑，
#   想在本轮 RTL 改动落定后再补一轮"的场景，避免同一次 Vivado 并发抢占。
param(
    [int] $WaitPid = 0
)
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\zhaoy\Desktop\FPGA'
Set-Location $root

if ($WaitPid -gt 0) {
    Write-Output "等待 PID $WaitPid 结束（当前这轮实现跑完再开工）..."
    try {
        Wait-Process -Id $WaitPid -ErrorAction Stop
        Write-Output "PID $WaitPid 已结束，开始重跑。"
    } catch {
        Write-Output "PID $WaitPid 不存在或已结束，直接开始重跑。"
    }
}

Write-Output "############ [1/2] 生产版 tools/impl_check.tcl ############"
$t0 = Get-Date
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
    -Tcl tools\impl_check.tcl -LogFile '_synth_work\impl_build.log' -Tail 25
$rc1 = $LASTEXITCODE
Write-Output "PROD_EXIT=$rc1  用时 $([int]((Get-Date)-$t0).TotalMinutes) 分"

Write-Output ""
Write-Output "############ [2/2] ILA 版 tools/ila_debug.tcl ############"
$t1 = Get-Date
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
    -Tcl tools\ila_debug.tcl -LogFile '_synth_work\ila_build.log' -Tail 25
$rc2 = $LASTEXITCODE
Write-Output "ILA_EXIT=$rc2  用时 $([int]((Get-Date)-$t1).TotalMinutes) 分"

Write-Output ""
Write-Output "############ 产物时间戳 ############"
Get-ChildItem '_synth_work\*.bit','_synth_work\*.ltx','_synth_work\*.rpt' |
    Sort-Object LastWriteTime |
    ForEach-Object { "{0:MM-dd HH:mm:ss} {1,12} B  {2}" -f $_.LastWriteTime, $_.Length, $_.Name }
Write-Output "ALL_IMPL_DONE"
