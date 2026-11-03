<#
.SYNOPSIS
    交付包门禁：一条命令量完「完整性标签 / 文件数 / 大小 / SHA256 / PYZ / 包内烟测」。

.DESCRIPTION
    为什么需要它（2026-10-16 的现场，见 docs/ai-collaboration-log.md 记录 72）：

    打包时如果进程处在**受限令牌 / 低完整性**环境（DSH 文件沙箱、被降权的终端……），
    PyInstaller 产出的 exe 会带上 `Mandatory Label\Low Mandatory Level`，并且把这份
    可继承的标签写进包里；资源管理器双击这种 exe 时，Windows 按**镜像标签**把进程降权到
    低完整性 ⇒ 它只能写标签允许的目录：保存 PNG 报 `[Errno 13]`、「打开文件夹」报
    `[WinError 5]`，看着像"软件坏了"，其实产物在出厂那天就带了病。

    所以本脚本把"记得检查"变成"一条命令 + 非零退出码"：
      ① 当前终端是不是受限令牌/低完整性（在**源头**就告诉你这批包会脏）；
      ② 产物 exe、整包目录、工作区根有没有 `Low` 标签 / `S-1-4-…` 沙箱 ACE；
      ③ 文件数与总字节数（可与 README/DEV_STATUS 里记的数字对照）；
      ④ 包内 PYZ：模块数 + 正向命中 + 逆向退场串（调 tools/check_pyz.py）；
      ⑤ 可选（-Smoke）：包内烟测（起窗口 → 截图 → 退出），跑完自动清掉它留下的运行时文件。

    全部 PASS → exit 0；任何一项不过 → exit 1。可以挂进交付流程 / CI。

.PARAMETER PackageDir
    交付目录，默认 `host\dist_onedir\host_app`。

.PARAMETER ExeName
    包内主程序名，默认 `host_app.exe`。

.PARAMETER Python
    PYZ 复核用的解释器（须能 `import PyInstaller`），默认 `python`。

.PARAMETER ExpectFiles
    期望文件数；0（默认）表示不核对。给上就会在数字变了时报警。

.PARAMETER ExpectBytes
    期望总字节数；0（默认）表示不核对。

.PARAMETER SkipLabel / SkipPyz / SkipSmoke
    分别跳过 标签门禁 / PYZ 复核 / 烟测。

.PARAMETER Smoke
    跑包内烟测（默认不跑）。它会在包目录里留下 `ui_prefs.json`、`host_app_run.log`，
    本脚本随后删掉，回到出厂目录。

.PARAMETER SmokeSeconds
    烟测最多等多少秒（默认 20）。

.PARAMETER Fix
    发现 Low 标签时**就地修**（只改完整性级别，逐级设置，不做 `icacls /reset`）。

.Notes
    ★ 修标签只动**完整性级别**，不要顺手 `icacls /reset /T`：
    工作区树上的 `S-1-4-…` 授权与 `Everyone:(CI)(DENY)(DC)` 是 DSH 沙箱的**预期状态**
    （见技能 `diagnose-windows-sandbox-acl`），`/reset /T` 会把沙箱机制一起删掉。
    真要修，用：`icacls <路径> /setintegritylevel "(OI)(CI)M" /T /C /Q`。
    本脚本的 `-Fix` 就是这么做的，而且只对**交付目录 + 工作区根**下手。

.EXAMPLE
    pwsh -File tools\check_package.ps1
.EXAMPLE
    pwsh -File tools\check_package.ps1 -Smoke -Fix
.EXAMPLE
    pwsh -File tools\check_package.ps1 -PackageDir host\dist_onedir\host_app -ExpectFiles 439
#>
[CmdletBinding()]
param(
    [string]$PackageDir,
    [string]$ExeName = "host_app.exe",
    [string]$Python = "python",
    [int]$ExpectFiles = 0,
    [long]$ExpectBytes = 0,
    [switch]$SkipLabel,
    [switch]$SkipPyz,
    [switch]$SkipSmoke,
    [switch]$Smoke,
    [int]$SmokeSeconds = 20,
    [switch]$Fix
)

$ErrorActionPreference = "Stop"

# 本机 pwsh 常不在 PATH，README 里也是先放行 Process 作用域
try {
    if ((Get-ExecutionPolicy -Scope Process) -eq 'Restricted') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    }
} catch { }

# ★ Windows PowerShell 5.1 下必须显式把控制台输出编码设成 UTF-8：
#   否则 `python tools\check_pyz.py` 的 UTF-8 输出会被按 OEM 码页（936）解码，
#   屏幕上全是 `PYZ ģ���� = 684` 这种乱码（实测踩到）。pwsh 7 默认 UTF-8，不受影响。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
$env:PYTHONIOENCODING = "utf-8"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok  ($msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [~~] $msg" -ForegroundColor Yellow }
function Bad ($msg) { Write-Host "    [!!] $msg" -ForegroundColor Red }

$script:Fails = New-Object System.Collections.ArrayList
function Fail($msg) { Bad $msg; [void]$script:Fails.Add($msg) }

# ★ GUI exe 往**管道**里写的是系统 ANSI 码页（本机 cp936），不是 UTF-8：
#   实测字节 `bd d8 cd bc b3 c9 b9 a6` = "截图成功"。所以烟测输出按**字节**读回，
#   先当 UTF-8 严解码，失败再按 ANSI 码页解 —— 两种写法都对，
#   不会再出现 `��ͼ�ɹ���` 这种把 GBK 当 UTF-8 解出来的乱码。
function Convert-RawText {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return "" }
    try {
        $strict = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        return $strict.GetString($Bytes)
    } catch {
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        return [System.Text.Encoding]::GetEncoding($cp).GetString($Bytes)
    }
}

function Read-RawStream {
    param([System.IO.Stream]$Stream)
    $ms  = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    while (($n = $Stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    return $ms.ToArray()
}

$RepoRoot  = Split-Path -Parent $PSScriptRoot
if (-not $PackageDir) { $PackageDir = Join-Path $RepoRoot "host\dist_onedir\host_app" }
if (-not (Test-Path -LiteralPath $PackageDir)) {
    Bad "找不到交付目录：$PackageDir"
    exit 1
}
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$ExePath    = Join-Path $PackageDir $ExeName
if (-not (Test-Path -LiteralPath $ExePath)) {
    Bad "交付目录里没有 $ExeName：$ExePath"
    exit 1
}

# 量一份路径的标签情况：Low 强制完整性标签条数、沙箱 SID 授权条数
function Get-LabelFacts([string]$Path, [bool]$Recurse) {
    $out = if ($Recurse) { & icacls $Path /T /C 2>&1 } else { & icacls $Path 2>&1 }
    $text = (@($out) | Out-String)
    [pscustomobject]@{
        Rows = @($out).Count
        Low  = ([regex]::Matches($text, [regex]::Escape('Mandatory Label\Low'))).Count
        Sid  = ([regex]::Matches($text, 'S-1-4-')).Count
    }
}

Write-Host ""
Write-Host "交付包门禁：$PackageDir" -ForegroundColor Cyan
Write-Host ""

# ---- ① 当前终端身份：脏包的第一现场 ----------------------------------------
Step "① 当前终端身份（打包装包的那双手）"
$groups = @(whoami /groups 2>&1 | ForEach-Object { "$_" })
$gtext  = $groups -join "`n"
$mand   = @($groups | Where-Object { $_ -match 'Mandatory Level' } | ForEach-Object { $_.Trim() })
$tokLow = $gtext -match [regex]::Escape('Mandatory Label\Low')
$tokSid = $gtext -match 'S-1-4-'
if ($mand.Count) { Ok ("完整性：" + ($mand -join ' | ')) } else { Warn "读不到完整性级别（whoami /groups 没给出 Mandatory Level 行）" }
if ($tokLow -or $tokSid) {
    $why = @()
    if ($tokLow) { $why += "Low 完整性" }
    if ($tokSid) { $why += "沙箱令牌 SID" }
    Warn "当前终端是受限环境（$($why -join ' + ')）—— 从这里打出来的 exe 会带 Low 标签"
    Warn "  建议改在普通终端打包：资源管理器里双击 .bat，或用不在沙箱内的 PowerShell"
} else {
    Ok "普通令牌（非受限、非低完整性）⇒ 现在打包不会引入 Low 标签"
}

# ---- ② 标签门禁（核心）-----------------------------------------------------
$dirty = $false
if ($SkipLabel) {
    Step "② 完整性标签门禁"
    Warn "跳过（-SkipLabel）"
} else {
    Step "② 完整性标签门禁（Low 标签 = 交付物带病）"
    $exeL  = Get-LabelFacts $ExePath    $false
    $dirL  = Get-LabelFacts $PackageDir $false
    $treeL = Get-LabelFacts $PackageDir $true
    $rootL = Get-LabelFacts $RepoRoot   $false

    if ($exeL.Low -gt 0)  { Bad "exe 自己带 Low 标签（$ExeName）" } else { Ok "exe 标签干净" }
    if ($dirL.Low -gt 0)  { Bad "交付目录带 Low 标签（会被子文件继承）" } else { Ok "交付目录标签干净" }
    if ($treeL.Low -gt 0) { Bad "包内树有 $($treeL.Low) 行 Low 标签（扫了 $($treeL.Rows) 行）" } else { Ok "包内树无 Low 标签（扫了 $($treeL.Rows) 行）" }
    if ($rootL.Low -gt 0) { Bad "工作区根带可继承 Low 标签 ⇒ 下次重打立刻复发" } else { Ok "工作区根标签干净" }

    if (($treeL.Sid + $rootL.Sid + $exeL.Sid) -gt 0) {
        Warn "发现 $($treeL.Sid + $rootL.Sid + $exeL.Sid) 行 S-1-4-… 沙箱指纹：产物出自受限环境的构建"
        Warn "  它本身只是授权（不拒绝普通用户），但它和 Low 标签同源 ⇒ 这批数必须是新打的才敢交"
    } else {
        Ok "无 S-1-4-… 沙箱指纹"
    }

    $dirty = ($exeL.Low -gt 0) -or ($dirL.Low -gt 0) -or ($treeL.Low -gt 0) -or ($rootL.Low -gt 0)

    if ($dirty -and $Fix) {
        Step "就地修复完整性标签（只改标签，不用 icacls /reset）"
        & icacls $ExePath /setintegritylevel M | Out-Null
        & icacls $PackageDir /setintegritylevel "(OI)(CI)M" /T /C /Q | Out-Null
        & icacls $RepoRoot  /setintegritylevel "(OI)(CI)M" /T /C /Q | Out-Null
        Ok "已对 exe / 交付目录树 / 工作区根树执行 /setintegritylevel"
        Warn "注：只动完整性级别；工作区树上的 S-1-4-… 授权与 Everyone deny 是沙箱预期状态，故意保留"
        $exeL  = Get-LabelFacts $ExePath    $false
        $treeL = Get-LabelFacts $PackageDir $true
        $rootL = Get-LabelFacts $RepoRoot   $false
        $dirty = ($exeL.Low -gt 0) -or ($treeL.Low -gt 0) -or ($rootL.Low -gt 0)
        if ($dirty) { Fail "修复后仍有 Low 标签（exe $($exeL.Low) / 树 $($treeL.Low) / 根 $($rootL.Low)）" }
        else { Ok "复核：Low 标签已归零" }
    }
    if ($dirty) {
        Fail "产物带 Low 标签 ⇒ 用户双击后会被降权（记录 72 现场）。先修标签再重打："
        Bad  "     icacls `"$PackageDir`" /setintegritylevel `"(OI)(CI)M`" /T /C /Q"
        Bad  "     icacls `"$RepoRoot`" /setintegritylevel `"(OI)(CI)M`" /T /C /Q"
        Bad  "    （或直接重跑：pwsh -File tools\build_host_onedir.ps1，它在打包前先查令牌）"
    }
}

# ---- ③ 文件数 / 大小 / SHA256 ---------------------------------------------
Step "③ 文件数 / 大小 / SHA256（此步在烟测之前量，数字即出厂状态）"
$files = @(Get-ChildItem -LiteralPath $PackageDir -Recurse -File -Force)
$bytes = 0
foreach ($f in $files) { $bytes += $f.Length }
$hash  = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash
$exeIt = Get-Item -LiteralPath $ExePath
Write-Host "    目录    : $PackageDir"
Write-Host "    文件数  : $($files.Count)  总字节 : $bytes（$([math]::Round($bytes/1MB,1)) MB）"
Write-Host "    主程序  : $($exeIt.Name)  $($exeIt.Length) B  $($exeIt.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "    SHA256  : $hash"
if ($ExpectFiles -gt 0) {
    if ($files.Count -ne $ExpectFiles) { Fail "文件数 $($files.Count) ≠ 期望 $ExpectFiles" } else { Ok "文件数 = $ExpectFiles" }
}
if ($ExpectBytes -gt 0) {
    if ($bytes -ne $ExpectBytes) { Fail "总字节 $bytes ≠ 期望 $ExpectBytes" } else { Ok "总字节 = $ExpectBytes" }
}
# ★ 数字对不上时最常见的原因不是"包坏了"，而是**上一个包/上一次烟测留下的运行时文件**
#   （`ui_prefs.json`、`host_app_run.log`、`_gate_smoke.png`）——直接点名，别让人对着
#   "439 ≠ 441" 猜（实测自己就踩过：跑了一次编码探针留下两个文件，门禁报 FAIL）。
$strays = @(Get-ChildItem -LiteralPath $PackageDir -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('ui_prefs.json', 'host_app_run.log', '_gate_smoke.png', '_gate_smoke.out.txt', '_gate_smoke.err.txt') })
if ($strays.Count) {
    Warn "目录里有运行时残留（数字会偏大）：$(($strays | ForEach-Object { $_.Name }) -join ', ')"
    Warn "    清掉再量：Remove-Item -LiteralPath <上面那些> -Force"
}

# ---- ④ 包内 PYZ 复核 ------------------------------------------------------
if ($SkipPyz) {
    Step "④ 包内 PYZ 复核"
    Warn "跳过（-SkipPyz）"
} else {
    Step "④ 包内 PYZ 复核（模块数 + 正向串 + 逆向退场串）"
    $chk = Join-Path $RepoRoot "tools\check_pyz.py"
    if (-not (Test-Path -LiteralPath $chk)) {
        Fail "找不到 $chk"
    } else {
        & $Python $chk $ExePath
        if ($LASTEXITCODE -ne 0) { Fail "PYZ 复核退出码 $LASTEXITCODE（缺模块或正向串缺失/逆向后门复活）" }
        else { Ok "PYZ 复核 PASS" }
    }
}

# ---- ⑤ 包内烟测（可选）---------------------------------------------------
if ($SkipSmoke -or -not $Smoke) {
    Step "⑤ 包内烟测"
    if ($SkipSmoke) { Warn "跳过（-SkipSmoke）" } else { Warn "跳过（未给 -Smoke）" }
} else {
    Step "⑤ 包内烟测（起窗口 → 截图 → 退出）"
    $png  = Join-Path $PackageDir "_gate_smoke.png"
    $outF = Join-Path $PackageDir "_gate_smoke.out.txt"
    $errF = Join-Path $PackageDir "_gate_smoke.err.txt"
    foreach ($f in @($png, $outF, $errF)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    # ★ 三个坑（别改回去）：
    #   1. GUI 子系统（Subsystem=2）的 exe 用 `& $Exe` 在 PowerShell 里**立即返回**，
    #      于是"退出码/截图"都在拿空气 ⇒ 必须显式等进程结束。
    #   2. `Start-Process -PassThru` 拿到的进程对象在 Windows PowerShell 5.1 上
    #      `ExitCode` 可能读成**空串**（实测：exit 0 被判成 FAIL"烟测退出码"）⇒
    #      改用 System.Diagnostics.Process，WaitForExit 之后再读 `ExitCode`。
    #   3. 输出只有几行，先等进程结束再读两个流是安全的（不会撑满管道缓冲）。
    #   4. exe 写的是 ANSI 码页（见上面 Convert-RawText）⇒ 按字节读回再解码，
    #      别直接用 StandardOutputEncoding 猜一种编码。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ExePath
    $psi.Arguments              = "--smoke `"$png`" --seconds 3"
    $psi.WorkingDirectory       = $PackageDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($SmokeSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        Fail "烟测 $SmokeSeconds s 内没退出（-SmokeSeconds 加大试试）"
    } else {
        $outBytes = Read-RawStream $proc.StandardOutput.BaseStream
        $errBytes = Read-RawStream $proc.StandardError.BaseStream
        $txt = "$(Convert-RawText $outBytes)$(Convert-RawText $errBytes)"
        foreach ($line in ($txt -split "`r?`n")) { if ("$line".Trim()) { Write-Host "    $line" } }
        if ($proc.ExitCode -ne 0) {
            Fail "烟测退出码 $($proc.ExitCode)"
        } elseif (-not (Test-Path -LiteralPath $png)) {
            Fail "烟测没生成截图"
        } else {
            Ok "烟测 exit 0，截图 $([math]::Round((Get-Item -LiteralPath $png).Length/1KB,1)) kB"
        }
    }
    # 烟测会在包里留下运行时文件，交付前必须清掉（保持出厂目录）
    $residue = @($png, (Join-Path $PackageDir "ui_prefs.json"), (Join-Path $PackageDir "host_app_run.log"))
    foreach ($f in $residue) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $left = @($residue | Where-Object { Test-Path -LiteralPath $_ })
    if ($left.Count) { Warn "有残留删不掉：$($left -join ', ')" } else { Ok "已清掉烟测残留（截图 / ui_prefs.json / host_app_run.log）" }
}

# ---- 结论 -----------------------------------------------------------------
Write-Host ""
if ($script:Fails.Count) {
    Write-Host "结论：FAIL（$($script:Fails.Count) 项）" -ForegroundColor Red
    foreach ($m in $script:Fails) { Write-Host "  - $m" -ForegroundColor Red }
    exit 1
}
Write-Host "结论：PASS" -ForegroundColor Green
exit 0
