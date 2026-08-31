[CmdletBinding()]
param(
    [string]$Godot = "D:\Godot\godot.exe",
    [string]$Project = "D:\Projects\standalone\core_gameplay_lab",
    [string]$RunId = (Get-Date -Format "yyyyMMdd-HHmmss"),
    [ValidateRange(60, 57600)]
    [int]$TimeoutSeconds = 3600,
    [switch]$CleanEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$log = Join-Path $Project ".audit-logs\full-gameplay-ui-$RunId.log"
$evidence = Join-Path $Project "artifacts\test-results\full-gameplay-ui.json"
$milestones = @(
    "01_new_game", "02_first_industry", "03_first_steel", "04_logistics_bottleneck", "05_research",
    "06_remote_base", "07_advanced_industry", "08_megastructure_early", "09_megastructure_mid", "10_megastructure_complete"
)

if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot executable not found: $Godot"
}
if (Get-Process godot -ErrorAction SilentlyContinue) {
    throw "Another Godot process is already running. Refusing to mix journey evidence."
}
if ($CleanEvidence) {
    if (Test-Path -LiteralPath $evidence -PathType Leaf) {
        Remove-Item -LiteralPath $evidence -Force
    }
    foreach ($locale in @("en", "zh_CN")) {
        foreach ($milestone in $milestones) {
            $screenshot = Join-Path $Project "artifacts\ui\playthrough\$locale\$milestone.png"
            if (Test-Path -LiteralPath $screenshot -PathType Leaf) {
                Remove-Item -LiteralPath $screenshot -Force
            }
        }
    }
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName = $Godot
$process.StartInfo.Arguments = "--windowed --single-window --resolution 1920x1080 --position 0,0 --path `"$Project`" --log-file `"$log`" res://tests/full_gameplay_ui_test.tscn -- --no-persistence --locale=en --evidence-run-id=$RunId"
$process.StartInfo.WorkingDirectory = $Project
$process.StartInfo.UseShellExecute = $false

if (-not $process.Start()) {
    throw "Could not start Godot"
}
Write-Host "FULL_GAMEPLAY_UI_PID=$($process.Id)"
Write-Host "FULL_GAMEPLAY_UI_RUN_ID=$RunId"
Write-Host "FULL_GAMEPLAY_UI_LOG=$log"

$completed = $process.WaitForExit($TimeoutSeconds * 1000)
if (-not $completed) {
    $process.Kill()
    $process.WaitForExit()
    throw "Full Gameplay UI journey timed out after $TimeoutSeconds seconds"
}
Write-Host "FULL_GAMEPLAY_UI_EXIT=$($process.ExitCode)"

$logText = if (Test-Path -LiteralPath $log -PathType Leaf) {
    Get-Content -Raw -Encoding UTF8 -LiteralPath $log
} else {
    ""
}
if ($process.ExitCode -ne 0) {
    throw "Godot exited with code $($process.ExitCode). See $log"
}
if ($logText -match "SCRIPT ERROR|Parse Error|FAIL:" -or $logText -notmatch "FULL_GAMEPLAY_UI_TERMINAL=PASS") {
    throw "Full Gameplay UI terminal contract failed. See $log"
}
if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) {
    throw "Fresh journey did not write evidence: $evidence"
}

$result = Get-Content -Raw -Encoding UTF8 -LiteralPath $evidence | ConvertFrom-Json
if ([string]$result.runId -ne $RunId) {
    throw "Evidence runId mismatch: expected $RunId, got $($result.runId)"
}
Write-Host "FULL_GAMEPLAY_UI_VERIFIED=PASS"
