@echo off
rem Build the onedir bundle with the OpenBLAS build environment (179 MB instead of 375 MB).
rem Requires .venv-blas created as described in host\requirements-build.txt.
setlocal
set HERE=%~dp0
set PY=%HERE%..\.venv-blas\Scripts\python.exe
if not exist "%PY%" (
  echo [!] .venv-blas not found. Create it first:
  echo     python -m venv .venv-blas
  echo     .venv-blas\Scripts\python.exe -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple numpy==2.3.5 matplotlib==3.10.6 PySide6==6.9.2 pyserial==3.5 pyinstaller==6.22.3
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%build_host_onedir.ps1" -Python "%PY%" %*
