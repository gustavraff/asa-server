$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CmdConfig = Join-Path $ProjectRoot 'server-config.cmd'
$BackupsFolder = Join-Path $ProjectRoot 'backups'

function Read-SafeCmdConfig {
    $values = @{}
    if (-not (Test-Path -LiteralPath $CmdConfig)) { return $values }
    $raw = [IO.File]::ReadAllText($CmdConfig)
    foreach ($match in [regex]::Matches($raw, '(?m)^set\s+"(?<key>[A-Z_]+)=(?<value>.*)"\s*$')) {
        $key = $match.Groups['key'].Value
        if ($key -in @('SERVER_NAME','MAP','MAX_PLAYERS','MODS')) { $values[$key] = $match.Groups['value'].Value }
    }
    return $values
}

$config = Read-SafeCmdConfig
$server = Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
$drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($ProjectRoot).TrimEnd(':\'))
$latestBackup = Get-ChildItem -LiteralPath $BackupsFolder -Directory -Filter 'ASA_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$totalMemoryGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeMemoryGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$memoryPercent = if ($totalMemoryGb -gt 0) { [math]::Round((($totalMemoryGb - $freeMemoryGb) / $totalMemoryGb) * 100, 0) } else { 0 }
$mods = if ($config.MODS) { @($config.MODS -split ',' | Where-Object { $_ }) } else { @() }
$mapNames = @{ Aberration_WP='Aberration'; TheIsland_WP='The Island'; ScorchedEarth_WP='Scorched Earth'; TheCenter_WP='The Center'; Extinction_WP='Extinction'; Ragnarok_WP='Ragnarok' }
$mapKey = [string]$config.MAP

[ordered]@{
    timestamp=(Get-Date).ToString('o'); readOnly=$true
    server=[ordered]@{ running=[bool]$server; pid=if($server){$server.Id}else{$null}; privateMemoryGb=if($server){[math]::Round($server.PrivateMemorySize64/1GB,1)}else{0}; name=if($config.SERVER_NAME){[string]$config.SERVER_NAME}else{'ASA Server'}; map=if($mapNames.ContainsKey($mapKey)){$mapNames[$mapKey]}elseif($mapKey){$mapKey}else{'Unknown'}; mapId=$mapKey; maxPlayers=if($config.MAX_PLAYERS -match '^\d+$'){[int]$config.MAX_PLAYERS}else{$null}; modCount=$mods.Count }
    host=[ordered]@{ cpuPercent=[math]::Round([double]$cpu.Average,0); memoryPercent=$memoryPercent; memoryUsedGb=[math]::Round($totalMemoryGb-$freeMemoryGb,1); memoryTotalGb=$totalMemoryGb; diskFreeGb=[math]::Round($drive.Free/1GB,1) }
    backup=if($latestBackup){[ordered]@{found=$true;timestamp=$latestBackup.LastWriteTime.ToString('o');name=$latestBackup.Name}}else{[ordered]@{found=$false;timestamp=$null;name=$null}}
} | ConvertTo-Json -Depth 6 -Compress
