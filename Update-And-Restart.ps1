param(
    [switch]$ValidateOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$steamCmd = Join-Path $root 'steamcmd\steamcmd.exe'
$serverPath = Join-Path $root 'server'
$warningScript = Join-Path $root 'WarnPlayers-And-Wait.ps1'
$wasRunning = [bool](Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue)

if ($ValidateOnly) {
    $required = @($steamCmd, $serverPath, $warningScript, (Join-Path $root 'StopServer.ps1'), (Join-Path $root 'StartServer.bat'))
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count) { throw 'Update validation failed. Missing: ' + ($missing -join ', ') }
    Write-Host 'PASS: SteamCMD and safe stop/start helpers are present.' -ForegroundColor Green
    Write-Host 'PASS: Update target is official ASA Dedicated Server App 2430930.' -ForegroundColor Green
    Write-Host "PASS: Validation only; ASA was not stopped and SteamCMD was not run. Running=$wasRunning" -ForegroundColor Green
    exit 0
}

try {
    if ($wasRunning) {
        Write-Host 'Warning connected players before update...' -ForegroundColor Yellow
        $warning = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $warningScript -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($warning.ExitCode -ne 0) { throw 'Player warning failed. Update was cancelled and ASA remains online.' }
        Write-Host 'Safely stopping ASA before update...' -ForegroundColor Yellow
        $stopHelper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'StopServer.ps1') -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($stopHelper.ExitCode -ne 0) { throw 'Safe shutdown failed. Update was not started.' }
    }
    if (-not (Test-Path $steamCmd)) { throw "SteamCMD not found: $steamCmd" }

    Write-Host 'Updating official ARK: Survival Ascended Dedicated Server App 2430930...' -ForegroundColor Cyan
    & $steamCmd +force_install_dir $serverPath +login anonymous +app_info_update 1 +app_update 2430930 validate +quit
    if ($LASTEXITCODE -ne 0) { throw "SteamCMD update failed with exit code $LASTEXITCODE." }
    Write-Host 'ASA update and validation completed successfully.' -ForegroundColor Green
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Press Enter to close' }
    exit 1
}
finally {
    if ($wasRunning -and -not (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f (Join-Path $root 'StartServer.bat')) -WorkingDirectory $root -WindowStyle Hidden
        Write-Host 'Restarting ASA...' -ForegroundColor Yellow
    }
}

if (-not $NoPause) { Read-Host 'Press Enter to close' }
