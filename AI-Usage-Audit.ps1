param(
    [switch]$ShowWindow,
    [switch]$LatestReport,
    [switch]$Preflight,
    [int]$PlannedToolCalls = 0,
    [int]$PlannedRepeatedActions = 0,
    [int]$PlannedFullScans = 0,
    [int]$PlannedFullTestSuites = 0
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AuditFolder = Join-Path $Root 'usage-audit'
$AuditLog = Join-Path $AuditFolder 'entries.jsonl'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-AuditEntries {
    if (-not (Test-Path -LiteralPath $AuditLog)) { return @() }
    return @(Get-Content -LiteralPath $AuditLog -ErrorAction Stop | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json }
    })
}

function Get-AuditAssessment($Entry) {
    $flags = New-Object Collections.Generic.List[string]
    if ($null -ne $Entry.CreditsSpent -and $Entry.CreditsSpent -ge $Entry.ReviewLimit) {
        $flags.Add("Credit spend reached the review limit ($($Entry.ReviewLimit)).")
    }
    if ($Entry.RepeatedActions -gt 1) { $flags.Add('More than one repeated scan/test/action was recorded.') }
    if ($Entry.FullScans -gt 0) { $flags.Add('A full repository scan was used; confirm that a targeted search was insufficient.') }
    if ($Entry.FullTestSuites -gt 1) { $flags.Add('The full test suite ran more than once during one task.') }
    if ($Entry.ToolCalls -gt 25) { $flags.Add('More than 25 tool calls were recorded.') }

    if ($flags.Count -eq 0) {
        return [pscustomobject]@{ Level='OK'; Detail='No clear local sign of avoidable overuse.'; Flags=@() }
    }
    return [pscustomobject]@{
        Level='REVIEW'
        Detail='Review the task and use narrower reads, combined searches, and targeted tests next time.'
        Flags=@($flags)
    }
}

function Get-PreflightEstimate([int]$ToolCalls,[int]$RepeatedActions,[int]$FullScans,[int]$FullTestSuites) {
    $score = $ToolCalls
    $score += (8 * $RepeatedActions)
    $score += (20 * $FullScans)
    $score += (12 * $FullTestSuites)
    if ($score -le 8 -and $FullScans -eq 0 -and $FullTestSuites -eq 0) {
        return [pscustomobject]@{ Level='LOW'; Detail='Small targeted task. Proceed with focused reads and one targeted verification.' }
    }
    if ($score -le 25 -and $FullScans -eq 0 -and $FullTestSuites -le 1) {
        return [pscustomobject]@{ Level='MEDIUM'; Detail='Moderate task. Combine searches and stop if the planned scope expands.' }
    }
    return [pscustomobject]@{ Level='HIGH'; Detail='Potentially expensive task. Reduce scope or ask the user before continuing.' }
}

function Format-AuditReport($Entry) {
    $assessment = Get-AuditAssessment $Entry
    $spent = if ($null -eq $Entry.CreditsSpent) { 'not supplied' } else { [string]$Entry.CreditsSpent }
    $lines = @(
        'AI USAGE AUDIT',
        ('Time: {0}' -f $Entry.Timestamp),
        ('Agent: {0}' -f $Entry.Agent),
        ('Task: {0}' -f $Entry.Task),
        ('Measured credits spent: {0}' -f $spent),
        ('Tool calls: {0}; repeated actions: {1}; full scans: {2}; full test suites: {3}' -f $Entry.ToolCalls,$Entry.RepeatedActions,$Entry.FullScans,$Entry.FullTestSuites),
        ('Outcome: {0}' -f $Entry.Outcome),
        '',
        ('Assessment: {0} - {1}' -f $assessment.Level,$assessment.Detail)
    )
    foreach ($flag in $assessment.Flags) { $lines += ('- ' + $flag) }
    $lines += ''
    $lines += 'Important: this is a local efficiency audit, not OpenAI billing data and not a refund request.'
    return ($lines -join [Environment]::NewLine)
}

function Save-AuditEntry($Entry) {
    if (-not (Test-Path -LiteralPath $AuditFolder)) { [void](New-Item -ItemType Directory -Path $AuditFolder) }
    $json = $Entry | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($AuditLog, $json + [Environment]::NewLine, $Utf8NoBom)
}

if ($LatestReport) {
    $entry = @(Get-AuditEntries | Select-Object -Last 1)
    if ($entry.Count -eq 0) { Write-Output 'No local usage audits have been recorded.'; exit 0 }
    Write-Output (Format-AuditReport $entry[0])
    exit 0
}

if ($Preflight) {
    $estimate = Get-PreflightEstimate $PlannedToolCalls $PlannedRepeatedActions $PlannedFullScans $PlannedFullTestSuites
    Write-Output ("{0}: {1}" -f $estimate.Level,$estimate.Detail)
    exit 0
}

if (-not $ShowWindow) {
    Write-Output 'Run with -ShowWindow, -LatestReport, or -Preflight plus planned activity counts.'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'AI usage audit - ASA Manager'
$form.Size = New-Object Drawing.Size(760, 770)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [Drawing.Color]::FromArgb(25,29,36)
$form.ForeColor = [Drawing.Color]::FromArgb(238,241,245)
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

function Add-Label($text,$x,$y,$w=210) {
    $label = New-Object Windows.Forms.Label
    $label.Text=$text; $label.Location=New-Object Drawing.Point($x,$y); $label.Size=New-Object Drawing.Size($w,25)
    $form.Controls.Add($label); return $label
}
function Add-Number($x,$y,$max=100000) {
    $box=New-Object Windows.Forms.NumericUpDown
    $box.Location=New-Object Drawing.Point($x,$y); $box.Size=New-Object Drawing.Size(130,28)
    $box.Maximum=$max; $box.DecimalPlaces=2; $box.Increment=1
    $box.BackColor=[Drawing.Color]::FromArgb(53,61,72); $box.ForeColor=$form.ForeColor
    $form.Controls.Add($box); return $box
}

[void](Add-Label 'Local AI usage audit' 20 15 400)
$intro=Add-Label 'Before a task, enter planned activity and press Preflight. Afterwards, enter actual activity and official before/after credits.' 20 48 700
$intro.Size=New-Object Drawing.Size(700,45)
[void](Add-Label 'Agent' 20 105)
$agent=New-Object Windows.Forms.ComboBox
$agent.Location=New-Object Drawing.Point(235,103); $agent.Size=New-Object Drawing.Size(170,28); $agent.DropDownStyle='DropDownList'
[void]$agent.Items.AddRange([object[]]@('Codex','Claude','Other')); $agent.SelectedIndex=0; $form.Controls.Add($agent)
[void](Add-Label 'Task' 20 145)
$task=New-Object Windows.Forms.TextBox
$task.Location=New-Object Drawing.Point(235,143); $task.Size=New-Object Drawing.Size(485,28); $task.BackColor=[Drawing.Color]::FromArgb(53,61,72); $task.ForeColor=$form.ForeColor; $form.Controls.Add($task)
[void](Add-Label 'Credits before (optional)' 20 185); $before=Add-Number 235 183
[void](Add-Label 'Credits after (optional)' 20 225); $after=Add-Number 235 223
[void](Add-Label 'Review limit' 420 185); $limit=Add-Number 550 183; $limit.Value=100
[void](Add-Label 'Tool calls' 20 275); $tools=Add-Number 235 273 10000
[void](Add-Label 'Repeated actions' 20 315); $repeats=Add-Number 235 313 1000
[void](Add-Label 'Full repository scans' 20 355); $scans=Add-Number 235 353 1000
[void](Add-Label 'Full test-suite runs' 20 395); $suites=Add-Number 235 393 1000
[void](Add-Label 'Outcome' 20 435)
$outcome=New-Object Windows.Forms.TextBox
$outcome.Location=New-Object Drawing.Point(235,433); $outcome.Size=New-Object Drawing.Size(485,28); $outcome.BackColor=[Drawing.Color]::FromArgb(53,61,72); $outcome.ForeColor=$form.ForeColor; $form.Controls.Add($outcome)

$report=New-Object Windows.Forms.RichTextBox
$report.Location=New-Object Drawing.Point(20,485); $report.Size=New-Object Drawing.Size(700,160); $report.ReadOnly=$true
$report.BackColor=[Drawing.Color]::FromArgb(37,43,52); $report.ForeColor=$form.ForeColor; $form.Controls.Add($report)
$save=New-Object Windows.Forms.Button
$preflight=New-Object Windows.Forms.Button
$preflight.Text='Preflight estimate'; $preflight.Location=New-Object Drawing.Point(20,665); $preflight.Size=New-Object Drawing.Size(170,38)
$preflight.BackColor=[Drawing.Color]::FromArgb(232,165,64); $preflight.ForeColor=[Drawing.Color]::White; $preflight.FlatStyle='Flat'; $form.Controls.Add($preflight)
$save.Text='Save post-task audit'; $save.Location=New-Object Drawing.Point(205,665); $save.Size=New-Object Drawing.Size(170,38)
$save.BackColor=[Drawing.Color]::FromArgb(56,190,114); $save.ForeColor=[Drawing.Color]::White; $save.FlatStyle='Flat'; $form.Controls.Add($save)
$open=New-Object Windows.Forms.Button
$open.Text='Open audit folder'; $open.Location=New-Object Drawing.Point(390,665); $open.Size=New-Object Drawing.Size(155,38)
$open.BackColor=[Drawing.Color]::FromArgb(64,137,232); $open.ForeColor=[Drawing.Color]::White; $open.FlatStyle='Flat'; $form.Controls.Add($open)
$close=New-Object Windows.Forms.Button
$close.Text='Close'; $close.Location=New-Object Drawing.Point(560,665); $close.Size=New-Object Drawing.Size(160,38)
$close.BackColor=[Drawing.Color]::FromArgb(79,99,125); $close.ForeColor=[Drawing.Color]::White; $close.FlatStyle='Flat'; $form.Controls.Add($close)

$preflight.Add_Click({
    $estimate=Get-PreflightEstimate ([int]$tools.Value) ([int]$repeats.Value) ([int]$scans.Value) ([int]$suites.Value)
    $report.Text = @(
        "PREFLIGHT USAGE RISK: $($estimate.Level)",
        $estimate.Detail,
        '',
        ('Planned activity: {0} tool calls, {1} repeated actions, {2} full scans, {3} full test-suite runs.' -f $tools.Value,$repeats.Value,$scans.Value,$suites.Value),
        'This is a relative workload estimate, not an exact credit prediction. Check Settings > Usage for the official balance.'
    ) -join [Environment]::NewLine
})
$save.Add_Click({
    if ([string]::IsNullOrWhiteSpace($task.Text)) { [Windows.Forms.MessageBox]::Show('Enter a short task name.') | Out-Null; return }
    $creditsSpent=$null
    if ($before.Value -gt 0 -or $after.Value -gt 0) { $creditsSpent=[math]::Max(0,[decimal]$before.Value-[decimal]$after.Value) }
    $entry=[pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Agent=[string]$agent.SelectedItem; Task=$task.Text.Trim()
        CreditsBefore=if($before.Value -gt 0){[decimal]$before.Value}else{$null}
        CreditsAfter=if($after.Value -gt 0){[decimal]$after.Value}else{$null}
        CreditsSpent=$creditsSpent; ReviewLimit=[decimal]$limit.Value; ToolCalls=[int]$tools.Value
        RepeatedActions=[int]$repeats.Value; FullScans=[int]$scans.Value; FullTestSuites=[int]$suites.Value
        Outcome=$outcome.Text.Trim()
    }
    Save-AuditEntry $entry
    $report.Text=Format-AuditReport $entry
})
$open.Add_Click({ if(-not(Test-Path $AuditFolder)){[void](New-Item -ItemType Directory -Path $AuditFolder)}; Start-Process explorer.exe $AuditFolder })
$close.Add_Click({$form.Close()})
[void]$form.ShowDialog()
