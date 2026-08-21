param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$saved = Join-Path $root 'server\ShooterGame\Saved'
$dailyRoot = Join-Path $root 'backups\Daily'
$stopScript = Join-Path $root 'StopServer.ps1'
$warningScript = Join-Path $root 'WarnPlayers-And-Wait.ps1'
$startBat = Join-Path $root 'StartServer.bat'
$steamCmd = Join-Path $root 'steamcmd\steamcmd.exe'
$serverPath = Join-Path $root 'server'
$resultFile = Join-Path $root 'DailyMaintenance-last-result.txt'
$maintenanceLog = Join-Path $root 'DailyMaintenance.log'
$steamOutputLog = Join-Path $root 'DailyMaintenance-SteamCMD.log'
$steamErrorLog = Join-Path $root 'DailyMaintenance-SteamCMD-error.log'
$serverLog = Join-Path $saved 'Logs\ShooterGame.log'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$mutex = $null
$wasRunning = $false

function Write-MaintenanceLog([string]$Message) {
    $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    [IO.File]::AppendAllText($maintenanceLog, $line + [Environment]::NewLine, $utf8NoBom)
}

function Set-Result([string]$Message) {
    [IO.File]::WriteAllText($resultFile, $Message, $utf8NoBom)
    Write-MaintenanceLog $Message
}

function Assert-SafeChildPath([string]$Parent, [string]$Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside daily backup folder: $childFull"
    }
}

try {
    $mutex = [Threading.Mutex]::new($false, 'Local\GustavASADailyMaintenance')
    if (-not $mutex.WaitOne(0)) { throw 'Daily maintenance is already running.' }

    foreach ($required in @($saved, $warningScript, $stopScript, $startBat, $steamCmd, $serverPath)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Required path is missing: $required" }
    }
    if (-not (Select-String -LiteralPath $startBat -SimpleMatch '%*' -Quiet)) {
        throw 'StartServer.bat cannot accept the one-time -ForceRespawnDinos flag.'
    }

    if ($ValidateOnly) {
        Set-Result 'VALIDATION_OK: Backup, SteamCMD ASA App 2430930 update, safe-stop, restart, mod validation, retention, and one-time wild-dino wipe prerequisites passed. No server action was taken.'
        exit 0
    }

    $wasRunning = [bool](Get-Process -Name ArkAscendedServer -ErrorAction SilentlyContinue)
    Write-MaintenanceLog "START: Daily maintenance. ServerRunning=$wasRunning"

    if ($wasRunning) {
        $warning = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $warningScript -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($warning.ExitCode -ne 0) {
            $warningDetail = if (Test-Path -LiteralPath (Join-Path $root 'WarnPlayers-last-result.txt')) { [IO.File]::ReadAllText((Join-Path $root 'WarnPlayers-last-result.txt')).Trim() } else { 'No warning detail was written.' }
            throw "Player restart warning failed; daily maintenance was cancelled and ASA remains online. $warningDetail"
        }
        Write-MaintenanceLog 'PLAYER_WARNING_OK: Connected players received the restart countdown, or no players were online.'
        $stopHelper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stopScript -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
        if ($stopHelper.ExitCode -ne 0 -or (Get-Process -Name ArkAscendedServer -ErrorAction SilentlyContinue)) {
            throw 'Safe server shutdown failed; backup and wipe were cancelled.'
        }
    }

    [void](New-Item -ItemType Directory -Path $dailyRoot -Force)
    $destination = Join-Path $dailyRoot ('ASA_Daily_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    Assert-SafeChildPath $dailyRoot $destination
    [void](New-Item -ItemType Directory -Path $destination)
    Copy-Item -LiteralPath $saved -Destination $destination -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'server-config.cmd') -Destination $destination -Force

    $world = Join-Path $destination 'Saved\SavedArks\Aberration_WP\Aberration_WP.ark'
    if (-not (Test-Path -LiteralPath $world)) { throw 'Backup verification failed: Aberration world file is missing.' }
    if ((Get-Item -LiteralPath $world).Length -lt 1MB) { throw 'Backup verification failed: Aberration world file is unexpectedly small.' }

    $backupFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
    $backupBytes = ($backupFiles | Measure-Object Length -Sum).Sum
    $manifest = @(
        'ASA daily maintenance backup'
        'Created=' + (Get-Date -Format 'o')
        'FileCount=' + $backupFiles.Count
        'TotalBytes=' + $backupBytes
        'WorldFile=' + $world
        'WorldBytes=' + (Get-Item -LiteralPath $world).Length
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $destination 'backup-manifest.txt'), $manifest, $utf8NoBom)
    Write-MaintenanceLog "BACKUP_OK: $destination Files=$($backupFiles.Count) Bytes=$backupBytes"

    $expired = @(Get-ChildItem -LiteralPath $dailyRoot -Directory -Filter 'ASA_Daily_*' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 14)
    foreach ($folder in $expired) {
        Assert-SafeChildPath $dailyRoot $folder.FullName
        Remove-Item -LiteralPath $folder.FullName -Recurse -Force
        Write-MaintenanceLog "RETENTION_REMOVED: $($folder.FullName)"
    }

    Remove-Item -LiteralPath $steamOutputLog, $steamErrorLog -Force -ErrorAction SilentlyContinue
    $steamArguments = '+force_install_dir "' + $serverPath + '" +login anonymous +app_info_update 1 +app_update 2430930 validate +quit'
    Write-MaintenanceLog 'UPDATE_START: SteamCMD validating official ASA Dedicated Server App 2430930.'
    $updateProcess = Start-Process -FilePath $steamCmd -ArgumentList $steamArguments -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $steamOutputLog -RedirectStandardError $steamErrorLog -PassThru
    if (-not $updateProcess.WaitForExit(900000)) {
        $updateProcess.Kill()
        throw 'SteamCMD exceeded the 15-minute update limit and was stopped.'
    }
    # PowerShell 5 can leave ExitCode unset after a timed WaitForExit when
    # stdout/stderr are redirected. A second wait flushes async readers and
    # Refresh makes the final native-process exit code available reliably.
    $updateProcess.WaitForExit()
    $updateProcess.Refresh()
    if ($updateProcess.ExitCode -ne 0) {
        throw "SteamCMD ASA update failed with exit code $($updateProcess.ExitCode)."
    }
    $steamText = if (Test-Path -LiteralPath $steamOutputLog) { [IO.File]::ReadAllText($steamOutputLog) } else { '' }
    if ($steamText -notmatch '(?i)(Success! App .2430930. fully installed|already up to date)') {
        throw 'SteamCMD exited without confirming that ASA App 2430930 is installed or current.'
    }
    Write-MaintenanceLog 'UPDATE_OK: ASA Dedicated Server App 2430930 is installed and validated.'

    if ($wasRunning) {
        $maintenanceStarted = Get-Date
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'StartServer.bat -ForceRespawnDinos' -WorkingDirectory $root -WindowStyle Hidden

        $expectedModCount = ((Select-String -LiteralPath (Join-Path $root 'server-config.cmd') -Pattern '^set "MODS=([^"\r\n]*)"$').Matches.Groups[1].Value -split ',' | Where-Object { $_ }).Count
        $deadline = (Get-Date).AddMinutes(10)
        $ready = $false
        do {
            Start-Sleep -Seconds 5
            $server = Get-CimInstance Win32_Process -Filter "Name='ArkAscendedServer.exe'" -ErrorAction SilentlyContinue
            $hasWipeFlag = $server -and $server.CommandLine -match '(?i)-ForceRespawnDinos(?:\s|$)'
            $freshLog = (Test-Path -LiteralPath $serverLog) -and ((Get-Item -LiteralPath $serverLog).LastWriteTime -ge $maintenanceStarted)
            $advertising = $freshLog -and (Select-String -LiteralPath $serverLog -Pattern 'advertising for join' -Quiet)
            $validModCount = if ($freshLog) { @(Select-String -LiteralPath $serverLog -Pattern 'LogCFCore: Mod valid:').Count } else { 0 }
            $loadedModCount = if ($freshLog) { @(Select-String -LiteralPath $serverLog -Pattern 'UShooterEngine::LoadGameMods Loading Mod').Count } else { 0 }
            $critical = $freshLog -and (Select-String -LiteralPath $serverLog -Pattern 'LowLevelFatal|Fatal error|Unhandled Exception|mod invalid|Failed to install mod' -CaseSensitive:$false -Quiet)
            if ($critical) { throw 'ASA reported a critical startup error after daily maintenance.' }
            $ready = $hasWipeFlag -and $advertising -and ($validModCount -eq $expectedModCount) -and ($loadedModCount -eq $expectedModCount)
        } while (-not $ready -and (Get-Date) -lt $deadline)

        if (-not $ready) { throw 'ASA did not confirm the updated mod set, wild-dino restart, and public advertising within ten minutes.' }
        Set-Result "SUCCESS: Daily backup verified, ASA App 2430930 updated, all $expectedModCount mods validated, wild dinos respawned, and ASA is advertising. Backup=$destination"
    }
    else {
        Set-Result "SUCCESS_BACKUP_UPDATE_ONLY: Server was already stopped; backup and ASA App 2430930 update were verified, but no restart/wipe was forced. Backup=$destination"
    }
}
catch {
    Set-Result ('ERROR: ' + $_.Exception.Message)
    if ($wasRunning -and -not (Get-Process -Name ArkAscendedServer -ErrorAction SilentlyContinue)) {
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'StartServer.bat' -WorkingDirectory $root -WindowStyle Hidden
            Write-MaintenanceLog 'FAILSAFE_RESTART: A normal no-wipe restart was requested after maintenance failed.'
        }
        catch {
            Write-MaintenanceLog ('FAILSAFE_RESTART_ERROR: ' + $_.Exception.Message)
        }
    }
    exit 1
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
