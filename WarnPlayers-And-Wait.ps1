param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rcon = Join-Path $root 'Invoke-Rcon.ps1'
$resultPath = Join-Path $root 'WarnPlayers-last-result.txt'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Invoke-RconWithRetry([string]$Command) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return [string](& $rcon -Command $Command -TimeoutMilliseconds 15000)
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    throw "RCON command failed after 3 attempts: $lastError"
}

try {
    if (-not (Test-Path -LiteralPath $rcon)) { throw 'Local RCON helper is missing.' }
    if (-not (Get-Process -Name ArkAscendedServer -ErrorAction SilentlyContinue)) {
        [IO.File]::WriteAllText($resultPath, 'SKIPPED_OFFLINE: ASA is not running.', $utf8NoBom)
        exit 0
    }

    $players = Invoke-RconWithRetry 'ListPlayers'
    $hasPlayers = $players -and $players -notmatch '(?i)No Players Connected'

    if ($ValidateOnly) {
        [IO.File]::WriteAllText($resultPath, "VALIDATION_OK: RCON authenticated. PlayersConnected=$hasPlayers. No broadcast was sent.", $utf8NoBom)
        exit 0
    }

    if (-not $hasPlayers) {
        [IO.File]::WriteAllText($resultPath, 'SKIPPED_NO_PLAYERS: ASA is running but nobody is connected.', $utf8NoBom)
        exit 0
    }

    Invoke-RconWithRetry 'Broadcast SERVER RESTART IN 60 SECONDS - Please leave safely now.' | Out-Null
    Start-Sleep -Seconds 30
    Invoke-RconWithRetry 'Broadcast SERVER RESTART IN 30 SECONDS - Please leave now.' | Out-Null
    Start-Sleep -Seconds 20
    Invoke-RconWithRetry 'Broadcast SERVER RESTART IN 10 SECONDS - Disconnect now.' | Out-Null
    Start-Sleep -Seconds 10
    Invoke-RconWithRetry 'Broadcast SERVER RESTARTING NOW' | Out-Null
    Start-Sleep -Seconds 2

    [IO.File]::WriteAllText($resultPath, 'SUCCESS: Connected players received 60, 30, 10, and 0 second restart warnings.', $utf8NoBom)
}
catch {
    [IO.File]::WriteAllText($resultPath, ('ERROR: ' + $_.Exception.Message), $utf8NoBom)
    exit 1
}
