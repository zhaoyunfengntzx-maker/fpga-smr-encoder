#=============================================================================
# tools/lint_all.ps1 —— 用 Vivado xvlog 对全部 RTL / 测试台做语法+语义检查
#
#   xvlog --sv 是增量分析，每调用一次就把结果累积进 work 库。
#   这里对每个文件**单独新建一个干净目录**分析，逐个报告 ERROR/WARNING，
#   与最终 xelab 的"整体精化"互补：
#       lint_all.ps1  -> 单文件编译期问题（未声明标识符、非 reg 赋值、格式串不匹配只在 xelab 报）
#       run_sim.ps1   -> 每个测试台的整体编译 + 精化 + 仿真
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\lint_all.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\lint_all.ps1 -Clean
#
# 退出码: 0 = 无 ERROR/WARNING；1 = 存在 ERROR（WARNING 只报告不失败）
#=============================================================================
#   ★ 2026-10-15：这里刻意**不加** [CmdletBinding()]。
#     加了它，脚本就成了"高级脚本"，在受限语言模式下被调用时 PowerShell 会
#     尝试把它点源(dot-source)进调用者作用域，而跨语言模式点源是被禁止的：
#         NotSupportedException / DotSourceNotSupported
#     结果同样是"一行都不跑"。本脚本只用到 [switch] 参数这一个高级特性，
#     用普通 param 声明完全等价，去掉后可在受限模式下正常执行。
param(
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$WorkRoot  = Join-Path $Root '_sim_work\_lint'
$VivadoBin = 'D:\Vivado\2026.1\Vivado\bin'
if (-not (Test-Path (Join-Path $VivadoBin 'xvlog.bat'))) { throw "找不到 Vivado: $VivadoBin" }
$env:Path = "$VivadoBin;$env:Path"

# 编码设置只影响控制台显示，不影响 xvlog 的判定。
#   ★ 2026-10-15：在受限语言模式（ConstrainedLanguage）下 New-Object 会被拒
#     （CannotCreateTypeConstrainedLanguage），旧版这里会直接抛异常、整个脚本一行不跑。
#     包一层 try 让它降级为乱码显示，而不是让 lint 静默失效。
try {
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [Console]::OutputEncoding = $Utf8Bom
} catch {
    Write-Host "  (注意: 无法设置控制台编码，中文可能显示为乱码，不影响判定)" -ForegroundColor DarkYellow
}

if ($Clean -and (Test-Path $WorkRoot)) { Remove-Item $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

#   ★ 2026-10-15 补：disp/ 此前完全没有 lint 覆盖 —— 旧版只扫 rtl\*.v 与 sim\tb_*.v，
#     而显示引擎已经长到 9 个模块（disp_engine / font_rom / text_ram / val_format /
#     touch_view / band_view / ui_edit / touch_ctrl / i2c_master_seq）。
#     也就是说它过去报的 "ERROR 0 / WARNING 0" 从来不包含显示代码。
#     disp\sim\ 是仿真专用件（IIC 从机模型、IOBUF/BUFG 桩），与设计源分开维护，
#     所以单独列出，便于一眼看出问题出在"设计"还是"仿真件"。
$targets = @()
foreach ($f in (Get-ChildItem (Join-Path $Root 'rtl\*.v')      | Sort-Object Name)) { $targets += $f }
foreach ($f in (Get-ChildItem (Join-Path $Root 'sim\tb_*.v')   | Sort-Object Name)) { $targets += $f }
foreach ($f in (Get-ChildItem (Join-Path $Root 'disp\*.v')     | Sort-Object Name)) { $targets += $f }
foreach ($f in (Get-ChildItem (Join-Path $Root 'disp\sim\*.v') | Sort-Object Name)) { $targets += $f }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " xvlog 逐文件语法检查:  $($targets.Count) 个文件"
Write-Host "================================================================" -ForegroundColor Cyan

$nErr = 0
$nWarn = 0

foreach ($f in $targets) {
    # 目录名带上相对路径：不同目录下的同名文件（sim/ 与 disp/sim/ 都有 iic_slave_model.v
    # 这类桩件）如果复用同一个目录，前一个文件留下的 work 库会把模块定义带进后一次分析，
    # 于是报出"重复定义"这种假 ERROR。
    #   ★ 2026-10-15：这里原来用 [System.IO.Path]::GetFileNameWithoutExtension()，
    #     但 .NET 静态方法在受限语言模式下同样被拒（MethodInvocationNotSupported-
    #     InConstrainedLanguage），等于又给脚本埋了一个"整段跑不起来"的坑。
    #     相对路径里的分隔符已换成 '__'，剩下的最后一个点后面一定就是扩展名，
    #     用纯字符串替换去掉它，效果等价且只依赖核心类型。
    $rel  = $f.FullName.Substring($Root.Length + 1) -replace '[\\/]', '__'
    $name = $rel -replace '\.[^.]*$', ''
    $d = Join-Path $WorkRoot $name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Push-Location $d
    $o = & xvlog --sv $f.FullName 2>&1
    $code = $LASTEXITCODE
    Pop-Location

    $msgs = @($o | Where-Object { $_ -match '^(ERROR|WARNING)' })
    $errs = @($msgs | Where-Object { $_ -match '^ERROR' })
    $nErr += $errs.Count
    $nWarn += @($msgs | Where-Object { $_ -match '^WARNING' }).Count

    if ($msgs.Count -eq 0) {
        Write-Host ("  [ok]   {0}" -f $f.Name) -ForegroundColor Green
    } else {
        $col = 'Yellow'
        if ($errs.Count -gt 0) { $col = 'Red' }
        Write-Host ("  [{0,2}E {1,2}W] {2}" -f $errs.Count,
                    @($msgs | Where-Object { $_ -match '^WARNING' }).Count, $f.Name) -ForegroundColor $col
        $msgs | ForEach-Object { Write-Host "           $_" -ForegroundColor $col }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
$c = 'Green'
if ($nErr -gt 0) { $c = 'Red' }
Write-Host (" 合计: ERROR {0} / WARNING {1}" -f $nErr, $nWarn) -ForegroundColor $c
if ($nErr -gt 0) { exit 1 }
exit 0
