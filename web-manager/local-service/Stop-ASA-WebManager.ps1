$ErrorActionPreference = 'Stop'
$WebRoot = Split-Path -Parent $PSScriptRoot
$RuntimeFile = Join-Path $WebRoot '.runtime\processes.json'

if (-not (Test-Path -LiteralPath $RuntimeFile)) {
    Write-Output 'No tracked ASA Control Deck preview is running.'
    exit 0
}

$state = Get-Content -LiteralPath $RuntimeFile -Raw | ConvertFrom-Json
$expectedRoot = [IO.Path]::GetFullPath($WebRoot)
$stopped = New-Object Collections.Generic.List[int]
foreach ($id in @($state.UiListenerPid, $state.ApiWrapperPid) | Select-Object -Unique) {
    if (-not $id) { continue }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    $command = [string]$process.CommandLine
    if ($command -notlike "*$expectedRoot*" -and $command -notlike '*ASA-WebStatusService.ps1*') {
        throw "Refusing to stop PID $id because it is not a tracked ASA Control Deck process."
    }
    Stop-Process -Id $id -Force -ErrorAction Stop
    $stopped.Add([int]$id)
}
Remove-Item -LiteralPath $RuntimeFile -Force
Write-Output ('Stopped ASA Control Deck processes: ' + (($stopped | Sort-Object -Unique) -join ', '))
