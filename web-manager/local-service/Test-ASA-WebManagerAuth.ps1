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
    $ui = Start-Process npm.cmd -ArgumentList @('start','--','--hostname','127.0.0.1','--port','13000') -WorkingDirectory $WebRoot -WindowStyle Hidden -PassThru
    $previousTestMode = $env:ASA_WEB_ACTION_TEST_MODE
    $env:ASA_WEB_ACTION_TEST_MODE = '1'
    try {
        $service = Start-Process node.exe -ArgumentList @(
            (Join-Path $PSScriptRoot 'server.mjs'), '--host', '127.0.0.1', '--port', $port, '--ui-port', '13000', '--auth-path', $config
        ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    }
    finally { $env:ASA_WEB_ACTION_TEST_MODE = $previousTestMode }
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $owner = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
        $uiOwner = Get-NetTCPConnection -State Listen -LocalPort 13000 -ErrorAction SilentlyContinue
    } until (($owner -and $uiOwner) -or (Get-Date) -gt $deadline)
    if (-not $owner -or -not $uiOwner) { throw "Service failed to start: $(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)" }
    $uiListenerPid = $uiOwner.OwningProcess

    $baseUrl = "http://127.0.0.1:$port"
    $anonymous = & curl.exe -s -o NUL -w '%{http_code}' "$baseUrl/"
    $valid = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' "$baseUrl/api/status"
    $invalid = & curl.exe -u 'gustav:DefinitelyWrongPassword!' -s -o NUL -w '%{http_code}' "$baseUrl/api/status"
    $page = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' "$baseUrl/"
    $anonymousAction = & curl.exe -s -o NUL -w '%{http_code}' -X POST "$baseUrl/api/actions/save"
    $unknownAction = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' -X POST "$baseUrl/api/actions/not-real"
    $acceptedAction = & curl.exe -u "gustav:$password" -s -o NUL -w '%{http_code}' -X POST "$baseUrl/api/actions/save"
    Start-Sleep -Milliseconds 600
    $jobJson = & curl.exe -u "gustav:$password" -s "$baseUrl/api/actions"
    $job = $jobJson | ConvertFrom-Json
    Write-Output "anonymous=$anonymous status=$valid invalidStatus=$invalid page=$page anonymousAction=$anonymousAction unknownAction=$unknownAction acceptedAction=$acceptedAction job=$($job.state)"
    if ($anonymous -ne '401' -or $valid -ne '200' -or $invalid -ne '200' -or $page -ne '200' -or $anonymousAction -ne '401' -or $unknownAction -ne '404' -or $acceptedAction -ne '202' -or $job.state -ne 'success') {
        Write-Output "service stdout: $(Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)"
        Write-Output "service stderr: $(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)"
        throw 'Targeted authentication test failed.'
    }
    Write-Output 'PASS: authenticated control service protected the dashboard/actions and completed a simulated allowlisted action without touching ASA.'
}
finally {
    if ($service -and -not $service.HasExited) { Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue }
    if ($ui -and -not $ui.HasExited) { Stop-Process -Id $ui.Id -Force -ErrorAction SilentlyContinue }
    if ($uiListenerPid) { Stop-Process -Id $uiListenerPid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
    $password = $null
}
