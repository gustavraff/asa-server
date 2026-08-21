$ErrorActionPreference = 'Stop'
$name = 'ARK Survival Ascended Server UDP 27015'
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
    -LocalPort 27015 `
    -Program $exe `
    -Profile Private,Public `
    -Description 'Allows the ASA server query/browser service on UDP 27015 only.' | Out-Null

Get-NetFirewallRule -DisplayName $name | Format-List DisplayName,Enabled,Direction,Action,Profile
Get-NetFirewallRule -DisplayName $name | Get-NetFirewallPortFilter | Format-List Protocol,LocalPort,RemotePort
Write-Host 'ASA UDP 27015 firewall rule added successfully.' -ForegroundColor Green
Read-Host 'Press Enter to close'
