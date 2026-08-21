param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultPath = Join-Path $root 'StopServer-last-result.txt'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

trap {
    try { [IO.File]::WriteAllText($resultPath, ('ERROR: ' + $_.Exception.Message), $utf8NoBom) } catch { }
    exit 1
}

$server = Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue
if (-not $server -and -not $ValidateOnly) {
    [IO.File]::WriteAllText($resultPath, 'NOT_RUNNING: ASA server was already stopped.', $utf8NoBom)
    exit 0
}

$serverProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" -ErrorAction SilentlyContinue
$serverParent = if ($serverProcessInfo) {
    Get-Process -Id $serverProcessInfo.ParentProcessId -ErrorAction SilentlyContinue
}

$rconHelper = Join-Path $root 'Invoke-Rcon.ps1'
if (-not $ValidateOnly -and (Test-Path -LiteralPath $rconHelper)) {
    try {
        & $rconHelper -Command 'SaveWorld' | Out-Null
        Start-Sleep -Seconds 3
        & $rconHelper -Command 'DoExit' | Out-Null
        Wait-Process -Id $server.Id -Timeout 120 -ErrorAction Stop
        [IO.File]::WriteAllText($resultPath, "SUCCESS: ASA PID $($server.Id) saved and stopped through local RCON.", $utf8NoBom)
        exit 0
    }
    catch {
        # Older/running instances may not have RCON enabled yet. Continue to
        # the console-signal fallback below without exposing the password.
    }
}
else {
    $null
}

if (-not ('ConsoleSignal.NativeMethods' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace ConsoleSignal {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AttachConsole(uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
    }
}
'@
}

if ($ValidateOnly) {
    Write-Host 'PASS: Safe-shutdown signal helper compiled successfully.' -ForegroundColor Green
    if ($server) { Write-Host "PASS: ASA process detected (PID $($server.Id)). No signal was sent." -ForegroundColor Green }
    else { Write-Host 'INFO: ASA is currently stopped. No signal was sent.' -ForegroundColor Yellow }
    exit 0
}

[IO.File]::WriteAllText($resultPath, "REQUESTED: Safe shutdown for ASA PID $($server.Id).", $utf8NoBom)
[ConsoleSignal.NativeMethods]::FreeConsole() | Out-Null
$attached = [ConsoleSignal.NativeMethods]::AttachConsole([uint32]$server.Id)

# ArkAscendedServer.exe is currently built as a Windows-subsystem process, so
# it may share the launcher's console without owning one itself. In that case,
# attach to the verified cmd.exe parent that launched the server.
if (-not $attached -and $serverParent -and $serverParent.ProcessName -eq 'cmd') {
    $attached = [ConsoleSignal.NativeMethods]::AttachConsole([uint32]$serverParent.Id)
}

if (-not $attached) {
    # Recent ASA builds expose their own Server Console window but do not allow
    # another process to attach to it. Closing that window is Windows' normal
    # console-close signal and gives ASA time to run its shutdown/save handler.
    if (-not $server.CloseMainWindow()) {
        throw "Could not signal the ASA Server Console to close. Windows error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}
else {
    # Ignore the signal in this helper, then send the equivalent of Ctrl+C to
    # the server console. ASA handles Ctrl+C as its normal shutdown path.
    [ConsoleSignal.NativeMethods]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
    if (-not [ConsoleSignal.NativeMethods]::GenerateConsoleCtrlEvent(0, 0)) {
        throw "Could not send Ctrl+C to ASA. Windows error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    Start-Sleep -Milliseconds 500
    [ConsoleSignal.NativeMethods]::FreeConsole() | Out-Null
}

try {
    Wait-Process -Id $server.Id -Timeout 90 -ErrorAction Stop
    [IO.File]::WriteAllText($resultPath, "SUCCESS: ASA PID $($server.Id) stopped safely.", $utf8NoBom)
    exit 0
}
catch {
    throw 'ASA did not stop within 90 seconds. It was not force-killed.'
}
