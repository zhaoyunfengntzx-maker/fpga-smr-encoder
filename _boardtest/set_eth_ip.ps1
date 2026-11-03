# set_eth_ip.ps1 -- needs Administrator (UAC elevation)
# Configure the wired NIC to 192.168.1.100/24 (board is fixed at 192.168.1.10) and add a
# low-metric host route so the same-subnet WLAN (192.168.1.104/24) does not steal traffic.
# Log: _boardtest\eth_setup.log
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'eth_setup.log'
function Log($m) { $m | Tee-Object -FilePath $log -Append }

Log "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log ("admin=" + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

$nic = Get-NetAdapter | Where-Object { $_.ifIndex -eq 12 } | Select-Object -First 1
if (-not $nic) { $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.LinkSpeed -eq '1 Gbps' } | Select-Object -First 1 }
if (-not $nic) { $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wireless|Wi-Fi|WLAN' } | Select-Object -First 1 }
if (-not $nic) { Log 'NO_NIC'; exit 1 }
$idx = $nic.ifIndex
Log ("NIC=" + $nic.Name + " idx=" + $idx + " desc=" + $nic.InterfaceDescription + " speed=" + $nic.LinkSpeed + " status=" + $nic.Status)

Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-NetIPAddress -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
try {
    New-NetIPAddress -InterfaceIndex $idx -IPAddress '192.168.1.100' -PrefixLength 24 -ErrorAction Stop | Out-Null
    Log 'SET_IP_OK 192.168.1.100/24'
} catch {
    Log ("SET_IP_FAIL " + $_.Exception.Message)
}

route delete 192.168.1.10 2>$null | Out-Null
$r = route add 192.168.1.10 mask 255.255.255.255 0.0.0.0 if $idx metric 1 2>&1
Log ("ROUTE: " + ($r -join ' '))

Start-Sleep -Seconds 1
Log '--- ipconfig ---'
Log ((ipconfig | Out-String -Width 120))
Log '--- ping 192.168.1.10 ---'
Log ((ping -n 4 -w 1000 192.168.1.10 2>&1 | Out-String -Width 120))
Log '=== done ==='
