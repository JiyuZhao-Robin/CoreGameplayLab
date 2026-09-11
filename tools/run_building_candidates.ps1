param(
    [string]$GodotPath = '',
    [string]$Candidate = 'arc-furnace',
    [switch]$Capture
)
$ErrorActionPreference = 'Stop'
$candidateProject = Split-Path -Parent $PSScriptRoot
if (-not $GodotPath) {
    $candidateCommand = Get-Command godot, godot4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidateCommand) { $GodotPath = $candidateCommand.Source }
    elseif (Test-Path -LiteralPath 'D:\Godot\godot.exe') { $GodotPath = 'D:\Godot\godot.exe' }
    else { throw 'Pass -GodotPath with the location of your Godot 4.6 executable, or add Godot to PATH.' }
}
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) { throw "Godot missing: $GodotPath" }
& $GodotPath --headless --editor --import --path $candidateProject -- --no-persistence | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Capture) {
    & $GodotPath --path $candidateProject --script res://tests/building_candidates_test.gd -- --no-persistence | Out-Host
} else {
    & $GodotPath --path $candidateProject res://src/ui/art_calibration/building_candidates/building_candidates.tscn -- --no-persistence "--candidate=$Candidate" | Out-Host
}
exit $LASTEXITCODE
