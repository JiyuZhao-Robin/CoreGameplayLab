param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$calibrationProject = Split-Path -Parent $PSScriptRoot
$calibrationEngine = 'D:\Godot\godot.exe'
if (-not (Test-Path -LiteralPath $calibrationEngine)) { throw "Godot missing: $calibrationEngine" }
& $calibrationEngine --headless --editor --import --path $calibrationProject -- --no-persistence | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Capture) {
    & $calibrationEngine --path $calibrationProject --script res://tests/art_calibration_test.gd -- --no-persistence | Out-Host
} else {
    & $calibrationEngine --path $calibrationProject res://src/ui/art_calibration/art_calibration.tscn -- --no-persistence | Out-Host
}
exit $LASTEXITCODE
