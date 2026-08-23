param([switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$WebRoot = Split-Path -Parent $PSScriptRoot
$RuntimeFolder = Join-Path $WebRoot '.runtime'
$RuntimeFile = Join-Path $RuntimeFolder 'processes.json'
$ServiceScript = Join-Path $PSScriptRoot 'ASA-WebStatusService.ps1'

function Get-PortOwner([int]$Port) {
    return Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
}

foreach ($port in @(3000, 8415)) {
    if (Get-PortOwner $port) { throw "Port $port is already in use. Stop the existing preview before starting another one." }
}
if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'dist\server\index.js'))) {
    & npm.cmd run build --prefix $WebRoot
    if ($LASTEXITCODE -ne 0) { throw 'The web manager build failed safely.' }
}

[void](New-Item -ItemType Directory -Path $RuntimeFolder -Force)
$api = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ServiceScript) -WindowStyle Hidden -PassThru
$ui = Start-Process npm.cmd -ArgumentList @('start','--','--host','127.0.0.1') -WorkingDirectory $WebRoot -WindowStyle Hidden -PassThru

try {
    $deadline = (Get-Date).AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 300
        $apiOwner = Get-PortOwner 8415
        $uiOwner = Get-PortOwner 3000
    } until (($apiOwner -and $uiOwner) -or (Get-Date) -gt $deadline)
    if (-not $apiOwner -or -not $uiOwner) { throw 'The local preview did not become ready in time.' }
    [ordered]@{
        Started = (Get-Date).ToString('o')
        ApiWrapperPid = $api.Id
        UiWrapperPid = $ui.Id
        UiListenerPid = $uiOwner.OwningProcess
    } | ConvertTo-Json | Set-Content -LiteralPath $RuntimeFile -Encoding utf8
    if (-not $NoBrowser) { Start-Process 'http://localhost:3000/' }
    Write-Output 'ASA Control Deck is running locally at http://localhost:3000/'
}
catch {
    foreach ($process in @($api, $ui)) { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
    throw
}
