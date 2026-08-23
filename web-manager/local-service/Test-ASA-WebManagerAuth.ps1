$ErrorActionPreference = 'Stop'
$WebRoot = Split-Path -Parent $PSScriptRoot
$RuntimeRoot = [IO.Path]::GetFullPath((Join-Path $WebRoot '.runtime'))
$TestRoot = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'auth-test'))
if (-not $TestRoot.StartsWith($RuntimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }

$password = 'T-' + [Guid]::NewGuid().ToString('N') + '!9a'
$config = Join-Path $TestRoot 'auth.json'
$stdout = Join-Path $TestRoot 'service.out'
$stderr = Join-Path $TestRoot 'service.err'
$port = 18415
$service = $null
$ui = $null
$uiListenerPid = $null

try {
    [void](New-Item -ItemType Directory -Path $TestRoot -Force)
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    & (Join-Path $PSScriptRoot 'Initialize-ASA-WebManagerAuth.ps1') -Password $secure -ConfigPath $config
    $authFolder = Join-Path $PSScriptRoot '.secrets'
    $liveConfig = Join-Path $authFolder 'auth.json'
    [void](New-Item -ItemType Directory -Path $authFolder -Force)
    if (Test-Path -LiteralPath $liveConfig) { throw 'Targeted test refuses to replace the live web manager authentication file.' }
    Copy-Item -LiteralPath $config -Destination $liveConfig
    $ui = Start-Process npm.cmd -ArgumentList @('start','--','--host','127.0.0.1','--port','13000') -WorkingDirectory $WebRoot -WindowStyle Hidden -PassThru
    $service = Start-Process node.exe -ArgumentList @(
        (Join-Path $PSScriptRoot 'server.mjs'), '--host', '127.0.0.1', '--port', $port, '--ui-port', '13000'
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $owner = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
        $uiOwner = Get-NetTCPConnection -State Listen -LocalPort 13000 -ErrorAction SilentlyContinue
    } until (($owner -and $uiOwner) -or (Get-Date) -gt $deadline)
    if (-not $owner -or -not $uiOwner) { throw "Service failed to start: $(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)" }
    $uiListenerPid = $uiOwner.OwningProcess

    $baseUrl = "http://127.0.0.1:$port"
    $anonymous = & curl.exe -s -o NUL -w '%{http_code}' "$baseUrl/api/status"
    $valid = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' "$baseUrl/api/status"
    $invalid = & curl.exe -u 'gustav:DefinitelyWrongPassword!' -s -o NUL -w '%{http_code}' "$baseUrl/api/status"
    $page = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' "$baseUrl/"
    Write-Output "anonymous=$anonymous valid=$valid invalid=$invalid page=$page"
    if ($anonymous -ne '401' -or $valid -ne '200' -or $invalid -ne '401' -or $page -ne '200') {
        Write-Output "service stdout: $(Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)"
        Write-Output "service stderr: $(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)"
        throw 'Targeted authentication test failed.'
    }
    Write-Output 'PASS: authenticated read-only service rejected anonymous/wrong credentials and accepted correct credentials.'
}
finally {
    if ($service -and -not $service.HasExited) { Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue }
    if ($ui -and -not $ui.HasExited) { Stop-Process -Id $ui.Id -Force -ErrorAction SilentlyContinue }
    if ($uiListenerPid) { Stop-Process -Id $uiListenerPid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
    $liveConfig = Join-Path $PSScriptRoot '.secrets\auth.json'
    if (Test-Path -LiteralPath $liveConfig) { Remove-Item -LiteralPath $liveConfig -Force }
    $password = $null
}
