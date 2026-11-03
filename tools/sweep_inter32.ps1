<#
    tools/sweep_inter32.ps1
    ---------------------------------------------------------------------------
    用途：**inter = 32 高频重扫**（`0x0101 = 0x0020` ⇒ 128 个 AB 边沿/电周期）
    的"批量抓 ILA"驱动 —— 在同一块板、同一位流（v9 **ILA 版**）上，
    按给定顺序改 `0x0302`（环路档位）并各抓一版 ILA CSV。

    为什么要有这个脚本：每次 ILA 抓波都要跑一次 vivado + JTAG，
    单独调用 6 次要 6 次提权；放进一个脚本里只需 1 次。

    前置条件（调用者负责）：
      1) 板上已烧 v9 **ILA 版**位流 `_synth_work/enc_top_ila.bit`；
      2) 已写 `0x0101 = 0x0020`（inter = 32）并回读确认；
      3) AFG 已设到目标频率（12 kHz / 20 kHz），幅度/偏置不变。

    用法（在仓库根目录）：
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\sweep_inter32.ps1 `
          -Tag v9k12 -SettingsCsv "04,1A,00"

    ★ 值一定要**加引号**：PowerShell 会把裸 `04`/`00` 当数值 ⇒ 不加引号会变成
      `4,1A,0`（写入仍对，但 CSV 文件名丢前导零；脚本已用 PadLeft 兜底）。

    ★ 为什么是 -SettingsCsv（逗号分隔的**单个字符串**）而不是 [string[]]：
      `powershell.exe -File` 传参不做逗号数组解析，`-Settings 04,1A,00` 会被
      当成**一个**字符串 "04,1A,00" ⇒ 只跑一档、且 $reg 变成 "0x004,1A,0"
      ⇒ `tools/uart_spi.py` 抛 `ValueError: invalid literal for int() with base 0`。
      所以这里收一个 CSV 字符串，脚本内部自己 `-split '[,\s]+'`。

    产物：
      `_synth_work/ila_cap_<Tag>_<档>.csv`   每档一版波形
      `_synth_work/sweep_<Tag>.log`          全过程日志（含寄存器回读）
#>
[CmdletBinding()]
param(
    [string]$Tag = "v9k12",
    [string]$Port = "COM6",
    [string]$SettingsCsv = "04,0C,1A,1C,00",
    [int]$Depth = 1024,
    [int]$WaitMs = 30000
)
$ErrorActionPreference = "Continue"
Set-Location (Split-Path -Parent $PSScriptRoot)
$Settings = @($SettingsCsv -split '[,\s]+' | Where-Object { $_ -ne '' })
if ($Settings.Count -eq 0) { throw "-SettingsCsv 为空" }
$py  = "E:\Anaconda\python.exe"
$log = "_synth_work\sweep_$Tag.log"

function Say([string]$m) {
    $line = "{0} {1}" -f ([DateTime]::Now.ToString("HH:mm:ss")), $m
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}
function Get-Reg([string]$addr) {
    $env:PYTHONIOENCODING = "utf-8"
    $out = & $py tools\uart_spi.py --port $Port read $addr 2>&1 | Out-String
    (($out -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($addr) }) -join " | "
}

Say ("SWEEP BEGIN tag={0} depth={1} wait={2}ms settings={3}" -f $Tag, $Depth, $WaitMs, ($Settings -join ","))
Say ("  0x05F2 = {0}" -f (Get-Reg 0x05F2))
Say ("  0x0101 = {0}" -f (Get-Reg 0x0101))
Say ("  0x0102 = {0}" -f (Get-Reg 0x0102))
Say ("  0x0108 = {0}" -f (Get-Reg 0x0108))

$ok = 0
$bad = @()
foreach ($s in $Settings) {
    # ★ PowerShell 会把裸 `04` / `00` 当数值 ⇒ 传进来变成 "4" / "0"（写入仍对，
    #   因为 0x004/0x000 可解析，但 CSV 文件名会丢前导零）⇒ 这里补齐两位。
    $s = ("{0}" -f $s).Trim().PadLeft(2, '0')
    $reg = "0x00$s"
    Say "--- 档位 0x0302 = $reg ---"
    $env:PYTHONIOENCODING = "utf-8"
    & $py tools\uart_spi.py --port $Port write 0x0302 $reg | Out-Null
    Start-Sleep -Milliseconds 300
    Say ("  回读 0x0302 = {0}" -f (Get-Reg 0x0302))
    $cnt = @('0x0505','0x0507','0x0509','0x050B','0x050D') | ForEach-Object { (Get-Reg $_).Trim() }
    Say ("  毛刺计数: " + ($cnt -join ' ; '))

    $csv  = "_synth_work/ila_cap_${Tag}_$s.csv"
    $clog = "_synth_work/ila_cap_${Tag}_$s.log"
    if (Test-Path $csv) { Remove-Item $csv -Force }
    $env:ILA_MODE  = "capture"
    $env:ILA_CSV   = $csv
    $env:ILA_DEPTH = "$Depth"
    $env:ILA_WAIT  = "$WaitMs"
    Remove-Item Env:ILA_TRIG -ErrorAction SilentlyContinue

    $t0 = [DateTime]::Now
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 -Tcl tools\ila_capture.tcl -LogFile $clog -Tail 6
    $dt = ([DateTime]::Now - $t0).TotalSeconds

    if (Test-Path $csv) {
        Say ("  CSV 已生成 {0} ({1} B, {2:N1} s)" -f $csv, (Get-Item $csv).Length, $dt)
        $ok++
    } else {
        Say ("  !! CSV 缺失 {0}（{1:N1} s）—— 看 {2} 尾部" -f $csv, $dt, $clog)
        $bad += $s
    }
}
Say ("SWEEP END ok={0} bad=[{1}]" -f $ok, ($bad -join ","))
