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
# 11. Dependency evaluation reasons about EFFECTIVE configuration values
#     (regression test for the PvEDinoDecayPeriodMultiplier false positive:
#     DisableDinoDecayPvE defaults to False, so when it isn't explicitly
#     configured the dependency is satisfied by that documented default, not
#     flagged as an issue).
# ---------------------------------------------------------------------------

# 11a. Deterministic parsing of "SettingName=Value" hints; non-value hints
# (command-line flags, presence-only) are left for the unchanged fallback path.
$reqParsed = Get-AsaDependencyRequirement -HintText 'DisableDinoDecayPvE=false'
Assert-True ($reqParsed.SettingName -eq 'DisableDinoDecayPvE' -and $reqParsed.RequiredValue -eq 'false') 'Get-AsaDependencyRequirement parses a "SettingName=Value" hint'
Assert-True ((Get-AsaDependencyRequirement -HintText '-clusterid') -eq $null) 'Get-AsaDependencyRequirement returns $null for a bare command-line-flag hint'
Assert-True ((Get-AsaDependencyRequirement -HintText 'CustomDynamicConfigUrl in GameUserSettings.ini') -eq $null) 'Get-AsaDependencyRequirement returns $null for a presence-only hint'

# 11b. Unknown: no explicitly configured value AND no verified/documented default.
$unknownEffective = Get-AsaEffectiveSettingValue -SettingName 'ZzzNotInAnyCatalogDataset' -ParsedEntries @()
Assert-True ($unknownEffective.Value -eq $null -and $unknownEffective.Source -eq 'Unknown') 'Get-AsaEffectiveSettingValue reports Unknown when neither a configured value nor a documented default exists'

# 11c. Satisfied by an EXPLICITLY configured value.
$depExplicitSatisfied = @('[ServerSettings]', 'PvEDinoDecayPeriodMultiplier=2.0', 'DisableDinoDecayPvE=False')
$diagDepA = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $depExplicitSatisfied -GameIniLines @()
Assert-True ((Get-FindingsFor $diagDepA 'PvEDinoDecayPeriodMultiplier' 'DEPENDENCY ISSUES').Count -eq 0) 'Dependency satisfied by explicit value: no DEPENDENCY ISSUES finding'
$satisfiedExplicitInfo = @(Get-FindingsFor $diagDepA 'PvEDinoDecayPeriodMultiplier' 'INFORMATION')
Assert-True (($satisfiedExplicitInfo | Where-Object { $_.Message -like '*Dependency satisfied by explicit configuration*DisableDinoDecayPvE=False*' }).Count -ge 1) 'Dependency satisfied by explicit value: explanation names explicit configuration as the source'

# 11d. Violated by an EXPLICITLY configured value.
$depExplicitViolated = @('[ServerSettings]', 'PvEDinoDecayPeriodMultiplier=2.0', 'DisableDinoDecayPvE=True')
$diagDepB = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $depExplicitViolated -GameIniLines @()
$violatedFindings = @(Get-FindingsFor $diagDepB 'PvEDinoDecayPeriodMultiplier' 'DEPENDENCY ISSUES')
Assert-True ($violatedFindings.Count -ge 1) 'Dependency violated by explicit value: DEPENDENCY ISSUES finding is reported'
Assert-True (($violatedFindings | Where-Object { $_.Message -like '*violates the dependency*' -and $_.Message -like '*DisableDinoDecayPvE=True*' }).Count -ge 1) 'Dependency violated by explicit value: explanation states the actual effective value and that it violates the dependency'

# 11e. Satisfied by a DOCUMENTED DEFAULT (the exact motivating false-positive:
# DisableDinoDecayPvE not present in the INI at all).
$depDefaultSatisfied = @('[ServerSettings]', 'PvEDinoDecayPeriodMultiplier=1')
$diagDepC = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $depDefaultSatisfied -GameIniLines @()
Assert-True ((Get-FindingsFor $diagDepC 'PvEDinoDecayPeriodMultiplier' 'DEPENDENCY ISSUES').Count -eq 0) 'Dependency satisfied by documented default: false-positive DEPENDENCY ISSUES finding no longer appears'
$satisfiedDefaultInfo = @(Get-FindingsFor $diagDepC 'PvEDinoDecayPeriodMultiplier' 'INFORMATION')
Assert-True (($satisfiedDefaultInfo | Where-Object { $_.Message -eq 'Dependency satisfied by documented default: DisableDinoDecayPvE=False.' }).Count -ge 1) 'Dependency satisfied by documented default: explanation matches the required deterministic wording'

# ---------------------------------------------------------------------------
# 12. Copy selected finding -- clean plain-text formatting
# ---------------------------------------------------------------------------

# 12a. WRONG TARGET FILE finding (matches the worked example in the request).
$wrongFileLines = @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2')
$diagWrongFile = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $wrongFileLines -GameIniLines @()
$wrongFileFinding = (Get-FindingsFor $diagWrongFile 'PassiveTameIntervalMultiplier' 'WRONG TARGET FILE')[0]
Assert-True ($wrongFileFinding -ne $null) 'Synthetic config reproduces a WRONG TARGET FILE finding for PassiveTameIntervalMultiplier'
if ($wrongFileFinding) {
    $copyText = Format-AsaDiagnosticFindingClipboardText -Finding $wrongFileFinding
    Assert-True ($copyText -like '*ASA Configuration Diagnostic*') 'Copied finding text has the expected header'
    Assert-True ($copyText -like '*Type: WRONG TARGET FILE*') 'Copied finding text includes Type'
    Assert-True ($copyText -like '*Setting: PassiveTameIntervalMultiplier*') 'Copied finding text includes Setting'
    Assert-True ($copyText -like '*Current value: 0.2*') 'Copied finding text includes Current value'
    Assert-True ($copyText -like '*Current file: GameUserSettings.ini*') 'Copied finding text includes Current file'
    Assert-True ($copyText -like '*Expected file: Game.ini*') 'Copied finding text includes Expected file'
    Assert-True ($copyText -match [regex]::Escape('Expected section: [/script/shootergame.shootergamemode]')) 'Copied finding text includes Expected section'
    Assert-True ($copyText -like '*Suggested correction:*Move the setting to the expected location while preserving its value.*') 'Copied finding text includes a deterministic suggested correction'
    Assert-True ($copyText -like '*Read-only diagnostic. No configuration files were changed.*') 'Copied finding text ends with the read-only status line'
}

# 12b. Dependency/effective-default information is included when relevant.
$depDefaultFinding = (Get-FindingsFor $diagDepC 'PvEDinoDecayPeriodMultiplier' 'INFORMATION')[0]
Assert-True ($depDefaultFinding -ne $null) 'Dependency-satisfied finding is available to format'
if ($depDefaultFinding) {
    $depCopyText = Format-AsaDiagnosticFindingClipboardText -Finding $depDefaultFinding
    Assert-True ($depCopyText -like '*Effective value: False*') 'Copied dependency finding includes Effective value'
    Assert-True ($depCopyText -like '*Value source: Documented default*') 'Copied dependency finding includes Value source'
    Assert-True ($depCopyText -like '*Dependency information:*DisableDinoDecayPvE=false*') 'Copied dependency finding includes Dependency information'
}

# 12c. Copying a finding never mutates the live config files.
$pathsForCopy = Get-AsaAiFixedConfigPaths
$beforeCopyUser = if (Test-Path -LiteralPath $pathsForCopy.GameUserSettings) { (Get-Item -LiteralPath $pathsForCopy.GameUserSettings).LastWriteTimeUtc } else { $null }
Format-AsaDiagnosticFindingClipboardText -Finding $wrongFileFinding | Out-Null
$afterCopyUser = if (Test-Path -LiteralPath $pathsForCopy.GameUserSettings) { (Get-Item -LiteralPath $pathsForCopy.GameUserSettings).LastWriteTimeUtc } else { $null }
Assert-True ($beforeCopyUser -eq $afterCopyUser) 'Formatting a finding for copy does not touch GameUserSettings.ini'

# ---------------------------------------------------------------------------
# 13. Copy diagnostic report -- grouped, summarized, read-only
# ---------------------------------------------------------------------------
$reportGameUserSettings = @(
    '[ServerSettings]'
    'PassiveTameIntervalMultiplier=0.2'
    'MaxPlayers=10'
    ''
    '[/Script/ShooterGame.ShooterGameUserSettings]'
    'LastJoinedSessionPerCategory=1'
    'LastJoinedSessionPerCategory=2'
)
$diagForReport = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $reportGameUserSettings -GameIniLines @()
$displayForReport = @(Get-AsaConfigDiagnosticsDisplayFindings -Diagnostics $diagForReport)
$reportText = Format-AsaDiagnosticsReportClipboardText -Diagnostics $diagForReport -DisplayFindings $displayForReport

Assert-True ($reportText -like '*ASA Configuration Diagnostic Report*') 'Report text has the expected header'
Assert-True ($reportText -like "*Configuration problems: $($diagForReport.ProblemFindingsCount)*") 'Report text includes the configuration-problems summary count'
Assert-True ($reportText -like "*Informational findings: $($diagForReport.InformationalFindingsCount)*") 'Report text includes the informational-findings summary count'
Assert-True ($reportText -like "*Ignored non-server/bookkeeping entries: $($diagForReport.IgnoredNonServerCount)*") 'Report text includes the ignored-non-server summary count'
Assert-True ($diagForReport.IgnoredNonServerCount -ge 1) 'Sanity: synthetic report input actually contains ignored non-server entries'
Assert-True ($reportText -notlike '*LastJoinedSessionPerCategory*') 'Report text does not dump individual IGNORED_NON_SERVER bookkeeping entries'
Assert-True ($reportText -like '*WRONG TARGET FILE*') 'Report text groups findings under their category heading'
Assert-True ($reportText -like '*PassiveTameIntervalMultiplier = 0.2*') 'Report text lists the finding under its category'
Assert-True ($reportText -like '*End of report*') 'Report text includes the closing marker'
Assert-True ($reportText -like '*Diagnostics are read-only.*No configuration files were modified.*') 'Report text ends with the read-only status lines'

# Report is built only from the passed-in (already displayed/filtered) findings.
$filteredDisplay = @($displayForReport | Where-Object { $_.Category -ne 'UNSUPPORTED' })
$filteredReportText = Format-AsaDiagnosticsReportClipboardText -Diagnostics $diagForReport -DisplayFindings $filteredDisplay
Assert-True ($filteredReportText -notlike '*UNSUPPORTED*') 'Report reflects only the currently displayed/filtered findings passed to it, not the full raw set'

# ---------------------------------------------------------------------------
# 14. Secret redaction in copy/export text
# ---------------------------------------------------------------------------
# Deliberately the WRONG section (mirrors test 7's redaction check) so each
# password produces a WRONG SECTION finding carrying a Value to redact --
# a correctly-sectioned secret produces no finding at all to copy.
$secretLines = @('[WrongSection]', 'ServerAdminPassword=SuperSecret123', 'ServerPassword=AnotherSecret456', 'MyCustomApiToken=leaked-token-value')
$diagSecrets = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $secretLines -GameIniLines @()

$adminPwFinding = @($diagSecrets.Findings | Where-Object { $_.Key -eq 'ServerAdminPassword' }) | Select-Object -First 1
Assert-True ($adminPwFinding -ne $null) 'ServerAdminPassword produces at least one finding to copy'
if ($adminPwFinding) {
    $adminPwCopyText = Format-AsaDiagnosticFindingClipboardText -Finding $adminPwFinding
    Assert-True ($adminPwCopyText -notlike '*SuperSecret123*') 'Copied ServerAdminPassword finding never exposes the real value'
    Assert-True ($adminPwCopyText -like '*[REDACTED]*') 'Copied ServerAdminPassword finding shows [REDACTED]'
}

$pwFinding = @($diagSecrets.Findings | Where-Object { $_.Key -eq 'ServerPassword' }) | Select-Object -First 1
if ($pwFinding) {
    $pwCopyText = Format-AsaDiagnosticFindingClipboardText -Finding $pwFinding
    Assert-True ($pwCopyText -notlike '*AnotherSecret456*') 'Copied ServerPassword finding never exposes the real value'
}

# Generic/unrecognized secret-like key name (not in the curated catalog at all)
# must still be redacted in copy/export text via the name-based heuristic.
$apiTokenFinding = @($diagSecrets.Findings | Where-Object { $_.Key -eq 'MyCustomApiToken' }) | Select-Object -First 1
Assert-True ($apiTokenFinding -ne $null) 'Unrecognized token-like key still produces a finding (UNKNOWN_SERVER_SETTING)'
if ($apiTokenFinding) {
    $apiTokenCopyText = Format-AsaDiagnosticFindingClipboardText -Finding $apiTokenFinding
    Assert-True ($apiTokenCopyText -notlike '*leaked-token-value*') 'Copied finding for an unrecognized token-like key never exposes its raw value'
}

$secretsDisplay = @(Get-AsaConfigDiagnosticsDisplayFindings -Diagnostics $diagSecrets)
$secretsReportText = Format-AsaDiagnosticsReportClipboardText -Diagnostics $diagSecrets -DisplayFindings $secretsDisplay
Assert-True ($secretsReportText -notlike '*SuperSecret123*') 'Full report text never exposes ServerAdminPassword'
Assert-True ($secretsReportText -notlike '*AnotherSecret456*') 'Full report text never exposes ServerPassword'
Assert-True ($secretsReportText -notlike '*leaked-token-value*') 'Full report text never exposes an unrecognized token-like value'

# ---------------------------------------------------------------------------
# 15. Cache / index refresh
# ---------------------------------------------------------------------------
Sync-AsaKnowledgeIndex
$index = Get-AsaKnowledgeIndex
Assert-True (Test-Path -LiteralPath (Get-AsaKnowledgeCachePath)) 'Knowledge cache file is written after a sync'
Assert-True ([int]$index.Counts.core -eq 149) 'Index reports the expected core dataset count (149, after adding StartTimeHour and OverrideSecondsUntilBuriedTreasureAutoReveals)'
Assert-True (@($index.Settings).Count -gt 400) 'Merged index contains settings from all datasets'

# ---------------------------------------------------------------------------
# 16. Setting relocation planning (Get-AsaSettingRelocationPlan) -- pure,
#     deterministic, read-only. Covers the "existing setting stuck in the
#     wrong INI file/section" capability end to end at the planning layer.
# ---------------------------------------------------------------------------

# 16a. Valid relocation: setting in the wrong FILE entirely (the motivating
# example from the request).
$relocGU = @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2')
$relocGI = @('[/Script/ShooterGame.ShooterGameMode]')
$validPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines $relocGU -GameIniLines $relocGI
Assert-True $validPlan.Success 'Relocation plan: valid relocation (wrong source file) succeeds'
Assert-True ($validPlan.FromTarget -eq 'GameUserSettings.ini' -and $validPlan.FromSection -eq '[ServerSettings]') 'Relocation plan: source file/section identified correctly'
Assert-True (($validPlan.SourceValues -join ',') -eq '0.2') 'Relocation plan: current value preserved on the plan'

# 16b. Destination always comes from the authoritative catalog -- verified as
# an invariant (the schema never accepts a caller-supplied destination at
# all, so there is no "wrong destination in the proposal" input to reject;
# instead we assert the derived destination always equals the catalog).
$catalogEntry = @(Find-AsaSettingExact -Name 'PassiveTameIntervalMultiplier') | Select-Object -First 1
Assert-True ($validPlan.ToTarget -ceq $catalogEntry.target -and $validPlan.ToSection -ceq $catalogEntry.section) 'Relocation plan: destination always exactly matches the authoritative knowledge-base target/section'

# 16c. Valid relocation: setting in the correct FILE but wrong SECTION.
$wrongSectionPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]') -GameIniLines @('[SomeOtherSection]', 'PassiveTameIntervalMultiplier=0.3')
Assert-True $wrongSectionPlan.Success 'Relocation plan: valid relocation (wrong source section, correct file) succeeds'
Assert-True ($wrongSectionPlan.FromTarget -eq 'Game.ini' -and $wrongSectionPlan.FromSection -eq '[SomeOtherSection]') 'Relocation plan: wrong-section source identified correctly'
Assert-True ($wrongSectionPlan.ToTarget -eq 'Game.ini' -and $wrongSectionPlan.ToSection -ceq $catalogEntry.section) 'Relocation plan: wrong-section relocation still resolves to the authoritative section'

# 16d. Unsupported setting is refused.
$unsupportedPlan = Get-AsaSettingRelocationPlan -SettingName 'MaxPlayers' -GameUserSettingsLines @('[ServerSettings]', 'MaxPlayers=10') -GameIniLines @()
Assert-True (-not $unsupportedPlan.Success) 'Relocation plan: UNSUPPORTED setting is refused'
Assert-True ($unsupportedPlan.Error -like '*UNSUPPORTED*') 'Relocation plan: UNSUPPORTED refusal explains why'

# 16e. Blocked (never_auto_apply) setting is refused.
$blockedPlan = Get-AsaSettingRelocationPlan -SettingName 'ActiveMods' -GameUserSettingsLines @() -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'ActiveMods=12345')
Assert-True (-not $blockedPlan.Success) 'Relocation plan: BLOCKED setting is refused'
Assert-True ($blockedPlan.Error -like '*BLOCKED*') 'Relocation plan: BLOCKED refusal explains why'

# 16f. Unverified setting is refused.
$unverifiedPlan = Get-AsaSettingRelocationPlan -SettingName '-NoDinosExceptForcedSpawn' -GameUserSettingsLines @('[ServerSettings]', '-NoDinosExceptForcedSpawn=True') -GameIniLines @()
Assert-True (-not $unverifiedPlan.Success) 'Relocation plan: UNVERIFIED setting is refused'
Assert-True ($unverifiedPlan.Error -like '*UNVERIFIED*') 'Relocation plan: UNVERIFIED refusal explains why'

# 16g. Unknown/mod setting is refused.
$unknownPlan = Get-AsaSettingRelocationPlan -SettingName 'NeedsPowerToActivateAquaticCompartments' -GameUserSettingsLines @('[ServerSettings]', 'NeedsPowerToActivateAquaticCompartments=True') -GameIniLines @()
Assert-True (-not $unknownPlan.Success) 'Relocation plan: unknown/mod setting is refused'
Assert-True ($unknownPlan.Error -like '*not in the authoritative*') 'Relocation plan: unknown-setting refusal explains why'

# 16h. Value validation still applies at the source before relocating.
$outOfRangePlan = Get-AsaSettingRelocationPlan -SettingName 'SupplyCrateLootQualityMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'SupplyCrateLootQualityMultiplier=99') -GameIniLines @()
Assert-True (-not $outOfRangePlan.Success) 'Relocation plan: out-of-range source value is refused'
Assert-True ($outOfRangePlan.Error -like '*maximum*') 'Relocation plan: out-of-range refusal names the violated bound'

# 16i. Destination already has the SAME value -- unambiguous, proceeds
# without a conflict (source duplicate removed, destination left as-is).
$sameValuePlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2') -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'PassiveTameIntervalMultiplier=0.2')
Assert-True ($sameValuePlan.Success -and -not $sameValuePlan.Conflict) 'Relocation plan: destination with the SAME value is not a conflict'
Assert-True (-not $sameValuePlan.WriteDestination) 'Relocation plan: destination is left untouched when it already matches'

# 16j. Destination already has a DIFFERENT value -- refused without an
# explicit resolution; never silently overwritten.
$conflictPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2') -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'PassiveTameIntervalMultiplier=0.5')
Assert-True (-not $conflictPlan.Success -and $conflictPlan.Conflict) 'Relocation plan: destination with a DIFFERENT value is refused as a conflict, not silently overwritten'
Assert-True ($conflictPlan.DestinationValue -eq '0.5' -and $conflictPlan.SourceValue -eq '0.2') 'Relocation plan: conflict reports both the destination and source values'

# 16j-2. Explicit resolutions deterministically resolve the same conflict.
$useSourcePlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2') -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'PassiveTameIntervalMultiplier=0.5') -Resolution use_source
Assert-True ($useSourcePlan.Success -and $useSourcePlan.WriteDestination -and ($useSourcePlan.DestinationLines -join ',') -eq 'PassiveTameIntervalMultiplier=0.2') 'Relocation plan: use_source resolution overwrites the destination with the source value'
$keepDestPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2') -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'PassiveTameIntervalMultiplier=0.5') -Resolution keep_destination
Assert-True ($keepDestPlan.Success -and -not $keepDestPlan.WriteDestination) 'Relocation plan: keep_destination resolution leaves the existing destination value untouched'

# 16k. Repeatable settings are moved as a whole set, not treated as a single
# scalar value.
$repeatableGameIni = @(
    '[ServerSettings]'
    'ConfigOverrideItemCraftingCosts=(ItemClassString="A",BaseCraftingResourceRequirements=((ResourceItemTypeString="B",BaseResourceRequirement=1.0,bCraftingRequireExactResourceType=False)))'
    'ConfigOverrideItemCraftingCosts=(ItemClassString="C",BaseCraftingResourceRequirements=((ResourceItemTypeString="D",BaseResourceRequirement=2.0,bCraftingRequireExactResourceType=False)))'
)
$repeatablePlan = Get-AsaSettingRelocationPlan -SettingName 'ConfigOverrideItemCraftingCosts' -GameUserSettingsLines $repeatableGameIni -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]')
Assert-True ($repeatablePlan.Success -and $repeatablePlan.Repeatable) 'Relocation plan: repeatable setting is recognized as repeatable, not scalar'
Assert-True (@($repeatablePlan.SourceLines).Count -eq 2) 'Relocation plan: ALL repeatable source lines are captured, not just the first'
Assert-True (@($repeatablePlan.DestinationLines).Count -eq 2) 'Relocation plan: ALL repeatable lines are carried over to the destination'

# 16l. A setting that is not documented as repeatable but appears more than
# once at the source is refused rather than silently picking one.
$duplicateScalarPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2', 'PassiveTameIntervalMultiplier=0.4') -GameIniLines @()
Assert-True (-not $duplicateScalarPlan.Success) 'Relocation plan: duplicate non-repeatable source lines are refused'

# 16m. Nothing to relocate: already at the authoritative location.
$alreadyCorrectPlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines @('[ServerSettings]') -GameIniLines @('[/Script/ShooterGame.ShooterGameMode]', 'PassiveTameIntervalMultiplier=0.2')
Assert-True (-not $alreadyCorrectPlan.Success) 'Relocation plan: a setting already at its authoritative location has nothing to relocate'

# ---------------------------------------------------------------------------
# 17. Preview text -- shows a relocation as one clear MOVE, never as two
#     unrelated changes; pure formatting, no file access at all.
# ---------------------------------------------------------------------------
$previewFinding = [pscustomobject]@{
    Setting = 'PassiveTameIntervalMultiplier'; FromTarget = 'GameUserSettings.ini'; FromSection = '[ServerSettings]'
    ToTarget = 'Game.ini'; ToSection = '[/script/shootergame.shootergamemode]'; SourceValues = @('0.2')
    DestinationHadExisting = $false; WriteDestination = $true; Reason = 'Authoritative ASA knowledge base specifies Game.ini as the correct target.'
}
$previewText = Format-AsaRelocationPreviewText -Relocation $previewFinding
Assert-True ($previewText -like '*MOVE*') 'Preview: shows MOVE, not a generic change label'
Assert-True ($previewText -like '*PassiveTameIntervalMultiplier=0.2*') 'Preview: shows the setting and its preserved value'
Assert-True ($previewText -match ('FROM:[\s\S]*' + [regex]::Escape('GameUserSettings.ini [ServerSettings]'))) 'Preview: shows the source location'
Assert-True ($previewText -match ('TO:[\s\S]*' + [regex]::Escape('Game.ini [/script/shootergame.shootergamemode]'))) 'Preview: shows the destination location'
Assert-True ($previewText -like '*Reason:*') 'Preview: includes the reason'
Assert-True ($previewText -like '*Value preserved: 0.2*') 'Preview: explicitly confirms the value is preserved'

$previewConflictFinding = $previewFinding.PSObject.Copy()
$previewConflictFinding.DestinationHadExisting = $true
$previewConflictFinding.WriteDestination = $true
$conflictPreviewText = Format-AsaRelocationPreviewText -Relocation $previewConflictFinding
Assert-True ($conflictPreviewText -like '*Destination conflict:*') 'Preview: shows a destination conflict clearly when present'

# ---------------------------------------------------------------------------
# 18. Full relocation apply pipeline -- fixture-based, NEVER touches the live
#     GameUserSettings.ini/Game.ini. Get-AsaAiFixedConfigPaths is redirected
#     via $script:AsaAiTestConfigPathOverride to an isolated temp directory.
# ---------------------------------------------------------------------------
$serverRunningForRelocationTests = [bool](Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue)
if ($serverRunningForRelocationTests) {
    Write-Host 'SKIP: ASA server process is currently running -- Invoke-AsaAiApplyProposal refuses to write by design, so the fixture-based apply/backup/rollback relocation tests are skipped this run.' -ForegroundColor Yellow
}
else {
    $relocFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('asa-relocation-test-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $relocFixtureRoot -Force)
    $relocFixtureGU = Join-Path $relocFixtureRoot 'GameUserSettings.ini'
    $relocFixtureGI = Join-Path $relocFixtureRoot 'Game.ini'
    $relocFixtureBackups = Join-Path $relocFixtureRoot 'backups'
    $relocFixtureChangelog = Join-Path $relocFixtureRoot 'CHANGELOG.md'
    [void](New-Item -ItemType File -Path $relocFixtureChangelog -Force)

    $relocOriginalGU = @('[ServerSettings]', 'PassiveTameIntervalMultiplier=0.2', 'ServerHardcore=False')
    $relocOriginalGI = @('[/Script/ShooterGame.ShooterGameMode]', 'BabyMatureSpeedMultiplier=1.0')

    try {
        # --- 18a. Successful relocation: removes source, adds destination, backs up both files first ---
        [IO.File]::WriteAllLines($relocFixtureGU, $relocOriginalGU)
        [IO.File]::WriteAllLines($relocFixtureGI, $relocOriginalGI)
        $script:AsaAiTestConfigPathOverride = [pscustomobject]@{
            GameUserSettings = $relocFixtureGU; GameIni = $relocFixtureGI; BackupRoot = $relocFixtureBackups; ChangelogPath = $relocFixtureChangelog
        }

        $applyProposal = [pscustomobject]@{
            Changes = @(); Recipes = @()
            Relocations = @([pscustomobject]@{ Setting = 'PassiveTameIntervalMultiplier'; Reason = 'test relocation' })
        }
        $applyResult = Invoke-AsaAiApplyProposal -Proposal $applyProposal
        Assert-True $applyResult.Success 'Relocation apply: succeeds against an isolated fixture'
        Assert-True (Test-Path -LiteralPath $applyResult.BackupPath) 'Relocation apply: a backup snapshot directory was created'

        $backupGU = Get-Content -LiteralPath (Join-Path $applyResult.BackupPath 'GameUserSettings.ini')
        $backupGI = Get-Content -LiteralPath (Join-Path $applyResult.BackupPath 'Game.ini')
        Assert-True ((Compare-Object $relocOriginalGU $backupGU -SyncWindow 0) -eq $null) 'Relocation apply: backup contains the PRE-CHANGE GameUserSettings.ini exactly'
        Assert-True ((Compare-Object $relocOriginalGI $backupGI -SyncWindow 0) -eq $null) 'Relocation apply: backup contains the PRE-CHANGE Game.ini exactly'

        $afterGU = Get-Content -LiteralPath $relocFixtureGU
        $afterGI = Get-Content -LiteralPath $relocFixtureGI
        Assert-True (($afterGU -join "`n") -notlike '*PassiveTameIntervalMultiplier*') 'Relocation apply: source setting was removed from GameUserSettings.ini'
        Assert-True (($afterGU -join "`n") -like '*ServerHardcore=False*') 'Relocation apply: unrelated settings in the source file are untouched'
        Assert-True (($afterGI -join "`n") -like '*PassiveTameIntervalMultiplier=0.2*') 'Relocation apply: destination setting was added to Game.ini with its value preserved'
        Assert-True (($afterGI -join "`n") -like '*BabyMatureSpeedMultiplier=1.0*') 'Relocation apply: unrelated settings in the destination file are untouched'

        # Post-write validation: re-run the deterministic planner against the
        # NEW live state -- it must now report nothing left to relocate
        # (source gone) and see the setting correctly at its destination.
        $postWriteLines = @{ GU = [IO.File]::ReadAllLines($relocFixtureGU); GI = [IO.File]::ReadAllLines($relocFixtureGI) }
        $postWritePlan = Get-AsaSettingRelocationPlan -SettingName 'PassiveTameIntervalMultiplier' -GameUserSettingsLines $postWriteLines.GU -GameIniLines $postWriteLines.GI
        Assert-True (-not $postWritePlan.Success) 'Relocation apply: post-write validation confirms the source is gone (nothing left to relocate)'
        $postWriteDiag = Invoke-AsaConfigDiagnostics -GameUserSettingsLines $postWriteLines.GU -GameIniLines $postWriteLines.GI
        Assert-True ((@($postWriteDiag.Findings | Where-Object { $_.Key -eq 'PassiveTameIntervalMultiplier' -and $_.Category -eq 'WRONG TARGET FILE' })).Count -eq 0) 'Relocation apply: post-write diagnostics no longer flag the setting as WRONG TARGET FILE'

        Assert-True (((Get-Content -LiteralPath $relocFixtureChangelog) -join "`n") -match 'PassiveTameIntervalMultiplier') 'Relocation apply: a changelog entry was recorded'

        # --- 18b. Rollback restores BOTH files exactly on a forced mid-write failure ---
        [IO.File]::WriteAllLines($relocFixtureGU, $relocOriginalGU)
        [IO.File]::WriteAllLines($relocFixtureGI, $relocOriginalGI)
        Remove-Item -LiteralPath $relocFixtureBackups -Recurse -Force -ErrorAction SilentlyContinue
        Clear-Content -LiteralPath $relocFixtureChangelog -ErrorAction SilentlyContinue

        # Force the SECOND write in the transaction (the Game.ini destination)
        # to fail by simulating "the server started mid-write" on exactly that
        # check -- this happens strictly after GameUserSettings.ini has
        # already been fully replaced with its new content, so rollback must
        # restore a file that really was changed, not a no-op.
        $script:AsaRelocationMockCallCount = 0
        $script:AsaRelocationMockTripAt = 5
        function Get-Process {
            param([string]$Name, $ErrorAction)
            $script:AsaRelocationMockCallCount++
            if ($Name -eq 'ArkAscendedServer' -and $script:AsaRelocationMockCallCount -eq $script:AsaRelocationMockTripAt) {
                return [pscustomobject]@{ Id = 999999; ProcessName = 'ArkAscendedServer' }
            }
            return $null
        }

        try {
            $rollbackResult = Invoke-AsaAiApplyProposal -Proposal $applyProposal
            Assert-True (-not $rollbackResult.Success) 'Relocation rollback: a forced mid-write failure is reported as a failed apply'
            Assert-True ($rollbackResult.Message -like '*restored*') 'Relocation rollback: the failure message confirms automatic restoration'

            $rolledBackGU = Get-Content -LiteralPath $relocFixtureGU
            $rolledBackGI = Get-Content -LiteralPath $relocFixtureGI
            Assert-True ((Compare-Object $relocOriginalGU $rolledBackGU -SyncWindow 0) -eq $null) 'Relocation rollback: GameUserSettings.ini (the file that was actually changed) is restored exactly'
            Assert-True ((Compare-Object $relocOriginalGI $rolledBackGI -SyncWindow 0) -eq $null) 'Relocation rollback: Game.ini is exactly its original content after rollback'
        }
        finally {
            Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
        }
    }
    finally {
        $script:AsaAiTestConfigPathOverride = $null
        Remove-Item -LiteralPath $relocFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 19. Natural-language diagnostic-context resolution -- deterministic, never
#     delegated to the local model. Fixture-based (via the same path
#     override), so this never depends on -- or drifts out of sync with --
#     the live server's current configuration.
# ---------------------------------------------------------------------------
$diagContextFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('asa-diagcontext-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $diagContextFixtureRoot -Force)
$diagContextGU = Join-Path $diagContextFixtureRoot 'GameUserSettings.ini'
$diagContextGI = Join-Path $diagContextFixtureRoot 'Game.ini'
try {
    # The exact three-finding scenario from the request, plus two settings
    # that must NEVER be auto-included (one BLOCKED, one entirely unknown),
    # plus a third that's simply not part of this diagnostic category.
    [IO.File]::WriteAllLines($diagContextGU, @(
        '[ServerSettings]'
        'PassiveTameIntervalMultiplier=0.2'
        'bAllowSpeedLeveling=True'
        'SupplyCrateLootQualityMultiplier=2.0'
        'MaxPlayers=10'
        'NeedsPowerToActivateAquaticCompartments=True'
    ))
    [IO.File]::WriteAllLines($diagContextGI, @(
        '[/Script/ShooterGame.ShooterGameMode]'
        'ActiveMods=12345'
    ))
    $script:AsaAiTestConfigPathOverride = [pscustomobject]@{
        GameUserSettings = $diagContextGU; GameIni = $diagContextGI
        BackupRoot = (Join-Path $diagContextFixtureRoot 'backups'); ChangelogPath = (Join-Path $diagContextFixtureRoot 'CHANGELOG.md')
    }

    # Sanity: ActiveMods (BLOCKED) really does surface as WRONG TARGET FILE
    # too, alongside its BLOCKED finding -- proving the exclusion below is
    # real defense-in-depth, not just "the category never overlaps".
    $diagContextDiag = Invoke-AsaConfigDiagnostics
    Assert-True ((@($diagContextDiag.Findings | Where-Object { $_.Key -eq 'ActiveMods' -and $_.Category -eq 'WRONG TARGET FILE' })).Count -ge 1) 'Sanity: the BLOCKED fixture setting genuinely produces a WRONG TARGET FILE finding too'

    foreach ($phrase in @(
        'Fix the settings diagnostics found in the wrong file',
        'Fix the WRONG TARGET FILE findings',
        'Fix the settings diagnostics identified as WRONG TARGET FILE while preserving their current values. Do not change anything else.'
    )) {
        $nlProposal = Get-AsaAiProposal -Prompt $phrase
        Assert-True (@($nlProposal.Relocations).Count -eq 3) "Diagnostic-context '$phrase': resolves to exactly 3 relocations"
        $relocatedNames = @($nlProposal.Relocations | ForEach-Object { $_.Setting })
        Assert-True ($relocatedNames -contains 'PassiveTameIntervalMultiplier') "Diagnostic-context '$phrase': includes PassiveTameIntervalMultiplier"
        Assert-True ($relocatedNames -contains 'bAllowSpeedLeveling') "Diagnostic-context '$phrase': includes bAllowSpeedLeveling"
        Assert-True ($relocatedNames -contains 'SupplyCrateLootQualityMultiplier') "Diagnostic-context '$phrase': includes SupplyCrateLootQualityMultiplier"
        Assert-True ($relocatedNames -notcontains 'MaxPlayers') "Diagnostic-context '$phrase': never includes MaxPlayers (UNSUPPORTED/BLOCKED)"
        Assert-True ($relocatedNames -notcontains 'NeedsPowerToActivateAquaticCompartments') "Diagnostic-context '$phrase': never includes an unknown/mod setting"
        Assert-True ($relocatedNames -notcontains 'ActiveMods') "Diagnostic-context '$phrase': never includes a BLOCKED setting, even though it also has a WRONG TARGET FILE finding"
        Assert-True (@($nlProposal.Changes).Count -eq 0 -and @($nlProposal.Actions).Count -eq 0 -and @($nlProposal.Recipes).Count -eq 0) "Diagnostic-context '$phrase': proposes nothing else (Do not change anything else)"
    }

    # A prompt that does not name a specific, safe category must NOT be
    # deterministically resolved from diagnostics at all (falls through to
    # the normal model path instead of guessing).
    Assert-True ((Get-AsaAiReferencedDiagnosticCategories -Prompt 'Set XP to 5').Count -eq 0) 'Diagnostic-context: an unrelated request never triggers diagnostic-category resolution'
    Assert-True ((Get-AsaAiReferencedDiagnosticCategories -Prompt 'Fix the diagnostics').Count -eq 0) 'Diagnostic-context: a vague "fix the diagnostics" request (no named safe category) is not guessed'
}
finally {
    $script:AsaAiTestConfigPathOverride = $null
    Remove-Item -LiteralPath $diagContextFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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
