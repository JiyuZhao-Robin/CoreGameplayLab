[CmdletBinding()]
param(
    [ValidateRange(60, 3600)]
    [int]$DefaultTimeoutSeconds = 360,

    [switch]$SkipGolden,

    [string]$RunId = (Get-Date -Format "yyyyMMdd-HHmmss")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GodotPath = "D:\Godot\godot.exe"
$ProjectPath = "D:\Projects\standalone\core_gameplay_lab"
$LogRoot = Join-Path $ProjectPath ".audit-logs\full-$RunId"
$AuditStartedUtc = [DateTime]::UtcNow
$AuditStartedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$EvidencePath = Join-Path $ProjectPath "artifacts\test-results\full-gameplay-ui.json"
$ActionCoveragePath = Join-Path $ProjectPath "artifacts\test-results\ui-action-coverage.json"
$StateCoveragePath = Join-Path $ProjectPath "artifacts\test-results\ui-state-coverage.json"
$InputAccessibilityPath = Join-Path $ProjectPath "artifacts\test-results\ui-input-accessibility.json"
$PersistenceEvidencePath = Join-Path $ProjectPath "artifacts\test-results\ui-persistence-audit.json"
$ScenarioRoot = Join-Path $ProjectPath "artifacts\ui-scenarios"
$CertificationMilestones = @(
    "01_new_game", "02_first_industry", "03_first_steel", "04_logistics_bottleneck", "05_research",
    "06_remote_base", "07_advanced_industry", "08_megastructure_early", "09_megastructure_mid", "10_megastructure_complete"
)
$CertificationLocales = @("en", "zh_CN")
[System.IO.Directory]::CreateDirectory($LogRoot) | Out-Null

if (-not $SkipGolden) {
    $resolvedProject = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $resolvedScenarioRoot = [System.IO.Path]::GetFullPath($ScenarioRoot)
    if (-not $resolvedScenarioRoot.StartsWith($resolvedProject + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Scenario evidence path escapes the project: $resolvedScenarioRoot"
    }
    # Scenario consumers must never inherit ignored checkpoints from an older
    # content or Domain revision. The Golden Path below regenerates this exact
    # evidence directory before any Action/State/endgame consumer runs.
    if (Test-Path -LiteralPath $resolvedScenarioRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedScenarioRoot -Recurse -Force
    }
    [System.IO.Directory]::CreateDirectory($resolvedScenarioRoot) | Out-Null
}

if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot executable not found: $GodotPath"
}

# Exact-target cleanup prevents a failed or interrupted run from inheriting a
# prior run's certification JSON or screenshots.
if (Test-Path -LiteralPath $EvidencePath -PathType Leaf) {
    Remove-Item -LiteralPath $EvidencePath -Force
}
foreach ($staleArtifact in @($ActionCoveragePath, $StateCoveragePath, $InputAccessibilityPath, $PersistenceEvidencePath)) {
    if (Test-Path -LiteralPath $staleArtifact -PathType Leaf) {
        Remove-Item -LiteralPath $staleArtifact -Force
    }
}
foreach ($locale in $CertificationLocales) {
    foreach ($milestone in $CertificationMilestones) {
        $staleScreenshot = Join-Path $ProjectPath "artifacts\ui\playthrough\$locale\$milestone.png"
        if (Test-Path -LiteralPath $staleScreenshot -PathType Leaf) {
            Remove-Item -LiteralPath $staleScreenshot -Force
        }
    }
}

& (Join-Path $ProjectPath "tools\audit_localization_duplicates.ps1") -ProjectPath $ProjectPath

$tests = [System.Collections.Generic.List[object]]::new()
function Add-AuditTest([string]$Name, [string]$Target, [bool]$Script, [string[]]$UserArgs, [int]$TimeoutSeconds = 0) {
    $tests.Add([pscustomobject]@{
        Name = $Name
        Target = $Target
        Script = $Script
        UserArgs = $UserArgs
        TimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { $DefaultTimeoutSeconds }
    })
}

Add-AuditTest "content-planner" "res://tests/content_planner_contract_test.gd" $true @("--no-persistence")
Add-AuditTest "core-integrity" "res://tests/core_integrity_test.gd" $true @("--no-persistence")
Add-AuditTest "asset-conservation" "res://tests/asset_conservation_test.gd" $true @("--no-persistence")
Add-AuditTest "headless-domain" "res://tests/headless_test.gd" $true @("--no-persistence")
Add-AuditTest "online-frame-budget" "res://tests/online_frame_budget_test.tscn" $false @("--no-persistence")
Add-AuditTest "location-inventory" "res://tests/location_inventory_test.gd" $true @("--no-persistence")
Add-AuditTest "playflow" "res://tests/playflow_test.tscn" $false @("--no-persistence", "--locale=zh_CN")
Add-AuditTest "location-ui" "res://tests/location_ui_smoke_test.tscn" $false @("--no-persistence", "--locale=zh_CN")
Add-AuditTest "ui-playflow" "res://tests/ui_playflow_test.tscn" $false @("--no-persistence", "--locale=zh_CN")
Add-AuditTest "localization-catalog" "res://tests/localization_catalog_test.tscn" $false @("--no-persistence", "--locale=zh_CN")
Add-AuditTest "journey-registry" "res://tests/gameplay_journey_registry_test.tscn" $false @("--no-persistence")
if (-not $SkipGolden) {
    Add-AuditTest "golden-path" "res://tests/golden_path_test.tscn" $false @("--no-persistence", "--emit-scenarios") 1800
    Add-AuditTest "scenario-builder" "res://tests/gameplay_scenario_builder_test.tscn" $false @("--no-persistence", "--require-generated-scenarios")
}
Add-AuditTest "player-action-registry" "res://tests/player_action_registry_test.tscn" $false @("--no-persistence")
Add-AuditTest "ui-action-coverage" "res://tests/ui_action_coverage_test.tscn" $false @("--no-persistence", "--locale=en") 900
Add-AuditTest "ui-state-registry" "res://tests/ui_state_registry_test.tscn" $false @("--no-persistence")
Add-AuditTest "ui-state-coverage" "res://tests/ui_state_coverage_test.tscn" $false @("--no-persistence", "--locale=en") 600
Add-AuditTest "ui-domain-integrity" "res://tests/ui_domain_integrity_test.tscn" $false @("--no-persistence")
Add-AuditTest "ui-input-accessibility" "res://tests/ui_input_accessibility_test.tscn" $false @("--no-persistence", "--locale=en") 600
Add-AuditTest "ui-localization-audit" "res://tests/ui_localization_audit_test.tscn" $false @("--no-persistence")
Add-AuditTest "ui-zh" "res://tests/ui_chinese_localization_smoke_test.tscn" $false @("--no-persistence", "--locale=zh_CN")
Add-AuditTest "ui-en" "res://tests/ui_english_localization_smoke_test.tscn" $false @("--no-persistence", "--locale=en")
Add-AuditTest "ui-endgame-scenario" "res://tests/ui_endgame_scenario_test.tscn" $false @("--no-persistence", "--locale=en", "--scenario=megastructure_phase_7") 1800
Add-AuditTest "full-gameplay-ui" "res://tests/full_gameplay_ui_test.tscn" $false @("--no-persistence", "--locale=en", "--evidence-run-id=$RunId") 3600
Add-AuditTest "economy-audit" "res://tools/economy_audit.gd" $true @("--no-persistence")
Add-AuditTest "ui-performance-contract" "res://tests/ui_performance_contract_test.gd" $true @("--no-persistence")

$results = [System.Collections.Generic.List[object]]::new()

# SAVE_GAME four-case coverage deliberately consumes cross-process evidence.
# Produce that isolated evidence before the action suite so a clean checkout does
# not depend on stale ignored artifacts from an earlier run.
Write-Host "AUDIT_START name=ui-persistence"
$persistenceRunner = Join-Path $ProjectPath "tools\run_ui_persistence_audit.ps1"
$persistencePassed = $true
try {
    & $persistenceRunner -Godot $GodotPath -Project $ProjectPath
}
catch {
    $persistencePassed = $false
    Write-Host "AUDIT_DIAGNOSTIC name=ui-persistence error=$($_.Exception.Message)"
}
$persistenceExitCode = if ($persistencePassed) { 0 } else { 1 }
$results.Add([pscustomobject]@{
    Name = "ui-persistence"
    Passed = $persistencePassed
    ExitCode = $persistenceExitCode
    TimedOut = $false
    LogPath = Join-Path $ProjectPath ".audit-logs\ui-persistence-reader.log"
})
Write-Host "AUDIT_RESULT name=ui-persistence pass=$persistencePassed exit=$persistenceExitCode timeout=False"

foreach ($test in $tests) {
    $logPath = Join-Path $LogRoot "$($test.Name).log"
    $targetArgument = if ($test.Script) { "--script $($test.Target)" } else { $test.Target }
    $userArgumentText = if (@($test.UserArgs).Count -gt 0) { " -- " + (@($test.UserArgs) -join " ") } else { "" }
    # The Fresh Save Journey captures real rendered viewports. Godot's dummy
    # headless renderer has no texture backing, so this one test uses the normal
    # windowed renderer while all player interaction remains automated.
    $displayArguments = if ($test.Name -eq "full-gameplay-ui") {
        "--windowed --single-window --resolution 1920x1080 --position 0,0"
    } else {
        "--headless"
    }
    $arguments = "$displayArguments --path `"$ProjectPath`" --log-file `"$logPath`" $targetArgument$userArgumentText"

    Write-Host "AUDIT_START name=$($test.Name)"
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $GodotPath
    $process.StartInfo.Arguments = $arguments
    $process.StartInfo.WorkingDirectory = $ProjectPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    if (-not $process.Start()) {
        throw "Could not start Godot for $($test.Name)"
    }
    $completed = $process.WaitForExit([int]$test.TimeoutSeconds * 1000)
    if (-not $completed) {
        # The process handle was created by this runner for this exact test.
        $process.Kill()
        $process.WaitForExit()
    }
    $exitCode = if ($completed) { $process.ExitCode } else { -1000 }
    $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $logPath } else { "" }
    $scriptFailure = $logText -match "SCRIPT ERROR|Parse Error|FAIL:"
    if ($test.Name -eq "full-gameplay-ui" -and $logText -notmatch "FULL_GAMEPLAY_UI_TERMINAL=PASS") {
        $scriptFailure = $true
    }
    $passed = $completed -and $exitCode -eq 0 -and -not $scriptFailure
    $results.Add([pscustomobject]@{
        Name = $test.Name
        Passed = $passed
        ExitCode = $exitCode
        TimedOut = -not $completed
        LogPath = $logPath
    })
    Write-Host "AUDIT_RESULT name=$($test.Name) pass=$passed exit=$exitCode timeout=$(-not $completed) log=$logPath"
}

& (Join-Path $ProjectPath "tools\generate_ui_coverage.ps1") -ProjectPath $ProjectPath

# A zero exit code is not sufficient for the certification journey. Require the
# structured Fresh Save claim, exact runtime Action/State/Input/Persistence
# evidence created by this run, the exact ten-Journey registry set, and every
# bilingual 1920x1080 milestone screenshot before the runner can report PASS.
Write-Host "AUDIT_START name=certification-artifacts"
$certificationPassed = $true
$certificationError = ""
function Read-FreshCertificationJson([string]$Label, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label evidence is missing: $Path"
    }
    $artifactFile = Get-Item -LiteralPath $Path
    if ($artifactFile.LastWriteTimeUtc -lt $AuditStartedUtc) {
        throw "$Label evidence predates this audit run: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "$Label evidence is not valid JSON: $Path ($($_.Exception.Message))"
    }
}

function Test-JsonNullOrInconclusive([object]$Value) {
    if ($null -eq $Value) {
        return $true
    }
    if ($Value -is [string]) {
        return $Value -match "(?i)\binconclusive\b"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entryValue in $Value.Values) {
            if (Test-JsonNullOrInconclusive $entryValue) {
                return $true
            }
        }
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entryValue in $Value) {
            if (Test-JsonNullOrInconclusive $entryValue) {
                return $true
            }
        }
        return $false
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-JsonNullOrInconclusive $property.Value) {
                return $true
            }
        }
    }
    return $false
}

try {
    $registryPath = Join-Path $ProjectPath "data\gameplay_journey_registry.json"
    $evidence = Read-FreshCertificationJson "Fresh Save UI" $EvidencePath
    $actionCoverage = Read-FreshCertificationJson "UI Action coverage" $ActionCoveragePath
    $stateCoverage = Read-FreshCertificationJson "UI State coverage" $StateCoveragePath
    $inputAccessibility = Read-FreshCertificationJson "UI Input/accessibility" $InputAccessibilityPath
    $persistenceEvidence = Read-FreshCertificationJson "UI Persistence" $PersistenceEvidencePath

    # ui-action-coverage.json encodes its FULL claim through the exact aggregate
    # and per-row four-case fields rather than a separate coverageClaim property.
    $invalidActionRows = @($actionCoverage.actions | Where-Object {
        $_.fourCaseVerified -ne $true -or
        $_.success.verified -ne $true -or
        $_.failure.verified -ne $true -or
        $_.consequence.verified -ne $true -or
        $_.persistence.verified -ne $true
    })
    if ([int]$actionCoverage.coverageDenominator -ne 57 -or
        [int]$actionCoverage.fourCaseVerifiedCount -ne 57 -or
        [string]$actionCoverage.fourCaseCoverage -ne "57/57" -or
        @($actionCoverage.fourCaseVerifiedActions).Count -ne 57 -or
        @($actionCoverage.actions).Count -ne 57 -or
        $invalidActionRows.Count -ne 0) {
        throw "UI Action evidence does not carry the exact FULL 57/57 four-case runtime claim"
    }

    $invalidStateRows = @($stateCoverage.results | Where-Object {
        [string]$_.status -ne "VERIFIED" -or
        $_.domainStateFormed -ne $true -or
        $_.uiStateVisible -ne $true -or
        $_.explanationVisible -ne $true -or
        $_.navigationControlVisible -ne $true
    })
    if ([string]$stateCoverage.coverageClaim -ne "FULL_CORE_STATE_RUNTIME_UI_EVIDENCE" -or
        [int]$stateCoverage.numerator -ne 43 -or
        [int]$stateCoverage.denominator -ne 43 -or
        [double]$stateCoverage.coverageRatio -ne 1.0 -or
        @($stateCoverage.results).Count -ne 43 -or
        $invalidStateRows.Count -ne 0) {
        throw "UI State evidence does not carry the exact FULL 43/43 runtime claim"
    }

    $invalidInputRows = @($inputAccessibility.observations | Where-Object { $_.passed -ne $true })
    if ($inputAccessibility.passed -ne $true -or
        @($inputAccessibility.failures).Count -ne 0 -or
        @($inputAccessibility.observations).Count -eq 0 -or
        $invalidInputRows.Count -ne 0 -or
        (Test-JsonNullOrInconclusive $inputAccessibility)) {
        throw "UI Input/accessibility evidence is not an explicit PASS with zero null/inconclusive observations"
    }

    $invalidPersistenceRows = @($persistenceEvidence.observations | Where-Object { $_.passed -ne $true })
    if ($persistenceEvidence.passed -ne $true -or
        @($persistenceEvidence.failures).Count -ne 0 -or
        @($persistenceEvidence.observations).Count -eq 0 -or
        $invalidPersistenceRows.Count -ne 0) {
        throw "UI Persistence evidence is not an explicit complete PASS"
    }

    $registry = Get-Content -Raw -Encoding UTF8 -LiteralPath $registryPath | ConvertFrom-Json
    if ($evidence.runId -ne $RunId -or
        [long]$evidence.generatedAtUnixMs -lt $AuditStartedUnixMs -or
        $evidence.claim -ne "FULL_FRESH_SAVE_UI_ONLY_EVIDENCE" -or
        $evidence.freshSave -ne $true -or
        $evidence.uiOnly -ne $true -or
        $evidence.usesDirectGameplayCommands -ne $false -or
        $evidence.usesDirectStateWrites -ne $false -or
        $evidence.journeyComplete -ne $true -or
        $evidence.highestVerifiedMilestone -ne "MEGASTRUCTURE_COMPLETED" -or
        @($evidence.unverifiedMandatoryMilestones).Count -ne 0) {
        throw "Fresh Save UI evidence does not carry the complete no-cheat certification claim"
    }
    $expectedJourneyIds = @($registry.journeys | Where-Object { $_.core -eq $true } | ForEach-Object { [string]$_.journeyId } | Sort-Object)
    $completedJourneyIds = @($evidence.completedJourneyIds | ForEach-Object { [string]$_ } | Sort-Object)
    if ($expectedJourneyIds.Count -ne 10 -or (Compare-Object -ReferenceObject $expectedJourneyIds -DifferenceObject $completedJourneyIds).Count -ne 0) {
        throw "Fresh Save evidence does not exactly cover the ten core Journey IDs"
    }
    foreach ($locale in $CertificationLocales) {
        foreach ($milestone in $CertificationMilestones) {
            $screenshotPath = Join-Path $ProjectPath "artifacts\ui\playthrough\$locale\$milestone.png"
            if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) {
                throw "Required rendered playthrough screenshot is missing: $screenshotPath"
            }
            $screenshotFile = Get-Item -LiteralPath $screenshotPath
            if ($screenshotFile.LastWriteTimeUtc -lt $AuditStartedUtc) {
                throw "Required rendered playthrough screenshot predates this audit run: $screenshotPath"
            }
            $png = [System.IO.File]::ReadAllBytes($screenshotPath)
            $signature = [byte[]](137,80,78,71,13,10,26,10)
            if ($png.Length -lt 24 -or -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$png[0..7], $signature)) {
                throw "Required rendered playthrough screenshot is not a valid PNG: $screenshotPath"
            }
            $width = ([int]$png[16] -shl 24) -bor ([int]$png[17] -shl 16) -bor ([int]$png[18] -shl 8) -bor [int]$png[19]
            $height = ([int]$png[20] -shl 24) -bor ([int]$png[21] -shl 16) -bor ([int]$png[22] -shl 8) -bor [int]$png[23]
            if ($width -ne 1920 -or $height -ne 1080) {
                throw "Required rendered playthrough screenshot is not exactly 1920x1080 ($($width)x$($height)): $screenshotPath"
            }
        }
    }
}
catch {
    $certificationPassed = $false
    $certificationError = $_.Exception.Message
    Write-Host "AUDIT_DIAGNOSTIC name=certification-artifacts error=$certificationError"
}
$results.Add([pscustomobject]@{
    Name = "certification-artifacts"
    Passed = $certificationPassed
    ExitCode = if ($certificationPassed) { 0 } else { 1 }
    TimedOut = $false
    LogPath = $EvidencePath
})
Write-Host "AUDIT_RESULT name=certification-artifacts pass=$certificationPassed exit=$(if ($certificationPassed) { 0 } else { 1 }) timeout=False"

$failed = @($results | Where-Object { -not $_.Passed })
$summaryPath = Join-Path $LogRoot "summary.json"
$summary = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    passed = $failed.Count -eq 0
    tests = @($results)
}
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

if ($failed.Count -gt 0) {
    Write-Host "FULL_AUDIT_FAIL failed=$($failed.Count) summary=$summaryPath"
    exit 1
}
Write-Host "FULL_AUDIT_PASS tests=$($results.Count) summary=$summaryPath"
