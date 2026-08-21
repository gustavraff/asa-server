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

$script:PendingProposal = $null

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
$form.Size = New-Object Drawing.Size(900, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Background
$form.ForeColor = $Text
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.MinimumSize = New-Object Drawing.Size(900, 700)

$title = New-Object Windows.Forms.Label
$title.Text = 'LOCAL AI ASSISTANT'
$title.Location = New-Object Drawing.Point(22, 18)
$title.Size = New-Object Drawing.Size(500, 34)
$title.ForeColor = $Text
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Preview first. Apply requires confirmation, a backup, and a stopped ASA server.'
$subtitle.Location = New-Object Drawing.Point(24, 54)
$subtitle.Size = New-Object Drawing.Size(800, 24)
$subtitle.ForeColor = $Muted
$form.Controls.Add($subtitle)

$promptLabel = New-Object Windows.Forms.Label
$promptLabel.Text = 'Tell the assistant what you want to change'
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
$askButton.Text = 'Ask local AI'
$askButton.Location = New-Object Drawing.Point(22, 220)
$askButton.Size = New-Object Drawing.Size(165, 42)
$askButton.BackColor = $Blue
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

$applyButton = New-Object Windows.Forms.Button
$applyButton.Text = 'Apply changes'
$applyButton.Location = New-Object Drawing.Point(321, 220)
$applyButton.Size = New-Object Drawing.Size(165, 42)
$applyButton.BackColor = $Green
$applyButton.ForeColor = [Drawing.Color]::White
$applyButton.FlatStyle = 'Flat'
$applyButton.FlatAppearance.BorderSize = 0
$applyButton.Enabled = $false
$form.Controls.Add($applyButton)

$status = New-Object Windows.Forms.Label
$status.Text = 'Ready - using local Ollama model qwen3:8b'
$status.Location = New-Object Drawing.Point(500, 230)
$status.Size = New-Object Drawing.Size(362, 26)
$status.ForeColor = $Green
$status.TextAlign = 'MiddleRight'
$form.Controls.Add($status)

$summaryLabel = New-Object Windows.Forms.Label
$summaryLabel.Text = 'Assistant summary'
$summaryLabel.Location = New-Object Drawing.Point(22, 278)
$summaryLabel.Size = New-Object Drawing.Size(300, 24)
$summaryLabel.ForeColor = $Text
$form.Controls.Add($summaryLabel)

$summaryBox = New-Object Windows.Forms.TextBox
$summaryBox.Location = New-Object Drawing.Point(22, 306)
$summaryBox.Size = New-Object Drawing.Size(840, 58)
$summaryBox.Multiline = $true
$summaryBox.ReadOnly = $true
$summaryBox.BackColor = $Panel
$summaryBox.ForeColor = $Text
$summaryBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($summaryBox)

$changesLabel = New-Object Windows.Forms.Label
$changesLabel.Text = 'Proposed setting changes'
$changesLabel.Location = New-Object Drawing.Point(22, 378)
$changesLabel.Size = New-Object Drawing.Size(300, 24)
$changesLabel.ForeColor = $Text
$form.Controls.Add($changesLabel)

$list = New-Object Windows.Forms.ListView
$list.Location = New-Object Drawing.Point(22, 406)
$list.Size = New-Object Drawing.Size(840, 175)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.BackColor = $Panel
$list.ForeColor = $Text
[void]$list.Columns.Add('Setting', 235)
[void]$list.Columns.Add('Value', 90)
[void]$list.Columns.Add('File', 180)
[void]$list.Columns.Add('Reason', 315)
$form.Controls.Add($list)

$safety = New-Object Windows.Forms.Label
$safety.Text = 'SAFETY: Only allow-listed settings can be applied. Apply refuses while ASA is running and snapshots both INI files first.'
$safety.Location = New-Object Drawing.Point(22, 596)
$safety.Size = New-Object Drawing.Size(840, 30)
$safety.ForeColor = $Amber
$safety.TextAlign = 'MiddleCenter'
$form.Controls.Add($safety)

$closeButton = New-Object Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Location = New-Object Drawing.Point(692, 628)
$closeButton.Size = New-Object Drawing.Size(170, 36)
$closeButton.BackColor = [Drawing.Color]::FromArgb(79, 99, 125)
$closeButton.ForeColor = [Drawing.Color]::White
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($closeButton)

$clearButton.Add_Click({
    $script:PendingProposal = $null
    $applyButton.Enabled = $false
    $promptBox.Clear()
    $summaryBox.Clear()
    $list.Items.Clear()
    $status.Text = 'Ready'
    $status.ForeColor = $Green
})

$closeButton.Add_Click({ $form.Close() })

$askButton.Add_Click({
    $script:PendingProposal = $null
    $applyButton.Enabled = $false

    $request = $promptBox.Text.Trim()
    if (-not $request) {
        $status.Text = 'Enter a request first.'
        $status.ForeColor = $Amber
        return
    }

    $askButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Thinking locally...'
    $status.ForeColor = $Amber
    $summaryBox.Clear()
    $list.Items.Clear()
    [Windows.Forms.Application]::DoEvents()

    try {
        $proposal = Get-AsaAiProposal -Prompt $request -Model 'qwen3:8b'
        $summaryBox.Text = $proposal.Summary

        foreach ($change in @($proposal.Changes)) {
            $item = New-Object Windows.Forms.ListViewItem([string]$change.Key)
            [void]$item.SubItems.Add(([string]$change.Value))
            [void]$item.SubItems.Add([string]$change.TargetFile)
            [void]$item.SubItems.Add([string]$change.Reason)
            [void]$list.Items.Add($item)
        }

        if (@($proposal.Rejected).Count -gt 0) {
            $summaryBox.Text += "`r`nRejected: " + (@($proposal.Rejected) -join '; ')
        }

        if (@($proposal.Changes).Count -gt 0) {
            $script:PendingProposal = $proposal
            $applyButton.Enabled = $true
            $status.Text = "Preview ready - $(@($proposal.Changes).Count) validated change(s)"
            $status.ForeColor = $Green
        }
        else {
            $status.Text = 'No allowed changes proposed - nothing to apply'
            $status.ForeColor = $Amber
        }
    }
    catch {
        $script:PendingProposal = $null
        $applyButton.Enabled = $false
        $status.Text = 'AI request failed safely'
        $status.ForeColor = $Red
        $summaryBox.Text = $_.Exception.Message
    }
    finally {
        $form.Cursor = 'Default'
        $askButton.Enabled = $true
    }
})

$applyButton.Add_Click({
    if (-not $script:PendingProposal) {
        $applyButton.Enabled = $false
        [Windows.Forms.MessageBox]::Show('There is no validated preview to apply.', 'ASA AI Assistant', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $canonical = Test-AsaAiApplyProposal -Proposal $script:PendingProposal
    if (-not $canonical.Success) {
        $script:PendingProposal = $null
        $applyButton.Enabled = $false
        [Windows.Forms.MessageBox]::Show("The preview failed apply-time validation and was discarded.`r`n`r`n$($canonical.Error)", 'ASA AI Assistant', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $changeText = ($canonical.Changes | ForEach-Object {
        "$($_.Key) = $($_.Value)    [$($_.TargetFile)]"
    }) -join "`r`n"

    $confirmationText = @"
Apply these exact validated settings?

$changeText

ASA must be stopped. Before writing, both GameUserSettings.ini and Game.ini will be copied to a timestamped backup folder.
"@

    $answer = [Windows.Forms.MessageBox]::Show(
        $confirmationText,
        'Confirm AI settings apply',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        $status.Text = 'Apply cancelled - nothing changed'
        $status.ForeColor = $Amber
        return
    }

    $askButton.Enabled = $false
    $clearButton.Enabled = $false
    $applyButton.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $status.Text = 'Applying validated settings safely...'
    $status.ForeColor = $Amber
    [Windows.Forms.Application]::DoEvents()

    try {
        $result = Invoke-AsaAiApplyProposal -Proposal $script:PendingProposal
        $script:PendingProposal = $null
        $applyButton.Enabled = $false

        if ($result.Success) {
            $status.Text = 'Settings applied - new preview required for another apply'
            $status.ForeColor = $Green
            [Windows.Forms.MessageBox]::Show(
                "$($result.Message)`r`n`r`nBackup:`r`n$($result.BackupPath)",
                'ASA AI Assistant',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        else {
            $status.Text = 'Apply refused or failed safely - preview discarded'
            $status.ForeColor = $Red
            $message = $result.Message
            if ($result.BackupPath) {
                $message += "`r`n`r`nBackup/snapshot path:`r`n$($result.BackupPath)"
            }
            [Windows.Forms.MessageBox]::Show(
                $message,
                'ASA AI Assistant',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
    catch {
        $script:PendingProposal = $null
        $applyButton.Enabled = $false
        $status.Text = 'Apply failed safely - preview discarded'
        $status.ForeColor = $Red
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'ASA AI Assistant',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.Cursor = 'Default'
        $askButton.Enabled = $true
        $clearButton.Enabled = $true
    }
})

[void]$form.ShowDialog()
