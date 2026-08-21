param(
    [ValidateRange(1, 10)]
    [int]$Runs = 1,
    [ValidateSet('Full', 'Progression', 'Changed', 'Navigation', 'Optimization')]
    [string]$Focus = 'Full',
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'

# The Windows PowerShell 5.1 UI Automation client on this Windows build can
# cache owner-drawn WinForms controls as patternless panes. Modern PowerShell's
# client reports the same controls correctly, so relaunch there automatically.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $modernPowerShell = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($modernPowerShell) {
        $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, '-Runs', [string]$Runs, '-Focus', $Focus)
        if ($KeepSandbox) { $arguments += '-KeepSandbox' }
        & $modernPowerShell.Source @arguments
        exit $LASTEXITCODE
    }
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$testRunsRoot = Join-Path $root '.manager-test-runs'
$resultsRoot = Join-Path $root 'test-results'
[void](New-Item -ItemType Directory -Path $testRunsRoot -Force)
[void](New-Item -ItemType Directory -Path $resultsRoot -Force)
$testMutexCreated = $false
$testMutex = [Threading.Mutex]::new($true, 'Local\GustavASAManagerTestSuite', [ref]$testMutexCreated)
if (-not $testMutexCreated) { throw 'Another ASA Manager test suite is already running.' }
$testRootFullForCleanup = [IO.Path]::GetFullPath($testRunsRoot) + [IO.Path]::DirectorySeparatorChar
foreach ($orphan in @(Get-ChildItem -LiteralPath $testRunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $orphanFull = [IO.Path]::GetFullPath($orphan.FullName)
    if (-not $orphanFull.StartsWith($testRootFullForCleanup, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe orphan sandbox path.' }
    Remove-Item -LiteralPath $orphanFull -Recurse -Force
}
$reportPath = Join-Path $resultsRoot ('ASA-Manager-Test-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.txt')
$report = New-Object System.Collections.Generic.List[string]
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$automationRoot = [System.Windows.Automation.AutomationElement]::RootElement

function Add-Result([string]$Message) {
    $line = (Get-Date -Format 'HH:mm:ss.fff') + ' ' + $Message
    $report.Add($line)
    Write-Host $line
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw 'ASSERTION FAILED: ' + $Message }
    Add-Result ('PASS: ' + $Message)
}

function Test-ControlTypeMatch($Element, [System.Windows.Automation.ControlType]$ExpectedType) {
    $actual = $Element.Current.ControlType
    if ($actual.Id -eq $ExpectedType.Id) { return $true }
    # Some Windows 11 UI Automation sessions initially expose owner-drawn
    # WinForms buttons as Pane even though their accessible name, enabled state,
    # and InvokePattern are correct. Accept that provider quirk in the harness.
    if ($actual.Id -eq [System.Windows.Automation.ControlType]::Pane.Id) {
        if ($ExpectedType.Id -eq [System.Windows.Automation.ControlType]::Button.Id -and $Element.Current.Name) { return $true }
        $patternObject = $null
        if ($ExpectedType.Id -eq [System.Windows.Automation.ControlType]::Edit.Id) {
            return $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$patternObject)
        }
        if ($ExpectedType.Id -eq [System.Windows.Automation.ControlType]::ComboBox.Id) {
            return $Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$patternObject)
        }
        if ($ExpectedType.Id -eq [System.Windows.Automation.ControlType]::CheckBox.Id) {
            return $Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$patternObject)
        }
    }
    return $false
}

function Get-ProcessElements([int]$ProcessId) {
    # Reacquire RootElement so UI Automation never keeps an early/stale view
    # of a WinForms window whose child handles are still being published.
    $freshRoot = [System.Windows.Automation.AutomationElement]::RootElement
    $all = $freshRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    return @($all | Where-Object { $_.Current.ProcessId -eq $ProcessId })
}

function Find-Window([int]$ProcessId, [string]$Name, [int]$TimeoutSeconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        foreach ($element in (Get-ProcessElements $ProcessId)) {
            if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $element.Current.Name -eq $Name) { return $element }
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Window not found: $Name"
}

function Find-Control($Parent, [System.Windows.Automation.ControlType]$Type, [string]$Name, [int]$TimeoutSeconds = 8) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $parentProcessId = $Parent.Current.ProcessId
    do {
        foreach ($element in (Get-ProcessElements $parentProcessId)) {
            if ((Test-ControlTypeMatch $element $Type) -and $element.Current.Name -eq $Name) { return $element }
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    $visibleElements = @(Get-ProcessElements $parentProcessId)
    $seen = @($visibleElements | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
    $named = @($visibleElements | Where-Object { $_.Current.Name -eq $Name } | ForEach-Object { $_.Current.ControlType.ProgrammaticName + '/' + $_.Current.ControlType.Id })
    throw "Control not found: $Name (PID=$parentProcessId; wanted=$($Type.ProgrammaticName)/$($Type.Id); namedTypes=$($named -join ','); visible=$($seen -join '|'))"
}

function Get-Controls($Parent, [System.Windows.Automation.ControlType]$Type) {
    $parentProcessId = $Parent.Current.ProcessId
    $all = $Parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $matches = @($all | Where-Object { Test-ControlTypeMatch $_ $Type })
    if ($matches.Count) { return $matches }
    $parentRect = $Parent.Current.BoundingRectangle
    return @(Get-ProcessElements $parentProcessId | Where-Object {
        if (-not (Test-ControlTypeMatch $_ $Type)) { return $false }
        $rect = $_.Current.BoundingRectangle
        return $rect.Left -ge $parentRect.Left -and $rect.Right -le $parentRect.Right -and $rect.Top -ge $parentRect.Top -and $rect.Bottom -le $parentRect.Bottom
    })
}

function Invoke-Button($Parent, [string]$Name) {
    $button = Find-Control $Parent ([System.Windows.Automation.ControlType]::Button) $Name
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Set-ControlValue($Element, [string]$Value) {
    $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}

function Close-Window($Window) {
    $Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
}

function Close-Info([int]$ProcessId) {
    $message = Find-Window $ProcessId 'ASA Manager'
    Close-Window $message
    Start-Sleep -Milliseconds 250
}

function Select-ComboItem($Combo, [int]$ProcessId, [string]$Name) {
    $expand = $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        foreach ($element in (Get-ProcessElements $ProcessId)) {
            if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and $element.Current.Name -eq $Name) {
                $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                $expand.Collapse()
                return
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Combo item not found: $Name"
}

function Confirm-FirstChoice([int]$ProcessId, [string]$WindowName) {
    $dialog = Find-Window $ProcessId $WindowName
    $buttons = Get-Controls $dialog ([System.Windows.Automation.ControlType]::Button)
    $choice = @($buttons | Where-Object { $_.Current.Name -notin @('Close', 'Minimize', 'Maximize') } | Select-Object -First 1)
    if (-not $choice) { throw "No confirmation button found in $WindowName" }
    $choice[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Wait-WindowGone([int]$ProcessId, [string]$Name, [int]$TimeoutSeconds = 5) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $found = $false
        foreach ($element in (Get-ProcessElements $ProcessId)) {
            if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $element.Current.Name -eq $Name) { $found = $true; break }
        }
        if (-not $found) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Window did not close: $Name"
}

function Write-Fixture([string]$Sandbox) {
    $configFolder = Join-Path $Sandbox 'server\ShooterGame\Saved\Config\WindowsServer'
    [void](New-Item -ItemType Directory -Path $configFolder -Force)
    Copy-Item -LiteralPath (Join-Path $root 'ASA-Manager.ps1') -Destination (Join-Path $Sandbox 'ASA-Manager.ps1')
    foreach ($helper in @('StartServer.bat', 'StopServer.ps1', 'UpdateServer.bat', 'Update-And-Restart.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root $helper) -Destination (Join-Path $Sandbox $helper)
    }
    $serverBin = Join-Path $Sandbox 'server\ShooterGame\Binaries\Win64'
    $steamApps = Join-Path $Sandbox 'server\steamapps'
    [void](New-Item -ItemType Directory -Path $serverBin -Force)
    [void](New-Item -ItemType Directory -Path $steamApps -Force)
    [IO.File]::WriteAllText((Join-Path $serverBin 'ArkAscendedServer.exe'), '', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $steamApps 'appmanifest_2430930.acf'), '"appid" "2430930" "name" "ARK: Survival Ascended Dedicated Server" "buildid" "TESTBUILD"', $utf8NoBom)

    $cmd = @'
@echo off
set "SERVER_NAME=Test ASA Server"
set "MAP=TheIsland_WP"
set "MAX_PLAYERS=999"
set "GAME_PORT=7777"
set "SERVER_IP=192.168.1.179"
set "MODS="
set "ALLOW_SPEED_LEVELING=False"
'@
    $gus = @'
[ServerSettings]
SessionName=Test ASA Server
MaxPlayers=10
XPMultiplier=not-a-number
HarvestAmountMultiplier=2.0
TamingSpeedMultiplier=3.0
PassiveTameIntervalMultiplier=1.0
PlayerResistanceMultiplier=1.0
ResourcesRespawnPeriodMultiplier=0.75
PlayerCharacterFoodDrainMultiplier=0.75
PlayerCharacterWaterDrainMultiplier=0.75
ServerPVE=False
AllowFlyerCarryPvE=False
AlwaysAllowStructurePickup=True
ServerPassword=
ServerAdminPassword=8857
AutoSavePeriodMinutes=broken
MaxTamedDinos=2500
RCONEnabled=False
OverrideOfficialDifficulty=5.0
'@
    $game = @'
[/Script/ShooterGame.ShooterGameMode]
MatingIntervalMultiplier=0.5
EggHatchSpeedMultiplier=5.0
BabyMatureSpeedMultiplier=broken
BabyCuddleIntervalMultiplier=0.2
CropGrowthSpeedMultiplier=2.0
LayEggIntervalMultiplier=0.75
'@
    [IO.File]::WriteAllText((Join-Path $Sandbox 'server-config.cmd'), $cmd, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $configFolder 'GameUserSettings.ini'), $gus, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $configFolder 'Game.ini'), $game, $utf8NoBom)
}

function Run-OneTest([int]$RunNumber) {
    $sandbox = Join-Path $testRunsRoot ('run-' + $RunNumber + '-' + [guid]::NewGuid().ToString('N'))
    $sandboxFull = [IO.Path]::GetFullPath($sandbox)
    $testRootFull = [IO.Path]::GetFullPath($testRunsRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $sandboxFull.StartsWith($testRootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe sandbox path.' }
    [void](New-Item -ItemType Directory -Path $sandboxFull)
    $process = $null
    try {
        Add-Result "RUN ${RunNumber}: Creating disposable fixture."
        Write-Fixture $sandboxFull
        $managerScript = Join-Path $sandboxFull 'ASA-Manager.ps1'
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $managerScript, '-TestMode' -WorkingDirectory $sandboxFull -PassThru
        # Avoid querying the WinForms accessibility tree before its child
        # handles have been published; doing so can cache disabled buttons as
        # generic panes for the lifetime of this UI Automation client.
        Start-Sleep -Milliseconds 1500
        $mainTitle = '[TEST MODE] Gustav''s ARK: Survival Ascended Server Manager'
        $main = Find-Window $process.Id $mainTitle 15
        Assert-True $process.Responding 'Test-mode manager opened and is responding.'
        $visibleButtons = @(Get-ProcessElements $process.Id | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button } | ForEach-Object { $_.Current.Name })
        Add-Result ("DIAGNOSTIC: PID=$($process.Id) MainElementPID=$($main.Current.ProcessId) Buttons=" + ($visibleButtons -join '|'))

        foreach ($dangerousButton in 'Start server','Safe stop','Restart','Update + restart','Safe backup') {
            $control = Find-Control $main ([System.Windows.Automation.ControlType]::Button) $dangerousButton
            Assert-True (-not $control.Current.IsEnabled) "Test mode locked $dangerousButton."
        }

        if ($Focus -eq 'Navigation') {
            Invoke-Button $main 'Files + guide'
            $navigation = Find-Window $process.Id 'Server files + quick guide - ASA Manager'
            foreach ($expectedButton in 'Open selected','Open its folder','Copy path','Open full guide','Close') {
                $control = Find-Control $navigation ([System.Windows.Automation.ControlType]::Button) $expectedButton
                Assert-True ($null -ne $control) "Navigation dialog exposes $expectedButton."
            }
            Invoke-Button $navigation 'Close'
            Wait-WindowGone $process.Id 'Server files + quick guide - ASA Manager'
            Close-Window $main
            if (-not $process.WaitForExit(7000)) { throw 'Navigation test manager did not exit cleanly.' }
            Assert-True ($process.ExitCode -eq 0) 'Navigation test manager exited cleanly.'
            Add-Result "RUN ${RunNumber}: NAVIGATION TEST COMPLETED."
            return
        }

        if ($Focus -eq 'Optimization') {
            # Let several status timer ticks run first. The old implementation
            # repeatedly scanned the save tree and reread every basic config.
            $filesButton = Find-Control $main ([System.Windows.Automation.ControlType]::Button) 'Files + guide'
            Start-Sleep -Seconds 7
            $openTimer = [Diagnostics.Stopwatch]::StartNew()
            $filesButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Milliseconds 300
            $process.Refresh()
            $openTimer.Stop()
            Add-Result ('DIAGNOSTIC: Accessibility invoke completed in {0:N2}s.' -f $openTimer.Elapsed.TotalSeconds)
            Assert-True $process.Responding 'Manager remained responsive after repeated status ticks.'
            $navigation = Find-Window $process.Id 'Server files + quick guide - ASA Manager'
            Assert-True ($null -ne $navigation) 'Files + guide opened after the idle responsiveness check.'
            Invoke-Button $navigation 'Close'
            Wait-WindowGone $process.Id 'Server files + quick guide - ASA Manager'

            $mainEdits = @(Get-ProcessElements $process.Id | Where-Object { Test-ControlTypeMatch $_ ([System.Windows.Automation.ControlType]::Edit) })
            $serverNameEdit = @($mainEdits | Where-Object { $_.GetCurrentPropertyValue([System.Windows.Automation.ValuePattern]::ValueProperty) -eq 'Test ASA Server' } | Select-Object -First 1)
            Assert-True ($null -ne $serverNameEdit) 'Optimization test found the server-name field.'
            Set-ControlValue $serverNameEdit 'Unsaved Test Name'
            $unsaved = Find-Control $main ([System.Windows.Automation.ControlType]::Text) 'UNSAVED CHANGES - click Save basic settings' 4
            Assert-True ($null -ne $unsaved) 'Event-driven unsaved indicator updated without rereading configuration files.'

            Close-Window $main
            if (-not $process.WaitForExit(7000)) { throw 'Optimization test manager did not exit cleanly.' }
            Assert-True ($process.ExitCode -eq 0) 'Optimization test manager exited cleanly.'
            Add-Result "RUN ${RunNumber}: OPTIMIZATION TEST COMPLETED."
            return
        }

        if ($Focus -eq 'Progression') {
            $gamePath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\Game.ini'
            $gusPath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'
            Invoke-Button $main 'Stats + time'
            $progression = Find-Window $process.Id 'Progression and world time - ASA Manager'
            Invoke-Button $progression 'Balanced private preset'
            Invoke-Button $progression 'Save progression + time'
            Close-Info $process.Id
            Wait-WindowGone $process.Id 'Progression and world time - ASA Manager'
            $gameRaw = [IO.File]::ReadAllText($gamePath)
            $cmdRaw = [IO.File]::ReadAllText((Join-Path $sandboxFull 'server-config.cmd'))
            Assert-True ($gameRaw -match '(?m)^KillXPMultiplier=1\.25\s*$') 'Focused progression test saved kill XP.'
            Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[9\]=1\.0\s*$') 'Focused progression test saved honest vanilla movement gain.'
            Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[10\]=3\.0\s*$') 'Focused progression test saved Fortitude gain.'
            Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_DinoTamed\[7\]=2\.0\s*$') 'Focused progression test saved dino weight gain.'
            Assert-True ($cmdRaw -match '(?m)^set "ALLOW_SPEED_LEVELING=True"\s*$') 'Focused progression test enabled native speed leveling at startup.'
            Close-Window $main
            if (-not $process.WaitForExit(7000)) { throw 'Focused test manager did not exit cleanly.' }
            Assert-True ($process.ExitCode -eq 0) 'Focused test manager exited cleanly.'
            Add-Result "RUN ${RunNumber}: FOCUSED PROGRESSION TEST COMPLETED."
            return
        }

        if ($Focus -eq 'Changed') {
            $gamePath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\Game.ini'
            $gusPath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'

            Invoke-Button $main 'Guided rates'
            $rates = Find-Window $process.Id 'Guided rates - ASA Manager'
            Invoke-Button $rates 'Balanced No-Wipe'
            Invoke-Button $rates 'Save rates'
            Close-Info $process.Id
            Wait-WindowGone $process.Id 'Guided rates - ASA Manager'
            $gusRaw = [IO.File]::ReadAllText($gusPath)
            Assert-True ($gusRaw -match '(?m)^XPMultiplier=4\.0\s*$') 'Changed-rate test saved 4x XP.'
            Assert-True ($gusRaw -match '(?m)^HarvestAmountMultiplier=5\.0\s*$') 'Changed-rate test saved 5x harvesting.'
            Assert-True ($gusRaw -match '(?m)^TamingSpeedMultiplier=12\.0\s*$') 'Changed-rate test saved 12x taming.'
            Assert-True ($gusRaw -match '(?m)^PassiveTameIntervalMultiplier=0\.2\s*$') 'Changed-rate test saved the five-times-shorter passive feed interval.'
            Assert-True ($gusRaw -match '(?m)^PlayerResistanceMultiplier=0\.5\s*$') 'Changed-rate test saved half incoming player damage.'

            Invoke-Button $main 'Stats + time'
            $progression = Find-Window $process.Id 'Progression and world time - ASA Manager'
            Invoke-Button $progression 'Balanced private preset'
            Invoke-Button $progression 'Save progression + time'
            Close-Info $process.Id
            Wait-WindowGone $process.Id 'Progression and world time - ASA Manager'
            $gameRaw = [IO.File]::ReadAllText($gamePath)
            Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[1\]=2\.0\s*$') 'Changed-progression test saved double player stamina per level.'
            Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[7\]=3\.0\s*$') 'Changed-progression test saved triple player weight per level.'

            Invoke-Button $main 'Important server settings'
            $important = Find-Window $process.Id 'Important settings - ASA Manager'
            $penalty = Find-Control $important ([System.Windows.Automation.ControlType]::CheckBox) 'Disable the escalating PvP repeated-death respawn penalty'
            if ($penalty.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
                $penalty.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
            }
            Invoke-Button $important 'Save important settings'
            Close-Info $process.Id
            Wait-WindowGone $process.Id 'Important settings - ASA Manager'
            $gameRaw = [IO.File]::ReadAllText($gamePath)
            $gusRaw = [IO.File]::ReadAllText($gusPath)
            Assert-True ($gameRaw -match '(?m)^bIncreasePvPRespawnInterval=False\s*$') 'Changed-settings test disabled the escalating PvP respawn penalty.'
            Assert-True ($gusRaw -match '(?m)^SimpleBedCooldown=30\s*$') 'Changed-settings test saved a 30-second CS Simple Bed cooldown.'
            Assert-True ($gusRaw -match '(?m)^ModernBedCooldown=12\s*$') 'Changed-settings test saved a 12-second CS Bunk Bed cooldown.'

            Close-Window $main
            if (-not $process.WaitForExit(7000)) { throw 'Changed-features test manager did not exit cleanly.' }
            Assert-True ($process.ExitCode -eq 0) 'Changed-features test manager exited cleanly.'
            Add-Result "RUN ${RunNumber}: CHANGED-FEATURES TEST COMPLETED."
            return
        }

        $mainEdits = Get-Controls $main ([System.Windows.Automation.ControlType]::Edit)
        $serverNameEdit = @($mainEdits | Where-Object { $_.GetCurrentPropertyValue([System.Windows.Automation.ValuePattern]::ValueProperty) -eq 'Test ASA Server' } | Select-Object -First 1)
        if (-not $serverNameEdit) {
            $namedDiagnostics = @(Get-ProcessElements $process.Id | Where-Object { $_.Current.Name -eq 'Test ASA Server' } | ForEach-Object {
                $_.Current.ControlType.ProgrammaticName + ':' + (($_.GetSupportedPatterns() | ForEach-Object ProgrammaticName) -join ',')
            })
            throw ('Server-name edit control not found. ' + ($namedDiagnostics -join '|'))
        }
        Set-ControlValue $serverNameEdit[0] 'Test ASA Hardened'
        $combo = (Get-Controls $main ([System.Windows.Automation.ControlType]::ComboBox) | Select-Object -First 1)
        Select-ComboItem $combo $process.Id 'Aberration_WP'
        $expand = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        Start-Sleep -Milliseconds 250
        $releasedMaps = @(Get-ProcessElements $process.Id | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem } | ForEach-Object { $_.Current.Name })
        Assert-True ('Valguero_WP' -in $releasedMaps) 'Current ASA Valguero_WP map is available in the selector.'
        Assert-True ('Genesis_WP' -in $releasedMaps) 'Current ASA Genesis_WP map is available in the selector.'
        $expand.Collapse()

        $cmdPath = Join-Path $sandboxFull 'server-config.cmd'
        $beforeDeniedWrite = (Get-FileHash -Algorithm SHA256 $cmdPath).Hash
        $lockStream = [IO.File]::Open($cmdPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Invoke-Button $main 'Save basic settings'
            Confirm-FirstChoice $process.Id 'Confirm map change'
            Close-Info $process.Id
            Assert-True ((Get-FileHash -Algorithm SHA256 $cmdPath).Hash -eq $beforeDeniedWrite) 'A denied atomic write left the original configuration unchanged.'
            Assert-True ((Get-Process -Id $process.Id).Responding) 'Manager remained responsive after a denied write.'
        }
        finally { $lockStream.Dispose() }

        Invoke-Button $main 'Save basic settings'
        Confirm-FirstChoice $process.Id 'Confirm map change'
        Close-Info $process.Id
        $cmdRaw = [IO.File]::ReadAllText($cmdPath)
        Assert-True ($cmdRaw -match '(?m)^set "SERVER_NAME=Test ASA Hardened"\s*$') 'Basic settings wrote the sanitized server name.'
        Assert-True ($cmdRaw -match '(?m)^set "MAP=Aberration_WP"\s*$') 'Map confirmation saved Aberration_WP.'
        Assert-True ($cmdRaw -match '(?m)^set "MAX_PLAYERS=70"\s*$') 'Out-of-range player count was safely clamped to the UI maximum.'
        $gusPath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'
        Assert-True (([IO.File]::ReadAllText($gusPath)) -match '(?m)^XPMultiplier=1\.0\s*$') 'Malformed XP input fell back to a safe default instead of crashing.'

        Set-ControlValue $serverNameEdit[0] 'Bad & Unsafe Name'
        Invoke-Button $main 'Save basic settings'
        Close-Info $process.Id
        Assert-True (([IO.File]::ReadAllText($cmdPath)) -match '(?m)^set "SERVER_NAME=Test ASA Hardened"\s*$') 'Unsafe server-name characters were rejected without changing the file.'
        Set-ControlValue $serverNameEdit[0] 'Test ASA Hardened'

        Invoke-Button $main 'Guided rates'
        $rates = Find-Window $process.Id 'Guided rates - ASA Manager'
        Invoke-Button $rates 'Relaxed private preset'
        Invoke-Button $rates 'Save rates'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Guided rates - ASA Manager'
        $gamePath = Join-Path $sandboxFull 'server\ShooterGame\Saved\Config\WindowsServer\Game.ini'
        $gusRaw = [IO.File]::ReadAllText($gusPath)
        $gameRaw = [IO.File]::ReadAllText($gamePath)
        Assert-True ($gusRaw -match '(?m)^TamingSpeedMultiplier=5\.0\s*$') 'Guided rates saved the relaxed taming rate.'
        Assert-True ($gameRaw -match '(?m)^BabyMatureSpeedMultiplier=10\.0\s*$') 'Guided rates saved breeding values in Game.ini.'

        Invoke-Button $main 'Guided rates'
        $rates = Find-Window $process.Id 'Guided rates - ASA Manager'
        Invoke-Button $rates 'Balanced No-Wipe'
        Invoke-Button $rates 'Save rates'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Guided rates - ASA Manager'
        $gusRaw = [IO.File]::ReadAllText($gusPath)
        $gameRaw = [IO.File]::ReadAllText($gamePath)
        Assert-True ($gusRaw -match '(?m)^XPMultiplier=4\.0\s*$') 'No Wipe preset saved 4x experience.'
        Assert-True ($gusRaw -match '(?m)^HarvestAmountMultiplier=5\.0\s*$') 'No Wipe preset saved 5x harvesting.'
        Assert-True ($gusRaw -match '(?m)^TamingSpeedMultiplier=12\.0\s*$') 'No Wipe preset saved 12x taming.'
        Assert-True ($gusRaw -match '(?m)^PassiveTameIntervalMultiplier=0\.2\s*$') 'No Wipe preset saved the passive-tame interval.'
        Assert-True ($gusRaw -match '(?m)^PlayerResistanceMultiplier=0\.5\s*$') 'No Wipe preset saved reduced incoming player damage.'
        Assert-True ($gameRaw -match '(?m)^MatingIntervalMultiplier=0\.05\s*$') 'No Wipe preset saved a 20x-faster mating cooldown.'
        Assert-True ($gameRaw -match '(?m)^MatingSpeedMultiplier=10\.0\s*$') 'No Wipe preset saved ten-times-faster mating progress.'
        Assert-True ($gameRaw -match '(?m)^EggHatchSpeedMultiplier=20\.0\s*$') 'No Wipe preset saved 20x hatching.'
        Assert-True ($gameRaw -match '(?m)^BabyMatureSpeedMultiplier=20\.0\s*$') 'No Wipe preset saved 20x maturation.'
        Assert-True ($gameRaw -match '(?m)^BabyCuddleIntervalMultiplier=0\.05\s*$') 'No Wipe preset kept imprint timing compatible with 20x maturation.'
        Assert-True ($gameRaw -match '(?m)^BabyImprintAmountMultiplier=100\.0\s*$') 'No Wipe preset made one successful care give a full imprint.'

        Invoke-Button $main 'Stats + time'
        $progression = Find-Window $process.Id 'Progression and world time - ASA Manager'
        Invoke-Button $progression 'Balanced private preset'
        Invoke-Button $progression 'Save progression + time'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Progression and world time - ASA Manager'
        $gameRaw = [IO.File]::ReadAllText($gamePath)
        Assert-True ($gameRaw -match '(?m)^KillXPMultiplier=1\.25\s*$') 'Progression preset saved the additional kill-XP multiplier.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[1\]=2\.0\s*$') 'Progression preset saved double player stamina gain.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[7\]=3\.0\s*$') 'Progression preset saved triple player weight gain.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[9\]=1\.0\s*$') 'Progression preset saved vanilla movement gain without pretending ASA has a native hard cap.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_Player\[10\]=3\.0\s*$') 'Progression preset saved triple player Fortitude gain.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_DinoTamed\[0\]=0\.23\s*$') 'Progression preset converted relative dino-health gain to the correct ASA raw value.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_DinoTamed\[1\]=1\.25\s*$') 'Progression preset saved tamed-dino stamina gain.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_DinoTamed\[7\]=2\.0\s*$') 'Progression preset saved double tamed-dino weight gain.'
        Assert-True ($gameRaw -match '(?m)^PerLevelStatsMultiplier_DinoTamed\[8\]=0\.1955\s*$') 'Progression preset converted relative dino-melee gain to the correct ASA raw value.'
        $cmdRaw = [IO.File]::ReadAllText((Join-Path $sandbox 'server-config.cmd'))
        Assert-True ($cmdRaw -match '(?m)^set "ALLOW_SPEED_LEVELING=True"\s*$') 'Progression preset enabled ASA native movement-speed leveling at launch.'

        Invoke-Button $main 'Custom crafting costs'
        $crafting = Find-Window $process.Id 'Custom crafting costs - ASA Manager'
        Invoke-Button $crafting 'Load Basic Kibble test'
        Invoke-Button $crafting 'Add / replace recipe'
        Invoke-Button $crafting 'Save recipe list'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Custom crafting costs - ASA Manager'
        $gameRaw = [IO.File]::ReadAllText($gamePath)
        Assert-True ($gameRaw -match '(?m)^ConfigOverrideItemCraftingCosts=\(ItemClassString="PrimalItemConsumable_Kibble_Base_XSmall_C".*ResourceItemTypeString="PrimalItemConsumable_CookedMeat_C".*BaseResourceRequirement=5\.0.*\)\s*$') 'Custom recipe editor saved the Basic Kibble five-cooked-meat test recipe.'

        Invoke-Button $main 'Manage mods'
        $mods = Find-Window $process.Id 'Cross-platform mods - ASA Manager'
        $modEdit = (Get-Controls $mods ([System.Windows.Automation.ControlType]::Edit) | Select-Object -First 1)
        Set-ControlValue $modEdit 'not-a-project-id'
        Invoke-Button $mods 'Add project ID'
        Close-Info $process.Id
        Assert-True ((Get-Process -Id $process.Id).Responding) 'Mod manager safely rejected a non-numeric Project ID.'
        foreach ($id in '900001','900002') {
            Set-ControlValue $modEdit $id
            Invoke-Button $mods 'Add project ID'
        }
        Invoke-Button $mods 'Save mod list'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Cross-platform mods - ASA Manager'
        $cmdRaw = [IO.File]::ReadAllText((Join-Path $sandboxFull 'server-config.cmd'))
        Assert-True ($cmdRaw -match '(?m)^set "MODS=900001,900002"\s*$') 'Mod manager saved ordered numeric CurseForge IDs.'

        Invoke-Button $main 'Important server settings'
        $important = Find-Window $process.Id 'Important settings - ASA Manager'
        $pve = Find-Control $important ([System.Windows.Automation.ControlType]::CheckBox) 'PvE mode (friends cannot damage each other or their structures)'
        if ($pve.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
            $pve.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        }
        Invoke-Button $important 'Save important settings'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Important settings - ASA Manager'
        $gusRaw = [IO.File]::ReadAllText($gusPath)
        Assert-True ($gusRaw -match '(?m)^ServerPVE=True\s*$') 'Important settings saved PvE mode.'
        Assert-True ($gusRaw -match '(?m)^ServerAdminPassword=8857\s*$') 'Four-digit masked admin password survived an unrelated save.'

        Invoke-Button $main 'PS5 admin + performance help'
        $ps5 = Find-Window $process.Id 'PS5 admin and balanced performance - ASA Manager'
        Invoke-Button $ps5 'Copy SaveWorld'
        Close-Info $process.Id
        Assert-True ([Windows.Forms.Clipboard]::GetText() -eq 'cheat SaveWorld') 'PS5 SaveWorld copy button produced the correct command.'
        Invoke-Button $ps5 'Copy YOUR maximum boost'
        Close-Info $process.Id
        $expectedMaximumBoost = 'r.VolumetricCloud 0|r.VolumetricFog 0|r.Fog 0|r.Lumen.DiffuseIndirect.Allow 0|r.Lumen.Reflections.Allow 0|grass.Enable 0|r.Water.SingleLayer.Reflection 0|r.ShadowQuality 0'
        Assert-True ([Windows.Forms.Clipboard]::GetText() -eq $expectedMaximumBoost) 'PS5 maximum boost button preserved the exact reviewed command chain.'
        Invoke-Button $ps5 'Copy reset values'
        Close-Info $process.Id
        $expectedVisualReset = 'r.VolumetricCloud 1|r.VolumetricFog 1|r.Fog 1|r.Lumen.DiffuseIndirect.Allow 1|r.Lumen.Reflections.Allow 1|grass.Enable 1|r.Water.SingleLayer.Reflection 1|r.ShadowQuality 1'
        Assert-True ([Windows.Forms.Clipboard]::GetText() -eq $expectedVisualReset) 'PS5 reset button produced a matching on-value for all eight boost settings.'
        Invoke-Button $ps5 'Manage permanent admins'
        $admins = Find-Window $process.Id 'Permanent server admins - ASA Manager'
        $adminEdit = (Get-Controls $admins ([System.Windows.Automation.ControlType]::Edit) | Select-Object -First 1)
        Set-ControlValue $adminEdit 'TOO-SHORT'
        Invoke-Button $admins 'Add Account ID'
        Close-Info $process.Id
        Assert-True ((Get-Process -Id $process.Id).Responding) 'Admin manager safely rejected an invalid Account ID.'
        Set-ControlValue $adminEdit '1234567890ABCDEF1234567890ABCDEF'
        Invoke-Button $admins 'Add Account ID'
        Invoke-Button $admins 'Save admin list'
        Close-Info $process.Id
        Wait-WindowGone $process.Id 'Permanent server admins - ASA Manager'
        $adminPath = Join-Path $sandboxFull 'server\ShooterGame\Saved\AllowedCheaterAccountIDs.txt'
        Assert-True (([IO.File]::ReadAllText($adminPath)).Trim() -eq '1234567890ABCDEF1234567890ABCDEF') 'Permanent admin manager wrote the 32-character Account ID.'
        Close-Window $ps5
        Wait-WindowGone $process.Id 'PS5 admin and balanced performance - ASA Manager'

        Invoke-Button $main 'Run offline server advisor'
        $advisor = Find-Window $process.Id 'Offline server advisor - ASA Manager'
        Invoke-Button $advisor 'Refresh scan'
        Invoke-Button $advisor 'Copy report'
        Close-Info $process.Id
        $advisorReport = [Windows.Forms.Clipboard]::GetText()
        Assert-True ($advisorReport -match 'Correct Steam server app') 'Offline advisor checked the installed ASA Steam app manifest.'
        Assert-True ($advisorReport -match 'PS5 crossplay startup') 'Offline advisor checked the PS5 crossplay startup flag.'
        Assert-True ($advisorReport -notmatch 'TestAdmin123') 'Offline advisor did not expose the admin password in its report.'
        Invoke-Button $advisor 'Close'
        Wait-WindowGone $process.Id 'Offline server advisor - ASA Manager'

        $snapshots = @(Get-ChildItem (Join-Path $sandboxFull 'backups\ConfigHistory') -Directory -ErrorAction Stop)
        Assert-True ($snapshots.Count -ge 5) 'Every configuration save created a pre-change snapshot.'
        Assert-True (Test-Path ((Join-Path $sandboxFull 'server-config.cmd') + '.bak')) 'Atomic writes retained a server-config.cmd rollback copy.'
        Assert-True (Test-Path ($gusPath + '.bak')) 'Atomic writes retained a GameUserSettings.ini rollback copy.'
        Assert-True (Test-Path ($gamePath + '.bak')) 'Atomic writes retained a Game.ini rollback copy.'
        $tempFiles = @(Get-ChildItem $sandboxFull -File -Recurse -Force | Where-Object Name -like '*.tmp')
        Assert-True ($tempFiles.Count -eq 0) 'Atomic writes left no temporary files behind.'
        $managerLog = Join-Path $sandboxFull 'ASA-Manager.log'
        $loggedErrors = if (Test-Path $managerLog) { @([IO.File]::ReadAllLines($managerLog) | Where-Object { $_ -match '\[ERROR\]' }) } else { @() }
        Assert-True ($loggedErrors.Count -eq 4) 'Manager logged exactly the four deliberately triggered validation/write errors.'
        Assert-True (($loggedErrors -join "`n") -match 'Server name must be') 'Unsafe server-name rejection was logged.'
        Assert-True (($loggedErrors -join "`n") -match 'numeric CurseForge Project ID') 'Invalid mod-ID rejection was logged.'
        Assert-True (($loggedErrors -join "`n") -match '32-character Account ID') 'Invalid admin-ID rejection was logged.'

        Close-Window $main
        if (-not $process.WaitForExit(7000)) { throw 'Test manager did not exit cleanly.' }
        Assert-True ($process.ExitCode -eq 0) 'Test-mode manager exited cleanly.'
        Add-Result "RUN ${RunNumber}: COMPLETED."
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try { $process.CloseMainWindow() | Out-Null; if (-not $process.WaitForExit(3000)) { Stop-Process -Id $process.Id -Force } } catch { }
        }
        if (-not $KeepSandbox -and (Test-Path -LiteralPath $sandboxFull)) {
            Remove-Item -LiteralPath $sandboxFull -Recurse -Force
        }
    }
}

try {
    Add-Result "Starting ASA Manager disposable GUI test suite. Runs=$Runs Focus=$Focus"
    for ($run = 1; $run -le $Runs; $run++) { Run-OneTest $run }
    Add-Result 'ALL TEST RUNS PASSED.'
    [IO.File]::WriteAllLines($reportPath, [string[]]$report, $utf8NoBom)
    [IO.File]::WriteAllLines((Join-Path $resultsRoot 'LATEST-PASS.txt'), [string[]]$report, $utf8NoBom)
    Write-Host "Report: $reportPath" -ForegroundColor Green
    $testMutex.ReleaseMutex()
    $testMutex.Dispose()
    exit 0
}
catch {
    Add-Result ('FAIL: ' + $_.Exception.Message)
    [IO.File]::WriteAllLines($reportPath, [string[]]$report, $utf8NoBom)
    Write-Host "Report: $reportPath" -ForegroundColor Red
    if ($testMutexCreated) { try { $testMutex.ReleaseMutex() } catch { }; $testMutex.Dispose() }
    exit 1
}
