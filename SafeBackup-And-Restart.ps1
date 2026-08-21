param(
    [switch]$ValidateOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$saved = Join-Path $root 'server\ShooterGame\Saved'
$backupRoot = Join-Path $root 'backups'
$warningScript = Join-Path $root 'WarnPlayers-And-Wait.ps1'
$wasRunning = [bool](Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue)

if ($ValidateOnly) {
    $required = @($saved, $warningScript, (Join-Path $root 'StopServer.ps1'), (Join-Path $root 'StartServer.bat'))
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count) { throw 'Backup validation failed. Missing: ' + ($missing -join ', ') }
    Write-Host 'PASS: Backup source and safe stop/start helpers are present.' -ForegroundColor Green
    Write-Host "PASS: Validation only; ASA was not stopped and no backup was created. Running=$wasRunning" -ForegroundColor Green
    exit 0
}

try {
    if ($wasRunning) {
        Write-Host 'Warning connected players before backup restart...' -ForegroundColor Yellow
        $warning = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $warningScript -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($warning.ExitCode -ne 0) { throw 'Player warning failed. Backup restart was cancelled and ASA remains online.' }
        Write-Host 'Safely stopping ASA before backup...' -ForegroundColor Yellow
        $stopHelper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'StopServer.ps1') -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($stopHelper.ExitCode -ne 0) { throw 'Safe shutdown failed. Backup was not started.' }
    }

    if (-not (Test-Path $saved)) { throw "Save folder not found: $saved" }
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    $destination = Join-Path $backupRoot ('ASA_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    Write-Host "Creating backup: $destination" -ForegroundColor Cyan
    [void](New-Item -ItemType Directory -Path $destination)
    Copy-Item -LiteralPath $saved -Destination $destination -Recurse -Force
    Write-Host 'Backup completed successfully.' -ForegroundColor Green
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
