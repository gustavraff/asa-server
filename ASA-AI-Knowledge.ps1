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

    # A question naming a current/effective-configuration concept ("current
    # player limit", "which mods are loaded", ...) is answered entirely
    # deterministically -- explicit command-line/INI value, documented
    # default, and obsolete/replaced precedence are never left for the
    # generative model to decide. This check runs before anything else and,
    # when it matches, is the whole answer.
    $effectiveValueConcept = Get-AsaEffectiveValueQueryConcept -Question $Question
    if ($effectiveValueConcept) {
        $effectiveAnswer = Get-AsaEffectiveSettingAnswer -SettingName $effectiveValueConcept
        $relatedFacts = @(Find-AsaSettingExact -Name $effectiveValueConcept)
        if ($effectiveAnswer.EffectiveSettingName -and $effectiveAnswer.EffectiveSettingName -ne $effectiveValueConcept) {
            $relatedFacts += @(Find-AsaSettingExact -Name $effectiveAnswer.EffectiveSettingName)
        }
        return [pscustomobject]@{ Answer = $effectiveAnswer.Message; Facts = $relatedFacts; Method = 'effective-value'; UsedLocalAi = $false }
    }

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

$script:AsaSecretKeyPattern = 'password|passwd|apikey|api[_-]?key|token|secret|credential'

function Test-AsaKeyLooksSecret {
    <# Heuristic, name-based secret detector used only for clipboard/export
       redaction -- independent of (and in addition to) the knowledge base's
       per-entry "sensitive" flag, so an unrecognized key like a mod-added
       token still never reaches the clipboard in cleartext. #>
    param([Parameter(Mandatory)][string]$Key)
    return [bool]([regex]::IsMatch($Key, $script:AsaSecretKeyPattern, 'IgnoreCase'))
}

function Get-AsaDependencyRequirement {
    <#
    Deterministically parses a dependency hint of the form "SettingName=Value"
    (optionally followed by trailing qualifier text such as "in command line")
    into a structured Setting/Value pair. Returns $null when the hint isn't in
    this shape (e.g. a bare command-line flag like "-clusterid" or a
    "SettingName in <file>" presence-only requirement) -- those keep being
    reported the same way as before, since there is no deterministic value to
    compare against.
    #>
    param([Parameter(Mandatory)][string]$HintText)

    $m = [regex]::Match($HintText.Trim(), '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\S+)')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{
        SettingName   = $m.Groups[1].Value
        RequiredValue = $m.Groups[2].Value
    }
}

function Get-AsaEffectiveSettingValue {
    <#
    Resolves the EFFECTIVE value of a dependency's required setting, in order:
    1. Explicitly configured value, if present anywhere in the parsed INI entries.
    2. Otherwise, the documented default from the knowledge base, if known.
    3. Otherwise Unknown -- no configured value and no verified default.
    Never writes anything -- purely a read/compare over already-parsed lines.
    #>
    param(
        [Parameter(Mandatory)][string]$SettingName,
        [Parameter(Mandatory)][AllowEmptyCollection()]$ParsedEntries
    )

    $baseName = Get-AsaSettingBaseName -Key $SettingName
    $catalog = @(Find-AsaSettingExact -Name $baseName)
    $isSensitive = (Test-AsaKeyLooksSecret -Key $baseName) -or
                   ((@($catalog | Where-Object { Get-AsaSettingIsSensitive -Entry $_ })).Count -gt 0)

    $explicit = @($ParsedEntries | Where-Object { (Get-AsaSettingBaseName -Key $_.Key) -ieq $baseName })
    if ($explicit.Count -gt 0) {
        $value = $explicit[0].Value.Trim()
        return [pscustomobject]@{
            Value        = $value
            Source       = 'Explicit configuration'
            DisplayValue = if ($isSensitive) { '[REDACTED]' } else { $value }
        }
    }

    if ($catalog.Count -gt 0 -and $null -ne $catalog[0].default) {
        $value = [string]$catalog[0].default
        return [pscustomobject]@{
            Value        = $value
            Source       = 'Documented default'
            DisplayValue = if ($isSensitive) { '[REDACTED]' } else { $value }
        }
    }

    return [pscustomobject]@{ Value = $null; Source = 'Unknown'; DisplayValue = $null }
}

function Test-AsaDependencyValueMatches {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Effective, [Parameter(Mandatory)][AllowEmptyString()][string]$Required)

    $e = $Effective.Trim().Trim('"')
    $r = $Required.Trim().Trim('"')
    if ($e -ieq $r) { return $true }

    [decimal]$en = 0; [decimal]$rn = 0
    if ([decimal]::TryParse($e, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$en) -and
        [decimal]::TryParse($r, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rn)) {
        return $en -eq $rn
    }
    return $false
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
    param(
        [string]$Category, [string]$File, [string]$Section, [string]$Key, [string]$Value, [int]$Line, [string]$Message,
        [string]$ExpectedFile, [string]$ExpectedSection, [string]$EffectiveValue, [string]$ValueSource,
        [string]$Dependency, [string]$Replacement
    )
    [pscustomobject]@{
        Category         = $Category
        File             = $File
        Section          = $Section
        Key              = $Key
        Value            = $Value
        Line             = $Line
        Message          = $Message
        # Optional, category-specific extras -- populated only when applicable
        # and deterministically derivable, so a plain-text/clipboard renderer
        # can include them without ever having to guess.
        ExpectedFile     = $ExpectedFile
        ExpectedSection  = $ExpectedSection
        EffectiveValue   = $EffectiveValue
        ValueSource      = $ValueSource
        Dependency       = $Dependency
        Replacement      = $Replacement
    }
}

# ---------------------------------------------------------------------------
# Current server configuration awareness -- reads the SAME files ASA Manager
# itself uses to launch ArkAscendedServer.exe (server-config.cmd for the
# editable values, StartServer.bat for the launch-line template) so the AI/
# diagnostics layer never maintains a second, independent notion of "what the
# server is actually configured to run with." Read-only throughout; never
# writes to either file.
# ---------------------------------------------------------------------------

function Get-AsaCurrentCmdConfig {
    <#
    Reads server-config.cmd exactly the way ASA-Manager.ps1's own
    Read-CmdConfig does (same file, same "set "KEY=value"" regex) -- this is
    the same source of truth ASA Manager uses to launch the server, not a
    second independent one.
    #>
    # Test-only redirection hook (mirrors $script:AsaAiTestConfigPathOverride
    # in ASA-AI-Assistant.ps1): lets tests point this at an isolated fixture
    # file instead of the real, live server-config.cmd. Never set in
    # production code paths.
    $path = if ($script:AsaAiTestCmdConfigPath) { $script:AsaAiTestCmdConfigPath } else { Join-Path $PSScriptRoot 'server-config.cmd' }
    $values = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $values }
    $raw = [IO.File]::ReadAllText($path)
    foreach ($match in [regex]::Matches($raw, '(?m)^set\s+"(?<key>[A-Z_]+)=(?<value>.*)"\s*$')) {
        $values[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }
    return $values
}

function Get-AsaEffectiveStartupArguments {
    <#
    Resolves StartServer.bat's actual launch line -- the same batch file ASA
    Manager's Start/Restart actions invoke -- into the REAL current startup
    arguments, by substituting server-config.cmd's variables and replicating
    StartServer.bat's own two conditional lines (-mods, -AllowSpeedLeveling).
    This is deliberately specific to this project's StartServer.bat template
    (a handful of "set VAR=" / "if defined VAR" lines), not a general batch
    interpreter -- if that template changes shape, this needs updating too.
    Read-only; never modifies either file. Any argument whose name looks
    secret-like is redacted in DisplayValue via Test-AsaKeyLooksSecret.
    #>
    # Test-only redirection hook, same pattern as Get-AsaCurrentCmdConfig's.
    $batPath = if ($script:AsaAiTestStartServerBatPath) { $script:AsaAiTestStartServerBatPath } else { Join-Path $PSScriptRoot 'StartServer.bat' }
    if (-not (Test-Path -LiteralPath $batPath)) {
        return [pscustomobject]@{ Available = $false; Reason = 'StartServer.bat was not found.'; Source = $null; Arguments = @(); UnresolvedPlaceholders = @() }
    }

    $content = Get-Content -LiteralPath $batPath -Raw
    $batLines = @($content -split "`r?`n")
    # The real invocation line STARTS by quoting and calling the resolved exe
    # variable (`"%EXE%" ...`) -- unlike the earlier `set "EXE=...exe"` line
    # that merely DEFINES it, or an `if not exist "%EXE%" (` existence guard,
    # both of which also contain "%EXE%"/".exe" but never at the line start.
    $execLine = @($batLines | Where-Object { $_ -match '^\s*"%EXE%"' }) | Select-Object -First 1
    if (-not $execLine) {
        # Defensive fallback for a differently-shaped launch line, excluding
        # any plain "set" variable definition.
        $execLine = @($batLines | Where-Object { $_ -match '\.exe"' -and $_ -notmatch '^\s*set\b' }) | Select-Object -First 1
    }
    if (-not $execLine) {
        return [pscustomobject]@{ Available = $false; Reason = 'StartServer.bat has no recognizable server .exe launch line.'; Source = $null; Arguments = @(); UnresolvedPlaceholders = @() }
    }

    $cmdConfig = Get-AsaCurrentCmdConfig
    if ($cmdConfig.Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Reason = 'server-config.cmd was not found or has no recognized values.'; Source = $null; Arguments = @(); UnresolvedPlaceholders = @() }
    }

    # Replicate StartServer.bat's own two conditionally-set variables.
    $modArg = if ([string]$cmdConfig['MODS']) { '-mods=' + $cmdConfig['MODS'] } else { '' }
    $speedArg = if (([string]$cmdConfig['ALLOW_SPEED_LEVELING']) -ieq 'True') { '-AllowSpeedLeveling' } else { '' }

    $substitutions = @{}
    foreach ($key in $cmdConfig.Keys) { $substitutions[$key] = $cmdConfig[$key] }
    $substitutions['MOD_ARG'] = $modArg
    $substitutions['SPEED_ARG'] = $speedArg

    $resolvedLine = $execLine
    foreach ($key in $substitutions.Keys) {
        $resolvedLine = $resolvedLine.Replace('%' + $key + '%', [string]$substitutions[$key])
    }

    # Anything still shaped like %SOME_VAR% after substitution is a value we
    # could not resolve (e.g. the template changed) -- surfaced, not guessed.
    # "%*" (StartServer.bat's own passthrough of any EXTRA args it was
    # invoked with) is a distinct batch construct, not a %VAR%, and is never
    # resolvable from these static files alone -- deliberately not modeled.
    $unresolvedPlaceholders = @([regex]::Matches($resolvedLine, '%[A-Za-z_][A-Za-z0-9_]*%') | ForEach-Object { $_.Value } | Select-Object -Unique)

    $tokens = @([regex]::Matches($resolvedLine, '(?<![\w%])[-?][A-Za-z][A-Za-z0-9_]*(=\S*)?') | ForEach-Object { $_.Value })
    $arguments = New-Object System.Collections.Generic.List[object]
    foreach ($token in $tokens) {
        $eq = $token.IndexOf('=')
        $name = if ($eq -ge 0) { $token.Substring(0, $eq) } else { $token }
        $hasValue = $eq -ge 0
        $value = if ($hasValue) { $token.Substring($eq + 1) } else { $null }
        $isSecret = Test-AsaKeyLooksSecret -Key $name
        $arguments.Add([pscustomobject]@{
            Name         = $name
            HasValue     = $hasValue
            Value        = $value
            DisplayValue = if ($isSecret) { '[REDACTED]' } else { $value }
            IsSecret     = $isSecret
        })
    }

    return [pscustomobject]@{
        Available              = $true
        Reason                 = $null
        Source                 = 'StartServer.bat startup arguments (server-config.cmd)'
        Arguments              = $arguments.ToArray()
        UnresolvedPlaceholders = $unresolvedPlaceholders
    }
}

function Find-AsaEffectiveStartupArgumentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$StartupArguments
    )
    if (-not $StartupArguments.Available) { return $null }
    return @($StartupArguments.Arguments | Where-Object { $_.Name -ieq $Name }) | Select-Object -First 1
}

function Resolve-AsaSingleSettingEffectiveValue {
    <#
    Deterministic precedence for ONE catalog entry -- never delegated to the
    generative model: explicit command-line configuration, or explicit INI
    configuration (whichever matches the entry's own documented target),
    then the documented default, then a plain "not configured, no default"
    fact. Returns Determined=$false only when we lack the information to
    even attempt this (e.g. startup arguments unavailable for a
    command-line-target entry) -- callers must report that as "unable to
    determine," never fall back to guessing.
    #>
    param([Parameter(Mandatory)]$Entry, $StartupArguments)

    $isSensitive = Get-AsaSettingIsSensitive -Entry $Entry

    if ($Entry.target -eq 'command-line') {
        if (-not $StartupArguments -or -not $StartupArguments.Available) {
            return [pscustomobject]@{ Determined = $false; Value = $null; Source = $null; ConfiguredIn = $null }
        }
        $match = Find-AsaEffectiveStartupArgumentValue -Name $Entry.name -StartupArguments $StartupArguments
        if ($match) {
            $rawValue = if ($match.HasValue) { $match.Value } else { 'True' }
            $displayValue = if ($isSensitive -or $match.IsSecret) { '[REDACTED]' } else { $rawValue }
            return [pscustomobject]@{ Determined = $true; Value = $displayValue; Source = 'Explicit command-line configuration'; ConfiguredIn = $StartupArguments.Source }
        }
        if ($null -ne $Entry.default) {
            return [pscustomobject]@{ Determined = $true; Value = [string]$Entry.default; Source = 'Documented default'; ConfiguredIn = $null }
        }
        return [pscustomobject]@{ Determined = $true; Value = $null; Source = 'Not explicitly configured (no documented default)'; ConfiguredIn = $null }
    }

    if ($Entry.target -in @('GameUserSettings.ini', 'Game.ini')) {
        $current = Get-AsaCurrentSettingValue -Entry $Entry
        if ($null -ne $current -and [string]$current -ne '') {
            $displayValue = if ($isSensitive) { '[REDACTED]' } else { [string]$current }
            return [pscustomobject]@{ Determined = $true; Value = $displayValue; Source = 'Explicit INI configuration'; ConfiguredIn = "$($Entry.target) $($Entry.section)" }
        }
        if ($null -ne $Entry.default) {
            return [pscustomobject]@{ Determined = $true; Value = [string]$Entry.default; Source = 'Documented default'; ConfiguredIn = $null }
        }
        return [pscustomobject]@{ Determined = $true; Value = $null; Source = 'Not explicitly configured (no documented default)'; ConfiguredIn = $null }
    }

    return [pscustomobject]@{ Determined = $false; Value = $null; Source = $null; ConfiguredIn = $null }
}

function Format-AsaEffectiveValueAnswerText {
    param(
        [Parameter(Mandatory)][string]$EffectiveSettingName,
        [Parameter(Mandatory)]$Result,
        $Legacy
    )

    if (-not $Result.Determined) { return 'Unable to determine from current local configuration.' }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Effective value: $(if ($null -ne $Result.Value) { $Result.Value } else { '(not set)' })")
    [void]$lines.Add('')
    [void]$lines.Add('Effective source:')
    if ($Result.Source -eq 'Documented default') {
        [void]$lines.Add("Documented default. $EffectiveSettingName is not explicitly configured.")
    }
    elseif ($Result.Source -like 'Not explicitly configured*') {
        [void]$lines.Add("$EffectiveSettingName is not explicitly configured, and no default is documented.")
    }
    else {
        [void]$lines.Add("$EffectiveSettingName=$($Result.Value)")
    }

    if ($Result.ConfiguredIn) {
        [void]$lines.Add('')
        [void]$lines.Add('Configured in:')
        [void]$lines.Add($Result.ConfiguredIn)
    }

    if ($Legacy) {
        [void]$lines.Add('')
        [void]$lines.Add('Legacy entry:')
        [void]$lines.Add("$($Legacy.Name)=$($Legacy.Value)")
        if ($Legacy.Location) { [void]$lines.Add($Legacy.Location) }
        [void]$lines.Add('')
        [void]$lines.Add('Status:')
        [void]$lines.Add($Legacy.StatusText)
    }

    return ($lines -join "`r`n")
}

function Get-AsaEffectiveSettingAnswer {
    <#
    Deterministic effective-value resolution for a named setting -- the
    generative model never decides precedence here. When the queried setting
    is itself unsupported/obsolete and its description names a replacement
    (e.g. MaxPlayers -> -WinLiveMaxPlayers), the REPLACEMENT's resolved value
    is what is reported as effective; the original is reported separately as
    a legacy/ineffective entry, but only when it actually has a value
    configured at its own (ineffective) location.
    #>
    param([Parameter(Mandatory)][string]$SettingName)

    $primaryCandidates = @(Find-AsaSettingExact -Name $SettingName)
    if ($primaryCandidates.Count -eq 0) {
        return [pscustomobject]@{ Determined = $false; EffectiveSettingName = $SettingName; EffectiveValue = $null; EffectiveSource = $null; ConfiguredIn = $null; Legacy = $null; Message = 'Unable to determine from current local configuration.' }
    }
    $primary = $primaryCandidates[0]

    $primaryTags = Get-AsaSettingStatusTags -Entry $primary
    $replacementName = $null
    if ($primaryTags -contains 'UNSUPPORTED' -or $primaryTags -contains 'OBSOLETE') {
        $replacementName = Get-AsaObsoleteReplacementHint -Entry $primary
    }

    $effective = $primary
    $legacySource = $null
    if ($replacementName) {
        $replacementCandidates = @(Find-AsaSettingExact -Name $replacementName | Where-Object { (Get-AsaSettingStatusTags -Entry $_) -contains 'SUPPORTED' })
        if ($replacementCandidates.Count -gt 0) {
            $effective = $replacementCandidates[0]
            $legacySource = $primary
        }
    }

    $startupArguments = $null
    if ($effective.target -eq 'command-line') { $startupArguments = Get-AsaEffectiveStartupArguments }
    $result = Resolve-AsaSingleSettingEffectiveValue -Entry $effective -StartupArguments $startupArguments

    $legacyInfo = $null
    if ($legacySource -and $legacySource.target -in @('GameUserSettings.ini', 'Game.ini')) {
        $legacyValue = Get-AsaCurrentSettingValue -Entry $legacySource
        if ($null -ne $legacyValue -and [string]$legacyValue -ne '') {
            $legacyDisplayValue = if (Get-AsaSettingIsSensitive -Entry $legacySource) { '[REDACTED]' } else { [string]$legacyValue }
            $legacyInfo = [pscustomobject]@{
                Name       = $legacySource.name
                Value      = $legacyDisplayValue
                Location   = "$($legacySource.target) $($legacySource.section)"
                StatusText = "$($legacySource.name) is not controlling the effective value."
            }
        }
    }

    $message = Format-AsaEffectiveValueAnswerText -EffectiveSettingName $effective.name -Result $result -Legacy $legacyInfo
    return [pscustomobject]@{
        Determined           = $result.Determined
        EffectiveSettingName = $effective.name
        EffectiveValue       = $result.Value
        EffectiveSource      = $result.Source
        ConfiguredIn         = $result.ConfiguredIn
        Legacy               = $legacyInfo
        Message              = $message
    }
}

# Deterministic phrase -> canonical setting-name map for "what is my current
# X" style questions. Matching here NEVER touches the local model -- a plain
# keyword check, so which concept (and therefore which catalog entry/
# precedence) is being asked about is never left for the model to invent.
$script:AsaEffectiveValueQueryConcepts = [ordered]@{
    'MaxPlayers'        = @('player limit', 'max player', 'maximum player', 'how many players')
    '-port'             = @('server port', 'which port', 'game port', 'what port')
    '-ServerPlatform'   = @('platform', 'platforms allowed', 'crossplay', 'which platforms')
    '-mods'             = @('mods loaded', 'which mods', 'mod list', 'loaded mods', 'mods are loaded')
    '-UseDynamicConfig' = @('dynamicconfig', 'dynamic config')
    '-clusterid'        = @('cluster id', 'cluster name', 'which cluster')
}

function Get-AsaEffectiveValueQueryConcept {
    <#
    Deterministic keyword match only -- never delegated to the model. The
    phrase list itself is deliberately narrow/specific ("player limit",
    "which mods", "cluster id", ...) so a plain "what does -mods do?"
    question (no such phrase present) still gets the normal facts-only
    answer instead of being redirected here.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Question)

    $lower = $Question.ToLowerInvariant()
    foreach ($setting in $script:AsaEffectiveValueQueryConcepts.Keys) {
        foreach ($phrase in $script:AsaEffectiveValueQueryConcepts[$setting]) {
            if ($lower.Contains($phrase)) { return $setting }
        }
    }
    return $null
}

function Get-AsaStartupArgumentFindings {
    <# Read-only, informational scan of StartServer.bat's ACTUAL RESOLVED launch arguments (server-config.cmd substituted in) against command-line-target catalog entries. #>
    $findings = New-Object System.Collections.Generic.List[object]
    $startupArguments = Get-AsaEffectiveStartupArguments
    if (-not $startupArguments.Available) { return $findings.ToArray() }

    foreach ($argument in $startupArguments.Arguments) {
        $commandLineMatch = @(Find-AsaSettingExact -Name $argument.Name) | Where-Object { $_.target -eq 'command-line' }
        if (-not $commandLineMatch) { continue }
        $entry = $commandLineMatch[0]
        foreach ($tag in (Get-AsaSettingStatusTags -Entry $entry)) {
            if ($tag -eq 'SUPPORTED') { continue }
            [void]$findings.Add((New-AsaDiagnosticFinding -Category $tag -File 'StartServer.bat' -Section '(startup arguments)' -Key $argument.Name -Value $argument.DisplayValue -Line 0 -Message $entry.description))
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
    # Computed once per run (not per finding) -- read-only snapshot of the
    # server's ACTUAL current startup arguments, reused below so an
    # unsupported/obsolete setting's real effective replacement (e.g.
    # MaxPlayers -> -WinLiveMaxPlayers) can be shown, not just its own
    # ignored value.
    $diagnosticsStartupArguments = Get-AsaEffectiveStartupArguments

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
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'WRONG SECTION' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "Documented section is $($best.section), not $($item.Section) -- it may silently have no effect here." -ExpectedFile $item.TargetFile -ExpectedSection $best.section))
            }
            elseif ($best.target -eq 'DynamicConfig') {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'NO EFFECT' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message 'This is a DynamicConfig-only setting; placing it in an INI file has no effect. It must be set through the live DynamicConfig mechanism instead.'))
            }
            elseif ($best.target -eq 'command-line') {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'NO EFFECT' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message 'This is a startup command-line argument, not an INI setting; placing it in an INI file has no effect.'))
            }
            else {
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'WRONG TARGET FILE' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "Documented target is $($best.target), not $($item.TargetFile)." -ExpectedFile $best.target -ExpectedSection $best.section))
            }
        }

        foreach ($tag in (Get-AsaSettingStatusTags -Entry $best)) {
            if ($tag -eq 'SUPPORTED') { continue }
            $extra = ''
            $replacementHint = $null
            $effectiveValueText = $null
            $effectiveValueSource = $null
            if ($tag -eq 'OBSOLETE' -or $tag -eq 'UNSUPPORTED') {
                $replacementHint = Get-AsaObsoleteReplacementHint -Entry $best
                if ($replacementHint) {
                    $extra = " Replacement: $replacementHint."
                    # Look up the replacement's REAL current effective value
                    # (startup arguments or INI, per its own documented
                    # target) so the finding shows what's actually governing
                    # behavior, not just that a replacement exists in theory.
                    $replacementEntry = @(Find-AsaSettingExact -Name $replacementHint | Where-Object { (Get-AsaSettingStatusTags -Entry $_) -contains 'SUPPORTED' }) | Select-Object -First 1
                    if ($replacementEntry) {
                        $resolvedReplacement = Resolve-AsaSingleSettingEffectiveValue -Entry $replacementEntry -StartupArguments $diagnosticsStartupArguments
                        if ($resolvedReplacement.Determined) {
                            $effectiveValueText = $resolvedReplacement.Value
                            $effectiveValueSource = $resolvedReplacement.Source
                            $shownValue = if ($null -ne $effectiveValueText) { $effectiveValueText } else { '(not set)' }
                            $extra += " Effective replacement: $($replacementEntry.name)=$shownValue ($effectiveValueSource). Safe cleanup candidate: this legacy $($best.name) entry can be removed without changing the effective value."
                        }
                    }
                }
            }
            [void]$findings.Add((New-AsaDiagnosticFinding -Category $tag -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "$($best.description)$extra" -Replacement $replacementHint -EffectiveValue $effectiveValueText -ValueSource $effectiveValueSource))
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
            # Deterministic EFFECTIVE-value evaluation -- never delegated to the
            # local generative model. A dependency setting that is missing from
            # the INI but has a documented default is satisfied by that default;
            # only a real violation or a genuinely unknown effective value is
            # reported as a DEPENDENCY ISSUES problem.
            $requirement = Get-AsaDependencyRequirement -HintText $dependency
            if ($requirement) {
                $effective = Get-AsaEffectiveSettingValue -SettingName $requirement.SettingName -ParsedEntries $parsed
                if ($null -eq $effective.Value) {
                    [void]$findings.Add((New-AsaDiagnosticFinding -Category 'DEPENDENCY ISSUES' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "This setting only takes effect when $dependency. $($requirement.SettingName) has no explicitly configured value and no documented default, so the dependency cannot be verified." -Dependency $dependency -ValueSource $effective.Source))
                }
                elseif (Test-AsaDependencyValueMatches -Effective $effective.Value -Required $requirement.RequiredValue) {
                    [void]$findings.Add((New-AsaDiagnosticFinding -Category 'INFORMATION' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "Dependency satisfied by $($effective.Source.ToLowerInvariant()): $($requirement.SettingName)=$($effective.DisplayValue)." -Dependency $dependency -EffectiveValue $effective.DisplayValue -ValueSource $effective.Source))
                }
                else {
                    [void]$findings.Add((New-AsaDiagnosticFinding -Category 'DEPENDENCY ISSUES' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "This setting only takes effect when $dependency. Currently $($requirement.SettingName)=$($effective.DisplayValue) ($($effective.Source)), which violates the dependency." -Dependency $dependency -EffectiveValue $effective.DisplayValue -ValueSource $effective.Source))
                }
            }
            else {
                # Command-line-flag or presence-only requirement (e.g. "-clusterid",
                # "CustomDynamicConfigUrl in GameUserSettings.ini") -- no structured
                # value to compare against, so behavior is unchanged from before.
                [void]$findings.Add((New-AsaDiagnosticFinding -Category 'DEPENDENCY ISSUES' -File $item.TargetFile -Section $item.Section -Key $item.Key -Value $displayValue -Line $item.LineNumber -Message "This setting only takes effect when $dependency -- verify that is also configured." -Dependency $dependency))
            }
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

# ---------------------------------------------------------------------------
# Setting relocation planning -- deterministic, read-only. Decides whether an
# existing, known-supported setting can safely be moved from an incorrect
# INI file/section to its authoritative location. Never writes anything;
# never lets a caller supply the destination -- it is always re-derived from
# the knowledge base here. Used by both the "Run request" write pipeline
# (ASA-AI-Assistant.ps1) and the diagnostics-context resolver, so a
# relocation is validated identically no matter how it was requested.
# ---------------------------------------------------------------------------

function Get-AsaSettingRelocationPlan {
    <#
    Given a setting name and the CURRENT contents of both INI files, decides
    whether relocating that setting from wherever it currently, incorrectly
    lives to its authoritative knowledge-base target/section is safe -- and if
    so, exactly what to move. The destination always comes from the
    authoritative catalog entry (Entry.target / Entry.section); nothing here
    is ever influenced by a generative model's guess. A destination conflict
    (existing value differs) is refused unless -Resolution explicitly says
    how to resolve it -- never silently overwritten.
    #>
    param(
        [Parameter(Mandatory)][string]$SettingName,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$GameUserSettingsLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$GameIniLines,
        [ValidateSet('use_source', 'keep_destination')]
        [string]$Resolution
    )

    $baseName = Get-AsaSettingBaseName -Key $SettingName
    $catalog = @(Find-AsaSettingExact -Name $baseName)
    if ($catalog.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' is not in the authoritative ASA knowledge base (unknown, mod, or custom setting) -- relocation refused." }
    }

    $best = $catalog[0]
    $tags = Get-AsaSettingStatusTags -Entry $best
    if ($tags -notcontains 'SUPPORTED') {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' is tagged $($tags -join ', ') in the knowledge base -- only a SUPPORTED setting may be relocated automatically." }
    }
    if ($best.target -notin @('GameUserSettings.ini', 'Game.ini')) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' is documented as a $($best.target) setting, not an INI setting -- there is no INI location to relocate it to." }
    }

    $toTarget = [string]$best.target
    $toSection = [string]$best.section
    $isRepeatable = ($best.value_type -eq 'array') -or ([string]$best.description -match $script:AsaKnowledgeRepeatableHintPattern)

    $guEntries = @(ConvertFrom-AsaIniLines -Lines $GameUserSettingsLines -TargetFile 'GameUserSettings.ini')
    $giEntries = @(ConvertFrom-AsaIniLines -Lines $GameIniLines -TargetFile 'Game.ini')
    $allEntries = @($guEntries) + @($giEntries)

    $matching = @($allEntries | Where-Object { (Get-AsaSettingBaseName -Key $_.Key) -ieq $baseName })
    $atDestination = @($matching | Where-Object { $_.TargetFile -ceq $toTarget -and $_.Section.Trim() -ieq $toSection.Trim() })
    $elsewhere = @($matching | Where-Object { -not ($_.TargetFile -ceq $toTarget -and $_.Section.Trim() -ieq $toSection.Trim()) })

    if ($elsewhere.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' was not found in an incorrect location -- nothing to relocate (it may already be correctly located, or not configured at all)." }
    }

    $sourceGroups = @($elsewhere | Group-Object -Property { $_.TargetFile + '|' + $_.Section })
    if ($sourceGroups.Count -gt 1) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' appears in more than one incorrect location -- relocation refused rather than guessing which one to move." }
    }
    $source = $sourceGroups[0].Group
    $fromTarget = $source[0].TargetFile
    $fromSection = $source[0].Section

    if (-not $isRepeatable -and $source.Count -gt 1) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' is not documented as repeatable but appears $($source.Count) times at the source location -- relocation refused (resolve the duplicate first)." }
    }
    if (-not $isRepeatable -and $source[0].Key.Trim() -cne $baseName) {
        return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$($source[0].Key)' is an indexed/subscripted setting -- automatic relocation is not supported for these yet." }
    }

    foreach ($entry in $source) {
        if ($isRepeatable) {
            $syntaxIssues = @(Test-AsaComplexSettingSyntax -Entry $best -Value $entry.Value)
            if ($syntaxIssues.Count -gt 0) {
                return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' at the source location fails validation and cannot be relocated: $($syntaxIssues[0])" }
            }
        }
        else {
            $typeIssue = Test-AsaScalarValueType -ValueType $best.value_type -Value $entry.Value
            if ($typeIssue) { return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' at the source location fails validation and cannot be relocated: $typeIssue" } }
            $rangeIssue = Test-AsaValueRange -Entry $best -Value $entry.Value
            if ($rangeIssue) { return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' at the source location fails validation and cannot be relocated: $rangeIssue" } }
            $enumIssue = Test-AsaValueEnum -Entry $best -Value $entry.Value
            if ($enumIssue) { return [pscustomobject]@{ Success = $false; Setting = $baseName; Conflict = $false; Error = "'$baseName' at the source location fails validation and cannot be relocated: $enumIssue" } }
        }
    }

    $sourceLines = @($source | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $sourceValues = @($source | ForEach-Object { $_.Value.Trim() })

    $writeDestination = $true
    $destinationLines = $sourceLines

    if ($atDestination.Count -gt 0) {
        if ($isRepeatable) {
            if ($Resolution -eq 'keep_destination') {
                $writeDestination = $false
            }
            elseif ($Resolution -eq 'use_source') {
                $writeDestination = $true
                $destinationLines = $sourceLines
            }
            else {
                return [pscustomobject]@{
                    Success = $false; Setting = $baseName; Conflict = $true
                    Error   = "'$baseName' already has $($atDestination.Count) entr$(if ($atDestination.Count -eq 1) { 'y' } else { 'ies' }) at the destination -- relocating a repeatable setting onto an existing destination requires an explicit resolution ('use_source' or 'keep_destination') and was refused to avoid silently merging or overwriting."
                }
            }
        }
        else {
            $destValue = $atDestination[0].Value.Trim()
            $sourceValue = $sourceValues[0]
            if (Test-AsaDependencyValueMatches -Effective $destValue -Required $sourceValue) {
                # Same value already at the destination -- unambiguous: remove
                # the source duplicate, leave the destination untouched.
                $writeDestination = $false
            }
            elseif ($Resolution -eq 'use_source') {
                $writeDestination = $true
                $destinationLines = $sourceLines
            }
            elseif ($Resolution -eq 'keep_destination') {
                $writeDestination = $false
            }
            else {
                return [pscustomobject]@{
                    Success          = $false
                    Setting          = $baseName
                    Conflict         = $true
                    DestinationValue = $destValue
                    SourceValue      = $sourceValue
                    Error            = "Destination already has $baseName=$destValue, which differs from the source value $sourceValue. An explicit resolution ('use_source' or 'keep_destination') is required before this relocation can proceed."
                }
            }
        }
    }

    return [pscustomobject]@{
        Success                = $true
        Setting                = $baseName
        Conflict               = $false
        FromTarget             = $fromTarget
        FromSection            = $fromSection
        ToTarget               = $toTarget
        ToSection              = $toSection
        Repeatable             = $isRepeatable
        SourceLines            = $sourceLines
        SourceValues           = $sourceValues
        WriteDestination       = $writeDestination
        DestinationLines       = $destinationLines
        DestinationHadExisting = $atDestination.Count -gt 0
        Reason                 = "Authoritative ASA knowledge base specifies $toTarget $toSection as the correct target."
        Error                  = ''
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

# ---------------------------------------------------------------------------
# Plain-text clipboard/export formatting -- pure, read-only functions used by
# the "Copy selected finding" / "Copy diagnostic report" UI controls. Never
# writes any file, never mutates a finding, and always redacts anything that
# looks like a secret before it can reach the clipboard.
# ---------------------------------------------------------------------------

function Get-AsaBestCatalogEntryForFinding {
    <# Mirrors the same exact/same-target/first selection Invoke-AsaConfigDiagnostics
       uses internally, so "Support status" in a copied finding matches what the
       diagnostic actually reasoned about. #>
    param([Parameter(Mandatory)]$Finding)

    $baseName = Get-AsaSettingBaseName -Key $Finding.Key
    $candidates = @(Find-AsaSettingExact -Name $baseName)
    if ($candidates.Count -eq 0) { return $null }

    $exact = @($candidates | Where-Object { $_.target -ceq $Finding.File -and ([string]$_.section).Trim() -ieq ([string]$Finding.Section).Trim() })
    if ($exact.Count -gt 0) { return $exact[0] }
    $sameTarget = @($candidates | Where-Object { $_.target -ceq $Finding.File })
    if ($sameTarget.Count -gt 0) { return $sameTarget[0] }
    return $candidates[0]
}

function Get-AsaDiagnosticSuggestedCorrection {
    <# Fixed, category-derived corrections only -- never an invented, per-instance
       guess. Categories without a deterministic correction return $null. #>
    param([Parameter(Mandatory)]$Finding)

    switch ($Finding.Category) {
        'WRONG TARGET FILE' { return 'Move the setting to the expected location while preserving its value.' }
        'WRONG SECTION'     { return 'Move the setting to the expected section while preserving its value.' }
        'DUPLICATES'        { return 'Remove the extra duplicate line(s), keeping only one.' }
        'OBSOLETE'          { if ($Finding.Replacement) { return "Replace with $($Finding.Replacement)." } else { return $null } }
        default             { return $null }
    }
}

function Get-AsaDiagnosticSafeValue {
    <# Current-value text for clipboard/export use: redacts anything whose key
       looks secret-like, even if it wasn't already caught by the knowledge
       base's per-entry "sensitive" flag upstream. #>
    param([Parameter(Mandatory)]$Finding)
    if (Test-AsaKeyLooksSecret -Key $Finding.Key) { return '[REDACTED]' }
    return $Finding.Value
}

function Format-AsaDiagnosticFindingClipboardText {
    <#
    Builds the clean, human-readable plain-text report for a single selected
    diagnostic finding. Only includes fields that actually have information;
    never invents a correction that can't be deterministically derived.
    #>
    param([Parameter(Mandatory)]$Finding)

    $catalogEntry = Get-AsaBestCatalogEntryForFinding -Finding $Finding
    $supportStatus = if ($catalogEntry) { (Get-AsaSettingStatusTags -Entry $catalogEntry) -join ', ' } else { $null }
    $suggestedCorrection = Get-AsaDiagnosticSuggestedCorrection -Finding $Finding
    $safeValue = Get-AsaDiagnosticSafeValue -Finding $Finding

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('ASA Configuration Diagnostic')
    [void]$lines.Add('')
    [void]$lines.Add("Type: $($Finding.Category)")
    if ($Finding.Key) { [void]$lines.Add("Setting: $($Finding.Key)") }
    if ($safeValue) { [void]$lines.Add("Current value: $safeValue") }
    if ($Finding.File) { [void]$lines.Add("Current file: $($Finding.File)") }
    if ($Finding.Section) { [void]$lines.Add("Current section: $($Finding.Section)") }
    if ($Finding.ExpectedFile) { [void]$lines.Add("Expected file: $($Finding.ExpectedFile)") }
    if ($Finding.ExpectedSection) { [void]$lines.Add("Expected section: $($Finding.ExpectedSection)") }
    if ($supportStatus) { [void]$lines.Add("Support status: $supportStatus") }
    if ($Finding.EffectiveValue) { [void]$lines.Add("Effective value: $($Finding.EffectiveValue)") }
    if ($Finding.ValueSource) { [void]$lines.Add("Value source: $($Finding.ValueSource)") }

    if ($Finding.Message) {
        [void]$lines.Add('')
        [void]$lines.Add('Reason:')
        [void]$lines.Add($Finding.Message)
    }
    if ($Finding.Dependency) {
        [void]$lines.Add('')
        [void]$lines.Add('Dependency information:')
        [void]$lines.Add($Finding.Dependency)
    }
    if ($Finding.Replacement) {
        [void]$lines.Add('')
        [void]$lines.Add('Replacement:')
        [void]$lines.Add($Finding.Replacement)
    }
    if ($suggestedCorrection) {
        [void]$lines.Add('')
        [void]$lines.Add('Suggested correction:')
        [void]$lines.Add($suggestedCorrection)
    }

    [void]$lines.Add('')
    [void]$lines.Add('Status:')
    [void]$lines.Add('Read-only diagnostic. No configuration files were changed.')

    return ($lines -join "`r`n")
}

function Format-AsaDiagnosticFindingSummaryLine {
    param([Parameter(Mandatory)]$Finding)
    $safeValue = Get-AsaDiagnosticSafeValue -Finding $Finding
    if ($safeValue) { return "$($Finding.Key) = $safeValue" }
    return "$($Finding.Key)"
}

function Format-AsaDiagnosticsReportClipboardText {
    <#
    Builds the clean, plain-text export of the CURRENTLY DISPLAYED diagnostic
    findings (whatever the caller passes as -DisplayFindings), grouped by
    category, with a summary line for ignored/bookkeeping entries instead of
    dumping them individually. Read-only; makes no changes anywhere.
    #>
    param(
        [Parameter(Mandatory)]$Diagnostics,
        [Parameter(Mandatory)][AllowEmptyCollection()]$DisplayFindings
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('ASA Configuration Diagnostic Report')
    [void]$lines.Add('')
    [void]$lines.Add('Summary')
    [void]$lines.Add("Configuration problems: $($Diagnostics.ProblemFindingsCount)")
    [void]$lines.Add("Informational findings: $($Diagnostics.InformationalFindingsCount)")
    [void]$lines.Add("Ignored non-server/bookkeeping entries: $($Diagnostics.IgnoredNonServerCount)")

    $groups = @($DisplayFindings) | Where-Object { $_.Category -ne 'IGNORED_NON_SERVER' } | Group-Object -Property Category
    foreach ($group in $groups) {
        [void]$lines.Add('')
        [void]$lines.Add($group.Name)
        foreach ($finding in $group.Group) {
            [void]$lines.Add("- $(Format-AsaDiagnosticFindingSummaryLine -Finding $finding)")
            if ($finding.File -or $finding.Section) { [void]$lines.Add("  Current: $($finding.File) [$($finding.Section)]") }
            if ($finding.ExpectedFile -or $finding.ExpectedSection) { [void]$lines.Add("  Expected: $($finding.ExpectedFile) [$($finding.ExpectedSection)]") }
            if ($finding.EffectiveValue) { [void]$lines.Add("  Effective value: $($finding.EffectiveValue) ($($finding.ValueSource))") }
            if ($finding.Replacement) { [void]$lines.Add("  Replacement: $($finding.Replacement)") }
            if ($finding.Message) { [void]$lines.Add("  Reason: $($finding.Message)") }
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('End of report')
    [void]$lines.Add('')
    [void]$lines.Add('Diagnostics are read-only.')
    [void]$lines.Add('No configuration files were modified.')

    return ($lines -join "`r`n")
}
