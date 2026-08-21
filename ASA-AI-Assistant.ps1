param(
    [string]$Prompt,
    [string]$Model = 'qwen3:8b',
    [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
)

$ErrorActionPreference = 'Stop'

# The Ollama/model path is proposal-only and never receives filesystem access.
# Deterministic helpers below may apply only allow-listed settings to two fixed INI files.
$script:AllowedSettings = [ordered]@{
    XPMultiplier                         = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Overall XP multiplier.' }
    HarvestAmountMultiplier              = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Resources gathered per hit.' }
    TamingSpeedMultiplier                = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Higher makes taming complete faster.' }
    PassiveTameIntervalMultiplier        = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.05; Max=10.0;  Note='Lower shortens the wait between passive tame feeds.' }
    PlayerResistanceMultiplier           = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=5.0;   Note='Lower means players take less incoming damage.' }
    ResourcesRespawnPeriodMultiplier     = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower makes resources respawn sooner.' }
    PlayerCharacterFoodDrainMultiplier   = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower means hunger drains more slowly.' }
    PlayerCharacterWaterDrainMultiplier  = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower means thirst drains more slowly.' }
    MatingIntervalMultiplier             = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.01; Max=10.0;  Note='Lower lets creatures mate again sooner.' }
    MatingSpeedMultiplier                = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher fills the mating progress bar faster.' }
    EggHatchSpeedMultiplier              = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes fertilized eggs hatch faster.' }
    BabyMatureSpeedMultiplier            = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes babies mature faster.' }
    BabyCuddleIntervalMultiplier         = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.01; Max=10.0;  Note='Lower requests imprint care more often.' }
    BabyImprintAmountMultiplier          = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher gives more imprint progress per care.' }
    CropGrowthSpeedMultiplier            = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes crops grow faster.' }
    DayCycleSpeedScale                   = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Higher makes the whole day/night cycle pass faster.' }
    DayTimeSpeedScale                    = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower makes daylight last longer.' }
    NightTimeSpeedScale                  = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Higher makes nighttime pass faster.' }
}

function Get-AsaAiAllowedSettingText {
    $lines = foreach ($key in $script:AllowedSettings.Keys) {
        $meta = $script:AllowedSettings[$key]
        "- ${key}: range $($meta.Min) to $($meta.Max). $($meta.Note)"
    }
    return ($lines -join "`n")
}

function ConvertTo-AsaValidatedProposal {
    param([Parameter(Mandatory)]$RawProposal)

    $validated = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[string]

    foreach ($change in @($RawProposal.changes)) {
        $key = [string]$change.key
        if (-not $script:AllowedSettings.Contains($key)) {
            $rejected.Add("Unknown or blocked setting: $key")
            continue
        }

        $meta = $script:AllowedSettings[$key]
        $rawValue = [string]$change.value
        [decimal]$value = 0
        $parsed = [decimal]::TryParse(
            $rawValue,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )

        if (-not $parsed) {
            $rejected.Add("Invalid numeric value for ${key}: $rawValue")
            continue
        }

        if ($value -lt [decimal]$meta.Min -or $value -gt [decimal]$meta.Max) {
            $rejected.Add("Out-of-range value for ${key}: $value (allowed $($meta.Min)-$($meta.Max))")
            continue
        }

        $validated.Add([pscustomobject]@{
            Key        = $key
            Value      = $value
            TargetFile = [string]$meta.TargetFile
            Section    = [string]$meta.Section
            Reason     = [string]$change.reason
        })
    }

    return [pscustomobject]@{
        Summary  = [string]$RawProposal.summary
        Changes  = $validated.ToArray()
        Rejected = $rejected.ToArray()
        ReadOnly = $true
    }
}

function Test-AsaAiApplyProposal {
    param([Parameter(Mandatory)]$Proposal)

    $proposalChanges = @($Proposal.Changes)
    if ($proposalChanges.Count -eq 0) {
        return [pscustomobject]@{
            Success = $false
            Changes = @()
            Error   = 'Proposal must contain at least one change.'
        }
    }

    $seenKeys = @{}
    $changes = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($change in $proposalChanges) {
        $key = [string]$change.Key
        if ([string]::IsNullOrWhiteSpace($key)) {
            $errors.Add('A proposed setting has no key.')
            continue
        }

        if ($seenKeys.ContainsKey($key)) {
            $errors.Add("Duplicate key: ${key}")
            continue
        }
        $seenKeys[$key] = $true

        if (-not $script:AllowedSettings.Contains($key)) {
            $errors.Add("Unknown or blocked setting: ${key}")
            continue
        }

        $meta = $script:AllowedSettings[$key]
        $targetFile = [string]$meta.TargetFile
        $section = [string]$meta.Section
        $metadataAllowed = (
            ($targetFile -ceq 'GameUserSettings.ini' -and $section -ceq '[ServerSettings]') -or
            ($targetFile -ceq 'Game.ini' -and $section -ceq '[/Script/ShooterGame.ShooterGameMode]')
        )
        if (-not $metadataAllowed) {
            $errors.Add("Blocked metadata for setting: ${key}")
            continue
        }

        $rawValue = [string]$change.Value
        [decimal]$value = 0
        $parsed = [decimal]::TryParse(
            $rawValue,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )

        if (-not $parsed) {
            $errors.Add("Invalid numeric value for ${key}: $rawValue")
            continue
        }

        if ($value -lt [decimal]$meta.Min -or $value -gt [decimal]$meta.Max) {
            $errors.Add("Out-of-range value for ${key}: $value (allowed $($meta.Min)-$($meta.Max))")
            continue
        }

        $changes.Add([pscustomobject]@{
            Key        = $key
            Value      = $value
            TargetFile = $targetFile
            Section    = $section
        })
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Success = $false
            Changes = @()
            Error   = ($errors.ToArray() -join "`n")
        }
    }

    return [pscustomobject]@{
        Success = $true
        Changes = $changes.ToArray()
        Error   = ''
    }
}

function Set-AsaIniValueInMemory {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $copy = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        [void]$copy.Add([string]$line)
    }

    $sectionIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -ieq $Section) {
            $sectionIndexes.Add($i)
        }
    }

    if ($sectionIndexes.Count -eq 0) {
        throw "Required INI section not found: $Section"
    }
    if ($sectionIndexes.Count -gt 1) {
        throw "Duplicate INI section is ambiguous: $Section"
    }

    $sectionIndex = $sectionIndexes[0]
    $nextSectionIndex = $copy.Count
    for ($i = $sectionIndex + 1; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -match '^\[[^\]]+\]$') {
            $nextSectionIndex = $i
            break
        }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $keyIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = $sectionIndex + 1; $i -lt $nextSectionIndex; $i++) {
        if ($copy[$i] -match $keyPattern) {
            $keyIndexes.Add($i)
        }
    }

    if ($keyIndexes.Count -gt 1) {
        throw "Duplicate INI key is ambiguous in ${Section}: $Key"
    }

    $replacement = $Key + '=' + $Value
    if ($keyIndexes.Count -eq 1) {
        $copy[$keyIndexes[0]] = $replacement
    }
    else {
        $copy.Insert($nextSectionIndex, $replacement)
    }

    return [string[]]$copy.ToArray()
}

function Get-AsaAiFixedConfigPaths {
    $configRoot = Join-Path $PSScriptRoot 'server\ShooterGame\Saved\Config\WindowsServer'
    return [pscustomobject]@{
        GameUserSettings = Join-Path $configRoot 'GameUserSettings.ini'
        GameIni          = Join-Path $configRoot 'Game.ini'
        BackupRoot       = Join-Path $PSScriptRoot 'backups\AI-Config'
    }
}

function New-AsaAiPreparedApply {
    param([Parameter(Mandatory)]$Proposal)

    $validated = Test-AsaAiApplyProposal -Proposal $Proposal
    if (-not $validated.Success) {
        return [pscustomobject]@{
            Success = $false
            Error   = $validated.Error
            Changes = @()
        }
    }

    $paths = Get-AsaAiFixedConfigPaths
    if (-not [IO.File]::Exists($paths.GameUserSettings) -or -not [IO.File]::Exists($paths.GameIni)) {
        return [pscustomobject]@{
            Success = $false
            Error   = 'Both GameUserSettings.ini and Game.ini must exist before applying AI settings.'
            Changes = @()
        }
    }

    try {
        [string[]]$gameUserLines = [IO.File]::ReadAllLines($paths.GameUserSettings)
        [string[]]$gameIniLines = [IO.File]::ReadAllLines($paths.GameIni)
        $writeGameUserSettings = $false
        $writeGameIni = $false

        foreach ($change in $validated.Changes) {
            $valueText = ([decimal]$change.Value).ToString([Globalization.CultureInfo]::InvariantCulture)
            if ($change.TargetFile -ceq 'GameUserSettings.ini') {
                $gameUserLines = Set-AsaIniValueInMemory -Lines $gameUserLines -Section $change.Section -Key $change.Key -Value $valueText
                $writeGameUserSettings = $true
            }
            elseif ($change.TargetFile -ceq 'Game.ini') {
                $gameIniLines = Set-AsaIniValueInMemory -Lines $gameIniLines -Section $change.Section -Key $change.Key -Value $valueText
                $writeGameIni = $true
            }
            else {
                throw "Blocked target file for setting: $($change.Key)"
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Error   = $_.Exception.Message
            Changes = @()
        }
    }

    return [pscustomobject]@{
        Success               = $true
        Error                 = ''
        Changes               = $validated.Changes
        GameUserSettingsPath  = $paths.GameUserSettings
        GameIniPath           = $paths.GameIni
        BackupRoot            = $paths.BackupRoot
        GameUserSettingsLines = $gameUserLines
        GameIniLines          = $gameIniLines
        WriteGameUserSettings = $writeGameUserSettings
        WriteGameIni          = $writeGameIni
    }
}

function Invoke-AsaAiApplyProposal {
    param([Parameter(Mandatory)]$Proposal)

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA is running. Stop the server before applying AI settings.'
            BackupPath = ''
        }
    }

    $prepared = New-AsaAiPreparedApply -Proposal $Proposal
    if (-not $prepared.Success) {
        return [pscustomobject]@{
            Success    = $false
            Message    = $prepared.Error
            BackupPath = ''
        }
    }

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA started while settings were being prepared. Nothing was written.'
            BackupPath = ''
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
    $backupPath = Join-Path $prepared.BackupRoot ($timestamp + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $backupGameUserSettings = Join-Path $backupPath 'GameUserSettings.ini'
    $backupGameIni = Join-Path $backupPath 'Game.ini'

    try {
        [void][IO.Directory]::CreateDirectory($backupPath)
        [IO.File]::Copy($prepared.GameUserSettingsPath, $backupGameUserSettings, $false)
        [IO.File]::Copy($prepared.GameIniPath, $backupGameIni, $false)

        if (([IO.FileInfo]$prepared.GameUserSettingsPath).Length -ne ([IO.FileInfo]$backupGameUserSettings).Length) {
            throw 'GameUserSettings.ini backup verification failed.'
        }
        if (([IO.FileInfo]$prepared.GameIniPath).Length -ne ([IO.FileInfo]$backupGameIni).Length) {
            throw 'Game.ini backup verification failed.'
        }
    }
    catch {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'Backup failed; no configuration files were written. ' + $_.Exception.Message
            BackupPath = $backupPath
        }
    }

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA started before writing. Backups exist, but no configuration files were written.'
            BackupPath = $backupPath
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writeItems = New-Object System.Collections.Generic.List[object]

    if ($prepared.WriteGameUserSettings) {
        $writeItems.Add([pscustomobject]@{
            Target = $prepared.GameUserSettingsPath
            Lines  = $prepared.GameUserSettingsLines
            Backup = $backupGameUserSettings
        })
    }
    if ($prepared.WriteGameIni) {
        $writeItems.Add([pscustomobject]@{
            Target = $prepared.GameIniPath
            Lines  = $prepared.GameIniLines
            Backup = $backupGameIni
        })
    }

    $tempPaths = New-Object System.Collections.Generic.List[string]
    $replaceBackups = New-Object System.Collections.Generic.List[string]
    $writeStarted = $false

    try {
        foreach ($item in $writeItems) {
            $directory = Split-Path -Parent $item.Target
            $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($item.Target) + '.' + [guid]::NewGuid().ToString('N') + '.ai.tmp')
            [IO.File]::WriteAllLines($tempPath, [string[]]$item.Lines, $utf8NoBom)
            $item | Add-Member -NotePropertyName TempPath -NotePropertyValue $tempPath
            $tempPaths.Add($tempPath)
        }

        foreach ($item in $writeItems) {
            if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
                throw 'ASA started during the apply operation.'
            }

            $replaceBackup = Join-Path (Split-Path -Parent $item.Target) ('.' + [IO.Path]::GetFileName($item.Target) + '.' + [guid]::NewGuid().ToString('N') + '.replace-backup.tmp')
            $replaceBackups.Add($replaceBackup)
            $writeStarted = $true
            [IO.File]::Replace($item.TempPath, $item.Target, $replaceBackup, $true)
        }
    }
    catch {
        $applyError = $_.Exception.Message
        $rollbackErrors = New-Object System.Collections.Generic.List[string]

        if ($writeStarted) {
            foreach ($pair in @(
                @{ Target = $prepared.GameUserSettingsPath; Backup = $backupGameUserSettings },
                @{ Target = $prepared.GameIniPath; Backup = $backupGameIni }
            )) {
                try {
                    $restoreTemp = Join-Path (Split-Path -Parent $pair.Target) ('.' + [IO.Path]::GetFileName($pair.Target) + '.' + [guid]::NewGuid().ToString('N') + '.restore.tmp')
                    [IO.File]::Copy($pair.Backup, $restoreTemp, $false)
                    $tempPaths.Add($restoreTemp)
                    $restoreDiscard = Join-Path (Split-Path -Parent $pair.Target) ('.' + [IO.Path]::GetFileName($pair.Target) + '.' + [guid]::NewGuid().ToString('N') + '.restore-backup.tmp')
                    $replaceBackups.Add($restoreDiscard)
                    [IO.File]::Replace($restoreTemp, $pair.Target, $restoreDiscard, $true)
                }
                catch {
                    $rollbackErrors.Add($_.Exception.Message)
                }
            }
        }

        $message = 'Apply failed. '
        if ($writeStarted -and $rollbackErrors.Count -eq 0) {
            $message += 'Both INI files were restored from the snapshot. '
        }
        elseif ($writeStarted) {
            $message += 'Automatic rollback had an error; use the snapshot path shown below to restore manually. '
        }
        else {
            $message += 'No configuration file was replaced. '
        }
        $message += $applyError

        return [pscustomobject]@{
            Success    = $false
            Message    = $message
            BackupPath = $backupPath
        }
    }
    finally {
        foreach ($path in @($tempPaths.ToArray()) + @($replaceBackups.ToArray())) {
            if ($path -and [IO.File]::Exists($path)) {
                try { [IO.File]::Delete($path) } catch { }
            }
        }
    }

    return [pscustomobject]@{
        Success    = $true
        Message    = "Applied $($prepared.Changes.Count) validated setting(s)."
        BackupPath = $backupPath
        Changes    = $prepared.Changes
    }
}

function Get-AsaAiProposal {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model = 'qwen3:8b',
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
    )

    $allowedKeys = [object[]]@($script:AllowedSettings.Keys)
    $schema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{
            summary = @{ type = 'string' }
            changes = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        key    = @{ type = 'string'; enum = $allowedKeys }
                        value  = @{ type = 'string' }
                        reason = @{ type = 'string' }
                    }
                    required = @('key','value','reason')
                }
            }
        }
        required = @('summary','changes')
    }

    $allowedText = Get-AsaAiAllowedSettingText
    $systemPrompt = @"
You are the read-only settings assistant for a private ARK: Survival Ascended dedicated server.
You may ONLY propose settings from the allow-list below. Never propose shell commands, PowerShell, file operations, passwords, paths, mods, firewall changes, deletes, or arbitrary INI keys.
Return only JSON matching the supplied schema.
Every numeric value must be a plain invariant decimal string such as "4", "0.5", or "12.0". Do not include x, %, units, or explanatory text in value.
If the request cannot be satisfied using only the allow-list, return an empty changes array and explain why in summary.
When a user asks for shorter nights, increase NightTimeSpeedScale. When a user asks for longer days, decrease DayTimeSpeedScale.

Allowed settings:
$allowedText
"@

    $body = @{
        model = $Model
        stream = $false
        format = $schema
        options = @{ temperature = 0 }
        messages = @(
            @{ role = 'system'; content = $systemPrompt },
            @{ role = 'user'; content = $Prompt }
        )
    }

    $uri = $OllamaBaseUrl.TrimEnd('/') + '/api/chat'
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 20)
    }
    catch {
        throw "Could not reach local Ollama at $uri. Start Ollama and confirm the model '$Model' is installed. $($_.Exception.Message)"
    }

    $content = [string]$response.message.content
    if (-not $content) {
        throw 'Ollama returned no structured response content.'
    }

    try {
        $rawProposal = $content | ConvertFrom-Json
    }
    catch {
        throw "Ollama returned invalid JSON. No changes were made. Raw response: $content"
    }

    return ConvertTo-AsaValidatedProposal -RawProposal $rawProposal
}

if ($Prompt) {
    Get-AsaAiProposal -Prompt $Prompt -Model $Model -OllamaBaseUrl $OllamaBaseUrl | ConvertTo-Json -Depth 8
}
