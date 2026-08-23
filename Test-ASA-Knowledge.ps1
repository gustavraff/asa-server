# Focused, fast unit tests for the local ASA settings knowledge base and
# diagnostics engine (ASA-AI-Knowledge.ps1). No UI, no Ollama required to
# pass -- these test the deterministic retrieval/validation layer only.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File Test-ASA-Knowledge.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $root 'ASA-AI-Assistant.ps1')

$script:TestFailures = New-Object System.Collections.Generic.List[string]
$script:TestPassCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:TestPassCount++
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
    else {
        $script:TestFailures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Get-FindingsFor {
    param($Result, [string]$Key, [string]$Category)
    # Leading comma keeps this an array across the function-return boundary
    # even when exactly one item matches (PowerShell otherwise unwraps a
    # single-element array back to a scalar on return).
    return ,@($Result.Findings | Where-Object { $_.Key -eq $Key -and $_.Category -eq $Category })
}

# ---------------------------------------------------------------------------
# 1. Exact lookup / valid core setting
# ---------------------------------------------------------------------------
$tamingMatches = @(Find-AsaSettingExact -Name 'TamingSpeedMultiplier')
Assert-True ($tamingMatches.Count -ge 1) 'Exact lookup finds TamingSpeedMultiplier'
Assert-True ((@($tamingMatches | Where-Object { $_.support -eq 'supported' })).Count -ge 1) 'TamingSpeedMultiplier is marked supported'

# ---------------------------------------------------------------------------
# 2. Exact setting Q&A (deterministic, no Ollama)
# ---------------------------------------------------------------------------
$answer = Get-AsaAiKnowledgeAnswer -Question 'What is TamingSpeedMultiplier?' -SkipLocalExplanation
Assert-True ($answer.Method -eq 'exact') 'Q&A uses exact-lookup method for a directly named setting'
Assert-True ((@($answer.Facts | Where-Object { $_.name -eq 'TamingSpeedMultiplier' })).Count -ge 1) 'Q&A facts include TamingSpeedMultiplier'

# ---------------------------------------------------------------------------
# 3. Semantic / natural-language lookup (grounded in real description text)
# ---------------------------------------------------------------------------
$semantic = Get-AsaAiKnowledgeAnswer -Question 'How do I make babies mature faster?' -SkipLocalExplanation
Assert-True ((@($semantic.Facts | Where-Object { $_.name -eq 'BabyMatureSpeedMultiplier' })).Count -ge 1) 'Natural-language query finds BabyMatureSpeedMultiplier via keyword search'

# ---------------------------------------------------------------------------
# 4. Unknown / insufficient evidence
# ---------------------------------------------------------------------------
$unknown = Get-AsaAiKnowledgeAnswer -Question 'zzzqqqxx totally not a real setting 99911' -SkipLocalExplanation
Assert-True ($unknown.Method -eq 'none') 'Gibberish query is reported as unknown/insufficient evidence, not guessed'

# ---------------------------------------------------------------------------
# 5. Status tag classification: obsolete / unverified / blocked / unsupported
# ---------------------------------------------------------------------------
$obsoleteEntry = @(Find-AsaSettingExact -Name '-ActiveEvent') | Where-Object { $_.target -eq 'command-line' } | Select-Object -First 1
Assert-True ($obsoleteEntry -ne $null) 'Catalog contains the obsolete -ActiveEvent command-line entry'
if ($obsoleteEntry) { Assert-True ((Get-AsaSettingStatusTags -Entry $obsoleteEntry) -contains 'OBSOLETE') 'Obsolete setting is tagged OBSOLETE' }

$unverifiedEntry = @(Find-AsaSettingExact -Name '-NoDinosExceptForcedSpawn') | Select-Object -First 1
Assert-True ($unverifiedEntry -ne $null) 'Catalog contains the unverified -NoDinosExceptForcedSpawn entry'
if ($unverifiedEntry) { Assert-True ((Get-AsaSettingStatusTags -Entry $unverifiedEntry) -contains 'UNVERIFIED') 'Unverified setting is tagged UNVERIFIED' }

$blockedEntry = @(Find-AsaSettingExact -Name 'ActiveMods') | Select-Object -First 1
Assert-True ($blockedEntry -ne $null) 'Catalog contains the never-auto-apply ActiveMods entry'
if ($blockedEntry) { Assert-True ((Get-AsaSettingStatusTags -Entry $blockedEntry) -contains 'BLOCKED') 'never_auto_apply setting is tagged BLOCKED' }

$unsupportedEntry = @(Find-AsaSettingExact -Name 'MaxPlayers') | Where-Object { $_.support -eq 'unsupported' } | Select-Object -First 1
Assert-True ($unsupportedEntry -ne $null) 'Catalog contains the unsupported MaxPlayers entry'
if ($unsupportedEntry) { Assert-True ((Get-AsaSettingStatusTags -Entry $unsupportedEntry) -contains 'UNSUPPORTED') 'Unsupported setting is tagged UNSUPPORTED' }

# ---------------------------------------------------------------------------
# 6. Direct validator unit tests: invalid enum, out-of-range (real catalog entry)
# ---------------------------------------------------------------------------
$fakeEnumEntry = [pscustomobject]@{ name = 'FakeEnumSetting'; allowed_values = @('PC', 'PS5', 'ALL') }
Assert-True ((Test-AsaValueEnum -Entry $fakeEnumEntry -Value 'Xbox') -ne $null) 'Invalid enum value is rejected'
Assert-True ((Test-AsaValueEnum -Entry $fakeEnumEntry -Value 'PS5') -eq $null) 'Valid enum value passes'

$fishingEntry = @(Find-AsaSettingExact -Name 'FishingLootQualityMultiplier') | Select-Object -First 1
Assert-True ($fishingEntry -ne $null) 'Catalog contains FishingLootQualityMultiplier (has documented min/max)'
if ($fishingEntry) {
    Assert-True ((Test-AsaValueRange -Entry $fishingEntry -Value '0.1') -ne $null) 'Below-minimum value is flagged out of range'
    Assert-True ((Test-AsaValueRange -Entry $fishingEntry -Value '2.0') -eq $null) 'In-range value passes range check'
}

# ---------------------------------------------------------------------------
# 7. Full diagnostics pass over synthetic (non-live) INI content
# ---------------------------------------------------------------------------
$syntheticGameUserSettings = @(
    '[ServerSettings]'
    'TamingSpeedMultiplier=3.0'
    'TamingSpeedMultiplier=5.0'
    'BabyMatureSpeedMultiplier=2.0'
    'ServerHardcore=Maybe'
    'HarvestAmountMultiplier=notanumber'
    'ActiveMods=12345'
    'NotARealSettingXyz=1'
    ''
    '[WrongSection]'
    'XPMultiplier=2.0'
    'ServerAdminPassword=SuperSecret123'
    ''
    '[/Script/Engine.GameSession]'
    'MaxPlayers=70'
    ''
    '[/Script/ShooterGame.ShooterGameUserSettings]'
    'LastJoinedSessionPerCategory=1'
    'LastJoinedSessionPerCategory=2'
    'MasterAudioVolume=1.0'
    ''
    '[ScalabilityGroups]'
    'sg.ResolutionQuality=100'
    ''
    '[SomeModSection]'
    'SomeModOnlySetting=42'
)
$syntheticGameIni = @(
    '[/Script/ShooterGame.ShooterGameMode]'
    'FishingLootQualityMultiplier=0.1'
    'PerLevelStatsMultiplier_Player[8]=notanumber'
    'LevelExperienceRampOverrides=(ExperiencePointsForLevel[0]=5'
    'ConfigOverrideItemCraftingCosts=(ItemClassString="X",BaseCraftingResourceRequirements=(broken'
)

$diag = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $syntheticGameUserSettings -GameIniLines $syntheticGameIni

Assert-True ((Get-FindingsFor $diag 'TamingSpeedMultiplier' 'DUPLICATES').Count -ge 1) 'Diagnostics: duplicate key detected'
Assert-True ((Get-FindingsFor $diag 'BabyMatureSpeedMultiplier' 'WRONG TARGET FILE').Count -ge 1) 'Diagnostics: wrong target file detected'
Assert-True ((Get-FindingsFor $diag 'ServerHardcore' 'ERRORS').Count -ge 1) 'Diagnostics: invalid boolean detected'
Assert-True ((Get-FindingsFor $diag 'HarvestAmountMultiplier' 'ERRORS').Count -ge 1) 'Diagnostics: invalid float detected'
Assert-True ((Get-FindingsFor $diag 'ActiveMods' 'BLOCKED').Count -ge 1) 'Diagnostics: blocked setting flagged'
Assert-True ((Get-FindingsFor $diag 'NotARealSettingXyz' 'UNKNOWN_SERVER_SETTING').Count -ge 1) 'Diagnostics: unknown server-like setting flagged as UNKNOWN_SERVER_SETTING'
Assert-True ((Get-FindingsFor $diag 'XPMultiplier' 'WRONG SECTION').Count -ge 1) 'Diagnostics: wrong section detected'
Assert-True ((Get-FindingsFor $diag 'MaxPlayers' 'UNSUPPORTED').Count -ge 1) 'Diagnostics: unsupported setting flagged'
Assert-True ((Get-FindingsFor $diag 'FishingLootQualityMultiplier' 'ERRORS').Count -ge 1) 'Diagnostics: out-of-range value detected'
Assert-True ((Get-FindingsFor $diag 'PerLevelStatsMultiplier_Player[8]' 'ERRORS').Count -ge 1) 'Diagnostics: malformed PerLevelStatsMultiplier value detected'
Assert-True ((Get-FindingsFor $diag 'LevelExperienceRampOverrides' 'ERRORS').Count -ge 1) 'Diagnostics: malformed LevelExperienceRampOverrides (unbalanced parens) detected'
Assert-True ((Get-FindingsFor $diag 'ConfigOverrideItemCraftingCosts' 'ERRORS').Count -ge 1) 'Diagnostics: malformed ConfigOverrideItemCraftingCosts detected'

# ---------------------------------------------------------------------------
# 7b. UNKNOWN_SERVER_SETTING vs IGNORED_NON_SERVER classification
# ---------------------------------------------------------------------------

# Direct unit tests of the structural classifier.
Assert-True (Test-AsaIsIgnoredNonServerEntry -Section '[/Script/ShooterGame.ShooterGameUserSettings]' -Key 'LastJoinedSessionPerCategory') 'Classifier: UE per-client GameUserSettings-class section is ignored-non-server'
Assert-True (Test-AsaIsIgnoredNonServerEntry -Section '[ScalabilityGroups]' -Key 'sg.ResolutionQuality') 'Classifier: fixed engine ScalabilityGroups section is ignored-non-server'
Assert-True (Test-AsaIsIgnoredNonServerEntry -Section '[ServerSettings]' -Key 'sg.Anything') 'Classifier: sg.-prefixed key is ignored-non-server regardless of section'
Assert-True (-not (Test-AsaIsIgnoredNonServerEntry -Section '[ServerSettings]' -Key 'TamingSpeedMultiplier')) 'Classifier: a real server section/key is NOT ignored'
Assert-True (-not (Test-AsaIsIgnoredNonServerEntry -Section '[CustomLevelDistrib]' -Key 'WantsEqualLevels')) 'Classifier: a known mod-but-server-relevant section is NOT ignored'
Assert-True (-not (Test-AsaIsIgnoredNonServerEntry -Section '[SomeModSection]' -Key 'SomeModOnlySetting')) 'Classifier: an unrecognized (possibly mod) section defaults to NOT ignored'

# LastJoinedSessionPerCategory (this ticket's motivating example) must never
# surface as a server configuration problem, in any category.
$leakedAsProblem = @($diag.Findings | Where-Object { $_.Key -eq 'LastJoinedSessionPerCategory' -and $script:AsaDiagnosticsDefaultVisibleCategories -contains $_.Category })
Assert-True ($leakedAsProblem.Count -eq 0) 'LastJoinedSessionPerCategory never appears as a server configuration problem'
Assert-True ((Get-FindingsFor $diag 'LastJoinedSessionPerCategory' 'IGNORED_NON_SERVER').Count -ge 1) 'LastJoinedSessionPerCategory is classified IGNORED_NON_SERVER, not UNKNOWN_SERVER_SETTING/DUPLICATES'
Assert-True ((Get-FindingsFor $diag 'MasterAudioVolume' 'IGNORED_NON_SERVER').Count -ge 1) 'Client audio setting (MasterAudioVolume) is classified IGNORED_NON_SERVER'
Assert-True ((Get-FindingsFor $diag 'sg.ResolutionQuality' 'IGNORED_NON_SERVER').Count -ge 1) 'Scalability group key is classified IGNORED_NON_SERVER'

# A genuinely unrecognized section (could plausibly be mod server config) must
# stay visible as UNKNOWN_SERVER_SETTING -- the classifier must not be so
# broad that it hides real unknowns just because they aren't in the catalog.
Assert-True ((Get-FindingsFor $diag 'SomeModOnlySetting' 'UNKNOWN_SERVER_SETTING').Count -ge 1) 'Unrecognized mod-like section stays UNKNOWN_SERVER_SETTING, not swept into IGNORED_NON_SERVER'

# Ignored entries are counted, and never removed from the raw findings --
# only hidden from the default display filter.
Assert-True ($diag.IgnoredNonServerCount -ge 4) 'Diagnostics reports a non-zero IgnoredNonServerCount'
$rawIgnoredCount = (@($diag.Findings | Where-Object { $_.Category -eq 'IGNORED_NON_SERVER' })).Count
Assert-True ($rawIgnoredCount -eq $diag.IgnoredNonServerCount) 'IgnoredNonServerCount matches the actual IGNORED_NON_SERVER findings still present in Findings (nothing deleted)'

$displayFindings = @(Get-AsaConfigDiagnosticsDisplayFindings -Diagnostics $diag)
Assert-True ((@($displayFindings | Where-Object { $_.Category -eq 'IGNORED_NON_SERVER' })).Count -eq 0) 'Default display view excludes IGNORED_NON_SERVER findings'
Assert-True ($displayFindings.Count -lt $diag.Findings.Count) 'Default display view is strictly smaller than the full raw findings (filtering, not deleting)'
Assert-True ((@($displayFindings | Where-Object { $_.Category -eq 'UNKNOWN_SERVER_SETTING' })).Count -ge 1) 'Default display view still includes genuine UNKNOWN_SERVER_SETTING findings'
Assert-True ($diag.ProblemFindingsCount -eq ($diag.TotalFindings - $diag.IgnoredNonServerCount - $diag.InformationalFindingsCount)) 'ProblemFindingsCount is computed consistently from the other counts'

# Ignored entries must never be modified or removed from the source lines
# diagnostics was handed -- it is read-only end to end, not just for its output.
$syntheticGameUserSettingsBefore = $syntheticGameUserSettings.Clone()
Invoke-AsaConfigDiagnostics -GameUserSettingsLines $syntheticGameUserSettings -GameIniLines $syntheticGameIni | Out-Null
Assert-True ((Compare-Object $syntheticGameUserSettingsBefore $syntheticGameUserSettings -SyncWindow 0) -eq $null) 'Diagnostics does not mutate the input INI lines, including ignored non-server entries'

# Secret redaction: the password's real value must never appear anywhere in the findings.
$anyLeakedSecret = @($diag.Findings | Where-Object { $_.Value -like '*SuperSecret123*' -or $_.Message -like '*SuperSecret123*' })
Assert-True ($anyLeakedSecret.Count -eq 0) 'Diagnostics never logs the raw ServerAdminPassword value'
$passwordFindingValue = @($diag.Findings | Where-Object { $_.Key -eq 'ServerAdminPassword' } | Select-Object -First 1)
Assert-True ($passwordFindingValue.Count -eq 1 -and $passwordFindingValue[0].Value -eq '[REDACTED]') 'ServerAdminPassword finding (wrong section) shows a redacted value, not the real one'

# Format-AsaSettingFact must also never read/print a secret's real value.
$passwordEntry = @(Find-AsaSettingExact -Name 'ServerAdminPassword') | Select-Object -First 1
Assert-True ($passwordEntry -ne $null) 'Catalog contains ServerAdminPassword'
if ($passwordEntry) {
    $fact = Format-AsaSettingFact -Entry $passwordEntry -IncludeCurrentValue
    Assert-True ($fact -like '*REDACTED*') 'Format-AsaSettingFact redacts sensitive settings'
}

# ---------------------------------------------------------------------------
# 8. Diagnostics and knowledge lookup are strictly read-only
# ---------------------------------------------------------------------------
$paths = Get-AsaAiFixedConfigPaths
$beforeUser = if (Test-Path -LiteralPath $paths.GameUserSettings) { (Get-Item -LiteralPath $paths.GameUserSettings).LastWriteTimeUtc } else { $null }
$beforeGame = if (Test-Path -LiteralPath $paths.GameIni) { (Get-Item -LiteralPath $paths.GameIni).LastWriteTimeUtc } else { $null }

Invoke-AsaConfigDiagnostics | Out-Null
Get-AsaAiKnowledgeAnswer -Question 'Set taming to 10x' -SkipLocalExplanation | Out-Null
Search-AsaSettings -Query 'harvest' | Out-Null

$afterUser = if (Test-Path -LiteralPath $paths.GameUserSettings) { (Get-Item -LiteralPath $paths.GameUserSettings).LastWriteTimeUtc } else { $null }
$afterGame = if (Test-Path -LiteralPath $paths.GameIni) { (Get-Item -LiteralPath $paths.GameIni).LastWriteTimeUtc } else { $null }
Assert-True ($beforeUser -eq $afterUser) 'GameUserSettings.ini is untouched by diagnostics/lookup'
Assert-True ($beforeGame -eq $afterGame) 'Game.ini is untouched by diagnostics/lookup'

# ---------------------------------------------------------------------------
# 9. Knowledge base stays separate from the write allow-list
# ---------------------------------------------------------------------------
$blockedProposal = Test-AsaAiApplyProposal -Proposal ([pscustomobject]@{
    Changes = @([pscustomobject]@{ Key = 'ActiveMods'; Value = '12345'; Reason = 'test' })
    Recipes = @()
})
Assert-True (-not $blockedProposal.Success) 'A knowledge-base-only setting (not in the write allow-list) is rejected by the apply validator'

# ---------------------------------------------------------------------------
# 10. Cache / index refresh
# ---------------------------------------------------------------------------
Sync-AsaKnowledgeIndex
$index = Get-AsaKnowledgeIndex
Assert-True (Test-Path -LiteralPath (Get-AsaKnowledgeCachePath)) 'Knowledge cache file is written after a sync'
Assert-True ([int]$index.Counts.core -eq 147) 'Index reports the expected core dataset count (147)'
Assert-True (@($index.Settings).Count -gt 400) 'Merged index contains settings from all datasets'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Passed: $script:TestPassCount, Failed: $($script:TestFailures.Count)"
if ($script:TestFailures.Count -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    $script:TestFailures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
exit 0
