$ErrorActionPreference = 'Stop'

$ruleName = 'ARK Survival Ascended Server UDP 7778'
$serverExe = 'C:\Users\Gustav\Documents\Codex\ASA_Server\server\ShooterGame\Binaries\Win64\ArkAscendedServer.exe'
$resultFile = 'C:\Users\Gustav\Documents\Codex\ASA_Server\firewall-7778-result.txt'

try {
    if (-not (Test-Path -LiteralPath $serverExe)) {
        throw "ASA server executable was not found at $serverExe"
    }

    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction Stop

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description 'Allows the documented ASA peer/advertising port for this server executable.' `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private,Public `
        -Program $serverExe `
        -Protocol UDP `
        -LocalPort 7778 | Out-Null

    "SUCCESS $(Get-Date -Format o)" | Set-Content -LiteralPath $resultFile
}
catch {
    "FAILED $(Get-Date -Format o): $($_.Exception.Message)" | Set-Content -LiteralPath $resultFile
    exit 1
}
