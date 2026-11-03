<#
.SYNOPSIS
    打包上位机为单文件 exe（S6）。

.DESCRIPTION
    调用 `host/host_exe.spec` 把 `host/app.py` 打成**单文件 exe**，
    产物固定落在 `host/dist/host_app.exe`。

    为什么用脚本而不是直接敲 pyinstaller：
      * 本机 PyInstaller 常在 `%APPDATA%\Python\Python313\Scripts`（不在 PATH），
        且 Anaconda 的 site-packages 不可写 ⇒ 统一走 `python -m PyInstaller`；
      * 打包前要做环境自检（Python / PyInstaller / PySide6 / pyserial /
        matplotlib / PIL，以及 spec 的 hiddenimports 依赖的 `tools/` 两个文件），
        缺东西当场说清楚，不要等打完了才发现 exe 起不来；
      * 把构建输出留在 `host/_exe_work/`，**不污染仓库根**。

.PARAMETER Python
    Python 解释器（默认 `python`，即当前 PATH 里的那个；须已装 PyInstaller）。

.PARAMETER NoClean
    不清理上次的 `host/_exe_work/` 与 `host/dist/`，增量重打（快，但可能残留旧文件）。

.PARAMETER SmokeSeconds
    冒烟自检最多等多少秒（默认 6）。单文件 exe 首次启动要解包（本包 208 MB），
    老机器/杀软扫描时会明显更慢，可加大到 30。

.PARAMETER NoSmoke
    跳过冒烟自检（只出产物）。**注意：DSH 沙箱里必须加这个开关**（见下）。

.Notes
    ★ DSH 文件沙箱（workspace-write / 更低权限）里，单文件 exe **起不来**，报：
        [PYI-xxxx:ERROR] Failed to extract Lerc.dll: failed to open target file!
        fopen: Permission denied
    根因在沙箱的受限令牌，不在产物：PyInstaller 引导器用**显式安全描述符**创建
    `%TEMP%\_MEIxxxxxx`（只给"当前用户 SID"完全控制），而沙箱进程的写权限是靠
    **一个额外令牌 SID**（`S-1-4-…`，见 `icacls <仓库根>`）授的 —— 引导器**不会**
    把这个 SID 写进新目录的 ACL，于是它自己刚建的目录自己写不进去。
    连"预先建好 `_MEI*` 目录 + 重赋 ACL + `--runtime-tmpdir` 指到仓库内"都绕不过
    （新目录一建出来仍是那份只有用户 SID 的 ACL）。
    ⇒ 沙箱内只做打包（`-NoSmoke`），**烟测与真机验证请在沙箱外的普通终端/双击做**：
        host\dist\host_app.exe --smoke smoke.png --seconds 4
        host\dist\host_app.exe --port COM3

.EXAMPLE
    pwsh -File tools\build_host_exe.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_host_exe.ps1
#>
[CmdletBinding()]
param(
    [string]$Python = "python",
    [switch]$NoClean,
    [int]$SmokeSeconds = 6,
    [switch]$NoSmoke
)

$ErrorActionPreference = "Stop"

# ---- 执行策略（本机 pwsh 不在 PATH，README 里也是先放行 Process 作用域）------
try {
    if ((Get-ExecutionPolicy -Scope Process) -eq 'Restricted') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }
} catch { }

$RepoRoot = Split-Path -Parent $PSScriptRoot          # tools\ 的上一级
$Spec     = Join-Path $RepoRoot "host\host_exe.spec"
$WorkDir  = Join-Path $RepoRoot "host\_exe_work"
$DistDir  = Join-Path $RepoRoot "host\dist"
$ExePath  = Join-Path $DistDir "host_app.exe"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok  ($msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Bad ($msg) { Write-Host "    [!!] $msg" -ForegroundColor Red }

Step "环境自检"
if (-not (Test-Path $Spec)) { Bad "找不到 $Spec"; exit 1 }
Ok "spec: $Spec"

$pyExe = (Get-Command $Python -ErrorAction SilentlyContinue)
if (-not $pyExe) { Bad "找不到 Python 解释器 '$Python'；用 -Python 指定完整路径"; exit 1 }
$pyVer = & $Python -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>&1
Ok "python: $($pyExe.Source) 版本 $pyVer"

# PySide6 / pyserial / matplotlib / PIL / PyInstaller 一个都不能少，
# 且必须和"打包时用的这个解释器"一致，否则 exe 里会缺模块。
$need = "PySide6", "serial", "matplotlib", "PIL", "PyInstaller"
foreach ($m in $need) {
    $v = & $Python -c "import $m,sys;print(getattr($m,'__version__','?'))" 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($m -eq "PyInstaller") {
            Bad "缺 PyInstaller。装法（本机 site-packages 不可写时会自动装到用户目录）："
            Write-Host "         $Python -m pip install pyinstaller -i https://pypi.tuna.tsinghua.edu.cn/simple"
        } else {
            Bad "缺 $m"
        }
        exit 1
    }
    Ok "$m $v"
}

# spec 的 hiddenimports 依赖仓库里的两个协议实现文件（见 host/host_exe.spec 文件头第 2 条）
$toolsNeeded = @("uart_scope.py", "uart_spi.py")
foreach ($f in $toolsNeeded) {
    $p = Join-Path $RepoRoot "tools\$f"
    if (-not (Test-Path $p)) { Bad "spec 的 hiddenimports 需要 $p，但它不在"; exit 1 }
    Ok "tools\$f 在位"
}

if (-not $NoClean) {
    Step "清理上次的构建目录"
    foreach ($d in @($WorkDir, $DistDir)) {
        if (Test-Path $d) {
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $d) { Bad "删不掉 $d（可能还被上次的 exe 占用，先关掉它）"; exit 1 }
            Ok "已删 $d"
        }
    }
}

Step "PyInstaller 打包（单文件，需要几分钟）"
$t0 = Get-Date
& $Python -m PyInstaller --noconfirm --clean `
    --workpath $WorkDir --distpath $DistDir $Spec
$rc = $LASTEXITCODE
$dt = (Get-Date) - $t0

if ($rc -ne 0) { Bad "PyInstaller 退出码 $rc（用时 $([int]$dt.TotalSeconds) s）"; exit $rc }
if (-not (Test-Path $ExePath)) { Bad "打包返回成功，但没看到 $ExePath"; exit 1 }

$item = Get-Item $ExePath
$hash = (Get-FileHash $ExePath -Algorithm SHA256).Hash
$mb   = [math]::Round($item.Length / 1MB, 1)

Step "产物"
Write-Host "    路径   : $($item.FullName)"
Write-Host "    大小   : $($item.Length) B（$mb MB）"
Write-Host "    时间   : $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "    SHA256 : $hash"
Write-Host "    用时   : $([int]$dt.TotalSeconds) s"

# ★ 完整性标签复核（2026-10-16，见 docs/ai-collaboration-log.md 记录 72）：
#   打包进程若处在受限/低完整性环境（DSH 文件沙箱、被降权的终端……），PyInstaller 会把
#   `Mandatory Label\Low Mandatory Level` 写进产物；这种 exe 被资源管理器双击时，
#   Windows 按镜像标签把进程**降权** ⇒ 保存 PNG 报 [Errno 13]、"打开文件夹"报
#   [WinError 5]，看着像"程序坏了"，其实产物在出厂那天就带了病。
#   宁可在这里拦下来（exit 1），也不要交出去。
Step "完整性标签复核（交付前必过）"
$aclText = (@(icacls $ExePath 2>&1) | Out-String)
if ($aclText -match [regex]::Escape('Mandatory Label\Low')) {
    Bad "exe 带 Low 完整性标签 ⇒ 用户双击后会被降权（写不进普通目录）"
    Warn "  修法：icacls `"$RepoRoot`" /setintegritylevel `"(OI)(CI)M`" /T /C /Q，然后重打"
    Warn "  根因：打包时进程处在受限环境（沙箱 / 被降权终端）⇒ 请在普通终端重打"
    exit 1
}
Ok "无 Low 标签"
if ($aclText -match 'S-1-4-') {
    Warn "有 S-1-4-… 沙箱指纹（产物出自受限环境的构建）⇒ 交付前再跑 tools\check_package.ps1 复核"
} else {
    Ok "无 S-1-4-… 沙箱指纹"
}

Step "冒烟自检（不连板子：建窗 → 截图 → 退出）"
# console=False 的 GUI exe 没有真正可读的 stdout，所以这里**以退出码 + 截图文件为准**，
# 打印内容能拿到就顺带显示（拿不到不算失败）。真机验证见 README 的 S6 一节。
#
# ★ 两个坑（2026-10-13 首轮打包踩到，别改回去）：
#   1. **必须用 Start-Process -Wait**。GUI 子系统（Subsystem=2）的 exe 直接 `& $Exe`
#      在 PowerShell 里**立即返回**（不等待窗口进程），于是"退出码/截图"都在拿空气：
#      首轮就报"烟测没生成截图"。
#   2. 单文件 exe **启动要先把包解到临时目录**（本包 208 MB，冷启动 3~10 s），
#      所以等待要给足，`--seconds`（默认 6 s）是"窗口起来之后再等多久"。
$smoke = Join-Path $DistDir "_smoke.png"
Remove-Item $smoke -Force -ErrorAction SilentlyContinue
if ($NoSmoke) {
    Ok "跳过（-NoSmoke）"
} else {
    $t1 = Get-Date
    $sp = Start-Process -FilePath $ExePath -ArgumentList @("--smoke", $smoke, "--seconds", "2") `
                        -PassThru -RedirectStandardOutput (Join-Path $DistDir "_smoke.out.txt") `
                        -RedirectStandardError (Join-Path $DistDir "_smoke.err.txt")
    if (-not $sp.WaitForExit($SmokeSeconds * 1000)) {
        $sp.Kill()
        Bad "烟测 $SmokeSeconds s 内没退出（单文件首次解包就该给它更多时间：-SmokeSeconds 30）"
        exit 1
    }
    $rc = $sp.ExitCode
    foreach ($f in @((Join-Path $DistDir "_smoke.out.txt"), (Join-Path $DistDir "_smoke.err.txt"))) {
        if (Test-Path $f) {
            foreach ($line in (Get-Content $f -ErrorAction SilentlyContinue)) {
                if ("$line".Trim()) { Write-Host "    $line" }
            }
        }
    }
    $el = [int]((Get-Date) - $t1).TotalSeconds
    if ($rc -ne 0) { Bad "烟测退出码 $rc（exe 能起但启动/截图有问题，用时 ${el}s）"; exit $rc }
    if (-not (Test-Path $smoke)) { Bad "烟测没生成截图（用时 ${el}s）"; exit 1 }
    Ok "截图 $([math]::Round((Get-Item $smoke).Length/1KB,1)) kB，用时 ${el}s"
}

Write-Host ""
Write-Host "打包完成：$ExePath" -ForegroundColor Green
Write-Host "目标机验证（真机）：& `"$ExePath`" --port COM3" -ForegroundColor Green
exit 0
