$ErrorActionPreference = 'Stop'
$ruleName = 'ASA Web Manager LAN (TCP 8415)'
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description 'Allows ASA Control Deck from the local home network.' `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -LocalAddress '192.168.1.179' `
        -LocalPort 8415 `
        -RemoteAddress LocalSubnet `
        -Program 'C:\Program Files\nodejs\node.exe' | Out-Null
}
Get-NetFirewallRule -DisplayName $ruleName | Enable-NetFirewallRule
