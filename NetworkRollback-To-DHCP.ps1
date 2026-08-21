param([int]$DelaySeconds = 120)

$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Seconds $DelaySeconds
Set-NetIPInterface -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ResetServerAddresses
ipconfig.exe /renew Ethernet | Out-Null
