$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$enginePath = Join-Path $root 'ASA-AI-Assistant.ps1'
if (-not (Test-Path -LiteralPath $enginePath)) {
    [Windows.Forms.MessageBox]::Show("Missing AI engine:`n$enginePath", 'ASA AI Assistant', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

. $enginePath

# Set only while the list is showing the results of the last "Analyze ASA
# configuration" run; cleared whenever any other action repopulates the list,
# so the copy buttons never export stale or mismatched findings.
$script:LastDiagnostics = $null
$script:LastDiagnosticsDisplayFindings = @()

$Background = [Drawing.Color]::FromArgb(25, 29, 36)
$Panel = [Drawing.Color]::FromArgb(37, 43, 52)
$Input = [Drawing.Color]::FromArgb(53, 61, 72)
$Text = [Drawing.Color]::FromArgb(238, 241, 245)
$Muted = [Drawing.Color]::FromArgb(168, 177, 190)
$Green = [Drawing.Color]::FromArgb(56, 190, 114)
$Blue = [Drawing.Color]::FromArgb(64, 137, 232)
$Amber = [Drawing.Color]::FromArgb(232, 165, 64)
$Red = [Drawing.Color]::FromArgb(226, 82, 82)

$form = New-Object Windows.Forms.Form
$form.Text = 'Local AI Assistant - ASA Manager'
$form.Size = New-Object Drawing.Size(900, 820)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Background
$form.ForeColor = $Text
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.MinimumSize = New-Object Drawing.Size(900, 820)

$title = New-Object Windows.Forms.Label
$title.Text = 'LOCAL AI ASSISTANT'
$title.Location = New-Object Drawing.Point(22, 18)
$title.Size = New-Object Drawing.Size(500, 34)
$title.ForeColor = $Text
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Tell it what you want. It runs immediately using only allow-listed settings and server actions.'
$subtitle.Location = New-Object Drawing.Point(24, 54)
$subtitle.Size = New-Object Drawing.Size(840, 24)
$subtitle.ForeColor = $Muted
$form.Controls.Add($subtitle)

$promptLabel = New-Object Windows.Forms.Label
$promptLabel.Text = 'Tell the assistant what you want to change or do'
$promptLabel.Location = New-Object Drawing.Point(22, 92)
$promptLabel.Size = New-Object Drawing.Size(500, 24)
$promptLabel.ForeColor = $Text
$form.Controls.Add($promptLabel)

$promptBox = New-Object Windows.Forms.TextBox
$promptBox.Location = New-Object Drawing.Point(22, 120)
$promptBox.Size = New-Object Drawing.Size(840, 88)
$promptBox.Multiline = $true
$promptBox.ScrollBars = 'Vertical'
$promptBox.BackColor = $Input
$promptBox.ForeColor = $Text
$promptBox.BorderStyle = 'FixedSingle'
$promptBox.Font = New-Object Drawing.Font('Segoe UI', 10)
$promptBox.Text = 'Set taming to 10x, harvesting to 4x, and make nights shorter'
$form.Controls.Add($promptBox)

$askButton = New-Object Windows.Forms.Button
$askButton.Text = 'Run request'
$askButton.Location = New-Object Drawing.Point(22, 220)
$askButton.Size = New-Object Drawing.Size(165, 42)
$askButton.BackColor = $Green
$askButton.ForeColor = [Drawing.Color]::White
$askButton.FlatStyle = 'Flat'
$askButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($askButton)

$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = 'Clear'
$clearButton.Location = New-Object Drawing.Point(199, 220)
$clearButton.Size = New-Object Drawing.Size(110, 42)
$clearButton.BackColor = [Drawing.Color]::FromArgb(79, 99, 125)
$clearButton.ForeColor = [Drawing.Color]::White
$clearButton.FlatStyle = 'Flat'
$clearButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($clearButton)

$testButton = New-Object Windows.Forms.Button
$testButton.Text = 'Test AI connection'
$testButton.Location = New-Object Drawing.Point(315, 220)
$testButton.Size = New-Object Drawing.Size(160, 42)
$testButton.BackColor = ([Drawing.Color]::FromArgb(46, 150, 145))
$testButton.ForeColor = [Drawing.Color]::White
$testButton.FlatStyle = 'Flat'
$testButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($testButton)

$status = New-Object Windows.Forms.Label
$status.Text = 'Ready - using local Ollama model qwen3:8b'
$status.Location = New-Object Drawing.Point(481, 230)
$status.Size = New-Object Drawing.Size(381, 26)
$status.ForeColor = $Green
$status.TextAlign = 'MiddleRight'
$form.Controls.Add($status)

$knowledgeButton = New-Object Windows.Forms.Button
$knowledgeButton.Text = 'Ask about a setting'
$knowledgeButton.Location = New-Object Drawing.Point(22, 270)
$knowledgeButton.Size = New-Object Drawing.Size(230, 36)
$knowledgeButton.BackColor = $Blue
$knowledgeButton.ForeColor = [Drawing.Color]::White
$knowledgeButton.FlatStyle = 'Flat'
$knowledgeButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($knowledgeButton)

$diagnosticsButton = New-Object Windows.Forms.Button
$diagnosticsButton.Text = 'Analyze ASA configuration'
$diagnosticsButton.Location = New-Object Drawing.Point(262, 270)
$diagnosticsButton.Size = New-Object Drawing.Size(230, 36)
$diagnosticsButton.BackColor = [Drawing.Color]::FromArgb(142, 105, 210)
$diagnosticsButton.ForeColor = [Drawing.Color]::White
$diagnosticsButton.FlatStyle = 'Flat'
$diagnosticsButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($diagnosticsButton)

$summaryLabel = New-Object Windows.Forms.Label
$summaryLabel.Text = 'Assistant summary'
$summaryLabel.Location = New-Object Drawing.Point(22, 318)
$summaryLabel.Size = New-Object Drawing.Size(300, 24)
$summaryLabel.ForeColor = $Text
$form.Controls.Add($summaryLabel)

$summaryBox = New-Object Windows.Forms.TextBox
$summaryBox.Location = New-Object Drawing.Point(22, 346)
$summaryBox.Size = New-Object Drawing.Size(840, 58)
$summaryBox.Multiline = $true
$summaryBox.ReadOnly = $true
$summaryBox.BackColor = $Panel
$summaryBox.ForeColor = $Text
$summaryBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($summaryBox)

$changesLabel = New-Object Windows.Forms.Label
$changesLabel.Text = 'Settings changes, actions, custom recipes, facts, or diagnostic findings'
$changesLabel.Location = New-Object Drawing.Point(22, 418)
$changesLabel.Size = New-Object Drawing.Size(430, 24)
$changesLabel.ForeColor = $Text
$form.Controls.Add($changesLabel)

$copySelectedButton = New-Object Windows.Forms.Button
$copySelectedButton.Text = 'Copy selected finding'
$copySelectedButton.Location = New-Object Drawing.Point(460, 412)
$copySelectedButton.Size = New-Object Drawing.Size(180, 32)
$copySelectedButton.BackColor = [Drawing.Color]::FromArgb(79, 99, 125)
$copySelectedButton.ForeColor = [Drawing.Color]::White
$copySelectedButton.FlatStyle = 'Flat'
$copySelectedButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($copySelectedButton)

$copyReportButton = New-Object Windows.Forms.Button
$copyReportButton.Text = 'Copy diagnostic report'
$copyReportButton.Location = New-Object Drawing.Point(648, 412)
$copyReportButton.Size = New-Object Drawing.Size(192, 32)
$copyReportButton.BackColor = [Drawing.Color]::FromArgb(79, 99, 125)
$copyReportButton.ForeColor = [Drawing.Color]::White
$copyReportButton.FlatStyle = 'Flat'
$copyReportButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($copyReportButton)

$list = New-Object Windows.Forms.ListView
$list.Location = New-Object Drawing.Point(22, 446)
$list.Size = New-Object Drawing.Size(840, 140)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.BackColor = $Panel
$list.ForeColor = $Text
[void]$list.Columns.Add('Type', 90)
[void]$list.Columns.Add('Setting / Action / Item', 210)
[void]$list.Columns.Add('Value / Resources', 260)
[void]$list.Columns.Add('Reason', 260)
$form.Controls.Add($list)

$logLabel = New-Object Windows.Forms.Label
$logLabel.Text = 'Execution log'
$logLabel.Location = New-Object Drawing.Point(22, 594)
$logLabel.Size = New-Object Drawing.Size(300, 24)
$logLabel.ForeColor = $Text
$form.Controls.Add($logLabel)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(22, 622)
$logBox.Size = New-Object Drawing.Size(840, 110)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = $Panel
$logBox.ForeColor = $Text
$logBox.BorderStyle = 'FixedSingle'
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$safety = New-Object Windows.Forms.Label
$safety.Text = 'SAFETY: Only allow-listed settings and actions can run. Settings writes always snapshot both INI files first and refuse while ASA is mid-write. Ask/Analyze are read-only and never write a file.'
$safety.Location = New-Object Drawing.Point(22, 740)
$safety.Size = New-Object Drawing.Size(840, 30)
$safety.ForeColor = $Amber
$safety.TextAlign = 'MiddleCenter'
$form.Controls.Add($safety)

$closeButton = New-Object Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Location = New-Object Drawing.Point(692, 772)
$closeButton.Size = New-Object Drawing.Size(170, 36)
$closeButton.BackColor = [Drawing.Color]::FromArgb(79, 99, 125)
$closeButton.ForeColor = [Drawing.Color]::White
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($closeButton)

$clearButton.Add_Click({
    $promptBox.Clear()
    $summaryBox.Clear()
    $list.Items.Clear()
    $logBox.Clear()
    $script:LastDiagnostics = $null
    $script:LastDiagnosticsDisplayFindings = @()
    $status.Text = 'Ready'
    $status.ForeColor = $Green
})

$closeButton.Add_Click({ $form.Close() })

$testButton.Add_Click({
    $testButton.Enabled = $false
    $askButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Testing AI connection...'
    $status.ForeColor = $Amber
    $summaryBox.Clear()
    $list.Items.Clear()
    $logBox.Clear()
    $script:LastDiagnostics = $null
    $script:LastDiagnosticsDisplayFindings = @()
    [Windows.Forms.Application]::DoEvents()

    try {
        $result = Test-AsaAiConnection -Model 'qwen3:8b'
        $logLines = foreach ($step in @($result.Steps)) {
            $mark = if ($step.Success) { 'OK' } else { 'FAILED' }
            "[$mark] $($step.Step): $($step.Message)"
        }
        $logBox.Text = ($logLines -join "`r`n")

        if ($result.Success) {
            $summaryBox.Text = 'AI connection test passed: Ollama is reachable, the model is installed, and it responded correctly to a test prompt. Nothing was written to any file.'
            $status.Text = 'Test passed - AI is working'
            $status.ForeColor = $Green
        }
        else {
            $summaryBox.Text = 'AI connection test failed - see the execution log below for exactly which step failed and why.'
            $status.Text = 'Test failed - see log'
            $status.ForeColor = $Red
        }
    }
    catch {
        $status.Text = 'Test failed unexpectedly'
        $status.ForeColor = $Red
        $summaryBox.Text = $_.Exception.Message
    }
    finally {
        $form.Cursor = 'Default'
        $testButton.Enabled = $true
        $askButton.Enabled = $true
    }
})

$knowledgeButton.Add_Click({
    $question = $promptBox.Text.Trim()
    if (-not $question) {
        $status.Text = 'Type a question in the box first.'
        $status.ForeColor = $Amber
        return
    }

    $knowledgeButton.Enabled = $false
    $diagnosticsButton.Enabled = $false
    $askButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Looking up local ASA knowledge base...'
    $status.ForeColor = $Amber
    $summaryBox.Clear()
    $list.Items.Clear()
    $logBox.Clear()
    $script:LastDiagnostics = $null
    $script:LastDiagnosticsDisplayFindings = @()
    [Windows.Forms.Application]::DoEvents()

    try {
        $result = Get-AsaAiKnowledgeAnswer -Question $question -Model 'qwen3:8b'
        $summaryBox.Text = $result.Answer

        foreach ($fact in @($result.Facts)) {
            $item = New-Object Windows.Forms.ListViewItem('Fact')
            [void]$item.SubItems.Add([string]$fact.name)
            [void]$item.SubItems.Add("$($fact.target) $($fact.section)".Trim())
            [void]$item.SubItems.Add([string]$fact.description)
            [void]$list.Items.Add($item)
        }

        $sourceText = if ($result.UsedLocalAi) { 'local model phrasing over verified facts' } else { 'verified facts only (local model not used)' }
        $logBox.Text = "Retrieval method: $($result.Method) ($sourceText). Nothing was read from or written to any live config beyond the current value shown for a matched setting."

        if ($result.Facts.Count -eq 0) {
            $status.Text = 'No match in the local knowledge base'
            $status.ForeColor = $Amber
        }
        else {
            $status.Text = "Answered from $($result.Facts.Count) local knowledge fact(s)"
            $status.ForeColor = $Green
        }
    }
    catch {
        $status.Text = 'Question failed'
        $status.ForeColor = $Red
        $summaryBox.Text = $_.Exception.Message
    }
    finally {
        $form.Cursor = 'Default'
        $knowledgeButton.Enabled = $true
        $diagnosticsButton.Enabled = $true
        $askButton.Enabled = $true
    }
})

$diagnosticsButton.Add_Click({
    $knowledgeButton.Enabled = $false
    $diagnosticsButton.Enabled = $false
    $askButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Analyzing current GameUserSettings.ini and Game.ini (read-only)...'
    $status.ForeColor = $Amber
    $summaryBox.Clear()
    $list.Items.Clear()
    $logBox.Clear()
    $script:LastDiagnostics = $null
    $script:LastDiagnosticsDisplayFindings = @()
    [Windows.Forms.Application]::DoEvents()

    try {
        $result = Invoke-AsaConfigDiagnostics
        $displayFindings = @(Get-AsaConfigDiagnosticsDisplayFindings -Diagnostics $result)
        $script:LastDiagnostics = $result
        $script:LastDiagnosticsDisplayFindings = $displayFindings

        $summaryLine = "Read-only configuration health check -- $($result.ProblemFindingsCount) configuration problem(s)"
        if ($result.InformationalFindingsCount -gt 0) { $summaryLine += ", $($result.InformationalFindingsCount) informational note(s)" }
        $summaryLine += '.'
        if ($result.IgnoredNonServerCount -gt 0) {
            $summaryLine += " $($result.IgnoredNonServerCount) non-server/config bookkeeping entries ignored (Unreal Engine/client/session state, e.g. audio/video/UI settings -- not dedicated-server configuration)."
        }
        $summaryBox.Text = $summaryLine

        foreach ($finding in $displayFindings) {
            $item = New-Object Windows.Forms.ListViewItem([string]$finding.Category)
            [void]$item.SubItems.Add([string]$finding.Key)
            [void]$item.SubItems.Add([string]$finding.Value)
            [void]$item.SubItems.Add("[$($finding.File) $($finding.Section) line $($finding.Line)] $($finding.Message)")
            $item.Tag = $finding
            [void]$list.Items.Add($item)
        }

        $logBox.Text = "Read-only: no setting was changed. Showing $($displayFindings.Count) of $($result.TotalFindings) total finding(s); $($result.IgnoredNonServerCount) non-server bookkeeping entries are hidden from this view but still counted above. To fix something found here, describe the change above and use Run request -- it still goes through the normal allow-list, preview, backup, and rollback pipeline. Select a row and use Copy selected finding, or use Copy diagnostic report for everything shown."
        $status.Text = if ($result.ProblemFindingsCount -eq 0) { 'No configuration problems found' } else { "$($result.ProblemFindingsCount) configuration problem(s) -- see list below" }
        $status.ForeColor = if ($result.ProblemFindingsCount -eq 0) { $Green } else { $Amber }
    }
    catch {
        $status.Text = 'Analysis failed'
        $status.ForeColor = $Red
        $summaryBox.Text = $_.Exception.Message
    }
    finally {
        $form.Cursor = 'Default'
        $knowledgeButton.Enabled = $true
        $diagnosticsButton.Enabled = $true
        $askButton.Enabled = $true
    }
})

$askButton.Add_Click({
    $request = $promptBox.Text.Trim()
    if (-not $request) {
        $status.Text = 'Enter a request first.'
        $status.ForeColor = $Amber
        return
    }

    $askButton.Enabled = $false
    $clearButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Thinking locally and running your request...'
    $status.ForeColor = $Amber
    $summaryBox.Clear()
    $list.Items.Clear()
    $logBox.Clear()
    $script:LastDiagnostics = $null
    $script:LastDiagnosticsDisplayFindings = @()
    [Windows.Forms.Application]::DoEvents()

    try {
        $result = Invoke-AsaAiRequest -Prompt $request -Model 'qwen3:8b'
        $summaryBox.Text = $result.Summary

        foreach ($change in @($result.Changes)) {
            $item = New-Object Windows.Forms.ListViewItem('Setting')
            [void]$item.SubItems.Add([string]$change.Key)
            [void]$item.SubItems.Add([string]$change.Value)
            [void]$item.SubItems.Add([string]$change.Reason)
            [void]$list.Items.Add($item)
        }
        foreach ($action in @($result.Actions)) {
            $item = New-Object Windows.Forms.ListViewItem('Action')
            [void]$item.SubItems.Add([string]$action.Name)
            [void]$item.SubItems.Add('')
            [void]$item.SubItems.Add([string]$action.Reason)
            [void]$list.Items.Add($item)
        }
        foreach ($recipe in @($result.Recipes)) {
            $resourceSummary = (@($recipe.Resources) | ForEach-Object { "$($_.Class) x$($_.Amount)" }) -join ', '
            $item = New-Object Windows.Forms.ListViewItem('Recipe')
            [void]$item.SubItems.Add([string]$recipe.ItemName)
            [void]$item.SubItems.Add($resourceSummary)
            [void]$item.SubItems.Add([string]$recipe.Reason)
            [void]$list.Items.Add($item)
        }
        foreach ($relocation in @($result.Relocations)) {
            $moveSummary = "$($relocation.FromTarget) $($relocation.FromSection) -> $($relocation.ToTarget) $($relocation.ToSection)"
            $valueSummary = "value: $($relocation.SourceValues -join ', ')"
            if ($relocation.DestinationHadExisting) {
                $valueSummary += if ($relocation.WriteDestination) { ' (overwrites existing destination value)' } else { ' (destination already matched; duplicate source removed)' }
            }
            $item = New-Object Windows.Forms.ListViewItem('Relocate')
            [void]$item.SubItems.Add([string]$relocation.Setting)
            [void]$item.SubItems.Add($moveSummary + ' | ' + $valueSummary)
            [void]$item.SubItems.Add([string]$relocation.Reason)
            [void]$list.Items.Add($item)
        }

        if (@($result.Rejected).Count -gt 0) {
            $summaryBox.Text += "`r`nRejected: " + (@($result.Rejected) -join '; ')
        }

        $logLines = foreach ($step in @($result.Steps)) {
            $mark = if ($step.Success) { 'OK' } else { 'FAILED' }
            "[$mark] $($step.Step): $($step.Message)"
        }
        $logBox.Text = ($logLines -join "`r`n")

        $stepCount = @($result.Steps).Count
        $failedCount = @(@($result.Steps) | Where-Object { -not $_.Success }).Count

        if ($stepCount -eq 0 -and @($result.Changes).Count -eq 0 -and @($result.Actions).Count -eq 0 -and @($result.Recipes).Count -eq 0 -and @($result.Relocations).Count -eq 0) {
            $status.Text = 'Nothing to do - no allowed changes or actions were proposed'
            $status.ForeColor = $Amber
        }
        elseif ($failedCount -gt 0) {
            $status.Text = "Done with $failedCount failed step(s) - see execution log"
            $status.ForeColor = $Red
        }
        else {
            $status.Text = "Done - $stepCount step(s) completed successfully"
            $status.ForeColor = $Green
        }
    }
    catch {
        $status.Text = 'Request failed safely'
        $status.ForeColor = $Red
        $summaryBox.Text = $_.Exception.Message
    }
    finally {
        $form.Cursor = 'Default'
        $askButton.Enabled = $true
        $clearButton.Enabled = $true
    }
})

$copySelectedButton.Add_Click({
    if (-not $script:LastDiagnostics) {
        $status.Text = 'Run "Analyze ASA configuration" first, then select a finding to copy.'
        $status.ForeColor = $Amber
        return
    }
    if ($list.SelectedItems.Count -eq 0) {
        $status.Text = 'Select a diagnostic finding row first.'
        $status.ForeColor = $Amber
        return
    }
    $finding = $list.SelectedItems[0].Tag
    if (-not $finding) {
        $status.Text = 'The selected row is not a diagnostic finding.'
        $status.ForeColor = $Amber
        return
    }
    try {
        $text = Format-AsaDiagnosticFindingClipboardText -Finding $finding
        [Windows.Forms.Clipboard]::SetText($text)
        $status.Text = 'Diagnostic copied to clipboard.'
        $status.ForeColor = $Green
    }
    catch {
        $status.Text = "Copy failed: $($_.Exception.Message)"
        $status.ForeColor = $Red
    }
})

$copyReportButton.Add_Click({
    if (-not $script:LastDiagnostics) {
        $status.Text = 'Run "Analyze ASA configuration" first to generate a report to copy.'
        $status.ForeColor = $Amber
        return
    }
    try {
        $text = Format-AsaDiagnosticsReportClipboardText -Diagnostics $script:LastDiagnostics -DisplayFindings $script:LastDiagnosticsDisplayFindings
        [Windows.Forms.Clipboard]::SetText($text)
        $status.Text = 'Diagnostic report copied to clipboard.'
        $status.ForeColor = $Green
    }
    catch {
        $status.Text = "Copy failed: $($_.Exception.Message)"
        $status.ForeColor = $Red
    }
})

[void]$form.ShowDialog()
