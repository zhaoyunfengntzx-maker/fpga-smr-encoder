<#
.SYNOPSIS
    交付用**目录版**包：一条命令完成「打源头闸 → PyInstaller → 门禁复核（标签/PYZ/烟测）」。
    （产物：host\dist_onedir\host_app\host_app.exe）

.DESCRIPTION
    正式交付的是目录版（不是单文件包）：`host/host_onedir.spec` → `host\dist_onedir\host_app\`。

    为什么要有这个脚本：交付前的清单本来靠"照着 README 手敲 PyInstaller + 记得查 icacls +
    记得跑 check_pyz + 记得清掉烟测残留"，任何一条漏掉都可能把带 `Low` 标签的 exe 交出去
    —— 2026-10-16 就是这么翻的车（用户双击后只能写标签允许的目录，见
    docs/ai-collaboration-log.md 记录 72）。脚本把顺序固定下来，并且：

      * **打包前先看自己是不是受限令牌**（DSH 沙箱 / 被降权的终端）。那才是病根：
        低完整性进程打出来的 exe 会带 `Mandatory Label\Low Mandatory Level`。
        发现受限就**默认拒绝打包**（要硬来加 -Force），而不是打完再解释。
      * 打完立刻调 `tools\check_package.ps1 -Fix`：量标签（含工作区根的继承标签）、文件数、
        总字节、SHA256、PYZ 模块数与正向/逆向串、包内烟测，并清掉烟测残留。
      * 一键打印"这次该把哪些数字抄进哪几个文件"，避免文档与产物不同步。

.PARAMETER Python
    Python 解释器（默认 `python`，须已装 PyInstaller）。

.PARAMETER NoClean
    不清理 `host\_exe_work_onedir`（增量重打，快，但可能残留旧文件）。

.PARAMETER NoSmoke
    不做包内烟测（只出产物 + 标签/PYZ 复核）。

.PARAMETER NoFix
    门禁发现 Low 标签时**不自动修**（默认会自动 `/setintegritylevel`）。

.PARAMETER Force
    明知当前终端是受限/低完整性，也照打（产物八成带 Low 标签，门禁会用 -Fix 试着救）。

.PARAMETER SmokeSeconds
    烟测最多等多少秒（默认 20）。

.EXAMPLE
    pwsh -File tools\build_host_onedir.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_host_onedir.ps1 -NoSmoke
#>
[CmdletBinding()]
param(
    [string]$Python = "python",
    [switch]$NoClean,
    [switch]$NoSmoke,
    [switch]$NoFix,
    [switch]$Force,
    [int]$SmokeSeconds = 20
)

$ErrorActionPreference = "Stop"

try {
    if ((Get-ExecutionPolicy -Scope Process) -eq 'Restricted') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }
} catch { }

# ★ Windows PowerShell 5.1 下显式设 UTF-8 控制台编码，否则 python 的 UTF-8 输出会变乱码
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
$env:PYTHONIOENCODING = "utf-8"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok  ($msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [~~] $msg" -ForegroundColor Yellow }
function Bad ($msg) { Write-Host "    [!!] $msg" -ForegroundColor Red }

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$Spec       = Join-Path $RepoRoot "host\host_onedir.spec"
$WorkDir    = Join-Path $RepoRoot "host\_exe_work_onedir"
$DistDir    = Join-Path $RepoRoot "host\dist_onedir"
$PackageDir = Join-Path $DistDir  "host_app"
$ExePath    = Join-Path $PackageDir "host_app.exe"
$Gate       = Join-Path $PSScriptRoot "check_package.ps1"

# ---- ① 打源头闸：受限令牌不许打包 -----------------------------------------
Step "① 打源头闸（受限令牌打出来的包会带 Low 标签，见记录 72）"
$groups = @(whoami /groups 2>&1 | ForEach-Object { "$_" })
$gtext  = $groups -join "`n"
$tokLow = $gtext -match [regex]::Escape('Mandatory Label\Low')
$tokSid = $gtext -match 'S-1-4-'
$mand   = @($groups | Where-Object { $_ -match 'Mandatory Level' } | ForEach-Object { $_.Trim() })
if ($mand.Count) { Ok ("完整性：" + ($mand -join ' | ')) } else { Warn "读不到完整性级别" }
if ($tokLow -or $tokSid) {
    $why = @()
    if ($tokLow) { $why += "Low 完整性" }
    if ($tokSid) { $why += "沙箱令牌 SID S-1-4-…" }
    Bad "当前终端是受限环境（$($why -join ' + ')）"
    Warn "  从这里打包 ⇒ exe 带 Low 标签 ⇒ 用户双击后写不进普通目录（[Errno 13] / [WinError 5]）"
    Warn "  请在**普通终端**里跑本脚本：资源管理器双击 .bat，或用不在沙箱内的 PowerShell"
    if (-not $Force) { Bad "已拒绝打包（真要硬来：加 -Force）"; exit 1 }
    Warn "  -Force 生效，继续打包（门禁会用 -Fix 试着把标签救回来）"
} else {
    Ok "普通令牌 ⇒ 具备打干净包的前提"
}

# ---- ② 环境自检 -----------------------------------------------------------
Step "② 环境自检"
if (-not (Test-Path -LiteralPath $Spec)) { Bad "找不到 $Spec"; exit 1 }
Ok "spec: $Spec"
$pyExe = (Get-Command $Python -ErrorAction SilentlyContinue)
if (-not $pyExe) { Bad "找不到 Python 解释器 '$Python'；用 -Python 指定完整路径"; exit 1 }
$pyVer = & $Python -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>&1
Ok "python: $($pyExe.Source) 版本 $pyVer"

$need = "PySide6", "serial", "matplotlib", "PIL", "PyInstaller"
foreach ($m in $need) {
    $v = & $Python -c "import $m,sys;print(getattr($m,'__version__','?'))" 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($m -eq "PyInstaller") {
            Bad "缺 PyInstaller。装法："
            Write-Host "         $Python -m pip install pyinstaller -i https://pypi.tuna.tsinghua.edu.cn/simple"
        } else { Bad "缺 $m" }
        exit 1
    }
    Ok "$m $v"
}
foreach ($f in @("uart_scope.py", "uart_spi.py")) {
    $p = Join-Path $RepoRoot "tools\$f"
    if (-not (Test-Path -LiteralPath $p)) { Bad "spec 的 hiddenimports 需要 $p，但它不在"; exit 1 }
    Ok "tools\$f 在位"
}
if (-not (Test-Path -LiteralPath $Gate)) { Bad "找不到门禁脚本 $Gate"; exit 1 }

# ---- ③ 先确认没人占着旧包 --------------------------------------------------
Step "③ 检查旧包是否被占用"
$running = @(Get-Process -Name "host_app" -ErrorAction SilentlyContinue)
if ($running.Count) {
    Bad "有正在运行的 host_app（PID $($running.Id -join ', ')）—— 目录删不掉，PyInstaller 会失败"
    Warn "  先关掉窗口再跑本脚本"
    exit 1
}
Ok "没有正在运行的 host_app"

if (-not $NoClean) {
    Step "清理上次的构建目录"
    foreach ($d in @($WorkDir, $PackageDir)) {
        if (Test-Path -LiteralPath $d) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $d) { Bad "删不掉 $d（可能还被占用）"; exit 1 }
            Ok "已删 $d"
        }
    }
}

# ---- ④ 打包 ---------------------------------------------------------------
Step "④ PyInstaller 打包（目录版，约 556 MB / 几分钟）"
$t0 = Get-Date
& $Python -m PyInstaller --noconfirm --clean `
    --workpath $WorkDir --distpath $DistDir $Spec
$rc = $LASTEXITCODE
$dt = (Get-Date) - $t0
if ($rc -ne 0) { Bad "PyInstaller 退出码 $rc（用时 $([int]$dt.TotalSeconds) s）"; exit $rc }
if (-not (Test-Path -LiteralPath $ExePath)) { Bad "打包返回成功，但没看到 $ExePath"; exit 1 }
$item = Get-Item -LiteralPath $ExePath
$hash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash

Step "产物"
Write-Host "    路径   : $($item.FullName)"
Write-Host "    大小   : $($item.Length) B（$([math]::Round($item.Length/1MB,2)) MB）"
Write-Host "    时间   : $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "    SHA256 : $hash"
Write-Host "    用时   : $([int]$dt.TotalSeconds) s"

# ---- ⑤ 门禁复核 -----------------------------------------------------------
Step "⑤ 门禁复核（tools\check_package.ps1）"
$gateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Gate, "-PackageDir", $PackageDir, "-SmokeSeconds", "$SmokeSeconds")
if (-not $NoSmoke) { $gateArgs += "-Smoke" }
if (-not $NoFix)   { $gateArgs += "-Fix" }
# ★ 用**当前宿主**的解释器跑门禁，不要写死 `pwsh`：本机 pwsh 常不在 PATH
#   （README 也记着这条），写死会直接 "无法将 pwsh 项识别为 cmdlet"。
$psHostExe = $null
try { $psHostExe = (Get-Process -Id $PID).Path } catch { }
if (-not $psHostExe -or -not (Test-Path -LiteralPath $psHostExe)) { $psHostExe = "powershell.exe" }
& $psHostExe @gateArgs
if ($LASTEXITCODE -ne 0) {
    Bad "门禁没过（exit $LASTEXITCODE）—— 这批产物不要交"
    exit $LASTEXITCODE
}

# ---- ⑥ 收尾：文档同步提醒 --------------------------------------------------
Step "⑥ 下一步：把这次数字抄进文档（别让文档和产物分叉）"
$stamp = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
Write-Host "    exe    : $($item.Length) B @$stamp"
Write-Host "    SHA256 : $hash"
$fileCount = @(Get-ChildItem -LiteralPath $PackageDir -Recurse -File -Force).Count
$totalBytes = 0
foreach ($f in @(Get-ChildItem -LiteralPath $PackageDir -Recurse -File -Force)) { $totalBytes += $f.Length }
Write-Host "    目录   : $fileCount 文件 / $totalBytes B"
Write-Host "    要更新的地方："
Write-Host "      * host\README.md 的「当前交付的目录版」段 + 文末状态表新增一行"
Write-Host "      * docs\DEV_STATUS.md 最新 §1.x 的交付小节"
Write-Host "      * docs\16_host_ui_refactor_R16_R20.md 最新 §13.x"
Write-Host "      * host\README.md 的「文件表」若本轮新增/改了模块也要补"
Write-Host ""
Write-Host "打包 + 门禁全部通过：$ExePath" -ForegroundColor Green
Write-Host "以后复核只需：powershell -ExecutionPolicy Bypass -File tools\check_package.ps1 -Smoke" -ForegroundColor Green
exit 0
