param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [string]$HostName = '127.0.0.1',
    [int]$Port = 27020,
    [int]$TimeoutMilliseconds = 10000
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $root 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'
$passwordLine = Get-Content -LiteralPath $settingsPath | Where-Object { $_ -match '^ServerAdminPassword=' } | Select-Object -First 1
if (-not $passwordLine) {
    throw 'ServerAdminPassword is not configured.'
}
$password = $passwordLine.Substring($passwordLine.IndexOf('=') + 1)

function Read-Exact {
    param([IO.Stream]$Stream, [int]$Count)
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'RCON connection closed unexpectedly.' }
        $offset += $read
    }
    return $buffer
}

function Send-RconPacket {
    param([IO.Stream]$Stream, [int]$RequestId, [int]$Type, [string]$Body)
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $payloadLength = 4 + 4 + $bodyBytes.Length + 2
    $packet = New-Object byte[] (4 + $payloadLength)
    [BitConverter]::GetBytes($payloadLength).CopyTo($packet, 0)
    [BitConverter]::GetBytes($RequestId).CopyTo($packet, 4)
    [BitConverter]::GetBytes($Type).CopyTo($packet, 8)
    $bodyBytes.CopyTo($packet, 12)
    $Stream.Write($packet, 0, $packet.Length)
    $Stream.Flush()
}

function Receive-RconPacket {
    param([IO.Stream]$Stream)
    $length = [BitConverter]::ToInt32((Read-Exact $Stream 4), 0)
    if ($length -lt 10 -or $length -gt 1048576) { throw "Invalid RCON packet length: $length" }
    $payload = Read-Exact $Stream $length
    [pscustomobject]@{
        RequestId = [BitConverter]::ToInt32($payload, 0)
        Type = [BitConverter]::ToInt32($payload, 4)
        Body = [Text.Encoding]::UTF8.GetString($payload, 8, $length - 10)
    }
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $connect = $client.ConnectAsync($HostName, $Port)
    if (-not $connect.Wait($TimeoutMilliseconds)) { throw 'Timed out connecting to local ASA RCON.' }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMilliseconds
    $stream.WriteTimeout = $TimeoutMilliseconds

    Send-RconPacket $stream 1001 3 $password
    $auth = Receive-RconPacket $stream
    if ($auth.RequestId -eq -1) { throw 'ASA RCON authentication failed.' }

    Send-RconPacket $stream 1002 2 $Command
    $response = Receive-RconPacket $stream
    if ($response.RequestId -ne 1002) { throw 'ASA returned an unexpected RCON response.' }
    $response.Body
}
finally {
    $password = $null
    if ($client) { $client.Dispose() }
}
