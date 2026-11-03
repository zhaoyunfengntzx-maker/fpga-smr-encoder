@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
set "RG_OUT=%CD%\deliverables\video\assets"

set "PY="
if exist "E:\Anaconda\python.exe" set "PY=E:\Anaconda\python.exe"
if not defined PY for %%I in (python.exe) do if exist "%%~$PATH:I" set "PY=%%~$PATH:I"
if not defined PY (
  echo [X] 没找到 python，请先安装 Python 3 并勾选 Add to PATH
  pause & exit /b 1
)

echo 解释器 : %PY%
"%PY%" -c "import PIL, imageio_ffmpeg" 2>nul
if errorlevel 1 (
  echo [X] 缺依赖，请先运行:  "%PY%" -m pip install pillow imageio-ffmpeg
  pause & exit /b 1
)

echo 输出目录: %RG_OUT%
echo.
"%PY%" tools\make_cg_assets.py
echo.
echo 完成。如果上面有 OK 行，mp4 已经在: %RG_OUT%
pause
