param(
    [switch]$TestMode,
    [switch]$HealthCheckOnly
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Launch PowerShell normally so WinForms can create a visible top-level window,
# then hide only the console host. Starting PowerShell itself as Hidden can also
# suppress the manager form on some Windows builds.
if (-not $TestMode -and -not $HealthCheckOnly) {
    if (-not ('ASAConsole.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace ASAConsole {
    public static class NativeMethods {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
'@
    }
    $consoleHandle = [ASAConsole.NativeMethods]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) { [ASAConsole.NativeMethods]::ShowWindow($consoleHandle, 0) | Out-Null }
}

$script:ManagerMutex = $null
if (-not $TestMode -and -not $HealthCheckOnly) {
    $createdNew = $false
    $script:ManagerMutex = [Threading.Mutex]::new($true, 'Local\GustavASAServerManager', [ref]$createdNew)
    if (-not $createdNew) {
        [Windows.Forms.MessageBox]::Show('ASA Server Manager is already open.', 'ASA Manager', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $script:ManagerMutex.Dispose()
        exit 0
    }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CmdConfig = Join-Path $Root 'server-config.cmd'
$GameUserSettings = Join-Path $Root 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'
$GameIni = Join-Path $Root 'server\ShooterGame\Saved\Config\WindowsServer\Game.ini'
$StartBat = Join-Path $Root 'StartServer.bat'
$StopPs1 = Join-Path $Root 'StopServer.ps1'
$RestartBat = Join-Path $Root 'RestartServer.bat'
$UpdatePs1 = Join-Path $Root 'Update-And-Restart.ps1'
$BackupPs1 = Join-Path $Root 'SafeBackup-And-Restart.ps1'
$LogFolder = Join-Path $Root 'server\ShooterGame\Saved\Logs'
$ConfigFolder = Split-Path -Parent $GameUserSettings
$BackupsFolder = Join-Path $Root 'backups'
$AdminWhitelist = Join-Path $Root 'server\ShooterGame\Saved\AllowedCheaterAccountIDs.txt'
$ManagerLog = Join-Path $Root 'ASA-Manager.log'
$GuidePath = Join-Path $Root 'ASA-SERVER-GUIDE.html'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Background = [Drawing.Color]::FromArgb(25, 29, 36)
$Panel = [Drawing.Color]::FromArgb(37, 43, 52)
$InputColor = [Drawing.Color]::FromArgb(53, 61, 72)
$Text = [Drawing.Color]::FromArgb(238, 241, 245)
$Muted = [Drawing.Color]::FromArgb(168, 177, 190)
$Green = [Drawing.Color]::FromArgb(56, 190, 114)
$Red = [Drawing.Color]::FromArgb(226, 82, 82)
$Blue = [Drawing.Color]::FromArgb(64, 137, 232)
$Amber = [Drawing.Color]::FromArgb(232, 165, 64)

# Released ASA maps and their exact dedicated-server level names. Keep this
# list centralized so validation, the selector, and the advisor cannot drift.
$script:VerifiedMaps = [ordered]@{
    'TheIsland_WP'      = 'The Island'
    'ScorchedEarth_WP' = 'Scorched Earth'
    'TheCenter_WP'      = 'The Center'
    'Aberration_WP'     = 'Aberration'
    'Extinction_WP'     = 'Extinction'
    'Astraeos_WP'       = 'Astraeos'
    'Ragnarok_WP'       = 'Ragnarok'
    'Valguero_WP'       = 'Valguero'
    'LostColony_WP'     = 'Lost Colony'
    'Genesis_WP'        = 'Genesis: Part 1'
}

function Write-ManagerLog([string]$Level, [string]$Message) {
    try {
        $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($ManagerLog, $line, $Utf8NoBom)
    }
    catch { }
}

function Write-TextFileAtomic([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tempPath, $Content, $Utf8NoBom)
        if (Test-Path $Path) {
            [IO.File]::Replace($tempPath, $Path, ($Path + '.bak'), $true)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Write-LinesFileAtomic([string]$Path, [string[]]$Lines) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($tempPath, $Lines, $Utf8NoBom)
        if (Test-Path $Path) {
            [IO.File]::Replace($tempPath, $Path, ($Path + '.bak'), $true)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function New-ConfigSnapshot([string]$Reason) {
    $safeReason = ($Reason -replace '[^A-Za-z0-9_-]', '_').Trim('_')
    $snapshotRoot = Join-Path $BackupsFolder 'ConfigHistory'
    $snapshot = Join-Path $snapshotRoot ((Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff') + '_' + $safeReason)
    [void](New-Item -ItemType Directory -Path $snapshot -Force)
    foreach ($path in @($CmdConfig, $GameUserSettings, $GameIni, $AdminWhitelist)) {
        if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $snapshot ([IO.Path]::GetFileName($path))) -Force }
    }
    Write-ManagerLog 'INFO' "Configuration snapshot created: $snapshot"
    return $snapshot
}

function Get-SafeDecimal([string]$TextValue, [decimal]$Default, [decimal]$Minimum, [decimal]$Maximum) {
    $parsed = [decimal]0
    $valid = [decimal]::TryParse($TextValue, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
    if (-not $valid) { $valid = [decimal]::TryParse($TextValue, [ref]$parsed) }
    if (-not $valid) { $parsed = $Default }
    if ($parsed -lt $Minimum) { return $Minimum }
    if ($parsed -gt $Maximum) { return $Maximum }
    return $parsed
}

function Read-CmdConfig {
    $values = @{}
    $raw = [IO.File]::ReadAllText($CmdConfig)
    foreach ($match in [regex]::Matches($raw, '(?m)^set\s+"(?<key>[A-Z_]+)=(?<value>.*)"\s*$')) {
        $values[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }
    return $values
}

function Set-CmdConfigValue([string]$Key, [string]$Value) {
    $raw = [IO.File]::ReadAllText($CmdConfig)
    $pattern = '(?m)^set\s+"' + [regex]::Escape($Key) + '=.*"\s*$'
    $replacement = 'set "' + $Key + '=' + $Value + '"'
    if (-not [regex]::IsMatch($raw, $pattern)) {
        throw "Missing setting $Key in server-config.cmd"
    }
    $raw = [regex]::Replace($raw, $pattern, $replacement, 1)
    Write-TextFileAtomic $CmdConfig $raw
}

function Get-IniValueFromFile([string]$Path, [string]$Key, [string]$Default = '') {
    if (-not (Test-Path $Path)) { return $Default }
    $raw = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($raw, '(?m)^' + [regex]::Escape($Key) + '=(?<value>.*)$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return $Default
}

function Set-IniSectionValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
    if (-not (Test-Path $Path)) { Write-TextFileAtomic $Path '' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.AddRange([string[]][IO.File]::ReadAllLines($Path))
    $sectionIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq $Section) { $sectionIndex = $i; break }
    }
    if ($sectionIndex -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
        [void]$lines.Add($Section)
        [void]$lines.Add($Key + '=' + $Value)
    }
    else {
        $nextSection = $lines.Count
        for ($i = $sectionIndex + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -match '^\[.+\]$') { $nextSection = $i; break }
        }
        $keyIndex = -1
        for ($i = $sectionIndex + 1; $i -lt $nextSection; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '=')) { $keyIndex = $i; break }
        }
        if ($keyIndex -ge 0) { $lines[$keyIndex] = $Key + '=' + $Value }
        else { $lines.Insert($nextSection, $Key + '=' + $Value) }
    }
    Write-LinesFileAtomic $Path ([string[]]@($lines))
}

function Set-IniSectionRepeatedLines([string]$Path, [string]$Section, [string]$Key, [string[]]$NewLines) {
    if (-not (Test-Path $Path)) { Write-TextFileAtomic $Path '' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.AddRange([string[]][IO.File]::ReadAllLines($Path))
    $sectionIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq $Section) { $sectionIndex = $i; break }
    }
    if ($sectionIndex -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
        [void]$lines.Add($Section)
        $sectionIndex = $lines.Count - 1
    }
    $nextSection = $lines.Count
    for ($i = $sectionIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[.+\]$') { $nextSection = $i; break }
    }
    for ($i = $nextSection - 1; $i -gt $sectionIndex; $i--) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '=')) {
            $lines.RemoveAt($i)
        }
    }
    # Keep repeated/advanced directives together at the end of their section.
    # INI key order is not semantic, but this makes Game.ini much easier for a
    # human to audit and keeps recipe overrides away from stat multipliers.
    $insertAt = $lines.Count
    for ($i = $sectionIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[.+\]$') { $insertAt = $i; break }
    }
    foreach ($line in @($NewLines)) {
        if ($line) { $lines.Insert($insertAt, $line); $insertAt++ }
    }
    Write-LinesFileAtomic $Path ([string[]]@($lines))
}

function Get-ServerProcess {
    if ($TestMode) { return $null }
    return Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function New-HealthItem([string]$Level, [string]$Title, [string]$Detail) {
    return [pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail }
}

function Get-ServerHealthItems {
    $items = New-Object System.Collections.Generic.List[object]
    $serverExe = Join-Path $Root 'server\ShooterGame\Binaries\Win64\ArkAscendedServer.exe'
    $manifest = Join-Path $Root 'server\steamapps\appmanifest_2430930.acf'
    $updateBat = Join-Path $Root 'UpdateServer.bat'

    $required = @($CmdConfig, $GameUserSettings, $GameIni, $StartBat, $StopPs1, $serverExe)
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq 0) {
        $items.Add((New-HealthItem 'OK' 'Core server files' 'Dedicated server, startup, safe-stop, and configuration files are present.'))
    }
    else {
        $items.Add((New-HealthItem 'BLOCKER' 'Core server files' ('Missing: ' + (($missing | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', '))))
    }

    if (Test-Path -LiteralPath $manifest) {
        $manifestRaw = [IO.File]::ReadAllText($manifest)
        if ($manifestRaw -match '"appid"\s+"2430930"' -and $manifestRaw -match 'ARK: Survival Ascended Dedicated Server') {
            $build = [regex]::Match($manifestRaw, '"buildid"\s+"(?<id>\d+)"').Groups['id'].Value
            $items.Add((New-HealthItem 'OK' 'Correct Steam server app' ("App 2430930 is installed. Steam build ID: $build.")))
        }
        else {
            $items.Add((New-HealthItem 'BLOCKER' 'Correct Steam server app' 'The installed Steam manifest does not identify ASA Dedicated Server App 2430930.'))
        }
    }
    else {
        $items.Add((New-HealthItem 'WARN' 'Steam installation record' 'App 2430930 manifest was not found. Update/validate the server before relying on this installation.'))
    }

    if (Test-Path -LiteralPath $StartBat) {
        $startRaw = [IO.File]::ReadAllText($StartBat)
        if ($startRaw -match '(?i)-ServerPlatform=ALL') {
            $items.Add((New-HealthItem 'OK' 'PS5 crossplay startup' '-ServerPlatform=ALL is present, allowing supported PC, PS5, and Xbox clients.'))
        }
        else {
            $items.Add((New-HealthItem 'BLOCKER' 'PS5 crossplay startup' 'StartServer.bat is missing -ServerPlatform=ALL. PS5 discovery could fail.'))
        }
        if ($startRaw -match '(?i)-MULTIHOME' -and $startRaw -match '(?i)-Port=%GAME_PORT%') {
            $items.Add((New-HealthItem 'OK' 'Network startup arguments' 'The game port and pinned LAN adapter startup arguments are present.'))
        }
        else {
            $items.Add((New-HealthItem 'WARN' 'Network startup arguments' 'Review the game-port and MultiHome arguments in StartServer.bat.'))
        }
    }

    $updateRaw = ''
    foreach ($path in @($updateBat, $UpdatePs1)) {
        if (Test-Path -LiteralPath $path) { $updateRaw += [IO.File]::ReadAllText($path) }
    }
    if ($updateRaw -match '(?i)app_update\s+2430930') {
        $items.Add((New-HealthItem 'OK' 'Update method' 'SteamCMD updates and validates official ASA Dedicated Server App 2430930.'))
    }
    else {
        $items.Add((New-HealthItem 'BLOCKER' 'Update method' 'The update helpers do not contain Steam App 2430930.'))
    }

    try {
        $config = Read-CmdConfig
        $map = [string]$config['MAP']
        if ($script:VerifiedMaps.Contains($map)) {
            $items.Add((New-HealthItem 'OK' 'Selected map' ("$($script:VerifiedMaps[$map]) uses the verified ASA level name $map.")))
        }
        else {
            $items.Add((New-HealthItem 'WARN' 'Selected map' ("$map is not in the manager's verified released-map list.")))
        }

        $players = 0
        if (-not [int]::TryParse([string]$config['MAX_PLAYERS'], [ref]$players) -or $players -lt 1) {
            $items.Add((New-HealthItem 'BLOCKER' 'Player limit' 'MAX_PLAYERS is not a valid positive number.'))
        }
        elseif ($players -gt 20) {
            $items.Add((New-HealthItem 'WARN' 'Player limit' ("$players slots is ambitious for a 16 GB private host. Keep it near 10 unless RAM headroom is proven.")))
        }
        else {
            $items.Add((New-HealthItem 'OK' 'Player limit' ("$players slots is reasonable for this private server.")))
        }

        $modIds = @()
        if ($config['MODS']) { $modIds = @(([string]$config['MODS']).Split(',') | Where-Object { $_.Trim() }) }
        $badMods = @($modIds | Where-Object { $_ -notmatch '^\d+$' })
        $duplicateMods = @($modIds | Group-Object | Where-Object Count -gt 1)
        if ($badMods.Count -or $duplicateMods.Count) {
            $items.Add((New-HealthItem 'BLOCKER' 'Mod list' 'The mod list contains an invalid or duplicate CurseForge Project ID.'))
        }
        elseif ($modIds.Count -gt 8) {
            $items.Add((New-HealthItem 'WARN' 'Mod load' ("$($modIds.Count) mods may increase startup time and memory use. Add and test them in small batches.")))
        }
        elseif ($modIds.Count -gt 0) {
            $items.Add((New-HealthItem 'TIP' 'Mod compatibility' ("$($modIds.Count) mod(s) configured. Confirm every one is marked cross-platform before PS5 players join.")))
        }
        else {
            $items.Add((New-HealthItem 'OK' 'Mod baseline' 'No mods are configured, giving the cleanest compatibility baseline.'))
        }

        if (-not $TestMode) {
            $serverIp = [string]$config['SERVER_IP']
            $activeIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -ExpandProperty IPAddress)
            if ($serverIp -and $serverIp -in $activeIps) {
                $items.Add((New-HealthItem 'OK' 'Pinned LAN address' ("$serverIp is active on this PC, so VPN adapters should not steal ASA traffic.")))
            }
            else {
                $items.Add((New-HealthItem 'BLOCKER' 'Pinned LAN address' ("Configured SERVER_IP $serverIp is not currently active on this PC.")))
            }
        }
    }
    catch {
        $items.Add((New-HealthItem 'BLOCKER' 'Readable startup configuration' $_.Exception.Message))
    }

    $adminPassword = Get-IniValueFromFile $GameUserSettings 'ServerAdminPassword' ''
    $joinPassword = Get-IniValueFromFile $GameUserSettings 'ServerPassword' ''
    if ($adminPassword.Length -ge 4) {
        $items.Add((New-HealthItem 'OK' 'Admin protection' 'An admin password of at least 4 characters is configured. Its value is never shown here.'))
    }
    else {
        $items.Add((New-HealthItem 'BLOCKER' 'Admin protection' 'Set an admin password of at least 4 characters in Important server settings.'))
    }
    if ($joinPassword.Length -ge 4) {
        $items.Add((New-HealthItem 'OK' 'Join protection' 'A join password is configured. Its value is never shown here.'))
    }
    else {
        $items.Add((New-HealthItem 'TIP' 'Join protection' 'The server has no join password. That is fine for discovery testing, but a private group may prefer one.'))
    }

    $autosave = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'AutoSavePeriodMinutes' '15') 15 1 120
    if ($autosave -le 20) {
        $items.Add((New-HealthItem 'OK' 'World autosave' ("Autosave is every $autosave minute(s).")))
    }
    else {
        $items.Add((New-HealthItem 'WARN' 'World autosave' ("$autosave minutes can lose too much progress after a crash. 10-15 is safer.")))
    }

    $xp = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'XPMultiplier' '1') 1 0.01 1000
    $harvest = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'HarvestAmountMultiplier' '1') 1 0.01 1000
    $taming = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'TamingSpeedMultiplier' '1') 1 0.01 1000
    if ($xp -le 5 -and $harvest -le 5 -and $taming -le 10) {
        $items.Add((New-HealthItem 'OK' 'Gameplay rates' ("XP ${xp}x, harvest ${harvest}x, taming ${taming}x are within a sensible private-server range.")))
    }
    else {
        $items.Add((New-HealthItem 'TIP' 'Gameplay rates' ("XP ${xp}x, harvest ${harvest}x, taming ${taming}x are very fast; check that this is intentional.")))
    }

    if (-not $TestMode) {
        try {
            $system = Get-CimInstance Win32_ComputerSystem
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $ramGb = [math]::Round($system.TotalPhysicalMemory / 1GB, 1)
            $diskGb = [math]::Round($disk.FreeSpace / 1GB, 0)
            if ($ramGb -ge 15.5) {
                $items.Add((New-HealthItem 'OK' 'Host memory' ("$ramGb GB installed is sufficient for ASA alone. Do not run the full Steam client beside it.")))
            }
            else {
                $items.Add((New-HealthItem 'WARN' 'Host memory' ("$ramGb GB installed is below the manager's 16 GB private-host baseline.")))
            }
            if ($diskGb -ge 50) {
                $items.Add((New-HealthItem 'OK' 'Storage headroom' ("$diskGb GB free on C: leaves room for maps, updates, logs, and backups.")))
            }
            else {
                $items.Add((New-HealthItem 'WARN' 'Storage headroom' ("Only $diskGb GB is free on C:. Prune old backups before large ASA updates.")))
            }
        }
        catch {
            $items.Add((New-HealthItem 'TIP' 'Host resources' 'Windows resource details could not be read in this session.'))
        }

        $server = Get-ServerProcess
        if ($server) {
            $privateGb = [math]::Round($server.PrivateMemorySize64 / 1GB, 1)
            $ports = @(Get-NetUDPEndpoint -OwningProcess $server.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort)
            $gamePort = 7777
            try { $gamePort = [int](Read-CmdConfig)['GAME_PORT'] } catch { }
            if ($gamePort -in $ports -and 27015 -in $ports) {
                $items.Add((New-HealthItem 'OK' 'Live ASA listeners' ("ASA PID $($server.Id) is responding, using $privateGb GB private memory, and listening on UDP $gamePort and 27015.")))
            }
            else {
                $items.Add((New-HealthItem 'WARN' 'Live ASA listeners' ("ASA PID $($server.Id) is running, but its expected UDP listeners were not both visible yet.")))
            }
        }
        else {
            $items.Add((New-HealthItem 'TIP' 'Live server state' 'ASA is stopped. Start it when you want to perform a live connection check.'))
        }
    }

    $latestBackup = Get-ChildItem -LiteralPath $BackupsFolder -Directory -Filter 'ASA_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestBackup) {
        $age = [math]::Round(((Get-Date) - $latestBackup.LastWriteTime).TotalDays, 1)
        if ($age -le 7) {
            $items.Add((New-HealthItem 'OK' 'Save backup' ("Latest full save backup is $age day(s) old.")))
        }
        else {
            $items.Add((New-HealthItem 'WARN' 'Save backup' ("Latest full save backup is $age day(s) old. Make a Safe backup before map or mod changes.")))
        }
    }
    else {
        $items.Add((New-HealthItem 'WARN' 'Save backup' 'No full save backup was found. Use Safe backup before adding mods or changing maps.'))
    }

    # Windows PowerShell 5.1 can throw "Argument types do not match" when the
    # array-subexpression operator wraps a generic List[object]. ToArray keeps
    # the result stable in both Windows PowerShell and modern PowerShell.
    return $items.ToArray()
}

function Show-Info([string]$Message, [string]$Title = 'ASA Manager') {
    [Windows.Forms.MessageBox]::Show($form, $Message, $Title, [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Show-ErrorBox([string]$Message) {
    Write-ManagerLog 'ERROR' $Message
    [Windows.Forms.MessageBox]::Show($form, $Message, 'ASA Manager', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Ask-YesNo([string]$Message, [string]$Title = 'Please confirm') {
    return [Windows.Forms.MessageBox]::Show($form, $Message, $Title, [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question) -eq [Windows.Forms.DialogResult]::Yes
}

function New-Label([string]$Caption, [int]$X, [int]$Y, [int]$Width, [int]$Height = 24, [Drawing.Color]$Color = $Text, [float]$Size = 10) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Caption
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($Width, $Height)
    $label.ForeColor = $Color
    $label.Font = New-Object Drawing.Font('Segoe UI', $Size)
    return $label
}

function New-TextBox([int]$X, [int]$Y, [int]$Width) {
    $box = New-Object Windows.Forms.TextBox
    $box.Location = New-Object Drawing.Point($X, $Y)
    $box.Size = New-Object Drawing.Size($Width, 28)
    $box.BackColor = $InputColor
    $box.ForeColor = $Text
    $box.BorderStyle = 'FixedSingle'
    $box.Font = New-Object Drawing.Font('Segoe UI', 10)
    return $box
}

function New-Button([string]$Caption, [int]$X, [int]$Y, [int]$Width, [Drawing.Color]$Color = $Blue) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Caption
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size($Width, 42)
    $button.BackColor = $Color
    $button.ForeColor = [Drawing.Color]::White
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $button.Cursor = 'Hand'
    return $button
}

function New-Group([string]$Caption, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $group = New-Object Windows.Forms.GroupBox
    $group.Text = $Caption
    $group.Location = New-Object Drawing.Point($X, $Y)
    $group.Size = New-Object Drawing.Size($Width, $Height)
    $group.ForeColor = $Text
    $group.BackColor = $Panel
    $group.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    return $group
}

function Start-Server {
    if (Get-ServerProcess) {
        Show-Info 'The server is already running.'
        return
    }
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $StartBat) -WorkingDirectory $Root -WindowStyle Hidden
    $statusDetail.Text = 'Starting ASA. Full startup normally takes about one minute...'
}

function Stop-ServerSafe {
    if (-not (Get-ServerProcess)) {
        Show-Info 'The server is already stopped.'
        return
    }
    $form.Cursor = 'WaitCursor'
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StopPs1 -WorkingDirectory $Root -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'Safe shutdown did not complete. The server was not force-killed.' }
    }
    finally {
        $form.Cursor = 'Default'
    }
}

function Ensure-ServerStoppedForConfigWrite {
    if (-not (Get-ServerProcess)) { return $true }
    $message = "ASA must be fully stopped before changing its INI files.`r`n`r`n" +
        "If settings are written while the server is running, ASA can overwrite them during shutdown.`r`n`r`n" +
        'Stop the server safely now? You can make several changes while it is offline, then press Start server.'
    if (-not (Ask-YesNo $message 'Safe configuration change')) { return $false }
    Stop-ServerSafe
    if (Get-ServerProcess) { throw 'ASA did not stop cleanly, so no configuration was changed.' }
    return $true
}

function Load-Settings {
    $script:LoadingBasicSettings = $true
    try {
        $config = Read-CmdConfig
        $serverNameBox.Text = $config['SERVER_NAME']
        $mapBox.SelectedItem = $config['MAP']
        if ($mapBox.SelectedIndex -lt 0) { $mapBox.Text = $config['MAP'] }
        $playersBox.Value = Get-SafeDecimal $config['MAX_PLAYERS'] 10 $playersBox.Minimum $playersBox.Maximum
        $modsBox.Text = $config['MODS']
        $xpBox.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'XPMultiplier' '1') 1 $xpBox.Minimum $xpBox.Maximum
        $harvestBox.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'HarvestAmountMultiplier' '1') 1 $harvestBox.Minimum $harvestBox.Maximum
        $tamingBox.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'TamingSpeedMultiplier' '1') 1 $tamingBox.Minimum $tamingBox.Maximum
        $script:BasicSettingsDirty = $false
    }
    finally {
        $script:LoadingBasicSettings = $false
    }
}

function Save-Settings {
    $name = $serverNameBox.Text.Trim()
    if ($name -notmatch "^[A-Za-z0-9 ._'()\-]{1,60}$") {
        throw "Server name must be 1-60 characters and use only letters, numbers, spaces, dots, apostrophes, parentheses, underscores, or hyphens."
    }
    $map = $mapBox.Text.Trim()
    if ($map -notmatch '^[A-Za-z0-9_]+$') { throw 'Please select a valid ASA map.' }
    $mods = ($modsBox.Text -replace '\s', '').Trim(',')
    if ($mods -and $mods -notmatch '^\d+(,\d+)*$') { throw 'Mods must be CurseForge project IDs separated by commas.' }

    $oldConfig = Read-CmdConfig
    if ($map -ne $oldConfig['MAP']) {
        $mapMessage = "Change the next-start map from $($oldConfig['MAP']) to $map?`r`n`r`n" +
            'Your old world is not deleted; ARK stores each map separately. Use Safe backup before the first restart on a new map, especially before installing mods.'
        if (-not (Ask-YesNo $mapMessage 'Confirm map change')) { return }
    }

    if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
    [void](New-ConfigSnapshot 'basic-settings')

    Set-CmdConfigValue 'SERVER_NAME' $name
    Set-CmdConfigValue 'MAP' $map
    Set-CmdConfigValue 'MAX_PLAYERS' ([string][int]$playersBox.Value)
    Set-CmdConfigValue 'MODS' $mods
    Set-IniSectionValue $GameUserSettings '[SessionSettings]' 'SessionName' $name
    Set-IniSectionValue $GameUserSettings '[/Script/Engine.GameSession]' 'MaxPlayers' ([string][int]$playersBox.Value)
    Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'XPMultiplier' $xpBox.Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'HarvestAmountMultiplier' $harvestBox.Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'TamingSpeedMultiplier' $tamingBox.Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    $script:BasicSettingsDirty = $false

    if (Get-ServerProcess) {
        Show-Info 'Settings saved. They will take effect after the next restart.'
    }
    else {
        Show-Info 'Settings saved. They will be used when the server starts.'
    }
}

function Show-AdminManager {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Permanent server admins - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(700, 555)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $dialog.Controls.Add((New-Label 'Permanent admin whitelist' 20 18 420 32 $Text 16))
    $dialog.Controls.Add((New-Label 'On PS5, open the console and run whoami. Enter the 32-character OSS/EOS Account ID shown. Never enter a PSN name here.' 22 54 640 52 $Muted 9))

    $list = New-Object Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(22, 116)
    $list.Size = New-Object Drawing.Size(450, 245)
    $list.BackColor = $InputColor
    $list.ForeColor = $Text
    $list.Font = New-Object Drawing.Font('Consolas', 10)
    if (Test-Path $AdminWhitelist) {
        foreach ($id in [IO.File]::ReadAllLines($AdminWhitelist)) {
            if ($id.Trim()) { [void]$list.Items.Add($id.Trim()) }
        }
    }
    $dialog.Controls.Add($list)

    $idBox = New-TextBox 22 378 450
    $idBox.MaxLength = 32
    $dialog.Controls.Add($idBox)
    $addButton = New-Button 'Add Account ID' 490 116 170 $Green
    $removeButton = New-Button 'Remove selected' 490 172 170 $Red
    $saveButton = New-Button 'Save admin list' 490 319 170 $Blue
    $dialog.Controls.AddRange(@($addButton, $removeButton, $saveButton))
    $dialog.Controls.Add((New-Label 'Changes take effect after the next server restart. Whitelisted admins do not need enablecheats.' 22 423 640 42 $Muted 9))

    $addButton.Add_Click({
        $id = $idBox.Text.Trim()
        if ($id -notmatch '^[A-Za-z0-9]{32}$') { Show-ErrorBox 'Enter the full 32-character Account ID shown by the whoami command.'; return }
        if ($list.Items.Contains($id)) { Show-Info 'That Account ID is already an admin.'; return }
        [void]$list.Items.Add($id)
        $idBox.Clear()
    })
    $removeButton.Add_Click({ if ($list.SelectedIndex -ge 0) { $list.Items.RemoveAt($list.SelectedIndex) } })
    $saveButton.Add_Click({
        try {
            [void](New-ConfigSnapshot 'admin-list')
            $folder = Split-Path -Parent $AdminWhitelist
            if (-not (Test-Path $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
            $ids = @($list.Items | ForEach-Object { [string]$_ })
            Write-LinesFileAtomic $AdminWhitelist ([string[]]$ids)
            if (Get-ServerProcess) { Show-Info 'Permanent admin list saved. Restart ASA when convenient to apply it.' }
            else { Show-Info 'Permanent admin list saved. It will apply at the next start.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-RatesDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Guided rates - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(820, 980)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $heading = New-Label 'Gameplay and breeding rates' 20 16 500 34 $Text 17
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add((New-Label 'Higher is faster/more unless the explanation says lower is faster.' 22 52 700 24 $Muted 9))

    $entries = @(
        @{ Key='XPMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Experience'; Default='1.0'; Min=0.1; Max=100; Explain='Higher gives players and tames more XP. 2.0 is a relaxed private-server rate.' },
        @{ Key='HarvestAmountMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Harvest amount'; Default='1.0'; Min=0.1; Max=100; Explain='Higher gives more wood, stone, berries, and other resources per hit.' },
        @{ Key='TamingSpeedMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Taming speed'; Default='1.0'; Min=0.1; Max=100; Explain='Higher makes taming complete faster. It does not increase creature stats.' },
        @{ Key='PassiveTameIntervalMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Passive feed interval'; Default='1.0'; Min=0.05; Max=10; Explain='Lower shortens the wait between passive-tame feeds (for example otters). 0.2 is five times sooner.' },
        @{ Key='PlayerResistanceMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Damage players receive'; Default='1.0'; Min=0.1; Max=5; Explain='Lower reduces incoming player damage. 0.5 means roughly half the normal damage.' },
        @{ Key='ResourcesRespawnPeriodMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Resource respawn'; Default='1.0'; Min=0.1; Max=10; Explain='Lower respawns trees, rocks, and bushes sooner. 0.5 is twice as frequent.' },
        @{ Key='PlayerCharacterFoodDrainMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Food drain'; Default='1.0'; Min=0.1; Max=10; Explain='Lower means players get hungry more slowly.' },
        @{ Key='PlayerCharacterWaterDrainMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Water drain'; Default='1.0'; Min=0.1; Max=10; Explain='Lower means players get thirsty more slowly.' },
        @{ Key='MatingIntervalMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Mating cooldown'; Default='1.0'; Min=0.01; Max=10; Explain='Lower lets creatures mate again sooner. 0.2 is five times sooner.' },
        @{ Key='MatingSpeedMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Mating progress'; Default='1.0'; Min=0.1; Max=100; Explain='Higher fills the mating bar faster. 5.0 completes mating about five times faster.' },
        @{ Key='EggHatchSpeedMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Egg hatch speed'; Default='1.0'; Min=0.1; Max=100; Explain='Higher makes fertilized eggs hatch faster.' },
        @{ Key='BabyMatureSpeedMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Baby maturation'; Default='1.0'; Min=0.1; Max=100; Explain='Higher makes baby creatures reach adulthood faster.' },
        @{ Key='BabyCuddleIntervalMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Imprint interval'; Default='1.0'; Min=0.01; Max=10; Explain='Lower requests imprint care more often. Keep this roughly inverse to maturation speed.' },
        @{ Key='BabyImprintAmountMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Imprint per care'; Default='1.0'; Min=0.1; Max=100; Explain='Higher gives more imprint progress per care. 100 makes the first successful care reach 100%.' },
        @{ Key='CropGrowthSpeedMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Crop growth'; Default='1.0'; Min=0.1; Max=100; Explain='Higher makes crops grow faster.' },
        @{ Key='StructureResistanceMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Structure toughness'; Default='1.0'; Min=0.05; Max=5; Explain='Lower makes structures take less damage. 0.5 means roughly half damage; 0.1 is nearly indestructible.' },
        @{ Key='DinoCharacterFoodDrainMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Dino food drain'; Default='1.0'; Min=0.1; Max=10; Explain='Lower means dinos get hungry more slowly (wild and tamed).' },
        @{ Key='DinoCharacterStaminaDrainMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Dino stamina drain'; Default='1.0'; Min=0.1; Max=10; Explain='Lower means dinos tire out more slowly while sprinting or flying.' }
    )

    $rateControls = @{}
    $y = 84
    foreach ($entry in $entries) {
        $dialog.Controls.Add((New-Label $entry.Label 22 $y 140 24 $Text 9))
        $number = New-Object Windows.Forms.NumericUpDown
        $number.Location = New-Object Drawing.Point(164, ($y - 2))
        $number.Size = New-Object Drawing.Size(92, 26)
        $number.DecimalPlaces = 2
        $number.Increment = 0.1
        $number.Minimum = [decimal]$entry.Min
        $number.Maximum = [decimal]$entry.Max
        $number.BackColor = $InputColor
        $number.ForeColor = $Text
        $current = Get-IniValueFromFile $entry.File $entry.Key $entry.Default
        $number.Value = Get-SafeDecimal $current ([decimal]$entry.Default) $number.Minimum $number.Maximum
        $rateControls[$entry.Key] = $number
        $dialog.Controls.Add($number)
        $dialog.Controls.Add((New-Label $entry.Explain 276 ($y - 2) 505 36 $Muted 8.5))
        $y += 45
    }

    $officialButton = New-Button 'Official 1x preset' 20 905 130 ([Drawing.Color]::FromArgb(79, 99, 125))
    $relaxedButton = New-Button 'Relaxed private preset' 158 905 150 $Green
    $noWipeButton = New-Button 'Balanced No-Wipe' 316 905 145 ([Drawing.Color]::FromArgb(46, 150, 145))
    $fastButton = New-Button 'Fast private preset' 469 905 135 $Amber
    $saveRatesButton = New-Button 'Save rates' 612 905 170 $Blue
    $dialog.Controls.AddRange(@($officialButton, $relaxedButton, $noWipeButton, $fastButton, $saveRatesButton))

    $officialButton.Add_Click({
        foreach ($control in $rateControls.Values) { $control.Value = 1.0 }
    })
    $relaxedButton.Add_Click({
        $rateControls['XPMultiplier'].Value = 2.5
        $rateControls['HarvestAmountMultiplier'].Value = 3.0
        $rateControls['TamingSpeedMultiplier'].Value = 8.0
        $rateControls['PassiveTameIntervalMultiplier'].Value = 0.4
        $rateControls['PlayerResistanceMultiplier'].Value = 0.75
        $rateControls['ResourcesRespawnPeriodMultiplier'].Value = 0.5
        $rateControls['PlayerCharacterFoodDrainMultiplier'].Value = 0.5
        $rateControls['PlayerCharacterWaterDrainMultiplier'].Value = 0.5
        $rateControls['MatingIntervalMultiplier'].Value = 0.2
        $rateControls['MatingSpeedMultiplier'].Value = 5.0
        $rateControls['EggHatchSpeedMultiplier'].Value = 10.0
        $rateControls['BabyMatureSpeedMultiplier'].Value = 10.0
        $rateControls['BabyCuddleIntervalMultiplier'].Value = 0.1
        $rateControls['BabyImprintAmountMultiplier'].Value = 1.0
        $rateControls['CropGrowthSpeedMultiplier'].Value = 3.0
    })
    $noWipeButton.Add_Click({
        # A small-group No-Wipe pace: progression remains meaningful, while
        # repetitive gathering and passive-tame waiting are substantially cut.
        $rateControls['XPMultiplier'].Value = 4.0
        $rateControls['HarvestAmountMultiplier'].Value = 5.0
        $rateControls['TamingSpeedMultiplier'].Value = 12.0
        $rateControls['PassiveTameIntervalMultiplier'].Value = 0.2
        $rateControls['PlayerResistanceMultiplier'].Value = 0.5
        $rateControls['ResourcesRespawnPeriodMultiplier'].Value = 0.5
        $rateControls['PlayerCharacterFoodDrainMultiplier'].Value = 0.5
        $rateControls['PlayerCharacterWaterDrainMultiplier'].Value = 0.5
        $rateControls['MatingIntervalMultiplier'].Value = 0.05
        $rateControls['MatingSpeedMultiplier'].Value = 10.0
        $rateControls['EggHatchSpeedMultiplier'].Value = 20.0
        $rateControls['BabyMatureSpeedMultiplier'].Value = 20.0
        $rateControls['BabyCuddleIntervalMultiplier'].Value = 0.05
        $rateControls['BabyImprintAmountMultiplier'].Value = 100.0
        $rateControls['CropGrowthSpeedMultiplier'].Value = 3.0
    })
    $fastButton.Add_Click({
        $rateControls['XPMultiplier'].Value = 7.0
        $rateControls['HarvestAmountMultiplier'].Value = 8.0
        $rateControls['TamingSpeedMultiplier'].Value = 20.0
        $rateControls['PassiveTameIntervalMultiplier'].Value = 0.1
        $rateControls['PlayerResistanceMultiplier'].Value = 0.35
        $rateControls['ResourcesRespawnPeriodMultiplier'].Value = 0.35
        $rateControls['PlayerCharacterFoodDrainMultiplier'].Value = 0.5
        $rateControls['PlayerCharacterWaterDrainMultiplier'].Value = 0.5
        $rateControls['MatingIntervalMultiplier'].Value = 0.1
        $rateControls['MatingSpeedMultiplier'].Value = 20.0
        $rateControls['EggHatchSpeedMultiplier'].Value = 20.0
        $rateControls['BabyMatureSpeedMultiplier'].Value = 20.0
        $rateControls['BabyCuddleIntervalMultiplier'].Value = 0.05
        $rateControls['BabyImprintAmountMultiplier'].Value = 100.0
        $rateControls['CropGrowthSpeedMultiplier'].Value = 5.0
    })
    $saveRatesButton.Add_Click({
        try {
            if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
            [void](New-ConfigSnapshot 'guided-rates')
            foreach ($entry in $entries) {
                $value = $rateControls[$entry.Key].Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
                Set-IniSectionValue $entry.File $entry.Section $entry.Key $value
            }
            Load-Settings
            if (Get-ServerProcess) { Show-Info 'Rates saved. Restart ASA when you want them to take effect.' }
            else { Show-Info 'Rates saved. They will be active at the next start.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-CraftingCostsDialog {
    $section = '[/Script/ShooterGame.ShooterGameMode]'
    $key = 'ConfigOverrideItemCraftingCosts'
    $recipeLines = New-Object System.Collections.ArrayList
    if (Test-Path $GameIni) {
        foreach ($line in [IO.File]::ReadAllLines($GameIni)) {
            if ($line -match ('^\s*' + [regex]::Escape($key) + '=')) { [void]$recipeLines.Add($line.Trim()) }
        }
    }

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Custom crafting costs - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(900, 690)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $heading = New-Label 'Custom crafting costs' 20 16 500 34 $Text 17
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add((New-Label 'Each recipe replaces the full vanilla ingredient list. Save creates a backup; a server restart activates it.' 22 52 840 34 $Muted 9))

    $dialog.Controls.Add((New-Label 'Saved recipe overrides' 22 88 300 24 $Text 10))
    $recipeList = New-Object Windows.Forms.ListBox
    $recipeList.Location = New-Object Drawing.Point(22, 116)
    $recipeList.Size = New-Object Drawing.Size(840, 145)
    $recipeList.BackColor = $InputColor
    $recipeList.ForeColor = $Text
    $recipeList.Font = New-Object Drawing.Font('Consolas', 9)
    $dialog.Controls.Add($recipeList)

    $dialog.Controls.Add((New-Label 'Item class' 22 282 120 24 $Text 9))
    $itemClassBox = New-TextBox 145 278 717
    $dialog.Controls.Add($itemClassBox)
    $dialog.Controls.Add((New-Label 'Resources - one per line as ResourceItemClass=Amount' 22 323 500 24 $Text 9))
    $resourcesBox = New-Object Windows.Forms.TextBox
    $resourcesBox.Location = New-Object Drawing.Point(22, 350)
    $resourcesBox.Size = New-Object Drawing.Size(840, 105)
    $resourcesBox.Multiline = $true
    $resourcesBox.ScrollBars = 'Vertical'
    $resourcesBox.BackColor = $InputColor
    $resourcesBox.ForeColor = $Text
    $resourcesBox.Font = New-Object Drawing.Font('Consolas', 9)
    $dialog.Controls.Add($resourcesBox)

    $presetButton = New-Button 'Load Basic Kibble test' 22 478 190 $Green
    $addButton = New-Button 'Add / replace recipe' 226 478 190 $Blue
    $removeButton = New-Button 'Remove selected' 430 478 170 $Red
    $openIniButton = New-Button 'Open INI folder' 614 478 150 ([Drawing.Color]::FromArgb(79, 99, 125))
    $saveButton = New-Button 'Save recipe list' 662 573 200 $Blue
    $dialog.Controls.AddRange(@($presetButton, $addButton, $removeButton, $openIniButton, $saveButton))
    $dialog.Controls.Add((New-Label 'Tip: class names must end in _C. Use Add / replace, then Save recipe list. Nothing changes in-game until restart.' 22 526 820 38 $Muted 9))

    $refreshList = {
        $recipeList.Items.Clear()
        foreach ($line in $recipeLines) {
            $itemMatch = [regex]::Match($line, 'ItemClassString="(?<item>[^"]+)"')
            $resourceMatches = [regex]::Matches($line, 'ResourceItemTypeString="(?<resource>[^"]+)"[^)]*BaseResourceRequirement=(?<amount>[0-9.]+)')
            $summary = @($resourceMatches | ForEach-Object { $_.Groups['resource'].Value + ' x' + $_.Groups['amount'].Value }) -join ', '
            $name = if ($itemMatch.Success) { $itemMatch.Groups['item'].Value } else { 'Unparsed recipe' }
            [void]$recipeList.Items.Add($name + '  <-  ' + $summary)
        }
    }
    & $refreshList

    $presetButton.Add_Click({
        $itemClassBox.Text = 'PrimalItemConsumable_Kibble_Base_XSmall_C'
        $resourcesBox.Text = 'PrimalItemConsumable_CookedMeat_C=5'
    })
    $addButton.Add_Click({
        try {
            $item = $itemClassBox.Text.Trim()
            if ($item -notmatch '^[A-Za-z0-9_]+_C$') { throw 'Enter a valid item class ending in _C.' }
            $requirements = New-Object System.Collections.Generic.List[string]
            foreach ($rawResource in @($resourcesBox.Lines)) {
                $rawResource = $rawResource.Trim()
                if (-not $rawResource) { continue }
                $parts = $rawResource.Split('=', 2)
                if ($parts.Count -ne 2 -or $parts[0].Trim() -notmatch '^[A-Za-z0-9_]+_C$') { throw "Invalid resource line: $rawResource" }
                [decimal]$amount = 0
                $amountValid = [decimal]::TryParse($parts[1].Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$amount)
                if (-not $amountValid -or $amount -lt 0.01 -or $amount -gt 1000000) { throw "Invalid amount in: $rawResource" }
                $amountText = $amount.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
                $requirements.Add('(ResourceItemTypeString="' + $parts[0].Trim() + '",BaseResourceRequirement=' + $amountText + ',bCraftingRequireExactResourceType=False)')
            }
            if ($requirements.Count -eq 0) { throw 'Add at least one resource line.' }
            $newLine = $key + '=(ItemClassString="' + $item + '",BaseCraftingResourceRequirements=(' + ($requirements -join ',') + '))'
            $replaceIndex = -1
            for ($i = 0; $i -lt $recipeLines.Count; $i++) {
                if ($recipeLines[$i] -match ('ItemClassString="' + [regex]::Escape($item) + '"')) { $replaceIndex = $i; break }
            }
            if ($replaceIndex -ge 0) { $recipeLines[$replaceIndex] = $newLine } else { [void]$recipeLines.Add($newLine) }
            & $refreshList
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    $removeButton.Add_Click({
        if ($recipeList.SelectedIndex -ge 0) {
            $recipeLines.RemoveAt($recipeList.SelectedIndex)
            & $refreshList
        }
    })
    $openIniButton.Add_Click({ Start-Process explorer.exe $ConfigFolder })
    $saveButton.Add_Click({
        try {
            if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
            [void](New-ConfigSnapshot 'custom-crafting-costs')
            Set-IniSectionRepeatedLines $GameIni $section $key ([string[]]@($recipeLines))
            if (Get-ServerProcess) { Show-Info 'Custom recipes saved. Restart ASA when you want them to take effect.' }
            else { Show-Info 'Custom recipes saved. They will be active at the next start.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-ProgressionDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Progression and world time - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(840, 950)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $heading = New-Label 'Progression, dino stats and world time' 20 16 650 34 $Text 17
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add((New-Label 'Values are shown relative to vanilla: 1.0 = normal and 2.0 = twice the normal effect.' 22 52 760 24 $Muted 9))

    $entries = @(
        @{ Key='KillXPMultiplier'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Kill XP'; Base=1.0; Min=0.1; Max=20; Explain='XP awarded for kills. This stacks with the main XP rate.' },
        @{ Key='PerLevelStatsMultiplier_Player[1]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player stamina / level'; Base=1.0; Min=0.1; Max=20; Explain='Stamina gained whenever a player spends one level point.' },
        @{ Key='PerLevelStatsMultiplier_Player[7]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player weight / level'; Base=1.0; Min=0.1; Max=20; Explain='Weight gained whenever a player spends one level point.' },
        @{ Key='PerLevelStatsMultiplier_Player[8]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player melee / level'; Base=1.0; Min=0.1; Max=20; Explain='Melee damage gained whenever a player spends one level point.' },
        @{ Key='PerLevelStatsMultiplier_Player[11]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player crafting / level'; Base=1.0; Min=0.1; Max=20; Explain='Crafting skill gained whenever a player spends one level point.' },
        @{ Key='PerLevelStatsMultiplier_Player[9]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player movement / level'; Base=1.0; Min=0.1; Max=20; Explain='1.0 is about +1.5% movement per point. Native ASA has no hard maximum for this stat.' },
        @{ Key='PerLevelStatsMultiplier_Player[10]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Player fortitude / level'; Base=1.0; Min=0.1; Max=20; Explain='Fortitude gained per point: improves heat, cold, disease and knockout resistance.' },
        @{ Key='PerLevelStatsMultiplier_DinoTamed[0]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Dino health / level'; Base=1.0; Min=0.1; Max=10; Explain='Health gained when spending a level on a tamed dino. 1.0 is vanilla.' },
        @{ Key='PerLevelStatsMultiplier_DinoTamed[1]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Dino stamina / level'; Base=1.0; Min=0.1; Max=10; Explain='Stamina gained when spending a level on a tamed dino.' },
        @{ Key='PerLevelStatsMultiplier_DinoTamed[7]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Dino weight / level'; Base=1.0; Min=0.1; Max=20; Explain='Weight gained when spending a level on a tamed dino.' },
        @{ Key='PerLevelStatsMultiplier_DinoTamed[8]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Dino melee / level'; Base=1.0; Min=0.1; Max=10; Explain='Melee damage gained when spending a level on a tamed dino. 1.0 is vanilla.' },
        @{ Key='DayCycleSpeedScale'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Whole day cycle'; Base=1.0; Min=0.1; Max=10; Explain='Higher makes the entire day/night cycle pass faster.' },
        @{ Key='DayTimeSpeedScale'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Daytime speed'; Base=1.0; Min=0.1; Max=10; Explain='Lower makes daylight last longer.' },
        @{ Key='NightTimeSpeedScale'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Night speed'; Base=1.0; Min=0.1; Max=10; Explain='Higher makes nighttime end sooner.' }
    )

    $controls = @{}
    $y = 84
    foreach ($entry in $entries) {
        $dialog.Controls.Add((New-Label $entry.Label 22 $y 180 24 $Text 9))
        $number = New-Object Windows.Forms.NumericUpDown
        $number.Location = New-Object Drawing.Point(205, ($y - 2))
        $number.Size = New-Object Drawing.Size(92, 26)
        $number.DecimalPlaces = 2
        $number.Increment = 0.1
        $number.Minimum = [decimal]$entry.Min
        $number.Maximum = [decimal]$entry.Max
        $number.BackColor = $InputColor
        $number.ForeColor = $Text
        $raw = Get-SafeDecimal (Get-IniValueFromFile $entry.File $entry.Key ([string]$entry.Base)) ([decimal]$entry.Base) 0.0001 100000
        $relative = $raw / [decimal]$entry.Base
        if ($relative -lt $number.Minimum) { $relative = $number.Minimum }
        if ($relative -gt $number.Maximum) { $relative = $number.Maximum }
        $number.Value = $relative
        $controls[$entry.Key] = $number
        $dialog.Controls.Add($number)
        $dialog.Controls.Add((New-Label $entry.Explain 318 ($y - 2) 485 36 $Muted 8.5))
        $y += 49
    }

    $speedCheck = New-Object Windows.Forms.CheckBox
    $speedCheck.Text = 'Allow native movement-speed leveling (players and non-flyers; no hard cap)'
    $speedCheck.Location = New-Object Drawing.Point(22, 779)
    $speedCheck.Size = New-Object Drawing.Size(650, 28)
    $speedCheck.ForeColor = $Text
    $speedCheck.Checked = ([string](Read-CmdConfig)['ALLOW_SPEED_LEVELING']) -ieq 'True'
    $dialog.Controls.Add($speedCheck)

    $vanillaButton = New-Button 'Set all to vanilla 1x' 22 824 180 ([Drawing.Color]::FromArgb(79, 99, 125))
    $balancedButton = New-Button 'Balanced private preset' 216 824 190 $Green
    $saveButton = New-Button 'Save progression + time' 584 824 220 $Blue
    $dialog.Controls.AddRange(@($vanillaButton, $balancedButton, $saveButton))
    $vanillaButton.Add_Click({ foreach ($control in $controls.Values) { $control.Value = 1.0 }; $speedCheck.Checked = $false })
    $balancedButton.Add_Click({
        $controls['KillXPMultiplier'].Value = 1.25
        $controls['PerLevelStatsMultiplier_Player[1]'].Value = 2.0
        $controls['PerLevelStatsMultiplier_Player[7]'].Value = 3.0
        $controls['PerLevelStatsMultiplier_Player[8]'].Value = 1.6
        $controls['PerLevelStatsMultiplier_Player[11]'].Value = 1.5
        $controls['PerLevelStatsMultiplier_Player[9]'].Value = 1.0
        $controls['PerLevelStatsMultiplier_Player[10]'].Value = 3.0
        $controls['PerLevelStatsMultiplier_DinoTamed[0]'].Value = 1.15
        $controls['PerLevelStatsMultiplier_DinoTamed[1]'].Value = 1.25
        $controls['PerLevelStatsMultiplier_DinoTamed[7]'].Value = 2.0
        $controls['PerLevelStatsMultiplier_DinoTamed[8]'].Value = 1.15
        $controls['DayCycleSpeedScale'].Value = 1.0
        $controls['DayTimeSpeedScale'].Value = 1.0
        $controls['NightTimeSpeedScale'].Value = 1.0
        $speedCheck.Checked = $true
    })
    $saveButton.Add_Click({
        try {
            if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
            [void](New-ConfigSnapshot 'progression-and-time')
            foreach ($entry in $entries) {
                $rawValue = $controls[$entry.Key].Value * [decimal]$entry.Base
                $textValue = $rawValue.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
                Set-IniSectionValue $entry.File $entry.Section $entry.Key $textValue
            }
            Set-CmdConfigValue 'ALLOW_SPEED_LEVELING' $speedCheck.Checked.ToString()
            if (Get-ServerProcess) { Show-Info 'Progression and world-time settings saved. Restart ASA when you want them to take effect.' }
            else { Show-Info 'Progression and world-time settings saved. They will be active at the next start.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-ModManager {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Cross-platform mods - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(680, 540)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $dialog.Controls.Add((New-Label 'Installed mod project IDs' 20 18 350 30 $Text 16))
    $dialog.Controls.Add((New-Label 'Only use CurseForge ASA mods marked cross-platform for PS5. Order can matter.' 22 52 620 36 $Muted 9))
    $list = New-Object Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(22, 94)
    $list.Size = New-Object Drawing.Size(420, 280)
    $list.BackColor = $InputColor
    $list.ForeColor = $Text
    $list.Font = New-Object Drawing.Font('Consolas', 11)
    $config = Read-CmdConfig
    if ($config['MODS']) { foreach ($id in $config['MODS'].Split(',')) { if ($id.Trim()) { [void]$list.Items.Add($id.Trim()) } } }
    $dialog.Controls.Add($list)

    $idBox = New-TextBox 22 390 260
    $dialog.Controls.Add($idBox)
    $addButton = New-Button 'Add project ID' 296 383 146 $Green
    $removeButton = New-Button 'Remove selected' 460 94 180 $Red
    $upButton = New-Button 'Move up' 460 149 180 ([Drawing.Color]::FromArgb(79, 99, 125))
    $downButton = New-Button 'Move down' 460 204 180 ([Drawing.Color]::FromArgb(79, 99, 125))
    $browseButton = New-Button 'Browse CurseForge' 460 259 180 ([Drawing.Color]::FromArgb(79, 99, 125))
    $saveButton = New-Button 'Save mod list' 460 328 180 $Blue
    $dialog.Controls.AddRange(@($addButton, $removeButton, $upButton, $downButton, $browseButton, $saveButton))
    $dialog.Controls.Add((New-Label 'Find Project ID in the About Project area on a CurseForge mod page.' 22 434 600 36 $Muted 9))

    $addButton.Add_Click({
        $id = $idBox.Text.Trim()
        if ($id -notmatch '^\d+$') { Show-ErrorBox 'Enter the numeric CurseForge Project ID.'; return }
        if ($list.Items.Contains($id)) { Show-Info 'That mod is already in the list.'; return }
        [void]$list.Items.Add($id)
        $idBox.Clear()
    })
    $removeButton.Add_Click({ if ($list.SelectedIndex -ge 0) { $list.Items.RemoveAt($list.SelectedIndex) } })
    $upButton.Add_Click({
        $index = $list.SelectedIndex
        if ($index -gt 0) { $item = $list.Items[$index]; $list.Items.RemoveAt($index); $list.Items.Insert($index - 1, $item); $list.SelectedIndex = $index - 1 }
    })
    $downButton.Add_Click({
        $index = $list.SelectedIndex
        if ($index -ge 0 -and $index -lt ($list.Items.Count - 1)) { $item = $list.Items[$index]; $list.Items.RemoveAt($index); $list.Items.Insert($index + 1, $item); $list.SelectedIndex = $index + 1 }
    })
    $browseButton.Add_Click({ Start-Process 'https://www.curseforge.com/ark-survival-ascended/mods' })
    $saveButton.Add_Click({
        try {
            $ids = @($list.Items | ForEach-Object { [string]$_ }) -join ','
            [void](New-ConfigSnapshot 'mod-list')
            Set-CmdConfigValue 'MODS' $ids
            $modsBox.Text = $ids
            if (Get-ServerProcess) { Show-Info 'Mod list saved. ASA downloads/updates these mods on the next restart.' }
            else { Show-Info 'Mod list saved. ASA downloads/updates these mods when it starts.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-WildDinoDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Wild dino settings - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(820, 800)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $heading = New-Label 'Wild dino population, difficulty and toughness' 20 16 650 34 $Text 17
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add((New-Label 'A wild dino wipe is needed for these changes to affect dinos already in the world (PS5 admin + performance help, or the AI Assistant).' 22 52 760 24 $Muted 9))

    $entries = @(
        @{ Key='DinoCountMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Dino population'; Default='1.0'; Min=0.1; Max=5.0; Explain='How many wild dinos spawn on the map overall. 1.0 is standard density.' },
        @{ Key='DinoCharacterHealthRecoveryMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Health regen speed'; Default='1.0'; Min=0.1; Max=20.0; Explain='How fast dinos regenerate lost health over time. Affects wild and tamed dinos together.' },
        @{ Key='SupplyCrateLootQualityMultiplier'; File=$GameUserSettings; Section='[ServerSettings]'; Label='Supply crate loot quality'; Default='1.0'; Min=0.5; Max=10.0; Explain='Higher gives better-quality loot in supply crates. Does not change how often crates spawn.' },
        @{ Key='PerLevelStatsMultiplier_DinoWild[0]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Wild dino health / level'; Default='1.0'; Min=0.1; Max=3.0; Explain='Health gained per wild dino level. Lower makes high-level wild dinos less tanky. 1.0 is vanilla.' },
        @{ Key='PerLevelStatsMultiplier_DinoWild[8]'; File=$GameIni; Section='[/Script/ShooterGame.ShooterGameMode]'; Label='Wild dino melee / level'; Default='1.0'; Min=0.1; Max=3.0; Explain='Melee damage gained per wild dino level. Lower makes high-level wild dinos hit less hard. 1.0 is vanilla.' }
    )

    $dialog.Controls.Add((New-Label 'Max wild dino level' 22 88 180 24 $Text 9))
    $difficultyBox = New-Object Windows.Forms.NumericUpDown
    $difficultyBox.Location = New-Object Drawing.Point(205, 86)
    $difficultyBox.Size = New-Object Drawing.Size(92, 26)
    $difficultyBox.DecimalPlaces = 2
    $difficultyBox.Increment = 0.5
    $difficultyBox.Minimum = 0.2
    $difficultyBox.Maximum = 5.0
    $difficultyBox.BackColor = $InputColor
    $difficultyBox.ForeColor = $Text
    $difficultyBox.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'OverrideOfficialDifficulty' '1.0') 1.0 $difficultyBox.Minimum $difficultyBox.Maximum
    $dialog.Controls.Add($difficultyBox)
    $difficultyExplain = New-Label ("Max wild dino level is roughly value x 30 = {0}. 5.0 is the official-server max (level 150)." -f [int]($difficultyBox.Value * 30)) 318 84 460 36 $Muted 8.5
    $dialog.Controls.Add($difficultyExplain)
    $difficultyBox.Add_ValueChanged({
        $difficultyExplain.Text = "Max wild dino level is roughly value x 30 = $([int]($difficultyBox.Value * 30)). 5.0 is the official-server max (level 150)."
    })

    $controls = @{}
    $y = 137
    foreach ($entry in $entries) {
        $dialog.Controls.Add((New-Label $entry.Label 22 $y 180 24 $Text 9))
        $number = New-Object Windows.Forms.NumericUpDown
        $number.Location = New-Object Drawing.Point(205, ($y - 2))
        $number.Size = New-Object Drawing.Size(92, 26)
        $number.DecimalPlaces = 2
        $number.Increment = 0.1
        $number.Minimum = [decimal]$entry.Min
        $number.Maximum = [decimal]$entry.Max
        $number.BackColor = $InputColor
        $number.ForeColor = $Text
        $current = Get-IniValueFromFile $entry.File $entry.Key $entry.Default
        $number.Value = Get-SafeDecimal $current ([decimal]$entry.Default) $number.Minimum $number.Maximum
        $controls[$entry.Key] = $number
        $dialog.Controls.Add($number)
        $dialog.Controls.Add((New-Label $entry.Explain 318 ($y - 2) 460 36 $Muted 8.5))
        $y += 45
    }

    $dialog.Controls.Add((New-Label 'Level distribution' 22 ($y + 8) 200 24 $Text 11))
    $y += 38
    $equalRadio = New-Object Windows.Forms.RadioButton
    $equalRadio.Text = 'Equal chance for every level (default)'
    $equalRadio.Location = New-Object Drawing.Point(22, $y)
    $equalRadio.Size = New-Object Drawing.Size(740, 26)
    $equalRadio.ForeColor = $Text
    $dialog.Controls.Add($equalRadio)
    $y += 30
    $highRadio = New-Object Windows.Forms.RadioButton
    $highRadio.Text = 'Skewed toward high levels'
    $highRadio.Location = New-Object Drawing.Point(22, $y)
    $highRadio.Size = New-Object Drawing.Size(740, 26)
    $highRadio.ForeColor = $Text
    $dialog.Controls.Add($highRadio)
    $y += 30
    $ragRadio = New-Object Windows.Forms.RadioButton
    $ragRadio.Text = 'Ragnarok-style (boosted high-level chance, but still skewed low overall; some levels never spawn)'
    $ragRadio.Location = New-Object Drawing.Point(22, $y)
    $ragRadio.Size = New-Object Drawing.Size(740, 26)
    $ragRadio.ForeColor = $Text
    $dialog.Controls.Add($ragRadio)
    $y += 34
    $dialog.Controls.Add((New-Label 'From the Custom Dino Levels mod (928708), if installed. Only one option applies at a time.' 22 $y 700 22 $Muted 8.5))
    $y += 30

    $currentHigh = (Get-IniValueFromFile $GameUserSettings 'WantsHighLevels' 'False') -ieq 'True'
    $currentRag = (Get-IniValueFromFile $GameUserSettings 'WantsRagLevels' 'False') -ieq 'True'
    if ($currentHigh) { $highRadio.Checked = $true }
    elseif ($currentRag) { $ragRadio.Checked = $true }
    else { $equalRadio.Checked = $true }

    $casualButton = New-Button 'Apply tonight''s casual-high preset' 22 ($y + 6) 280 ([Drawing.Color]::FromArgb(46, 150, 145))
    $saveButton = New-Button 'Save wild dino settings' 550 ($y + 6) 232 $Blue
    $dialog.Controls.AddRange(@($casualButton, $saveButton))

    $casualButton.Add_Click({
        $difficultyBox.Value = 5.0
        $controls['DinoCountMultiplier'].Value = 0.7
        $controls['DinoCharacterHealthRecoveryMultiplier'].Value = 4.0
        $controls['SupplyCrateLootQualityMultiplier'].Value = 2.0
        $controls['PerLevelStatsMultiplier_DinoWild[0]'].Value = 0.6
        $controls['PerLevelStatsMultiplier_DinoWild[8]'].Value = 0.6
        $highRadio.Checked = $true
    })

    $saveButton.Add_Click({
        try {
            if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
            [void](New-ConfigSnapshot 'wild-dino-settings')
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'OverrideOfficialDifficulty' $difficultyBox.Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
            foreach ($entry in $entries) {
                $value = $controls[$entry.Key].Value.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
                Set-IniSectionValue $entry.File $entry.Section $entry.Key $value
            }
            Set-IniSectionValue $GameUserSettings '[CustomLevelDistrib]' 'WantsEqualLevels' $equalRadio.Checked.ToString()
            Set-IniSectionValue $GameUserSettings '[CustomLevelDistrib]' 'WantsHighLevels' $highRadio.Checked.ToString()
            Set-IniSectionValue $GameUserSettings '[CustomLevelDistrib]' 'WantsRagLevels' $ragRadio.Checked.ToString()
            if (Get-ServerProcess) { Show-Info 'Wild dino settings saved. Restart ASA, then use a wild dino wipe to see the effect on existing dinos.' }
            else { Show-Info 'Wild dino settings saved. They will be active at the next start.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-ImportantSettingsDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Important settings - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(650, 690)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.Controls.Add((New-Label 'Important private-server settings' 20 18 450 32 $Text 16))

    $pveCheck = New-Object Windows.Forms.CheckBox
    $pveCheck.Text = 'PvE mode (friends cannot damage each other or their structures)'
    $pveCheck.Location = New-Object Drawing.Point(22, 68)
    $pveCheck.Size = New-Object Drawing.Size(570, 28)
    $pveCheck.ForeColor = $Text
    $pveCheck.Checked = (Get-IniValueFromFile $GameUserSettings 'ServerPVE' 'False') -ieq 'True'
    $dialog.Controls.Add($pveCheck)

    $flyerCheck = New-Object Windows.Forms.CheckBox
    $flyerCheck.Text = 'Allow flyers to carry wild creatures in PvE'
    $flyerCheck.Location = New-Object Drawing.Point(22, 100)
    $flyerCheck.Size = New-Object Drawing.Size(420, 28)
    $flyerCheck.ForeColor = $Text
    $flyerCheck.Checked = (Get-IniValueFromFile $GameUserSettings 'AllowFlyerCarryPvE' 'False') -ieq 'True'
    $dialog.Controls.Add($flyerCheck)

    $pickupCheck = New-Object Windows.Forms.CheckBox
    $pickupCheck.Text = 'Always allow placed structures to be picked up'
    $pickupCheck.Location = New-Object Drawing.Point(22, 132)
    $pickupCheck.Size = New-Object Drawing.Size(420, 28)
    $pickupCheck.ForeColor = $Text
    $pickupCheck.Checked = (Get-IniValueFromFile $GameUserSettings 'AlwaysAllowStructurePickup' 'True') -ieq 'True'
    $dialog.Controls.Add($pickupCheck)

    $dialog.Controls.Add((New-Label 'Join password' 22 179 150))
    $joinPassword = New-TextBox 180 176 270
    $joinPassword.UseSystemPasswordChar = $true
    $joinPassword.Text = Get-IniValueFromFile $GameUserSettings 'ServerPassword' ''
    $dialog.Controls.Add($joinPassword)
    $dialog.Controls.Add((New-Label 'Leave blank if the server name is private enough.' 180 207 400 22 $Muted 8.5))

    $dialog.Controls.Add((New-Label 'Admin password' 22 245 150))
    $adminPassword = New-TextBox 180 242 270
    $adminPassword.UseSystemPasswordChar = $true
    $adminPassword.Text = Get-IniValueFromFile $GameUserSettings 'ServerAdminPassword' ''
    $dialog.Controls.Add($adminPassword)

    $dialog.Controls.Add((New-Label 'Autosave minutes' 22 300 150))
    $autosave = New-Object Windows.Forms.NumericUpDown
    $autosave.Location = New-Object Drawing.Point(180, 297)
    $autosave.Size = New-Object Drawing.Size(90, 28)
    $autosave.Minimum = 5
    $autosave.Maximum = 60
    $autosave.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'AutoSavePeriodMinutes' '15') 15 $autosave.Minimum $autosave.Maximum
    $autosave.BackColor = $InputColor
    $autosave.ForeColor = $Text
    $dialog.Controls.Add($autosave)
    $dialog.Controls.Add((New-Label '15 minutes is a good balance between safety and brief save pauses.' 285 300 330 36 $Muted 8.5))

    $dialog.Controls.Add((New-Label 'Global tame cap' 22 352 150))
    $tameCap = New-Object Windows.Forms.NumericUpDown
    $tameCap.Location = New-Object Drawing.Point(180, 349)
    $tameCap.Size = New-Object Drawing.Size(110, 28)
    $tameCap.Minimum = 100
    $tameCap.Maximum = 5000
    $tameCap.Increment = 100
    $tameCap.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'MaxTamedDinos' '2500') 2500 $tameCap.Minimum $tameCap.Maximum
    $tameCap.BackColor = $InputColor
    $tameCap.ForeColor = $Text
    $dialog.Controls.Add($tameCap)
    $dialog.Controls.Add((New-Label 'Lower caps reduce late-game memory use. 1500-2500 is ample for a small group.' 305 346 305 48 $Muted 8.5))

    $noRespawnPenalty = New-Object Windows.Forms.CheckBox
    $noRespawnPenalty.Text = 'Disable the escalating PvP repeated-death respawn penalty'
    $noRespawnPenalty.Location = New-Object Drawing.Point(22, 405)
    $noRespawnPenalty.Size = New-Object Drawing.Size(520, 28)
    $noRespawnPenalty.ForeColor = $Text
    $noRespawnPenalty.Checked = (Get-IniValueFromFile $GameIni 'bIncreasePvPRespawnInterval' 'True') -ieq 'False'
    $dialog.Controls.Add($noRespawnPenalty)

    $dialog.Controls.Add((New-Label 'CS Simple Bed cooldown' 22 450 190))
    $simpleBedCooldown = New-Object Windows.Forms.NumericUpDown
    $simpleBedCooldown.Location = New-Object Drawing.Point(215, 447)
    $simpleBedCooldown.Size = New-Object Drawing.Size(90, 28)
    $simpleBedCooldown.Minimum = 0
    $simpleBedCooldown.Maximum = 600
    $simpleBedCooldown.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'SimpleBedCooldown' '30') 30 $simpleBedCooldown.Minimum $simpleBedCooldown.Maximum
    $simpleBedCooldown.BackColor = $InputColor
    $simpleBedCooldown.ForeColor = $Text
    $dialog.Controls.Add($simpleBedCooldown)
    $dialog.Controls.Add((New-Label 'seconds (30 = 10% of the normal 5 minutes; CS bed only)' 320 450 290 36 $Muted 8.5))

    $dialog.Controls.Add((New-Label 'CS Bunk Bed cooldown' 22 498 190))
    $modernBedCooldown = New-Object Windows.Forms.NumericUpDown
    $modernBedCooldown.Location = New-Object Drawing.Point(215, 495)
    $modernBedCooldown.Size = New-Object Drawing.Size(90, 28)
    $modernBedCooldown.Minimum = 0
    $modernBedCooldown.Maximum = 600
    $modernBedCooldown.Value = Get-SafeDecimal (Get-IniValueFromFile $GameUserSettings 'ModernBedCooldown' '12') 12 $modernBedCooldown.Minimum $modernBedCooldown.Maximum
    $modernBedCooldown.BackColor = $InputColor
    $modernBedCooldown.ForeColor = $Text
    $dialog.Controls.Add($modernBedCooldown)
    $dialog.Controls.Add((New-Label 'seconds (12 = 10% of the normal 2 minutes; CS bunk bed only)' 320 498 290 36 $Muted 8.5))

    $showPasswords = New-Object Windows.Forms.CheckBox
    $showPasswords.Text = 'Show passwords'
    $showPasswords.Location = New-Object Drawing.Point(470, 210)
    $showPasswords.Size = New-Object Drawing.Size(140, 28)
    $showPasswords.ForeColor = $Muted
    $dialog.Controls.Add($showPasswords)
    $showPasswords.Add_CheckedChanged({ $joinPassword.UseSystemPasswordChar = -not $showPasswords.Checked; $adminPassword.UseSystemPasswordChar = -not $showPasswords.Checked })

    $saveButton = New-Button 'Save important settings' 22 565 260 $Blue
    $cancelButton = New-Button 'Cancel' 300 565 150 ([Drawing.Color]::FromArgb(79, 99, 125))
    $dialog.Controls.AddRange(@($saveButton, $cancelButton))
    $cancelButton.Add_Click({ $dialog.Close() })
    $saveButton.Add_Click({
        try {
            if ($joinPassword.Text -and $joinPassword.Text -notmatch '^[A-Za-z0-9_-]{4,64}$') { throw 'Join password must use 4-64 letters, numbers, underscores, or hyphens.' }
            if ($adminPassword.Text -notmatch '^[A-Za-z0-9_-]{4,64}$') { throw 'Admin password must use 4-64 letters, numbers, underscores, or hyphens.' }
            if (-not (Ensure-ServerStoppedForConfigWrite)) { return }
            [void](New-ConfigSnapshot 'important-settings')
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'ServerPVE' $pveCheck.Checked.ToString()
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'AllowFlyerCarryPvE' $flyerCheck.Checked.ToString()
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'AlwaysAllowStructurePickup' $pickupCheck.Checked.ToString()
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'ServerPassword' $joinPassword.Text
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'ServerAdminPassword' $adminPassword.Text
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'AutoSavePeriodMinutes' ([string][int]$autosave.Value)
            Set-IniSectionValue $GameUserSettings '[ServerSettings]' 'MaxTamedDinos' ([string][int]$tameCap.Value)
            Set-IniSectionValue $GameIni '[/Script/ShooterGame.ShooterGameMode]' 'bIncreasePvPRespawnInterval' ((-not $noRespawnPenalty.Checked).ToString())
            Set-IniSectionValue $GameUserSettings '[CybersStructures]' 'SimpleBedCooldown' ([string][int]$simpleBedCooldown.Value)
            Set-IniSectionValue $GameUserSettings '[CybersStructures]' 'ModernBedCooldown' ([string][int]$modernBedCooldown.Value)
            if (Get-ServerProcess) { Show-Info 'Important settings saved. Restart ASA when you want them to take effect.' }
            else { Show-Info 'Important settings saved.' }
            $dialog.Close()
        }
        catch { Show-ErrorBox $_.Exception.Message }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-Ps5HelpDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'PS5 admin and balanced performance - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(760, 735)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $dialog.Controls.Add((New-Label 'PS5 admin console' 20 18 350 30 $Text 16))
    $dialog.Controls.Add((New-Label 'In ASA: Settings > Advanced > Console Access ON. Pause in-game, then use the Console control shown at lower-left (normally the PS5 touchpad).' 22 52 700 42 $Muted 9))
    $copyLogin = New-Button 'Copy admin login' 22 101 200 ([Drawing.Color]::FromArgb(117, 92, 190))
    $copySave = New-Button 'Copy SaveWorld' 236 101 180 ([Drawing.Color]::FromArgb(117, 92, 190))
    $copyDinos = New-Button 'Copy wild dino reset' 430 101 220 ([Drawing.Color]::FromArgb(117, 92, 190))
    $dialog.Controls.AddRange(@($copyLogin, $copySave, $copyDinos))

    $manageAdmins = New-Button 'Manage permanent admins' 22 151 250 $Blue
    $dialog.Controls.Add($manageAdmins)

    $dialog.Controls.Add((New-Label 'PS5 performance presets - no downloaded FPS mod' 20 215 620 30 $Text 15))
    $dialog.Controls.Add((New-Label 'Run a preset once in ASA Console Commands. ASA keeps it in command history for quick reuse. These are client-side and affect only the player who selects them.' 22 249 700 48 $Muted 9))
    $balanced = 'r.VolumetricCloud 0 | r.Water.SingleLayer.Reflection 0 | r.ContactShadows 0 | r.LightShaftQuality 0 | grass.DensityScale 0.5'
    $maximum = 'r.VolumetricCloud 0|r.VolumetricFog 0|r.Fog 0|r.Lumen.DiffuseIndirect.Allow 0|r.Lumen.Reflections.Allow 0|grass.Enable 0|r.Water.SingleLayer.Reflection 0|r.ShadowQuality 0'
    $visualReset = 'r.VolumetricCloud 1|r.VolumetricFog 1|r.Fog 1|r.Lumen.DiffuseIndirect.Allow 1|r.Lumen.Reflections.Allow 1|grass.Enable 1|r.Water.SingleLayer.Reflection 1|r.ShadowQuality 1'

    $maximumBox = New-Object Windows.Forms.TextBox
    $maximumBox.Location = New-Object Drawing.Point(22, 305)
    $maximumBox.Size = New-Object Drawing.Size(700, 82)
    $maximumBox.Multiline = $true
    $maximumBox.ReadOnly = $true
    $maximumBox.Text = $maximum
    $maximumBox.BackColor = $InputColor
    $maximumBox.ForeColor = $Text
    $maximumBox.Font = New-Object Drawing.Font('Consolas', 9)
    $dialog.Controls.Add($maximumBox)

    $copyMaximum = New-Button 'Copy YOUR maximum boost' 22 403 250 $Amber
    $copyBalanced = New-Button 'Copy balanced boost' 286 403 210 $Green
    $copyReset = New-Button 'Copy reset values' 510 403 190 ([Drawing.Color]::FromArgb(79, 99, 125))
    $dialog.Controls.AddRange(@($copyMaximum, $copyBalanced, $copyReset))

    $dialog.Controls.Add((New-Label 'What the maximum profile changes' 22 465 330 24 $Text 11))
    $dialog.Controls.Add((New-Label 'Removes clouds, volumetric and normal fog, Lumen indirect light/reflections, grass, water reflections, and shadows. Best FPS, but the largest visual downgrade.' 22 495 700 52 $Muted 9))
    $dialog.Controls.Add((New-Label 'Reset note' 22 557 180 24 $Text 11))
    $dialog.Controls.Add((New-Label 'Reset values turn each feature back on at level 1. Fully closing and reopening ASA is the only guaranteed way to restore Sony/Wildcard''s exact current defaults.' 22 585 700 48 $Muted 9))

    $copyLogin.Add_Click({ [Windows.Forms.Clipboard]::SetText('enablecheats ' + (Get-IniValueFromFile $GameUserSettings 'ServerAdminPassword' '')); Show-Info 'Admin login copied.' })
    $copySave.Add_Click({ [Windows.Forms.Clipboard]::SetText('cheat SaveWorld'); Show-Info 'SaveWorld command copied.' })
    $copyDinos.Add_Click({ [Windows.Forms.Clipboard]::SetText('cheat DestroyWildDinos'); Show-Info 'Wild dino reset command copied.' })
    $manageAdmins.Add_Click({ Show-AdminManager })
    $copyMaximum.Add_Click({ [Windows.Forms.Clipboard]::SetText($maximum); Show-Info 'Your exact maximum PS5 boost command was copied.' })
    $copyBalanced.Add_Click({ [Windows.Forms.Clipboard]::SetText($balanced); Show-Info 'Balanced visual preset copied.' })
    $copyReset.Add_Click({ [Windows.Forms.Clipboard]::SetText($visualReset); Show-Info 'Reset values copied. Fully restart ASA on PS5 for an exact factory visual reset.' })
    [void]$dialog.ShowDialog($form)
}

function Show-ServerAdvisor {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Offline server advisor - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(860, 720)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $heading = New-Label 'Offline server advisor' 20 16 500 34 $Text 17
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 17)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add((New-Label 'A read-only health check. It never changes Windows Firewall, your router, or server settings.' 22 52 790 24 $Muted 9))

    $summary = New-Label 'Scanning...' 22 82 790 34 $Amber 13
    $summary.Font = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $dialog.Controls.Add($summary)

    $reportBox = New-Object Windows.Forms.RichTextBox
    $reportBox.Location = New-Object Drawing.Point(22, 122)
    $reportBox.Size = New-Object Drawing.Size(800, 475)
    $reportBox.BackColor = $Panel
    $reportBox.ForeColor = $Text
    $reportBox.BorderStyle = 'FixedSingle'
    $reportBox.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $reportBox.ReadOnly = $true
    $reportBox.DetectUrls = $false
    $dialog.Controls.Add($reportBox)

    $refreshButton = New-Button 'Refresh scan' 22 614 170 $Green
    $copyButton = New-Button 'Copy report' 207 614 170 ([Drawing.Color]::FromArgb(117, 92, 190))
    $settingsButton = New-Button 'Important settings' 392 614 190 $Blue
    $closeButton = New-Button 'Close' 597 614 225 ([Drawing.Color]::FromArgb(79, 99, 125))
    $dialog.Controls.AddRange(@($refreshButton, $copyButton, $settingsButton, $closeButton))

    $refreshScan = {
        try {
            $dialog.Cursor = 'WaitCursor'
            $reportBox.Clear()
            $results = @(Get-ServerHealthItems)
            $blockers = @($results | Where-Object Level -eq 'BLOCKER').Count
            $warnings = @($results | Where-Object Level -eq 'WARN').Count
            $tips = @($results | Where-Object Level -eq 'TIP').Count
            if ($blockers -gt 0) {
                $summary.Text = "$blockers blocker(s), $warnings warning(s), $tips tip(s) - fix blockers before the next restart"
                $summary.ForeColor = $Red
            }
            elseif ($warnings -gt 0) {
                $summary.Text = "Ready with $warnings warning(s) and $tips tip(s)"
                $summary.ForeColor = $Amber
            }
            else {
                $summary.Text = "Ready - no blockers or warnings; $tips optional tip(s)"
                $summary.ForeColor = $Green
            }

            foreach ($item in $results) {
                $start = $reportBox.TextLength
                $reportBox.AppendText("[$($item.Level)]  $($item.Title)`r`n")
                $reportBox.Select($start, $reportBox.TextLength - $start)
                $reportBox.SelectionFont = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
                $reportBox.SelectionColor = switch ($item.Level) {
                    'OK' { $Green }
                    'TIP' { $Blue }
                    'WARN' { $Amber }
                    default { $Red }
                }
                $reportBox.Select($reportBox.TextLength, 0)
                $reportBox.SelectionFont = New-Object Drawing.Font('Segoe UI', 9.5)
                $reportBox.SelectionColor = $Muted
                $reportBox.AppendText($item.Detail + "`r`n`r`n")
            }
            $reportBox.Select(0, 0)
            $reportBox.ScrollToCaret()
        }
        catch {
            Show-ErrorBox ('Health scan failed safely: ' + $_.Exception.Message)
        }
        finally {
            $dialog.Cursor = 'Default'
        }
    }

    $refreshButton.Add_Click({ & $refreshScan })
    $copyButton.Add_Click({
        if ($reportBox.Text) {
            [Windows.Forms.Clipboard]::SetText($summary.Text + "`r`n`r`n" + $reportBox.Text)
            Show-Info 'The password-free health report was copied.'
        }
    })
    $settingsButton.Add_Click({ Show-ImportantSettingsDialog; & $refreshScan })
    $closeButton.Add_Click({ $dialog.Close() })

    & $refreshScan
    [void]$dialog.ShowDialog($form)
}

function Show-ServerFilesHelp {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Server files + quick guide - ASA Manager'
    $dialog.Size = New-Object Drawing.Size(900, 650)
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $Background
    $dialog.ForeColor = $Text
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false

    $dialog.Controls.Add((New-Label 'Server files + quick guide' 20 16 600 34 $Text 17))
    $dialog.Controls.Add((New-Label 'Choose a file to see what it controls. Use the manager for normal changes; edit INI files only for advanced settings.' 22 52 830 26 $Muted 9))

    $savedArks = Join-Path $Root 'server\ShooterGame\Saved\SavedArks'
    $entries = [ordered]@{
        'Launch settings (server-config.cmd)' = @{
            Path = $CmdConfig
            Detail = "Controls the server name, map, player limit, ports, local IP and active mod IDs used at startup.`r`n`r`nUse: change identity, map or mod list. Prefer Save basic settings or Manage mods in this manager."
            Safety = 'Advanced: a typing error can prevent startup.'
        }
        'General rates (GameUserSettings.ini)' = @{
            Path = $GameUserSettings
            Detail = "Controls XP, harvesting, taming, passive-tame interval, incoming damage, food/water drain, day/night rates, passwords and many server rules.`r`n`r`nUse: most normal server-rate changes. Prefer Guided rates or Important server settings."
            Safety = 'Safe with a backup; most changes require a restart.'
        }
        'Progression + breeding (Game.ini)' = @{
            Path = $GameIni
            Detail = "Controls player/dino points per level, breeding, imprinting, engrams, XP categories and custom crafting overrides.`r`n`r`nUse: advanced progression and recipe changes. Keep settings beneath the [/Script/ShooterGame.ShooterGameMode] header."
            Safety = 'Advanced: duplicate or malformed lines can be ignored by ASA.'
        }
        'Permanent admins (AllowedCheaterAccountIDs.txt)' = @{
            Path = $AdminWhitelist
            Detail = "One 32-character ASA EOS account ID per line. These accounts may receive permanent admin access.`r`n`r`nA PSN name is not an EOS ID. Temporary login still works with enablecheats followed by the admin password."
            Safety = 'Sensitive: do not share the IDs publicly.'
        }
        'World + character saves (SavedArks)' = @{
            Path = $savedArks
            Detail = "Contains the world, player, tribe and map save data. This is the progress you would lose after disk damage or a bad deletion.`r`n`r`nUse Safe backup in the manager instead of editing files here."
            Safety = 'Do not edit or delete while the server is running.'
        }
        'Server logs' = @{
            Path = $LogFolder
            Detail = "Startup, mod-loading, connection and runtime messages. Check the newest log when the server is missing, a mod fails or players disconnect.`r`n`r`nSearch for: Fatal, Error, Failed, advertising for join, and the relevant mod ID."
            Safety = 'Read-only troubleshooting; old logs may be safely archived.'
        }
        'Backups' = @{
            Path = $BackupsFolder
            Detail = "Timestamped recovery copies created by Safe backup. Keep several generations and occasionally copy one to another drive.`r`n`r`nRestore only while ASA is stopped."
            Safety = 'Safest recovery location.'
        }
    }

    $list = New-Object Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(22, 92)
    $list.Size = New-Object Drawing.Size(315, 390)
    $list.BackColor = $InputColor
    $list.ForeColor = $Text
    $list.Font = New-Object Drawing.Font('Segoe UI', 10)
    [void]$list.Items.AddRange([object[]]@($entries.Keys))
    $dialog.Controls.Add($list)

    $detail = New-Object Windows.Forms.RichTextBox
    $detail.Location = New-Object Drawing.Point(355, 92)
    $detail.Size = New-Object Drawing.Size(505, 390)
    $detail.BackColor = $Panel
    $detail.ForeColor = $Text
    $detail.BorderStyle = 'FixedSingle'
    $detail.Font = New-Object Drawing.Font('Segoe UI', 10)
    $detail.ReadOnly = $true
    $detail.DetectUrls = $false
    $dialog.Controls.Add($detail)

    $openButton = New-Button 'Open selected' 22 505 160 $Blue
    $folderButton = New-Button 'Open its folder' 194 505 160 ([Drawing.Color]::FromArgb(79, 99, 125))
    $copyButton = New-Button 'Copy path' 366 505 135 ([Drawing.Color]::FromArgb(79, 99, 125))
    $fullGuideButton = New-Button 'Open full guide' 513 505 160 ([Drawing.Color]::FromArgb(117, 92, 190))
    $closeButton = New-Button 'Close' 685 505 175 $Green
    $dialog.Controls.AddRange(@($openButton, $folderButton, $copyButton, $fullGuideButton, $closeButton))
    $dialog.Controls.Add((New-Label 'Fast search: open a text file in Notepad and press Ctrl+F. Make one change at a time, save, restart, then verify in game.' 22 560 835 30 $Amber 9))

    $getSelected = {
        if ($list.SelectedIndex -lt 0) { return $null }
        return $entries[[string]$list.SelectedItem]
    }
    $showSelected = {
        $entry = & $getSelected
        if (-not $entry) { return }
        $exists = Test-Path -LiteralPath $entry.Path
        $detail.Text = "WHAT IT DOES`r`n$($entry.Detail)`r`n`r`nSAFETY`r`n$($entry.Safety)`r`n`r`nPATH`r`n$($entry.Path)`r`n`r`nSTATUS`r`n" + $(if ($exists) { 'Found on this PC.' } else { 'Not created yet.' })
    }
    $list.Add_SelectedIndexChanged({ & $showSelected })
    $openButton.Add_Click({
        $entry = & $getSelected
        if (-not $entry) { return }
        if (-not (Test-Path -LiteralPath $entry.Path)) { Show-ErrorBox "Path not found:`n$($entry.Path)"; return }
        if (Test-Path -LiteralPath $entry.Path -PathType Container) { Start-Process explorer.exe -ArgumentList $entry.Path }
        else { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $entry.Path) }
    })
    $folderButton.Add_Click({
        $entry = & $getSelected
        if (-not $entry) { return }
        $folder = if (Test-Path -LiteralPath $entry.Path -PathType Container) { $entry.Path } else { Split-Path -Parent $entry.Path }
        if (Test-Path -LiteralPath $folder) { Start-Process explorer.exe -ArgumentList $folder }
        else { Show-ErrorBox "Folder not found:`n$folder" }
    })
    $copyButton.Add_Click({
        $entry = & $getSelected
        if ($entry) { [Windows.Forms.Clipboard]::SetText([string]$entry.Path); Show-Info 'Path copied.' }
    })
    $fullGuideButton.Add_Click({
        if (Test-Path -LiteralPath $GuidePath) { Start-Process $GuidePath }
        else { Show-ErrorBox "The offline guide is missing:`n$GuidePath" }
    })
    $closeButton.Add_Click({ $dialog.Close() })

    $list.SelectedIndex = 0
    [void]$dialog.ShowDialog($form)
}

function Update-Status {
    if ($TestMode) {
        $statusDot.ForeColor = $Amber
        $statusMain.Text = 'TEST MODE'
        $statusMain.ForeColor = $Amber
        $statusDetail.Text = 'Disposable configuration test. Server controls are locked.'
        foreach ($button in @($startButton, $stopButton, $restartButton, $updateButton, $backupButton)) { $button.Enabled = $false }
        if ($script:BasicSettingsDirty) {
            $pendingStatus.Text = 'UNSAVED CHANGES - click Save basic settings'
            $pendingStatus.ForeColor = $Amber
        }
        else {
            $pendingStatus.Text = 'Disposable configuration loaded; no unsaved changes.'
            $pendingStatus.ForeColor = $Muted
        }
        return
    }
    $process = Get-ServerProcess
    if ($process) {
        $statusDot.ForeColor = $Green
        $statusMain.Text = 'ONLINE'
        $statusMain.ForeColor = $Green
        $memory = [math]::Round($process.WorkingSet64 / 1GB, 1)
        $statusDetail.Text = "PID $($process.Id)  |  Memory $memory GB  |  PS5 crossplay enabled"
        $startButton.Enabled = $false
        $stopButton.Enabled = $true
    }
    else {
        $statusDot.ForeColor = $Red
        $statusMain.Text = 'OFFLINE'
        $statusMain.ForeColor = $Red
        $statusDetail.Text = 'The server is stopped.'
        $startButton.Enabled = $true
        $stopButton.Enabled = $false
    }

    if ([DateTime]::UtcNow -ge $script:NextSaveStatusRefresh) {
        $script:NextSaveStatusRefresh = [DateTime]::UtcNow.AddSeconds(30)
        $latestSave = Get-ChildItem (Join-Path $Root 'server\ShooterGame\Saved\SavedArks') -Filter '*.ark' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestSave) {
            $saveStatus.Text = 'Latest world save: ' + $latestSave.LastWriteTime.ToString('dd MMM yyyy  HH:mm:ss')
        }
    }

    if ($script:BasicSettingsDirty) {
        $pendingStatus.Text = 'UNSAVED CHANGES - click Save basic settings'
        $pendingStatus.ForeColor = $Amber
    }
    elseif ($process) {
        $pendingStatus.Text = 'Saved configuration is active or waiting for the next planned restart.'
        $pendingStatus.ForeColor = $Muted
    }
    else {
        $pendingStatus.Text = 'Configuration saved and ready for the next start.'
        $pendingStatus.ForeColor = $Muted
    }
}

if ($HealthCheckOnly) {
    $healthItems = @(Get-ServerHealthItems)
    foreach ($item in $healthItems) {
        Write-Output ("[{0}] {1}: {2}" -f $item.Level, $item.Title, $item.Detail)
    }
    if (@($healthItems | Where-Object Level -eq 'BLOCKER').Count -gt 0) { exit 2 }
    exit 0
}

$form = New-Object Windows.Forms.Form
$form.Text = if ($TestMode) { '[TEST MODE] Gustav''s ARK: Survival Ascended Server Manager' } else { 'Gustav''s ARK: Survival Ascended Server Manager' }
$form.Size = New-Object Drawing.Size(1040, 840)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Background
$form.ForeColor = $Text
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.MinimumSize = New-Object Drawing.Size(1040, 840)

$title = New-Label 'ARK: SURVIVAL ASCENDED' 24 18 500 40 $Text 20
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 20)
$form.Controls.Add($title)
$subtitle = New-Label 'Private PS5 crossplay server control panel' 27 56 500 24 $Muted 10
$form.Controls.Add($subtitle)
$aiAssistantButton = New-Button 'AI Assistant' 650 26 150 $Green
$guideButton = New-Button 'Files + guide' 814 26 165 ([Drawing.Color]::FromArgb(117, 92, 190))
$form.Controls.AddRange(@($aiAssistantButton, $guideButton))

$statusGroup = New-Group 'Server status' 24 92 978 92
$statusDot = New-Label 'O' 18 27 30 36 $Red 20
$statusMain = New-Label 'CHECKING' 54 29 140 30 $Amber 14
$statusMain.Font = New-Object Drawing.Font('Segoe UI Semibold', 14)
$statusDetail = New-Label 'Checking the ASA process...' 204 32 700 24 $Muted 10
$statusGroup.Controls.AddRange(@($statusDot, $statusMain, $statusDetail))
$form.Controls.Add($statusGroup)

$controlsGroup = New-Group 'Quick controls' 24 198 978 116
$startButton = New-Button 'Start server' 18 31 170 $Green
$stopButton = New-Button 'Safe stop' 202 31 170 $Red
$restartButton = New-Button 'Restart' 386 31 170 $Amber
$updateButton = New-Button 'Update + restart' 570 31 185 $Blue
$backupButton = New-Button 'Safe backup' 769 31 185 ([Drawing.Color]::FromArgb(117, 92, 190))
$controlsGroup.Controls.AddRange(@($startButton, $stopButton, $restartButton, $updateButton, $backupButton))
$form.Controls.Add($controlsGroup)

$settingsGroup = New-Group 'Easy server settings' 24 328 620 356
$settingsGroup.Controls.Add((New-Label 'Server name' 18 31 130))
$serverNameBox = New-TextBox 160 29 425
$settingsGroup.Controls.Add($serverNameBox)
$settingsGroup.Controls.Add((New-Label 'Map' 18 73 130))
$mapBox = New-Object Windows.Forms.ComboBox
$mapBox.Location = New-Object Drawing.Point(160, 71)
$mapBox.Size = New-Object Drawing.Size(260, 30)
$mapBox.DropDownStyle = 'DropDownList'
$mapBox.BackColor = $InputColor
$mapBox.ForeColor = $Text
$mapBox.Font = New-Object Drawing.Font('Segoe UI', 10)
[void]$mapBox.Items.AddRange([object[]]@($script:VerifiedMaps.Keys))
$settingsGroup.Controls.Add($mapBox)
$settingsGroup.Controls.Add((New-Label 'Max players' 438 73 95))
$playersBox = New-Object Windows.Forms.NumericUpDown
$playersBox.Location = New-Object Drawing.Point(535, 71)
$playersBox.Size = New-Object Drawing.Size(50, 28)
$playersBox.Minimum = 1
$playersBox.Maximum = 70
$playersBox.BackColor = $InputColor
$playersBox.ForeColor = $Text
$settingsGroup.Controls.Add($playersBox)

$settingsGroup.Controls.Add((New-Label 'XP rate' 18 116 130))
$xpBox = New-Object Windows.Forms.NumericUpDown
$xpBox.Location = New-Object Drawing.Point(160, 114)
$xpBox.Size = New-Object Drawing.Size(100, 28)
$xpBox.DecimalPlaces = 1
$xpBox.Increment = 0.5
$xpBox.Minimum = 0.1
$xpBox.Maximum = 100
$xpBox.BackColor = $InputColor
$xpBox.ForeColor = $Text
$settingsGroup.Controls.Add($xpBox)
$settingsGroup.Controls.Add((New-Label 'Harvest rate' 278 116 110))
$harvestBox = New-Object Windows.Forms.NumericUpDown
$harvestBox.Location = New-Object Drawing.Point(390, 114)
$harvestBox.Size = New-Object Drawing.Size(80, 28)
$harvestBox.DecimalPlaces = 1
$harvestBox.Increment = 0.5
$harvestBox.Minimum = 0.1
$harvestBox.Maximum = 100
$harvestBox.BackColor = $InputColor
$harvestBox.ForeColor = $Text
$settingsGroup.Controls.Add($harvestBox)
$settingsGroup.Controls.Add((New-Label 'Taming' 482 116 60))
$tamingBox = New-Object Windows.Forms.NumericUpDown
$tamingBox.Location = New-Object Drawing.Point(535, 114)
$tamingBox.Size = New-Object Drawing.Size(50, 28)
$tamingBox.DecimalPlaces = 1
$tamingBox.Increment = 0.5
$tamingBox.Minimum = 0.1
$tamingBox.Maximum = 100
$tamingBox.BackColor = $InputColor
$tamingBox.ForeColor = $Text
$settingsGroup.Controls.Add($tamingBox)

$settingsGroup.Controls.Add((New-Label 'Cross-platform mod IDs' 18 160 180))
$modsBox = New-TextBox 18 187 567
$settingsGroup.Controls.Add($modsBox)
$modHint = New-Label 'Comma-separated CurseForge project IDs. Leave blank for no mods.' 18 218 550 22 $Muted 9
$settingsGroup.Controls.Add($modHint)
$saveSettingsButton = New-Button 'Save basic settings' 18 247 132 $Blue
$manageModsButton = New-Button 'Manage mods' 158 247 132 ([Drawing.Color]::FromArgb(117, 92, 190))
$moreRatesButton = New-Button 'Guided rates' 298 247 132 $Green
$progressionButton = New-Button 'Stats + time' 438 247 148 $Amber
$settingsGroup.Controls.AddRange(@($saveSettingsButton, $manageModsButton, $moreRatesButton, $progressionButton))
$form.Controls.Add($settingsGroup)

$toolsGroup = New-Group 'Tools and PS5 admin' 660 328 342 356
$openLogsButton = New-Button 'Open server logs' 18 31 145 ([Drawing.Color]::FromArgb(79, 99, 125))
$openBackupsButton = New-Button 'Open backups' 177 31 145 ([Drawing.Color]::FromArgb(79, 99, 125))
$advisorButton = New-Button 'Run offline server advisor' 18 86 304 $Green
$importantButton = New-Button 'Important server settings' 18 141 304 $Blue
$ps5HelpButton = New-Button 'PS5 admin + performance help' 18 196 304 ([Drawing.Color]::FromArgb(117, 92, 190))
$openConfigButton = New-Button 'Custom crafting costs' 18 251 304 ([Drawing.Color]::FromArgb(79, 99, 125))
$wildDinoButton = New-Button 'Wild dino settings' 18 306 304 ([Drawing.Color]::FromArgb(46, 150, 145))
$toolsGroup.Controls.AddRange(@($openLogsButton, $openBackupsButton, $advisorButton, $importantButton, $ps5HelpButton, $openConfigButton, $wildDinoButton))
$form.Controls.Add($toolsGroup)

$saveStatus = New-Label 'Latest world save: checking...' 28 702 600 24 $Muted 9
$form.Controls.Add($saveStatus)
$safetyNote = New-Label 'Firewall/router settings are intentionally not controlled here.' 650 702 350 24 $Muted 9
$safetyNote.TextAlign = 'MiddleRight'
$form.Controls.Add($safetyNote)
$pendingStatus = New-Label 'Checking for unsaved changes...' 28 733 970 24 $Muted 9
$pendingStatus.TextAlign = 'MiddleCenter'
$form.Controls.Add($pendingStatus)

$startButton.Add_Click({
    try { Start-Server } catch { Show-ErrorBox $_.Exception.Message }
})

$stopButton.Add_Click({
    if (Ask-YesNo 'This safely saves and stops the server. Any connected players will be disconnected. Continue?') {
        try { Stop-ServerSafe; Update-Status } catch { Show-ErrorBox $_.Exception.Message }
    }
})

$restartButton.Add_Click({
    if (Ask-YesNo 'Restarting disconnects all players for about one minute. Continue?') {
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $RestartBat) -WorkingDirectory $Root -WindowStyle Hidden
            $statusDetail.Text = 'Restart requested...'
        }
        catch { Show-ErrorBox $_.Exception.Message }
    }
})

$updateButton.Add_Click({
    if (Ask-YesNo 'This safely stops ASA, validates the official Steam App 2430930 update, and restarts it. Players will be disconnected. A progress window will open. Continue?' 'Update ASA server') {
        try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $UpdatePs1 -WorkingDirectory $Root -WindowStyle Normal } catch { Show-ErrorBox $_.Exception.Message }
    }
})

$backupButton.Add_Click({
    if (Ask-YesNo 'This creates a consistent save backup. If ASA is running, it will safely stop, back up, and restart automatically. Continue?' 'Safe server backup') {
        try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BackupPs1 -WorkingDirectory $Root -WindowStyle Normal } catch { Show-ErrorBox $_.Exception.Message }
    }
})

$saveSettingsButton.Add_Click({
    try { Save-Settings } catch { Show-ErrorBox $_.Exception.Message }
})
$manageModsButton.Add_Click({ Show-ModManager; Load-Settings })
$moreRatesButton.Add_Click({ Show-RatesDialog; Load-Settings })
$progressionButton.Add_Click({ Show-ProgressionDialog })
$openLogsButton.Add_Click({ if (Test-Path $LogFolder) { Start-Process explorer.exe $LogFolder } })
$openBackupsButton.Add_Click({ if (-not (Test-Path $BackupsFolder)) { [void](New-Item -ItemType Directory -Path $BackupsFolder) }; Start-Process explorer.exe $BackupsFolder })
$openConfigButton.Add_Click({ Show-CraftingCostsDialog })
$advisorButton.Add_Click({ Show-ServerAdvisor })
$importantButton.Add_Click({ Show-ImportantSettingsDialog })
$wildDinoButton.Add_Click({ Show-WildDinoDialog })
$ps5HelpButton.Add_Click({ Show-Ps5HelpDialog })
$aiAssistantButton.Add_Click({
    $aiPanel = Join-Path $Root 'ASA-AI-Panel.ps1'
    if (-not (Test-Path -LiteralPath $aiPanel)) {
        Show-ErrorBox "AI Assistant panel is missing:`n$aiPanel"
        return
    }
    try { & $aiPanel }
    catch { Show-ErrorBox ('AI Assistant failed safely: ' + $_.Exception.Message) }
})
$guideButton.Add_Click({ Show-ServerFilesHelp })

$toolTip = New-Object Windows.Forms.ToolTip
$toolTip.SetToolTip($xpBox, 'Higher values award more experience. Your balanced private-server preset is 4.0.')
$toolTip.SetToolTip($harvestBox, 'Higher values give more resources per harvest hit. Your balanced private-server preset is 5.0.')
$toolTip.SetToolTip($tamingBox, 'Higher values make taming finish faster. Your balanced private-server preset is 12.0.')
$toolTip.SetToolTip($modsBox, 'Use numeric CurseForge ASA Project IDs separated by commas. The Manage Mods button is easier.')
$toolTip.SetToolTip($mapBox, 'Uses exact released ASA level names. Aberration is Aberration_WP. Changing maps keeps the old map save in its own folder.')
$toolTip.SetToolTip($advisorButton, 'Runs a password-safe, read-only check of ASA files, crossplay, resources, rates, mods, networking, and backups.')
$toolTip.SetToolTip($wildDinoButton, 'Controls wild dino population density, max level, level distribution, per-level toughness, health regen, and loot quality.')
$toolTip.SetToolTip($aiAssistantButton, 'Opens the local Ollama AI Assistant. It acts immediately on allow-listed settings and server actions (start/stop/restart/update/backup).')
$toolTip.SetToolTip($guideButton, 'Explains every important ASA server file and opens the selected file or folder directly.')

$script:BasicSettingsDirty = $false
$script:LoadingBasicSettings = $false
$script:NextSaveStatusRefresh = [DateTime]::MinValue
$markBasicSettingsDirty = {
    if (-not $script:LoadingBasicSettings) { $script:BasicSettingsDirty = $true }
}
$serverNameBox.Add_TextChanged($markBasicSettingsDirty)
$mapBox.Add_SelectedIndexChanged($markBasicSettingsDirty)
$playersBox.Add_ValueChanged($markBasicSettingsDirty)
$modsBox.Add_TextChanged($markBasicSettingsDirty)
$xpBox.Add_ValueChanged($markBasicSettingsDirty)
$harvestBox.Add_ValueChanged($markBasicSettingsDirty)
$tamingBox.Add_ValueChanged($markBasicSettingsDirty)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })

try {
    Load-Settings
    Update-Status
    $timer.Start()
    [void]$form.ShowDialog()
}
catch {
    Show-ErrorBox $_.Exception.Message
}
finally {
    $timer.Stop()
    $timer.Dispose()
    if ($script:ManagerMutex) {
        try { $script:ManagerMutex.ReleaseMutex() } catch { }
        $script:ManagerMutex.Dispose()
    }
}
