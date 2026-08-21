$ErrorActionPreference = 'Stop'

$managerPath = Join-Path $PSScriptRoot 'ASA-Manager.ps1'
if (-not (Test-Path -LiteralPath $managerPath)) {
    throw "ASA-Manager.ps1 was not found at: $managerPath"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$content = [IO.File]::ReadAllText($managerPath)
$nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

if ($content -match '\$aiAssistantButton\s*=') {
    Write-Host 'AI Assistant button is already installed. No changes made.' -ForegroundColor Yellow
    exit 0
}

$oldHeader = @(
    '$guideButton = New-Button ''Files + guide'' 814 26 165 ([Drawing.Color]::FromArgb(117, 92, 190))',
    '$form.Controls.Add($guideButton)'
) -join $nl

$newHeader = @(
    '$aiAssistantButton = New-Button ''AI Assistant'' 650 26 150 $Green',
    '$guideButton = New-Button ''Files + guide'' 814 26 165 ([Drawing.Color]::FromArgb(117, 92, 190))',
    '$form.Controls.AddRange(@($aiAssistantButton, $guideButton))'
) -join $nl

$oldEvents = @(
    '$ps5HelpButton.Add_Click({ Show-Ps5HelpDialog })',
    '$guideButton.Add_Click({ Show-ServerFilesHelp })'
) -join $nl

$newEvents = @(
    '$ps5HelpButton.Add_Click({ Show-Ps5HelpDialog })',
    '$aiAssistantButton.Add_Click({',
    "    `$aiPanel = Join-Path `$Root 'ASA-AI-Panel.ps1'",
    '    if (-not (Test-Path -LiteralPath $aiPanel)) {',
    '        Show-ErrorBox "AI Assistant panel is missing:`n$aiPanel"',
    '        return',
    '    }',
    "    try { & `$aiPanel }",
    "    catch { Show-ErrorBox ('AI Assistant failed safely: ' + `$_.Exception.Message) }",
    '})',
    '$guideButton.Add_Click({ Show-ServerFilesHelp })'
) -join $nl

$oldTooltips = @(
    '$toolTip.SetToolTip($advisorButton, ''Runs a password-safe, read-only check of ASA files, crossplay, resources, rates, mods, networking, and backups.'')',
    '$toolTip.SetToolTip($guideButton, ''Explains every important ASA server file and opens the selected file or folder directly.'')'
) -join $nl

$newTooltips = @(
    '$toolTip.SetToolTip($advisorButton, ''Runs a password-safe, read-only check of ASA files, crossplay, resources, rates, mods, networking, and backups.'')',
    '$toolTip.SetToolTip($aiAssistantButton, ''Opens the local Ollama AI Assistant. Preview-only: it cannot write server settings yet.'')',
    '$toolTip.SetToolTip($guideButton, ''Explains every important ASA server file and opens the selected file or folder directly.'')'
) -join $nl

foreach ($replacement in @(
    @{ Name = 'header button'; Old = $oldHeader; New = $newHeader },
    @{ Name = 'button click handler'; Old = $oldEvents; New = $newEvents },
    @{ Name = 'button tooltip'; Old = $oldTooltips; New = $newTooltips }
)) {
    if (-not $content.Contains($replacement.Old)) {
        throw "Safety stop: expected $($replacement.Name) code was not found. ASA-Manager.ps1 was NOT changed."
    }
    $content = $content.Replace($replacement.Old, $replacement.New)
}

[IO.File]::WriteAllText($managerPath, $content, $utf8NoBom)
Write-Host 'Installed AI Assistant preview button into ASA-Manager.ps1.' -ForegroundColor Green
Write-Host 'No INI files or server settings were changed.' -ForegroundColor Green
Write-Host 'Review with: git diff -- ASA-Manager.ps1' -ForegroundColor Cyan
