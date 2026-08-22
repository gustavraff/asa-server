$ErrorActionPreference = 'Stop'

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "TEST FAILED: $Message" }
}

$root = $PSScriptRoot
$enginePath = Join-Path $root 'ASA-AI-Assistant.ps1'
$panelPath = Join-Path $root 'ASA-AI-Panel.ps1'
$liveGameUserSettings = Join-Path $root 'server\ShooterGame\Saved\Config\WindowsServer\GameUserSettings.ini'
$liveGameIni = Join-Path $root 'server\ShooterGame\Saved\Config\WindowsServer\Game.ini'

if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    throw 'TEST STOPPED: ArkAscendedServer is running. Stop the server before running the disposable apply test.'
}

foreach ($file in @($enginePath, $panelPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) ("Syntax errors in " + [IO.Path]::GetFileName($file))
}
Write-Host 'PASS: script syntax'

$liveGameUserHash = if ([IO.File]::Exists($liveGameUserSettings)) { (Get-FileHash -LiteralPath $liveGameUserSettings -Algorithm SHA256).Hash } else { $null }
$liveGameIniHash = if ([IO.File]::Exists($liveGameIni)) { (Get-FileHash -LiteralPath $liveGameIni -Algorithm SHA256).Hash } else { $null }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('asa-ai-apply-test-' + [guid]::NewGuid().ToString('N'))
$testConfig = Join-Path $testRoot 'server\ShooterGame\Saved\Config\WindowsServer'
$testEngine = Join-Path $testRoot 'ASA-AI-Assistant.ps1'
$testGameUserSettings = Join-Path $testConfig 'GameUserSettings.ini'
$testGameIni = Join-Path $testConfig 'Game.ini'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [void][IO.Directory]::CreateDirectory($testConfig)
    [IO.File]::Copy($enginePath, $testEngine, $false)

    [IO.File]::WriteAllLines($testGameUserSettings, [string[]]@(
        '; disposable test only',
        '[ServerSettings]',
        'TamingSpeedMultiplier=2',
        'HarvestAmountMultiplier=5',
        '',
        '[Other]',
        'TamingSpeedMultiplier=999',
        'KeepMe=Yes'
    ), $utf8NoBom)

    [IO.File]::WriteAllLines($testGameIni, [string[]]@(
        '; disposable test only',
        '[/Script/ShooterGame.ShooterGameMode]',
        'BabyMatureSpeedMultiplier=1',
        'EggHatchSpeedMultiplier=3',
        '',
        '[Other]',
        'KeepGame=Yes'
    ), $utf8NoBom)

    & {
        param($Engine, $ExpectedRoot, $ExpectedGameUserSettings, $ExpectedGameIni)

        . $Engine

        $paths = Get-AsaAiFixedConfigPaths
        Assert-Test ([IO.Path]::GetFullPath($paths.GameUserSettings) -ceq [IO.Path]::GetFullPath($ExpectedGameUserSettings)) 'Temp isolation failed for GameUserSettings.ini; no apply was performed.'
        Assert-Test ([IO.Path]::GetFullPath($paths.GameIni) -ceq [IO.Path]::GetFullPath($ExpectedGameIni)) 'Temp isolation failed for Game.ini; no apply was performed.'
        Assert-Test ([IO.Path]::GetFullPath($paths.BackupRoot).StartsWith([IO.Path]::GetFullPath($ExpectedRoot), [StringComparison]::OrdinalIgnoreCase)) 'Temp isolation failed for backup root; no apply was performed.'
        Write-Host 'PASS: temp path isolation'

        $malicious = [pscustomobject]@{ Changes = @(
            [pscustomobject]@{ Key='TamingSpeedMultiplier'; Value='10'; TargetFile='evil.txt'; Section='[Bad]' }
        ) }
        $canonical = Test-AsaAiApplyProposal -Proposal $malicious
        Assert-Test $canonical.Success 'Valid allow-listed setting was rejected.'
        Assert-Test ($canonical.Changes[0].TargetFile -ceq 'GameUserSettings.ini') 'Proposal TargetFile was trusted.'
        Assert-Test ($canonical.Changes[0].Section -ceq '[ServerSettings]') 'Proposal Section was trusted.'
        Write-Host 'PASS: canonical allow-list validation'

        $sample = [string[]]@(
            '; keep this comment',
            '[ServerSettings]',
            'Foo=1',
            'TamingSpeedMultiplier=2',
            '',
            '[Other]',
            'TamingSpeedMultiplier=999'
        )
        $edited = Set-AsaIniValueInMemory -Lines $sample -Section '[ServerSettings]' -Key 'TamingSpeedMultiplier' -Value '10'
        Assert-Test ($edited -contains 'TamingSpeedMultiplier=10') 'Target key was not changed in memory.'
        Assert-Test ($edited -contains 'TamingSpeedMultiplier=999') 'Same key in another section was changed.'
        Assert-Test ($edited -contains '; keep this comment') 'Unrelated comment was lost.'
        Assert-Test ($edited -contains '') 'Blank line was lost.'
        Write-Host 'PASS: section-aware in-memory editing'

        $proposal = [pscustomobject]@{ Changes = @(
            [pscustomobject]@{ Key='TamingSpeedMultiplier'; Value='10' },
            [pscustomobject]@{ Key='BabyMatureSpeedMultiplier'; Value='20' }
        ) }

        $result = Invoke-AsaAiApplyProposal -Proposal $proposal
        Assert-Test $result.Success ("Disposable apply failed: " + $result.Message)

        $gameUserLines = [IO.File]::ReadAllLines($ExpectedGameUserSettings)
        $gameIniLines = [IO.File]::ReadAllLines($ExpectedGameIni)
        Assert-Test ($gameUserLines -contains 'TamingSpeedMultiplier=10') 'GameUserSettings.ini target value was not applied.'
        Assert-Test ($gameUserLines -contains 'HarvestAmountMultiplier=5') 'Unrelated GameUserSettings.ini setting changed.'
        Assert-Test ($gameUserLines -contains 'TamingSpeedMultiplier=999') 'Same key in another GameUserSettings.ini section changed.'
        Assert-Test ($gameUserLines -contains 'KeepMe=Yes') 'Unrelated GameUserSettings.ini content was lost.'
        Assert-Test ($gameIniLines -contains 'BabyMatureSpeedMultiplier=20') 'Game.ini target value was not applied.'
        Assert-Test ($gameIniLines -contains 'EggHatchSpeedMultiplier=3') 'Unrelated Game.ini setting changed.'
        Assert-Test ($gameIniLines -contains 'KeepGame=Yes') 'Unrelated Game.ini content was lost.'

        $backupPath = [IO.Path]::GetFullPath([string]$result.BackupPath)
        Assert-Test $backupPath.StartsWith([IO.Path]::GetFullPath($ExpectedRoot), [StringComparison]::OrdinalIgnoreCase) 'Backup was created outside the disposable test root.'
        $backupGameUserSettings = Join-Path $backupPath 'GameUserSettings.ini'
        $backupGameIni = Join-Path $backupPath 'Game.ini'
        Assert-Test ([IO.File]::Exists($backupGameUserSettings)) 'GameUserSettings.ini backup was not created.'
        Assert-Test ([IO.File]::Exists($backupGameIni)) 'Game.ini backup was not created.'
        Assert-Test ([IO.File]::ReadAllLines($backupGameUserSettings) -contains 'TamingSpeedMultiplier=2') 'GameUserSettings.ini backup does not contain the original value.'
        Assert-Test ([IO.File]::ReadAllLines($backupGameIni) -contains 'BabyMatureSpeedMultiplier=1') 'Game.ini backup does not contain the original value.'
        Write-Host 'PASS: disposable backup + write + preservation'
    } $testEngine $testRoot $testGameUserSettings $testGameIni

    if ($liveGameUserHash) {
        Assert-Test ($liveGameUserHash -ceq (Get-FileHash -LiteralPath $liveGameUserSettings -Algorithm SHA256).Hash) 'LIVE GameUserSettings.ini changed during disposable test.'
    }
    if ($liveGameIniHash) {
        Assert-Test ($liveGameIniHash -ceq (Get-FileHash -LiteralPath $liveGameIni -Algorithm SHA256).Hash) 'LIVE Game.ini changed during disposable test.'
    }
    Write-Host 'PASS: live INI files unchanged'
    Write-Host 'ALL DISPOSABLE APPLY TESTS PASSED'
}
finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
