$ErrorActionPreference = 'Stop'

$root = 'C:\Users\Gustav\Documents\Codex\ASA_Server'
$stateFile = Join-Path $root 'nordvpn-filter-test-state.json'
$resultFile = Join-Path $root 'nordvpn-filter-test-result.txt'
$adapterName = 'Wi-Fi'
$componentId = 'NordLwf'

try {
    $binding = Get-NetAdapterBinding -Name $adapterName -ComponentID $componentId -ErrorAction Stop
    $service = Get-Service -Name 'nordvpn-service' -ErrorAction SilentlyContinue

    [pscustomobject]@{
        AdapterName = $adapterName
        ComponentId = $componentId
        BindingWasEnabled = [bool]$binding.Enabled
        ServiceExisted = [bool]$service
        ServiceWasRunning = [bool]($service -and $service.Status -eq 'Running')
        CapturedAt = (Get-Date -Format o)
    } | ConvertTo-Json | Set-Content -LiteralPath $stateFile

    if ($service -and $service.Status -eq 'Running') {
        Stop-Service -Name 'nordvpn-service' -Force -ErrorAction Stop
    }

    if ($binding.Enabled) {
        Disable-NetAdapterBinding -Name $adapterName -ComponentID $componentId -Confirm:$false -ErrorAction Stop | Out-Null
    }

    "SUCCESS $(Get-Date -Format o)" | Set-Content -LiteralPath $resultFile
}
catch {
    "FAILED $(Get-Date -Format o): $($_.Exception.Message)" | Set-Content -LiteralPath $resultFile
    exit 1
}
