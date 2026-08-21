param(
    [string]$Prompt,
    [string]$Model = 'qwen3:8b',
    [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
)

$ErrorActionPreference = 'Stop'

# Read-only AI proposal engine for ASA Manager.
# This file NEVER writes Game.ini, GameUserSettings.ini, server-config.cmd, or any other server file.
# It only asks local Ollama for structured setting proposals and validates them against this allow-list.
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
        "- $key: range $($meta.Min) to $($meta.Max). $($meta.Note)"
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
            $rejected.Add("Invalid numeric value for $key: $rawValue")
            continue
        }

        if ($value -lt [decimal]$meta.Min -or $value -gt [decimal]$meta.Max) {
            $rejected.Add("Out-of-range value for $key: $value (allowed $($meta.Min)-$($meta.Max))")
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
