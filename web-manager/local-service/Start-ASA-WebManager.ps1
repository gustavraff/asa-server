param(
    [switch]$NoBrowser,
    [switch]$Lan
)

$ErrorActionPreference = 'Stop'
$WebRoot = Split-Path -Parent $PSScriptRoot
$RuntimeFolder = Join-Path $WebRoot '.runtime'
$RuntimeFile = Join-Path $RuntimeFolder 'processes.json'
$ServiceScript = Join-Path $PSScriptRoot 'server.mjs'
$AuthConfig = Join-Path $PSScriptRoot '.secrets\auth.json'
$AuthInitializer = Join-Path $PSScriptRoot 'Initialize-ASA-WebManagerAuth.ps1'

function Get-PortOwner([int]$Port) {
    return Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
}

foreach ($port in @(3000, 8415)) {
    if (Get-PortOwner $port) { throw "Port $port is already in use. Stop the existing preview before starting another one." }
}
if (-not (Test-Path -LiteralPath $AuthConfig)) {
    & $AuthInitializer -ConfigPath $AuthConfig
    if (-not (Test-Path -LiteralPath $AuthConfig)) { throw 'Web manager authentication was not configured.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'dist\server\index.js'))) {
    & npm.cmd run build --prefix $WebRoot
    if ($LASTEXITCODE -ne 0) { throw 'The web manager build failed safely.' }
}

[void](New-Item -ItemType Directory -Path $RuntimeFolder -Force)
$listenAddress = if ($Lan) {
    $defaultRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
    $candidate = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction Stop |
        Where-Object { $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' -and $_.AddressState -eq 'Preferred' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $candidate) { throw 'No private LAN IPv4 address was found.' }
    $candidate
} else { '127.0.0.1' }
$ui = Start-Process npm.cmd -ArgumentList @('start','--','--hostname','127.0.0.1','--port','3000') -WorkingDirectory $WebRoot -WindowStyle Hidden -PassThru
$api = Start-Process node.exe -ArgumentList @($ServiceScript,'--host',$listenAddress,'--port','8415','--ui-port','3000') -WorkingDirectory $WebRoot -WindowStyle Hidden -PassThru

try {
    $deadline = (Get-Date).AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 300
        $apiOwner = Get-PortOwner 8415
        $uiOwner = Get-PortOwner 3000
    } until (($apiOwner -and $uiOwner) -or (Get-Date) -gt $deadline)
    if (-not $apiOwner -or -not $uiOwner) { throw 'The web manager did not become ready in time.' }
    [ordered]@{
        Started = (Get-Date).ToString('o')
        ApiWrapperPid = $api.Id
        ServiceListenerPid = $apiOwner.OwningProcess
        UiListenerPid = $uiOwner.OwningProcess
        ListenAddress = $listenAddress
    } | ConvertTo-Json | Set-Content -LiteralPath $RuntimeFile -Encoding utf8
    $url = "http://${listenAddress}:8415/"
    if (-not $NoBrowser) { Start-Process $url }
    Write-Output "ASA Control Deck is running at $url"
    if ($Lan) { Write-Output 'No Windows Firewall rule was created. LAN devices may remain blocked until Gustav approves one.' }
}
catch {
    foreach ($process in @($api, $ui)) { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
    throw
}
