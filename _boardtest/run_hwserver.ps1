$ErrorActionPreference = 'Continue'
$root = 'C:\Users\zhaoy\Desktop\FPGA'
$work = Join-Path $root '_flash2_work'
$bin  = 'D:\Vivado\2026.1\Vivado\bin'

$env:Path = "$bin;" + $env:Path
$env:HOME         = Join-Path $work 'home'
$env:USERPROFILE  = Join-Path $work 'home'
$env:APPDATA      = Join-Path $work 'appdata'
$env:LOCALAPPDATA = Join-Path $work 'appdata'
$env:TEMP         = Join-Path $work 'tmp'
$env:TMP          = $env:TEMP
foreach ($d in @($env:HOME, $env:APPDATA, $env:TEMP)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$env:XILINXD_LICENSE_FILE = 'D:\Vivado\Xlnx_2026_1.lic'
Set-Location $work

& hw_server -L- -l discovery -s TCP::3121 *> (Join-Path $work 'hw_server_now.err')
