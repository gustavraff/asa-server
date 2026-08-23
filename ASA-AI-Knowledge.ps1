# Local, deterministic ARK: Survival Ascended settings knowledge base + diagnostics.
#
# Source of truth: asa_claude_package/*.json (curated from ark.wiki.gg). This
# file only ever READS that package and the server's current INI files -- it
# never writes to GameUserSettings.ini, Game.ini, or expands what
# ASA-AI-Assistant.ps1's write pipeline (ConvertTo-AsaValidatedProposal /
# Test-AsaAiApplyProposal / Invoke-AsaAiApplyProposal) is allowed to apply.
# Knowledge retrieval and diagnostics stay strictly read-only and separate
# from that allow-listed write path by design.

$script:AsaKnowledgeDatasetFiles = [ordered]@{
    core               = 'asa-core-settings.json'
    leveling           = 'asa-leveling-settings.json'
    spawns             = 'asa-spawn-settings.json'
    loot_items_engrams = 'asa-loot-items-engrams-settings.json'
    dynamic_config     = 'asa-dynamic-config-settings.json'
    content_niche      = 'asa-content-niche-settings.json'
    archive_blocked    = 'asa-archive-blocked-settings.json'
}

# core is always in context; everything else is loaded into a question's
# context only when the question's wording matches its intent keywords.
$script:AsaKnowledgeDefaultDatasets = @('core')

$script:AsaKnowledgeIntentKeywords = [ordered]@{
    leveling           = @('level', 'levels', 'leveling', 'levelling', 'xp', 'experience', 'engram point', 'stat point', 'perlevel', 'per level', 'ramp', 'mutagen')
    spawns             = @('spawn', 'spawns', 'spawning', 'wild dino', 'creature spawn', 'dino spawn', 'npc replace', 'replacement dino', 'dino class')
    loot_items_engrams = @('loot', 'item', 'items', 'engram', 'engrams', 'crafting', 'recipe', 'supply crate', 'harvest amount', 'stack size', 'item quantity')
    dynamic_config     = @('dynamic config', 'dynamicconfig', 'live config', 'runtime config', 'hotfix')
    content_niche      = @('map', 'bunker', 'mission', 'boss', 'tek', 'genesis', 'extinction', 'aberration', 'crystal isles', 'event', 'seasonal')
}

# value_type "array" settings (tuple/nested-parens syntax) documented as
# legitimately repeatable, plus anything whose description says so.
$script:AsaKnowledgeRepeatableHintPattern = 'multiple lines|repeat for each|can be specified multiple times|can have multiple'

function Get-AsaKnowledgePackageRoot {
    Join-Path $PSScriptRoot 'asa_claude_package'
}

function Get-AsaKnowledgeCachePath {
    Join-Path (Get-AsaKnowledgePackageRoot) '.knowledge-index.cache.json'
}

function Get-AsaKnowledgeSourceManifest {
    $root = Get-AsaKnowledgePackageRoot
    $entries = foreach ($dataset in $script:AsaKnowledgeDatasetFiles.Keys) {
        $path = Join-Path $root $script:AsaKnowledgeDatasetFiles[$dataset]
        if (Test-Path -LiteralPath $path) {
            $info = Get-Item -LiteralPath $path
            [pscustomobject]@{ Dataset = $dataset; Ticks = [long]$info.LastWriteTimeUtc.Ticks; Length = [long]$info.Length }
        }
    }
    return @($entries)
}

function Test-AsaKnowledgeManifestMatches {
    param([AllowNull()]$CachedManifest, [Parameter(Mandatory)]$CurrentManifest)

    if (-not $CachedManifest) { return $false }
    $cachedArr = @($CachedManifest)
    $currentArr = @($CurrentManifest)
    if ($cachedArr.Count -ne $currentArr.Count -or $currentArr.Count -eq 0) { return $false }

    foreach ($c in $currentArr) {
        $match = $cachedArr | Where-Object { $_.Dataset -eq $c.Dataset -and [long]$_.Ticks -eq [long]$c.Ticks -and [long]$_.Length -eq [long]$c.Length }
        if (-not $match) { return $false }
    }
    return $true
}

function Build-AsaKnowledgeIndexFromSource {
    $root = Get-AsaKnowledgePackageRoot
    $all = New-Object System.Collections.Generic.List[object]
    $counts = [ordered]@{}
    foreach ($dataset in $script:AsaKnowledgeDatasetFiles.Keys) {
        $path = Join-Path $root $script:AsaKnowledgeDatasetFiles[$dataset]
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @($doc.settings)
        $counts[$dataset] = $entries.Count
        foreach ($entry in $entries) {
            $entry | Add-Member -NotePropertyName Dataset -NotePropertyValue $dataset -Force
            [void]$all.Add($entry)
        }
    }
    return [pscustomobject]@{
        BuiltAtUtc = [DateTime]::UtcNow.ToString('o')
        Counts     = $counts
        Settings   = $all.ToArray()
    }
}

function Save-AsaKnowledgeCache {
    param([Parameter(Mandatory)]$IndexDocument, [Parameter(Mandatory)]$Manifest)

    $cachePath = Get-AsaKnowledgeCachePath
    try {
        $payload = [pscustomobject]@{ Manifest = $Manifest; Index = $IndexDocument }
        $json = $payload | ConvertTo-Json -Depth 12
        $tempPath = $cachePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Copy($tempPath, $cachePath, $true)
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        # The cache is a pure performance optimization; a failed write must
        # never block knowledge lookups, so keep working from the in-memory index.
    }
}

function Get-AsaKnowledgeIndex {
    param([switch]$Force)

    if (-not $Force -and $script:AsaKnowledgeIndex) { return $script:AsaKnowledgeIndex }

    $manifest = Get-AsaKnowledgeSourceManifest
    $cachePath = Get-AsaKnowledgeCachePath
    $document = $null

    if (-not $Force -and (Test-Path -LiteralPath $cachePath)) {
        try {
            $cached = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (Test-AsaKnowledgeManifestMatches -CachedManifest $cached.Manifest -CurrentManifest $manifest) {
                $document = $cached.Index
            }
        }
        catch { $document = $null }
    }

    if (-not $document) {
        $document = Build-AsaKnowledgeIndexFromSource
        Save-AsaKnowledgeCache -IndexDocument $document -Manifest $manifest
    }

    $byNameLower = @{}
    foreach ($entry in @($document.Settings)) {
        $key = ([string]$entry.name).ToLowerInvariant()
        if (-not $byNameLower.ContainsKey($key)) { $byNameLower[$key] = New-Object System.Collections.Generic.List[object] }
        $byNameLower[$key].Add($entry)
    }

    $script:AsaKnowledgeIndex = [pscustomobject]@{
        BuiltAtUtc  = $document.BuiltAtUtc
        Counts      = $document.Counts
        Settings    = @($document.Settings)
        ByNameLower = $byNameLower
    }
    return $script:AsaKnowledgeIndex
}

function Sync-AsaKnowledgeIndex {
    <# Forces a rebuild from the source JSON files and refreshes the disk cache. #>
    Get-AsaKnowledgeIndex -Force | Out-Null
}

function Get-AsaSettingIsSensitive {
    param([Parameter(Mandatory)]$Entry)
    return [bool]$Entry.sensitive
}

function Get-AsaSettingStatusTags {
    param([Parameter(Mandatory)]$Entry)

    $tags = New-Object System.Collections.Generic.List[string]
    switch ([string]$Entry.support) {
        'unsupported' { $tags.Add('UNSUPPORTED') }
        'obsolete'    { $tags.Add('OBSOLETE') }
        'unverified'  { $tags.Add('UNVERIFIED') }
    }
    if ([string]$Entry.ai_usage -eq 'never_auto_apply') { $tags.Add('BLOCKED') }
    if ($tags.Count -eq 0) { $tags.Add('SUPPORTED') }
    return $tags.ToArray()
}

function Get-AsaSettingBaseName {
    param([Parameter(Mandatory)][string]$Key)
    # Strip a trailing [n]/[Stat_ID] subscript so e.g.
    # "PerLevelStatsMultiplier_Player[8]" matches the catalog's base entry
    # "PerLevelStatsMultiplier_Player".
    return ($Key -replace '\[[^\]]*\]\s*$', '').Trim()
}

function Find-AsaSettingExact {
    param([Parameter(Mandatory)][string]$Name)
    $index = Get-AsaKnowledgeIndex
    $baseName = Get-AsaSettingBaseName -Key $Name
    $key = $baseName.ToLowerInvariant()
    if ($index.ByNameLower.ContainsKey($key)) { return [object[]]$index.ByNameLower[$key].ToArray() }
    return @()
}

$script:AsaKnowledgeSearchStopwords = @(
    'how', 'the', 'and', 'for', 'that', 'this', 'with', 'from', 'about', 'what', 'which', 'when', 'where',
    'does', 'doing', 'make', 'makes', 'making', 'want', 'need', 'please', 'help', 'setting', 'settings',
    'server', 'game', 'really', 'totally', 'real', 'actually', 'something', 'currently', 'right', 'much',
    'faster', 'slower', 'higher', 'lower', 'more', 'less', 'change', 'changes', 'changed', 'value', 'values'
)

function Get-AsaKnowledgeSearchTokens {
    param([Parameter(Mandatory)][string]$Text)
    return @(($Text.ToLowerInvariant() -split '[^a-z0-9]+') |
        Where-Object { $_.Length -ge 4 -and $_ -match '[a-z]' -and ($script:AsaKnowledgeSearchStopwords -notcontains $_) })
}

function Get-AsaRelevantDatasets {
    param([Parameter(Mandatory)][string]$Text)

    $lower = $Text.ToLowerInvariant()
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($d in $script:AsaKnowledgeDefaultDatasets) { [void]$selected.Add($d) }
    foreach ($dataset in $script:AsaKnowledgeIntentKeywords.Keys) {
        foreach ($phrase in $script:AsaKnowledgeIntentKeywords[$dataset]) {
            if ($lower -like "*$phrase*") {
                if (-not $selected.Contains($dataset)) { [void]$selected.Add($dataset) }
                break
            }
        }
    }
    return $selected.ToArray()
}

function Search-AsaSettings {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Datasets,
        [int]$MaxResults = 8
    )

    $index = Get-AsaKnowledgeIndex
    $tokens = Get-AsaKnowledgeSearchTokens -Text $Query
    if ($tokens.Count -eq 0) { return @() }

    $candidates = @($index.Settings)
    if ($Datasets -and $Datasets.Count -gt 0) {
        $candidates = @($candidates | Where-Object { $Datasets -contains $_.Dataset })
    }

    $scored = foreach ($entry in $candidates) {
        $haystack = (([string]$entry.name) + ' ' + ([string]$entry.description)).ToLowerInvariant()
        $score = 0
        foreach ($token in $tokens) { if ($haystack -like "*$token*") { $score++ } }
        if ($score -gt 0) { [pscustomobject]@{ Entry = $entry; Score = $score } }
    }

    return @($scored | Sort-Object -Property Score -Descending | Select-Object -First $MaxResults | ForEach-Object { $_.Entry })
}

function Get-AsaCurrentSettingValue {
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.target -notin @('GameUserSettings.ini', 'Game.ini')) { return $null }
    $paths = Get-AsaAiFixedConfigPaths
    $filePath = if ($Entry.target -ceq 'GameUserSettings.ini') { $paths.GameUserSettings } else { $paths.GameIni }
    if (-not (Test-Path -LiteralPath $filePath)) { return $null }
    $lines = [IO.File]::ReadAllLines($filePath)
    return Get-AsaIniValueFromLines -Lines $lines -Section $Entry.section -Key $Entry.name
}

function Format-AsaSettingFact {
    param([Parameter(Mandatory)]$Entry, [switch]$IncludeCurrentValue)

    $tags = Get-AsaSettingStatusTags -Entry $Entry
    $valuePart = ''
    if ($IncludeCurrentValue -and $Entry.target -in @('GameUserSettings.ini', 'Game.ini')) {
        if (Get-AsaSettingIsSensitive -Entry $Entry) {
            # Never read or print a secret's value -- not even redacted from a real read.
            $valuePart = ' Current value: [REDACTED -- secret setting].'
        }
        else {
            $current = Get-AsaCurrentSettingValue -Entry $Entry
            $valuePart = if ($null -ne $current -and [string]$current -ne '') { " Current configured value: $current." } else { ' Current value: not set (game uses its own default).' }
        }
    }

    $defaultText = if ($null -eq $Entry.default) { 'none documented' } else { [string]$Entry.default }
    $rangeText = if ($null -ne $Entry.minimum -or $null -ne $Entry.maximum) { " Range: $($Entry.minimum) to $($Entry.maximum)." } else { '' }
    $enumText = if ($Entry.allowed_values) { " Allowed values: $((@($Entry.allowed_values)) -join ', ')." } else { '' }

    return "$($Entry.name) [$($tags -join ', ')] -- target=$($Entry.target), section=$($Entry.section), type=$($Entry.value_type), default=$defaultText.$rangeText$enumText $($Entry.description)$valuePart"
}

function Get-AsaAiKnowledgeAnswer {
    <#
    Deterministic-first Q&A: exact lookup, then keyword search, always against
    the curated JSON package -- the model is never the authority for whether a
    setting exists. When facts are found, the local model may be asked to
    phrase them (still 100% local, no external tokens); when it isn't
    reachable, the raw facts are returned as the answer instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Model = 'qwen3:8b',
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
        [switch]$SkipLocalExplanation
    )

    $wordCandidates = @([regex]::Matches($Question, '[A-Za-z_][A-Za-z0-9_\[\]]*') | ForEach-Object { $_.Value })
    $exactMatches = New-Object System.Collections.Generic.List[object]
    foreach ($word in $wordCandidates) {
        foreach ($m in (Find-AsaSettingExact -Name $word)) {
            $already = $exactMatches | Where-Object { $_.name -eq $m.name -and $_.target -eq $m.target -and $_.section -eq $m.section }
            if (-not $already) { [void]$exactMatches.Add($m) }
        }
    }

    $facts = New-Object System.Collections.Generic.List[object]
    $method = 'exact'

    if ($exactMatches.Count -gt 0) {
        foreach ($m in $exactMatches) { [void]$facts.Add($m) }
    }
    else {
        $method = 'keyword'
        $datasets = Get-AsaRelevantDatasets -Text $Question
        foreach ($m in (Search-AsaSettings -Query $Question -Datasets $datasets -MaxResults 5)) { [void]$facts.Add($m) }
        if ($facts.Count -eq 0) {
            # Widen to every dataset once (still deterministic retrieval, no guessing) before giving up.
            foreach ($m in (Search-AsaSettings -Query $Question -MaxResults 5)) { [void]$facts.Add($m) }
        }
    }

    if ($facts.Count -eq 0) {
        return [pscustomobject]@{
            Answer      = 'Unknown / insufficient evidence: no setting in the local ASA knowledge base matches this question. It may not be part of the curated library, or the wording did not match a known setting name or description.'
            Facts       = @()
            Method      = 'none'
            UsedLocalAi = $false
        }
    }

    $factLines = @($facts | ForEach-Object { Format-AsaSettingFact -Entry $_ -IncludeCurrentValue })
    $factText = ($factLines | ForEach-Object { "- $_" }) -join "`n"

    if ($SkipLocalExplanation) {
        return [pscustomobject]@{ Answer = $factText; Facts = $facts.ToArray(); Method = $method; UsedLocalAi = $false }
    }

    $systemPrompt = @"
You explain ARK: Survival Ascended dedicated server settings for a private server admin.
You may ONLY use the facts listed below -- they come from a verified local knowledge base. Never invent a setting, default, range, or behavior that is not stated in these facts.
If the facts are insufficient to answer the question, say so plainly instead of guessing.
If a setting is tagged UNSUPPORTED, OBSOLETE, UNVERIFIED, or BLOCKED, say so clearly and do not recommend applying it.
Be concise: 2-6 sentences.

Facts:
$factText
"@

    try {
        $body = @{
            model    = $Model
            stream   = $false
            options  = @{ temperature = 0 }
            messages = @(
                @{ role = 'system'; content = $systemPrompt },
                @{ role = 'user'; content = $Question }
            )
        }
        $uri = $OllamaBaseUrl.TrimEnd('/') + '/api/chat'
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10)
        $answerText = [string]$response.message.content
        if (-not $answerText) { throw 'Empty response from local model.' }
        return [pscustomobject]@{ Answer = $answerText; Facts = $facts.ToArray(); Method = $method; UsedLocalAi = $true }
    }
    catch {
        # Local model unreachable/unavailable: fall back to the deterministic
        # fact text so the question still gets a grounded answer.
        return [pscustomobject]@{ Answer = $factText; Facts = $facts.ToArray(); Method = $method; UsedLocalAi = $false }
    }
}

function ConvertFrom-AsaIniLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines, [Parameter(Mandatory)][string]$TargetFile)

    $entries = New-Object System.Collections.Generic.List[object]
    $currentSection = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $raw = [string]$Lines[$i]
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^\[[^\]]+\]$') { $currentSection = $trimmed; continue }
        $eq = $raw.IndexOf('=')
        if ($eq -lt 0) { continue }
        [void]$entries.Add([pscustomobject]@{
            TargetFile = $TargetFile
            Section    = $currentSection
            Key        = $raw.Substring(0, $eq).Trim()
            Value      = $raw.Substring($eq + 1)
            LineNumber = $i + 1
        })
    }
    return $entries.ToArray()
}

function Test-AsaScalarValueType {
    param([Parameter(Mandatory)][string]$ValueType, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $trimmed = $Value.Trim()
    switch ($ValueType) {
        'boolean' {
            if ($trimmed -inotin @('True', 'False')) { return "Expected True or False, found '$trimmed'." }
        }
        'integer' {
            [long]$n = 0
            if (-not [long]::TryParse($trimmed, [ref]$n)) { return "Expected a whole number, found '$trimmed'." }
        }
        'float' {
            [decimal]$n = 0
            if (-not [decimal]::TryParse($trimmed, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return "Expected a decimal number, found '$trimmed'." }
        }
        default { }
    }
    return $null
}

function Test-AsaValueRange {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($null -eq $Entry.minimum -and $null -eq $Entry.maximum) { return $null }
    [decimal]$n = 0
    if (-not [decimal]::TryParse($Value.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    if ($null -ne $Entry.minimum -and $n -lt [decimal]$Entry.minimum) { return "Value $n is below the documented minimum $($Entry.minimum)." }
    if ($null -ne $Entry.maximum -and $n -gt [decimal]$Entry.maximum) { return "Value $n is above the documented maximum $($Entry.maximum)." }
    return $null
}

function Test-AsaValueEnum {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if (-not $Entry.allowed_values) { return $null }
    $trimmed = $Value.Trim().Trim('"')
    $allowed = @($Entry.allowed_values)
    if ($allowed -inotcontains $trimmed) { return "Value '$trimmed' is not one of the documented allowed values: $($allowed -join ', ')." }
    return $null
}

function Test-AsaSuspiciousValue {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Entry.value_type -ne 'float' -and $Entry.value_type -ne 'integer') { return $null }
    [decimal]$n = 0
    if (-not [decimal]::TryParse($Value.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    if ($Entry.name -match '(Multiplier|Scale|Speed)$' -and $n -le 0) {
        return "Value $n on a rate/multiplier setting will disable or invert its normal effect rather than scale it -- confirm this is intentional."
    }
    return $null
}

function Test-AsaComplexSettingSyntax {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $trimmed = $Value.Trim()
    $issues = New-Object System.Collections.Generic.List[string]

    $openCount = ([regex]::Matches($trimmed, '\(')).Count
    $closeCount = ([regex]::Matches($trimmed, '\)')).Count
    if ($openCount -ne $closeCount) { $issues.Add("Unbalanced parentheses ($openCount open vs $closeCount close).") }
    if ($trimmed -and -not $trimmed.StartsWith('(')) { $issues.Add('Expected the value to start with "(" for this tuple/array setting.') }

    $expectedFields = @([regex]::Matches([string]$Entry.syntax, '([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?=') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ine $Entry.name } |
        Select-Object -Unique)
    foreach ($field in $expectedFields) {
        if ($trimmed -notmatch ([regex]::Escape($field) + '(\[[^\]]*\])?=')) {
            $issues.Add("Missing expected field '$field' from the documented syntax ($($Entry.syntax)).")
        }
    }

    return $issues.ToArray()
}

function Get-AsaDependencyHint {
    param([Parameter(Mandatory)]$Entry)
    $m = [regex]::Match([string]$Entry.description, 'Requires\s+([^\.]+)\.?', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-AsaObsoleteReplacementHint {
    param([Parameter(Mandatory)]$Entry)
    $m = [regex]::Match([string]$Entry.description, '(?:use|replaced by)\s+([^\.]+)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# Fixed Unreal Engine section names that are always client/display bookkeeping,
# independent of ASA or any specific game -- a documented engine convention,
# not project data. Evidence: observed verbatim in this server's own
# GameUserSettings.ini (ScalabilityGroups = sg.* render-quality group values;
# Startup = DLSS/FSR/FrameGeneration/Reflex upscaling toggles), neither of
# which has any dedicated-server meaning (a headless server has no renderer).
$script:AsaKnownEngineNonServerSections = @('[ScalabilityGroups]', '[Startup]')

function Test-AsaIsIgnoredNonServerEntry {
    <#
    Conservative, structural classifier for INI entries that are Unreal
    Engine / client / session bookkeeping rather than dedicated-server
    configuration -- e.g. LastJoinedSessionPerCategory, MasterAudioVolume,
    sg.ResolutionQuality. Never based on a single literal key name: only on
    (a) a fixed, documented UE engine section, (b) the UE naming convention
    for its per-client "GameUserSettings" class (as opposed to the
    server-authoritative GameMode/ServerSettings classes), or (c) the UE
    "sg." scalability-group key prefix convention. Anything that doesn't
    match one of these stays classified as a possible server setting, even
    if it isn't in the catalog -- e.g. mod-added sections like
    [CustomLevelDistrib] or [CybersStructures] are deliberately NOT ignored,
    since mod config commonly is server-relevant.
    #>
    param([Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key)

    $normalizedSection = $Section.Trim()
    if ($script:AsaKnownEngineNonServerSections -icontains $normalizedSection) { return $true }

    # e.g. "[/Script/ShooterGame.ShooterGameUserSettings]" or
    # "[/Script/Engine.GameUserSettings]" -- UE's per-user settings object,
    # distinct from "[/Script/ShooterGame.ShooterGameMode]" / "[ServerSettings]".
    if ($normalizedSection -match '\.\w*GameUserSettings\w*\]$') { return $true }

    if ($Key.Trim() -match '^sg\.') { return $true }

    return $false
}

function New-AsaDiagnosticFinding {
    param([string]$Category, [string]$File, [string]$Section, [string]$Key, [string]$Value, [int]$Line, [string]$Message)
    [pscustomobject]@{ Category = $Category; File = $File; Section = $Section; Key = $Key; Value = $Value; Line = $Line; Message = $Message }
}

function Get-AsaStartupArgumentFindings {
    <# Read-only, informational scan of StartServer.bat's static launch line against command-line-target catalog entries. #>
    $findings = New-Object System.Collections.Generic.List[object]
    $batPath = Join-Path $PSScriptRoot 'StartServer.bat'
    if (-not (Test-Path -LiteralPath $batPath)) { return $findings.ToArray() }

    $content = Get-Content -LiteralPath $batPath -Raw
    $execLine = @($content -split "`r?`n") | Where-Object { $_ -match '\.exe"' } | Select-Object -First 1
    if (-not $execLine) { return $findings.ToArray() }

    $tokens = @([regex]::Matches($execLine, '(?<![\w%])[-?][A-Za-z][A-Za-z0-9_]*(=\S+)?') | ForEach-Object { $_.Value })
    foreach ($token in $tokens) {
        $eq = $token.IndexOf('=')
        $name = if ($eq -ge 0) { $token.Substring(0, $eq) } else { $token }
        $commandLineMatch = @(Find-AsaSettingExact -Name $name) | Where-Object { $_.target -eq 'command-line' }
        if (-not $commandLineMatch) { continue }
        $entry = $commandLineMatch[0]
        foreach ($tag in (Get-AsaSettingStatusTags -Entry $entry)) {
            if ($tag -eq 'SUPPORTED') { continue }
            [void]$findings.Add((New-AsaDiagnosticFinding -Category $tag -File 'StartServer.bat' -Section '(startup arguments)' -Key $name -Value '' -Line 0 -Message $entry.description))
        }
    }
    return $findings.ToArray()
}

function Invoke-AsaConfigDiagnostics {
    <#
    Read-only local configuration health check. Never writes any file.
    Compares the current GameUserSettings.ini / Game.ini (or injected line
    arrays, for testing) against the local ASA knowledge base and returns
    categorized findings. To apply a fix, turn it into a structured proposal
    and run it through the existing ConvertTo-AsaValidatedProposal ->
    Test-AsaAiApplyProposal -> Invoke-AsaAiApplyProposal pipeline -- this
    function never does that itself.
    #>
    param(
        [string[]]$GameUserSettingsLines,
        [string[]]$GameIniLines
    )

    if (-not $PSBoundParameters.ContainsKey('GameUserSettingsLines') -or -not $PSBoundParameters.ContainsKey('GameIniLines')) {
        $paths = Get-AsaAiFixedConfigPaths
        if (-not $PSBoundParameters.ContainsKey('GameUserSettingsLines')) {
            $GameUserSettingsLines = if (Test-Path -LiteralPath $paths.GameUserSettings) { [IO.File]::ReadAllLines($paths.GameUserSettings) } else { @() }
        }
        if (-not $PSBoundParameters.ContainsKey('GameIniLines')) {
            $GameIniLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }
        }
    }

    $parsed = New-Object System.Collections.Generic.List[object]
    [void]$parsed.AddRange([object[]]@(ConvertFrom-AsaIniLines -Lines $GameUserSettingsLines -TargetFile 'GameUserSettings.ini'))
    [void]$parsed.AddRange([object[]]@(ConvertFrom-AsaIniLines -Lines $GameIniLines -TargetFile 'Game.ini'))

    $findings = New-Object System.Collections.Generic.List[object]

    $groups = $parsed | Group-Object -Property { $_.TargetFile + '|' + $_.Section + '|' + $_.Key }
    foreach ($group in $groups) {
        if ($group.Count -le 1) { continue }
        $sample = $group.Group[0]

        if (Test-AsaIsIgnoredNonServerEntry -Section $sample.Section -Key $sample.Key) {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'IGNORED_NON_SERVER' -File $sample.TargetFile -Section $sample.Section -Key $sample.Key -Value '' -Line $sample.LineNumber -Message "Appears $($group.Count) times, but this is Unreal Engine / client bookkeeping, not a dedicated-server setting -- not a configuration problem."))
            continue
        }

        $baseName = Get-AsaSettingBaseName -Key $sample.Key
        $catalogEntries = Find-AsaSettingExact -Name $baseName
        $isRepeatable = (@($catalogEntries | Where-Object { $_.value_type -eq 'array' })).Count -gt 0 -or
                        (@($catalogEntries | Where-Object { [string]$_.description -match $script:AsaKnowledgeRepeatableHintPattern })).Count -gt 0
        $sensitiveHit = (@($catalogEntries | Where-Object { Get-AsaSettingIsSensitive -Entry $_ })).Count -gt 0
        $lines = ($group.Group | ForEach-Object { $val = if ($sensitiveHit) { '[REDACTED]' } else { $_.Value.Trim() }; "line $($_.LineNumber)=`"$val`"" }) -join '; '
        if ($isRepeatable) {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'INFORMATION' -File $sample.TargetFile -Section $sample.Section -Key $sample.Key -Value '' -Line $sample.LineNumber -Message "Appears $($group.Count) times ($lines) -- documented as repeatable; each line applies independently."))
        }
        else {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'DUPLICATES' -File $sample.TargetFile -Section $sample.Section -Key $sample.Key -Value '' -Line $sample.LineNumber -Message "Appears $($group.Count) times ($lines) -- ASA resolves duplicates to whichever the loader reads last; remove the extra line(s)."))
        }
    }

    foreach ($item in $parsed) {
        if (Test-AsaIsIgnoredNonServerEntry -Section $item.Section -Key $item.Key) {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'IGNORED_NON_SERVER' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $item.Value.Trim() -Line $item.LineNumber -Message 'Unreal Engine / client / session bookkeeping (e.g. audio, video, UI, or session-history state), not a dedicated-server configuration setting.'))
            continue
        }

        $baseName = Get-AsaSettingBaseName -Key $item.Key
        $candidates = Find-AsaSettingExact -Name $baseName
        $isSensitiveHit = (@($candidates | Where-Object { Get-AsaSettingIsSensitive -Entry $_ })).Count -gt 0
        $displayValue = if ($isSensitiveHit) { '[REDACTED]' } else { $item.Value.Trim() }

        if ($candidates.Count -eq 0) {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'UNKNOWN_SERVER_SETTING' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message 'No entry for this setting exists in the local ASA knowledge base (checked all categories, including archive/blocked). It may be a mod-added key, a typo, or a real server setting missing from the curated package.'))
            continue
        }

        $exact = @($candidates | Where-Object { $_.target -ceq $item.TargetFile -and ([string]$_.section).Trim() -ieq $item.Section.Trim() })
        $sameTarget = @($candidates | Where-Object { $_.target -ceq $item.TargetFile })
        $best = if ($exact.Count -gt 0) { $exact[0] } elseif ($sameTarget.Count -gt 0) { $sameTarget[0] } else { $candidates[0] }

        if ($exact.Count -eq 0) {
            if ($sameTarget.Count -gt 0) {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'WRONG SECTION' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "Documented section is $($best.section), not $($item.Section) -- it may silently have no effect here."))
            }
            elseif ($best.target -eq 'DynamicConfig') {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'NO EFFECT' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message 'This is a DynamicConfig-only setting; placing it in an INI file has no effect. It must be set through the live DynamicConfig mechanism instead.'))
            }
            elseif ($best.target -eq 'command-line') {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'NO EFFECT' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message 'This is a startup command-line argument, not an INI setting; placing it in an INI file has no effect.'))
            }
            else {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'WRONG TARGET FILE' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "Documented target is $($best.target), not $($item.TargetFile)."))
            }
        }

        foreach ($tag in (Get-AsaSettingStatusTags -Entry $best)) {
            if ($tag -eq 'SUPPORTED') { continue }
            $extra = ''
            if ($tag -eq 'OBSOLETE') {
                $hint = Get-AsaObsoleteReplacementHint -Entry $best
                if ($hint) { $extra = " Replacement: $hint." }
            }
            [void]$findings.Add((New-AsaDiagnosticFinding -Category $tag -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "$($best.description)$extra"))
        }

        if ($best.value_type -eq 'array') {
            foreach ($issue in (Test-AsaComplexSettingSyntax -Entry $best -Value $item.Value)) {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'ERRORS' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message $issue))
            }
        }
        else {
            $typeIssue = Test-AsaScalarValueType -ValueType $best.value_type -Value $item.Value
            if ($typeIssue) {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'ERRORS' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message $typeIssue))
            }
            else {
                $rangeIssue = Test-AsaValueRange -Entry $best -Value $item.Value
                if ($rangeIssue) { [void]$findings.Add((New-AsaDiagnosticFinding -Category 'ERRORS' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message $rangeIssue)) }

                $enumIssue = Test-AsaValueEnum -Entry $best -Value $item.Value
                if ($enumIssue) { [void]$findings.Add((New-AsaDiagnosticFinding -Category 'ERRORS' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message $enumIssue)) }

                $suspicious = Test-AsaSuspiciousValue -Entry $best -Value $item.Value
                if ($suspicious) { [void]$findings.Add((New-AsaDiagnosticFinding -Category 'SUSPICIOUS VALUES' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message $suspicious)) }
            }
        }

        $dependency = Get-AsaDependencyHint -Entry $best
        if ($dependency) {
            [void]$findings.Add((New-AsaDiagnosticFinding -Category 'DEPENDENCY ISSUES' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "This setting only takes effect when $dependency -- verify that is also configured."))
        }
    }

    foreach ($f in (Get-AsaStartupArgumentFindings)) { [void]$findings.Add($f) }

    $categorized = [ordered]@{}
    foreach ($f in $findings) {
        if (-not $categorized.Contains($f.Category)) { $categorized[$f.Category] = New-Object System.Collections.Generic.List[object] }
        $categorized[$f.Category].Add($f)
    }

    $ignoredCount = (@($findings | Where-Object { $_.Category -eq 'IGNORED_NON_SERVER' })).Count
    $informationalCount = (@($findings | Where-Object { $_.Category -eq 'INFORMATION' })).Count
    $problemCount = $findings.Count - $ignoredCount - $informationalCount

    return [pscustomobject]@{
        GeneratedAtUtc             = [DateTime]::UtcNow.ToString('o')
        TotalFindings              = $findings.Count
        Findings                   = $findings.ToArray()
        ByCategory                 = $categorized
        # Actual configuration problems the user should look at (everything
        # except INFORMATION and IGNORED_NON_SERVER).
        ProblemFindingsCount       = $problemCount
        InformationalFindingsCount = $informationalCount
        IgnoredNonServerCount      = $ignoredCount
    }
}

# Categories shown by default in the "Analyze ASA configuration" UI. Anything
# not listed here (currently just IGNORED_NON_SERVER) is still fully present
# in Findings/ByCategory for anyone who wants the raw detail -- it is only
# hidden from the default view, never deleted or recomputed away.
$script:AsaDiagnosticsDefaultVisibleCategories = @(
    'ERRORS', 'WRONG TARGET FILE', 'WRONG SECTION', 'DEPENDENCY ISSUES', 'CONFLICTS',
    'DUPLICATES', 'UNSUPPORTED', 'OBSOLETE', 'UNVERIFIED', 'BLOCKED',
    'SUSPICIOUS VALUES', 'UNKNOWN_SERVER_SETTING', 'INFORMATION', 'NO EFFECT'
)

function Get-AsaConfigDiagnosticsDisplayFindings {
    <#
    Read-only presentation filter for Invoke-AsaConfigDiagnostics's result:
    returns only the findings worth showing a human by default (drops
    IGNORED_NON_SERVER bookkeeping noise). The full, unfiltered result is
    still available on the Diagnostics object this was built from -- nothing
    is deleted, this just picks what a UI renders first.
    #>
    param([Parameter(Mandatory)]$Diagnostics)
    return @($Diagnostics.Findings | Where-Object { $script:AsaDiagnosticsDefaultVisibleCategories -contains $_.Category })
}
