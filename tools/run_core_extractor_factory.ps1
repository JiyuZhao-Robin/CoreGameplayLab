param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$godotPath = 'D:\Godot\godot.exe'
if (-not (Test-Path -LiteralPath $godotPath)) { throw "Godot not found: $godotPath" }
& $godotPath --headless --path $projectPath --editor --import --quit -- --no-persistence | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$sceneArgs = @('--path', $projectPath, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/factory_visual_capture.gd', '--', '--no-persistence', '--evidence-output=res://artifacts/ui/core-extractor-live')
if (-not $Capture) { $sceneArgs += '--stay-open' }
& $godotPath @sceneArgs | Out-Host
exit $LASTEXITCODE
