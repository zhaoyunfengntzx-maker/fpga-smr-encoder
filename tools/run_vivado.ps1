<#
    tools/run_vivado.ps1  ——  Vivado 前置信封（把本机四个必要环境一次设好）

    为什么需要这个包装：本机跑 Vivado 有四个必须手动做的事，漏一个就报错，
    而且报错信息都指向别的地方，很容易误判成"工程有问题"：

      1) PATH 里没有 Vivado
         Vivado 是 D:\Vivado\2026.1\Vivado\bin，不在系统 PATH，
         直接 `vivado` 会 CommandNotFoundException。
      2) HOME / USERPROFILE / APPDATA 指向用户目录时 Vivado 写 app.xml 失败
         ERROR: [Common 17-1219] Failed to create directory to save app.xml at 'C'
      3) ★ XILINXD_LICENSE_FILE 没设 → ILA 不可用
         D:\Vivado 下同时存在两个许可文件：
           D:\Vivado\Xilinx.lic        —— 只有 Vivado_Basic_Package（BASIC）
           D:\Vivado\Xlnx_2026_1.lic   —— Vivado_Tier=GOLD + ChipscopePro
         Vivado 默认按搜索路径命中 BASIC 那个，于是 create_debug_core 报
           ERROR: [Vivado 12-29205] 'create_debug_core' tcl command is not supported.
                  Your current selected license is BASIC.
         必须显式把 XILINXD_LICENSE_FILE 指到 GOLD 那个文件。
         设对后开机会打印：
           INFO: [Common 17-3922] A valid Vivado Design Suite GOLD license has been detected.
      4) 本 harness 的 pwsh 工具跑在 Windows PowerShell 5.1 上，没有 pwsh.exe，
         且默认禁止运行脚本 ⇒ 只能 powershell.exe -ExecutionPolicy Bypass -File。
      5) ★ TEMP / TMP / LOCALAPPDATA 必须钉在工作区内
         连 hw_server 时 cs_server 要把 VCRUNTIME140.dll 解包到 %TEMP%，
         沙箱只允许写工作区 ⇒ 报 [Labtools 27-2220] Unable to launch local
         cs_server executable / Failed to extract VCRUNTIME140.dll: Permission denied。
         症状极具误导性（看着像 JTAG 驱动问题），且只影响"要下板子/连 hw_server"
         的流程：synth/impl/bitgen 一切正常。

    用法：
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 -Tcl tools\impl_check.tcl
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 -Tcl tools\ila_debug.tcl
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 -Tcl tools\synth_check.tcl -Tail 40

    ★ 加了 -LogFile 支持：Vivado 的批量输出全部落到文件，便于事后定位卡在哪一步。
      没有这个文件时，后台作业的 job_output 只回显脚本正文，看不到 Vivado 的进度。
#>
<#
    ★ 2026-10-15：`param` 里**不能**出现 `[Parameter(Mandatory = $true)]`。
      带了它，脚本会被 PowerShell 当成"高级脚本"，在受限语言模式下被调用时
      会尝试点源进调用者作用域，而跨语言模式点源是禁止的：
          NotSupportedException / DotSourceNotSupported
      症状是"脚本一行不跑"。改成普通 `[string]` + 手工判空，效果等价。
      同理，`[string]::IsNullOrWhiteSpace()` 这类 .NET 静态方法在受限模式下
      也会被拒（MethodInvocationNotSupportedInConstrainedLanguage），
      统一换成 `-not $x`。
#>
param(
    [string] $Tcl,
    [string] $VivadoBin = 'D:\Vivado\2026.1\Vivado\bin',
    [string] $LicFile   = 'D:\Vivado\Xlnx_2026_1.lic',
    [int]    $Tail      = 40,
    [string] $LogFile   = ''
)

if (-not $Tcl) { throw 'run_vivado.ps1: 必须给 -Tcl <脚本路径>' }

$ErrorActionPreference = 'Continue'

# 1) PATH
if (Test-Path $VivadoBin) {
    $env:Path = "$VivadoBin;" + $env:Path
} else {
    Write-Warning "Vivado bin 不存在: $VivadoBin"
}

# 2) 把 HOME、USERPROFILE、APPDATA 钉在工作区，避免写 C 盘失败
#    ★ 踩坑记录：注释里不能出现斜杠加引号的组合（例如写成
#      HOME/USERPROFILE/APPDATA 再加一对双引号），PowerShell 会把斜杠
#      当成除号，报出与本行毫无关系的
#      Unexpected token '}' in expression or statement。
#      注释里保持纯中文和顿号即可。
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$env:HOME        = $root
$env:USERPROFILE = $root
$env:APPDATA     = Join-Path $root '.appdata'
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null

# 2b) ★ TEMP / TMP / LOCALAPPDATA 也必须钉在工作区内（2026-10-11 新增）
#     hw_server / cs_server 是 PyInstaller 打包的单文件程序，启动时要把
#     VCRUNTIME140.dll 等解包到 %TEMP%\_MEIxxxx。本 harness 的文件沙箱只允许
#     写工作区，于是解包失败，报出的是完全不像"写文件被拒"的三行：
#       ERROR: [Labtools 27-2220] Launch Error:
#       Unable to launch local cs_server executable.
#       ERROR] Failed to extract VCRUNTIME140.dll: failed to open target file! fopen: Permission denied
#     看起来像"JTAG 线不认/驱动没装"，实际是 %TEMP% 在 C 盘被沙箱拦了。
#     现象特征：build 类流程（synth/impl/bitgen）不受影响，只有要连
#     hw_server / 下板子的流程（program_hw_devices、ILA 采集）才炸。
$env:TEMP         = Join-Path $root '.tmp'
$env:TMP          = $env:TEMP
$env:LOCALAPPDATA = Join-Path $root '.appdata'
foreach ($d in @($env:TEMP, $env:LOCALAPPDATA)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# 3) ★ 许可证：必须显式指到含 Debug(GOLD) 的那个文件
if (Test-Path $LicFile) {
    $env:XILINXD_LICENSE_FILE = $LicFile
    $tiers = Select-String -Path $LicFile -Pattern 'License_Tier:([A-Za-z]+)' -AllMatches |
             ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
             Sort-Object -Unique
    Write-Host ("LICENSE: XILINXD_LICENSE_FILE = {0}  (tiers: {1})" -f $LicFile, ($tiers -join ','))
} else {
    Write-Warning "许可文件不存在: $LicFile  —— ILA 会报 12-29205"
}

$tclFull = Join-Path $root $Tcl
Write-Host ("VIVADO : {0}" -f (Join-Path $VivadoBin 'vivado.bat'))
Write-Host ("TCL    : {0}" -f $tclFull)

if (-not $LogFile) {
    Write-Host "------------------------------------------------------------"
    & vivado -mode batch -nojournal -nolog -source $tclFull 2>&1 | Select-Object -Last $Tail
} else {
    $logFull = Join-Path $root $LogFile
    Write-Host ("LOG    : {0}" -f $logFull)
    Write-Host "------------------------------------------------------------"
    & vivado -mode batch -nojournal -nolog -source $tclFull *> $logFull
    Write-Host ("---- tail of {0} (last {1} lines) ----" -f $logFull, $Tail)
    Get-Content $logFull -Tail $Tail
}
exit $LASTEXITCODE
