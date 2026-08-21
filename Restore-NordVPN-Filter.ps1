$ErrorActionPreference = 'Stop'

$root = 'C:\Users\Gustav\Documents\Codex\ASA_Server'
$stateFile = Join-Path $root 'nordvpn-filter-test-state.json'
$resultFile = Join-Path $root 'nordvpn-filter-restore-result.txt'

try {
    if (-not (Test-Path -LiteralPath $stateFile)) {
        throw 'The saved NordVPN test state was not found.'
    }

    $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
    if ($state.BindingWasEnabled) {
        Enable-NetAdapterBinding -Name $state.AdapterName -ComponentID $state.ComponentId -Confirm:$false -ErrorAction Stop | Out-Null
    }
    if ($state.ServiceExisted -and $state.ServiceWasRunning) {
        Start-Service -Name 'nordvpn-service' -ErrorAction Stop
    }

    "SUCCESS $(Get-Date -Format o)" | Set-Content -LiteralPath $resultFile
}
catch {
    "FAILED $(Get-Date -Format o): $($_.Exception.Message)" | Set-Content -LiteralPath $resultFile
    exit 1
}
