<#
.SYNOPSIS
    离线门槛：一条命令跑完「编译 + 全部离线自检 + 界面级自检」，任何一项不过就非零退出。

.DESCRIPTION
    为什么需要它（2026-10-17 全面自查的教训）：

    交付门槛 `tools\check_package.ps1` 只量**产物**（标签/文件数/PYZ/烟测），不跑**源码自检**；
    而 `host\README.md` 里列着七个 `--selftest` 命令，实际**从来没人跑**。自查时发现其中两个
    已经"恒假失败"很久，谁都没察觉：

      * `host/export_png.py`：像素断言里写死了**旧调色板**（primary 旧 `#2E7DD1`，主题现在是
        `#0071E3`）⇒ [2]/[4] 两条恒 FAIL（出图其实一直是对的，坏的是断言）；
      * `host/recorder.py`：断言只认"目录不可写就报 error"，而阶段 5 D 批起 `start()` 会先探写、
        自动改存到能写的位置 ⇒ [6] 恒 FAIL（新行为才是产品要的）。

    这类"自检自己坏了"最难发现：它不打断任何流程，只会让一条命令长期红着没人看。
    所以照 `check_package.ps1` 的思路，把"记得跑"变成"一条命令 + 非零退出码"。

    顺序与内容：
      ① 环境：python 能跑、仓库根正确、`host\selftest_ui.py` 在位；
      ② `python -m compileall -q host`（语法/字节码；写过 `__pycache__` 也算能写工作区）；
      ③ 八个纯逻辑离线自检：encoder / alarm / regs / ui_prefs / abz / recorder / export_png / analysis；
      ④ 界面级回归 `host\selftest_ui.py`（offscreen，不需要板子；它自己会写 `host\_ui_selftest_tmp`）。

    全部 PASS → exit 0；任何一项非零 → exit 1 并列名。

.PARAMETER Python
    解释器，默认 `python`。

.PARAMETER SkipUi
    跳过 ④（只跑纯逻辑模块；界面自检最慢，约 40 s）。

.PARAMETER Quiet
    只打印每步结论，不打印各模块自检正文。

.Notes
    ★ 真机自检（`selftest_link.py` / `selftest_s2..s5.py --port COM3`）**不在**这里：
    它们要插板子，属于"用户接回板子后补跑"的验收项。
    ★ 本脚本只读源码、只写自检临时目录；不碰交付包，也不改标签。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1
.EXAMPLE
    pwsh -File tools\check_offline.ps1 -SkipUi
#>
[CmdletBinding()]
param(
    [string]$Python = "python",
    [switch]$SkipUi,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

try {
    if ((Get-ExecutionPolicy -Scope Process) -eq 'Restricted') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }
} catch { }

# ★ Windows PowerShell 5.1：不设这个，python 的 UTF-8 中文输出会被按 OEM 码页（936）解码
#   ⇒ 汇总行全是乱码，等于没输出。pwsh 7 默认 UTF-8。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
$env:PYTHONIOENCODING = "utf-8"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok  ($msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [~~] $msg" -ForegroundColor Yellow }
function Bad ($msg) { Write-Host "    [!!] $msg" -ForegroundColor Red }

$script:Fails = New-Object System.Collections.ArrayList
function Fail($msg) { Bad $msg; [void]$script:Fails.Add($msg) }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HostDir = Join-Path $RepoRoot "host"
$UiTest = Join-Path $HostDir "selftest_ui.py"

# 每项：模块名 → 期望出现的"通过"关键字（纯提示用，判定只看退出码）
$Modules = @("encoder", "alarm", "regs", "ui_prefs", "abz", "recorder", "export_png", "analysis", "record_bin", "replay", "panel_lut", "panel_health", "linkctl", "taskrunner", "net_frames")

# ★ Windows PowerShell 5.1：`$ErrorActionPreference = "Stop"` 时，**原生命令往 stderr 写的任何
#   一行**都会变成 NativeCommandError 终止语句（Qt 在 offscreen 下会正常打印
#   `This plugin does not support propagateSizeHints()`、matplotlib 也会有告警）
#   ⇒ 自检明明通过却被判失败（实测踩到）。所有原生调用统一走这个包装：临时把偏好恢复成
#   Continue，判定只看退出码。
function Invoke-Py {
    param([string[]]$PyArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $text = & $Python @PyArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return @{ text = $text; code = $code }
}

# ------------------------------------------------------------------ 环境
Step "环境"
if (-not (Test-Path $UiTest)) {
    Fail "找不到 $UiTest（请在仓库里跑本脚本：$RepoRoot）"
    Bad "仓库根看起来不对，后面的步骤没法跑。"
    exit 1
}
Ok "仓库根 $RepoRoot"
$r0 = Invoke-Py @("-c", "import sys;print(sys.version.split()[0])")
if ($r0.code -ne 0) {
    Fail "`$Python = $Python 跑不起来：$($r0.text.Trim())"
    exit 1
}
Ok "python $($r0.text.Trim())"

# ------------------------------------------------------------------ ① 编译
Step "compileall（语法/字节码）"
$r1 = Invoke-Py @("-m", "compileall", "-q", $HostDir)
if ($r1.code -ne 0) {
    Fail "compileall 失败（exit $($r1.code)）"
    if ($r1.text.Trim()) { Write-Host $r1.text.Trim() }
} else {
    Ok "compileall exit 0"
}

# ------------------------------------------------------------------ ② 模块自检
function Last-Line($text) {
    $ls = @($text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($ls.Count -eq 0) { return "" }
    return $ls[-1].Trim()
}

Step "离线自检（$($Modules.Count) 个纯逻辑模块）"
foreach ($m in $Modules) {
    $script = Join-Path $HostDir "$m.py"
    if (-not (Test-Path $script)) { Fail "$m.py 不在（README 里列了它）"; continue }
    $r = Invoke-Py @("-X", "utf8", $script, "--selftest")
    $code = $r.code
    $text = $r.text
    if ($code -eq 0) {
        Ok ("{0,-11} exit 0   {1}" -f $m, (Last-Line $text))
    } else {
        Fail ("{0,-11} exit {1}   {2}" -f $m, $code, (Last-Line $text))
        if (-not $Quiet) {
            @($text -split "`r?`n" | Where-Object { $_ -match '\[!!\]|FAIL|失败' } |
              Select-Object -First 8) | ForEach-Object { Write-Host "         $($_.Trim())" -ForegroundColor DarkGray }
        }
    }
}

# --------------------------------------------------- ②.5 静态名字检查
# 拆分/搬家最容易漏的是"原来在 main_window 里随便可见的模块级别名"（C / uk / TAG_TEXT…），
# 这类漏的只在特定分支炸，自检走不到。用标准库 symtable 扫一遍，0 处才继续。
Step "静态名字检查（引用了但没定义/没导入的全局名）"
$rn = Invoke-Py @("tools\check_names.py")
$rn.text.TrimEnd() -split "`r?`n" | ForEach-Object {
    if ($_ -match '^\[未定义\]') { Write-Host "    $_" -ForegroundColor Red }
}
if ($rn.code -eq 0) {
    Ok ($rn.text.TrimEnd() -split "`r?`n" | Select-Object -Last 1)
} else {
    Fail ("{0,-11} exit {1}   {2}" -f "names", $rn.code,
          ($rn.text.TrimEnd() -split "`r?`n" | Select-Object -Last 1))
}

# ------------------------------------------------------------------ ③ 界面级自检
if ($SkipUi) {
    Warn "跳过界面级自检（-SkipUi）"
} else {
    Step "界面级自检 selftest_ui.py（offscreen）"
    $env:QT_QPA_PLATFORM = "offscreen"
    $env:QT_QPA_FONTDIR = "C:\Windows\Fonts"
    $r = Invoke-Py @("-X", "utf8", $UiTest)
    $code = $r.code
    $text = $r.text
    $summary = @($text -split "`r?`n" | Where-Object { $_ -match '通过|失败' } |
                 Select-Object -Last 2) -join " / "
    if ($code -eq 0) {
        Ok ("selftest_ui exit 0   {0}" -f $summary.Trim())
    } else {
        Fail ("selftest_ui exit {0}   {1}" -f $code, $summary.Trim())
        if (-not $Quiet) {
            @($text -split "`r?`n" | Where-Object { $_ -match '\[!!\]' } |
              Select-Object -First 10) | ForEach-Object { Write-Host "         $($_.Trim())" -ForegroundColor DarkGray }
        }
    }
}

# ------------------------------------------------------------------ 汇总
Step "结果"
if ($script:Fails.Count -eq 0) {
    Write-Host "    离线门槛 PASS（compileall + $($Modules.Count) 个模块自检$(if (-not $SkipUi) { ' + 界面级自检' }))" -ForegroundColor Green
    exit 0
}
Bad "离线门槛 FAIL，共 $($script:Fails.Count) 项："
$script:Fails | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
Write-Host "    修完重跑本脚本；真机门槛请等板子接回后跑 host\selftest_ui.py --real-port COM3 --seconds 6" -ForegroundColor Yellow
exit 1
