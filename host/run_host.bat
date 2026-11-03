@echo off
chcp 65001 >nul
rem ===================================================================
rem  host_app 启动脚本（双击即可运行）
rem  作用：切到仓库根目录、把控制台设成 UTF-8、启动图形界面。
rem  注意：本文件必须保持 CRLF 换行，且第一行就切 UTF-8，
rem        否则 cmd 按 GBK 解释中文注释/提示会乱码。
rem ===================================================================

cd /d "%~dp0.."

where python >nul 2>nul
if errorlevel 1 (
    echo [错误] 找不到 python，请先安装 Python 3.13 并勾选 "Add to PATH"。
    pause
    exit /b 1
)

python host\app.py %*
if errorlevel 1 (
    echo.
    echo [提示] 启动失败。若提示缺少 pyserial 或 PySide6，请执行：
    echo        pip install pyserial PySide6
    pause
)
