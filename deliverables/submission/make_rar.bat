@echo off
rem Build the RAR package required by the submission system.
rem Run this file on a machine with WinRAR installed (6.x or 7.x).
setlocal
set SRC=%~dp0..\..\_pkg\FPGA_encoder_source
set OUT=%~dp0source_FPGA_encoder.rar

if not exist "%SRC%\README.md" (
  echo [ERROR] staged sources not found: %SRC%
  echo Run: python tools\make_source_package.py
  pause
  exit /b 1
)

set RAR=
if exist "%ProgramFiles%\WinRAR\Rar.exe" set RAR=%ProgramFiles%\WinRAR\Rar.exe
if exist "%ProgramFiles(x86)%\WinRAR\Rar.exe" set RAR=%ProgramFiles(x86)%\WinRAR\Rar.exe
if "%RAR%"=="" (
  echo [ERROR] WinRAR not found. Install it from https://www.rarlab.com/ and re-run.
  pause
  exit /b 1
)

"%RAR%" a -r -m5 -ep1 "%OUT%" "%SRC%\*"
if errorlevel 1 (
  echo [ERROR] RAR creation failed.
  pause
  exit /b 1
)
echo [OK] created %OUT%
dir "%OUT%"
pause
