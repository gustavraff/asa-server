$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultPath = Join-Path $root 'Set-ServerStaticIP-last-result.txt'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$rollbackScript = Join-Path $root 'NetworkRollback-To-DHCP.ps1'
$rollback = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', $rollbackScript,
    '-DelaySeconds', '120'
) -WindowStyle Hidden -PassThru

try {
    netsh.exe interface ipv4 set address name="Ethernet" static 192.168.1.179 255.255.255.0 192.168.1.1 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Static address command failed with exit $LASTEXITCODE." }

    netsh.exe interface ipv4 set dnsservers name="Ethernet" static 193.162.153.164 primary validate=no | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Primary DNS command failed with exit $LASTEXITCODE." }

    netsh.exe interface ipv4 add dnsservers name="Ethernet" address=194.239.134.83 index=2 validate=no | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Secondary DNS command failed with exit $LASTEXITCODE." }

    Start-Sleep -Seconds 8
    $ip = Get-NetIPAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object IPAddress -eq '192.168.1.179'
    $gateway = Get-NetRoute -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Where-Object NextHop -eq '192.168.1.1'
    $router = Test-Connection -ComputerName '192.168.1.1' -Count 2 -Quiet
    $public = curl.exe --silent --max-time 15 --interface 192.168.1.179 https://api.ipify.org

    if (-not $ip -or -not $gateway -or -not $router -or $public -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw 'Static network verification failed.'
    }

    Stop-Process -Id $rollback.Id -Force -ErrorAction SilentlyContinue
    $result = "STATIC_IP=PASS IP=$($ip.IPAddress) GATEWAY=$($gateway.NextHop) ROUTER=$router PUBLIC=$public ROLLBACK=CANCELLED"
    [IO.File]::WriteAllText($resultPath, $result, $utf8NoBom)
    Write-Output $result
}
catch {
    netsh.exe interface ipv4 set address name="Ethernet" source=dhcp | Out-Null
    netsh.exe interface ipv4 set dnsservers name="Ethernet" source=dhcp | Out-Null
    Stop-Process -Id $rollback.Id -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($resultPath, ('ERROR: ' + $_.Exception.Message), $utf8NoBom)
    throw
}
