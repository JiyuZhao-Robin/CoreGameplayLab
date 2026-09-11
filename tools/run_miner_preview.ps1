param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$minerProject = Split-Path -Parent $PSScriptRoot
$minerEngine = 'D:\Godot\godot.exe'
if (-not (Test-Path -LiteralPath $minerEngine)) { throw "Godot missing: $minerEngine" }
& $minerEngine --headless --editor --import --path $minerProject -- --no-persistence | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Capture) {
    & $minerEngine --path $minerProject --script res://tests/miner_preview_test.gd -- --no-persistence | Out-Host
} else {
    & $minerEngine --path $minerProject res://src/ui/art_calibration/miner_preview.tscn -- --no-persistence | Out-Host
}
exit $LASTEXITCODE
