$ErrorActionPreference = 'Stop'
$name = 'ARK Survival Ascended Server UDP 7777'
$exe = Join-Path $PSScriptRoot 'server\ShooterGame\Binaries\Win64\ArkAscendedServer.exe'

if (-not (Test-Path -LiteralPath $exe)) {
    throw "ASA executable not found: $exe"
}

$existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
if ($existing) {
    Remove-NetFirewallRule -DisplayName $name
}

New-NetFirewallRule `
    -DisplayName $name `
    -Direction Inbound `
    -Action Allow `
    -Protocol UDP `
    -LocalPort 7777 `
    -Program $exe `
    -Profile Private,Public `
    -Description 'Allows ASA crossplay clients on UDP 7777 only. RCON is not exposed.' | Out-Null

Get-NetFirewallRule -DisplayName $name | Format-List DisplayName,Enabled,Direction,Action,Profile
Get-NetFirewallRule -DisplayName $name | Get-NetFirewallPortFilter | Format-List Protocol,LocalPort,RemotePort
Write-Host 'Firewall rule added successfully.' -ForegroundColor Green
Read-Host 'Press Enter to close'
