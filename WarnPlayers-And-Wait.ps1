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

    function Send-PlayerWarning([string]$Message) {
        # Sent on two separate channels (center-screen overlay and chat) because
        # a UI-replacement mod (for example a pause-menu mod) can suppress one
        # rendering path without affecting the other. RCON always acknowledges
        # with a generic "Server received, But no response!!" either way, so
        # this is belt-and-suspenders rather than something we can verify here.
        Invoke-RconWithRetry "Broadcast $Message" | Out-Null
        Invoke-RconWithRetry "ServerChat $Message" | Out-Null
    }

    Send-PlayerWarning 'SERVER RESTART IN 60 SECONDS - Please leave safely now.'
    Start-Sleep -Seconds 30
    Send-PlayerWarning 'SERVER RESTART IN 30 SECONDS - Please leave now.'
    Start-Sleep -Seconds 20
    Send-PlayerWarning 'SERVER RESTART IN 10 SECONDS - Disconnect now.'
    Start-Sleep -Seconds 10
    Send-PlayerWarning 'SERVER RESTARTING NOW'
    Start-Sleep -Seconds 2

    [IO.File]::WriteAllText($resultPath, 'SUCCESS: 60/30/10/0 second restart warnings were sent to the server via both Broadcast and ServerChat. RCON does not confirm on-screen delivery, so this does not guarantee players actually saw them.', $utf8NoBom)
}
catch {
    [IO.File]::WriteAllText($resultPath, ('ERROR: ' + $_.Exception.Message), $utf8NoBom)
    exit 1
}
