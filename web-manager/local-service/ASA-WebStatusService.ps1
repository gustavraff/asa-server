param(
    [ValidateRange(1024, 65535)][int]$Port = 8415,
    [ValidateSet('127.0.0.1')][string]$ListenAddress = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CmdConfig = Join-Path $ProjectRoot 'server-config.cmd'
$BackupsFolder = Join-Path $ProjectRoot 'backups'
$WebRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\client'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-SafeCmdConfig {
    $allowed = @('SERVER_NAME', 'MAP', 'MAX_PLAYERS', 'MODS')
    $values = @{}
    if (-not (Test-Path -LiteralPath $CmdConfig)) { return $values }
    $raw = [IO.File]::ReadAllText($CmdConfig)
    foreach ($match in [regex]::Matches($raw, '(?m)^set\s+"(?<key>[A-Z_]+)=(?<value>.*)"\s*$')) {
        $key = $match.Groups['key'].Value
        if ($key -in $allowed) { $values[$key] = $match.Groups['value'].Value }
    }
    return $values
}

function Get-StatusPayload {
    $config = Read-SafeCmdConfig
    $server = Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($ProjectRoot).TrimEnd(':\'))
    $latestBackup = Get-ChildItem -LiteralPath $BackupsFolder -Directory -Filter 'ASA_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $totalMemoryGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeMemoryGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedMemoryPercent = if ($totalMemoryGb -gt 0) { [math]::Round((($totalMemoryGb - $freeMemoryGb) / $totalMemoryGb) * 100, 0) } else { 0 }
    $mods = if ($config.MODS) { @($config.MODS -split ',' | Where-Object { $_ }) } else { @() }
    $mapNames = @{ Aberration_WP = 'Aberration'; TheIsland_WP = 'The Island'; ScorchedEarth_WP = 'Scorched Earth'; TheCenter_WP = 'The Center'; Extinction_WP = 'Extinction'; Ragnarok_WP = 'Ragnarok' }
    $mapKey = [string]$config.MAP

    return [ordered]@{
        timestamp = (Get-Date).ToString('o')
        readOnly = $true
        server = [ordered]@{
            running = [bool]$server
            pid = if ($server) { $server.Id } else { $null }
            privateMemoryGb = if ($server) { [math]::Round($server.PrivateMemorySize64 / 1GB, 1) } else { 0 }
            name = if ($config.SERVER_NAME) { [string]$config.SERVER_NAME } else { 'ASA Server' }
            map = if ($mapNames.ContainsKey($mapKey)) { $mapNames[$mapKey] } elseif ($mapKey) { $mapKey } else { 'Unknown' }
            mapId = $mapKey
            maxPlayers = if ($config.MAX_PLAYERS -match '^\d+$') { [int]$config.MAX_PLAYERS } else { $null }
            modCount = $mods.Count
        }
        host = [ordered]@{
            cpuPercent = [math]::Round([double]$cpu.Average, 0)
            memoryPercent = $usedMemoryPercent
            memoryUsedGb = [math]::Round($totalMemoryGb - $freeMemoryGb, 1)
            memoryTotalGb = $totalMemoryGb
            diskFreeGb = [math]::Round($drive.Free / 1GB, 1)
        }
        backup = if ($latestBackup) { [ordered]@{ found = $true; timestamp = $latestBackup.LastWriteTime.ToString('o'); name = $latestBackup.Name } } else { [ordered]@{ found = $false; timestamp = $null; name = $null } }
    }
}

function Set-SecurityHeaders([Net.HttpListenerResponse]$Response) {
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' http://127.0.0.1:8415; img-src 'self' data:"
}

function Send-Bytes([Net.HttpListenerContext]$Context, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200) {
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    Set-SecurityHeaders $Context.Response
    $origin = $Context.Request.Headers['Origin']
    if ($origin -in @('http://localhost:3000', 'http://127.0.0.1:3000')) {
        $Context.Response.Headers['Access-Control-Allow-Origin'] = $origin
        $Context.Response.Headers['Vary'] = 'Origin'
    }
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

function Send-Json([Net.HttpListenerContext]$Context, $Payload, [int]$StatusCode = 200) {
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    Send-Bytes $Context $Utf8NoBom.GetBytes($json) 'application/json; charset=utf-8' $StatusCode
}

$listener = New-Object Net.HttpListener
$prefix = "http://${ListenAddress}:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "ASA read-only web service listening on $prefix"
Write-Output 'Press Ctrl+C to stop. No write actions are registered.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            if ($context.Request.HttpMethod -notin @('GET', 'HEAD')) {
                Send-Json $context ([ordered]@{ error = 'Method not allowed'; readOnly = $true }) 405
                continue
            }
            $path = $context.Request.Url.AbsolutePath
            if ($path -eq '/api/status') {
                Send-Json $context (Get-StatusPayload)
                continue
            }
            if (-not (Test-Path -LiteralPath $WebRoot)) {
                Send-Json $context ([ordered]@{ error = 'Web build is not installed yet'; readOnly = $true }) 503
                continue
            }
            $relative = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
            $candidate = [IO.Path]::GetFullPath((Join-Path $WebRoot $relative))
            $rootFull = [IO.Path]::GetFullPath($WebRoot) + [IO.Path]::DirectorySeparatorChar
            if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $candidate = Join-Path $WebRoot 'index.html'
            }
            $contentTypes = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8'; '.png'='image/png'; '.ico'='image/x-icon'; '.svg'='image/svg+xml' }
            $extension = [IO.Path]::GetExtension($candidate).ToLowerInvariant()
            $contentType = if ($contentTypes.ContainsKey($extension)) { $contentTypes[$extension] } else { 'application/octet-stream' }
            Send-Bytes $context ([IO.File]::ReadAllBytes($candidate)) $contentType
        }
        catch {
            if ($context.Response.OutputStream.CanWrite) { Send-Json $context ([ordered]@{ error = 'Read-only status service error'; readOnly = $true }) 500 }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
