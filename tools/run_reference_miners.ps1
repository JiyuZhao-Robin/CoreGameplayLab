param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$referenceMinerProject = Split-Path -Parent $PSScriptRoot
$referenceMinerEngine = 'D:\Godot\godot.exe'
if (-not (Test-Path -LiteralPath $referenceMinerEngine)) { throw "Godot missing: $referenceMinerEngine" }
& $referenceMinerEngine --headless --editor --import --path $referenceMinerProject -- --no-persistence | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Capture) {
    & $referenceMinerEngine --path $referenceMinerProject --script res://tests/reference_mining_demo_test.gd -- --no-persistence | Out-Host
} else {
    & $referenceMinerEngine --path $referenceMinerProject res://src/ui/art_calibration/reference_mining_demo.tscn -- --no-persistence | Out-Host
}
exit $LASTEXITCODE
