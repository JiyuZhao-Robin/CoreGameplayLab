param(
    [string]$Godot = "D:\Godot\godot.exe",
    [string]$Project = "D:\Projects\standalone\core_gameplay_lab"
)

$ErrorActionPreference = "Stop"
$isolatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("helios-ui-persistence-audit-" + [Guid]::NewGuid().ToString("N"))
$writerLog = Join-Path $Project ".audit-logs\ui-persistence-writer.log"
$readerLog = Join-Path $Project ".audit-logs\ui-persistence-reader.log"
$resultArtifact = Join-Path $Project "artifacts\test-results\ui-persistence-audit.json"
$isolationToken = Split-Path $isolatedRoot -Leaf
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA

function Invoke-PersistencePhase([string]$Phase, [string]$LogPath) {
    $arguments = "--headless --path `"$Project`" --log-file `"$LogPath`" --scene res://tests/ui_persistence_audit_test.tscn -- --ui-persistence-phase=$Phase --ui-persistence-isolation-token=$isolationToken --ui-persistence-root=`"$isolatedRoot`""
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $Godot
    $process.StartInfo.Arguments = $arguments
    $process.StartInfo.WorkingDirectory = $Project
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    if (-not $process.Start()) {
        throw "Could not start isolated UI persistence $Phase phase"
    }
    $completed = $process.WaitForExit(120000)
    if (-not $completed) {
        $process.Kill()
        $process.WaitForExit()
        throw "UI persistence $Phase phase timed out. See $LogPath"
    }
    $logText = if (Test-Path -LiteralPath $LogPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $LogPath } else { "" }
    if ($process.ExitCode -ne 0 -or $logText -match "SCRIPT ERROR|Parse Error|FAIL:") {
        throw "UI persistence $Phase phase failed with exit code $($process.ExitCode). See $LogPath"
    }
}

try {
    # A failed rerun must never leave a previous PASS artifact available to the
    # action-coverage importer.
    Remove-Item -LiteralPath $resultArtifact -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null
    $env:APPDATA = Join-Path $isolatedRoot "Roaming"
    $env:LOCALAPPDATA = Join-Path $isolatedRoot "Local"
    New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    Invoke-PersistencePhase -Phase "write" -LogPath $writerLog
    Start-Sleep -Seconds 2
    Invoke-PersistencePhase -Phase "read" -LogPath $readerLog
    Write-Output "UI_PERSISTENCE_AUDIT_PASS"
}
finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTarget = [System.IO.Path]::GetFullPath($isolatedRoot)
    if ($resolvedTarget.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTarget -Leaf).StartsWith("helios-ui-persistence-audit-")) {
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
}
