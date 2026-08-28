[CmdletBinding()]
param(
    [ValidateSet("quick", "full")]
    [string]$Mode = "quick",

    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_.-]*$")]
    [string]$RunId = (Get-Date -Format "yyyyMMdd-HHmmss"),

    [string[]]$PagesOverride = @(),

    [string[]]$ResolutionsOverride = @(),

    [string]$ScenarioId = "",

    [ValidateRange(10, 180)]
    [int]$TimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GodotPath = "D:\Godot\godot.exe"
$ProjectPath = "D:\Projects\standalone\core_gameplay_lab"
$MatrixRoot = Join-Path $ProjectPath "artifacts\ui\matrix"
$RunRoot = Join-Path $MatrixRoot $RunId

$FullPages = @(
    "system_map",
    "location",
    "industry",
    "inventory",
    "logistics",
    "construction",
    "research",
    "ships",
    "survey",
    "megastructure",
    "diagnostics"
)
$QuickPages = @("system_map", "megastructure")
$FullResolutions = @("1920x1080", "2560x1440", "1366x768")
$QuickResolutions = @("1920x1080", "1366x768")
$Locales = @("en", "zh_CN")

if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot executable not found: $GodotPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath "project.godot") -PathType Leaf)) {
    throw "Godot project not found: $ProjectPath"
}

$Pages = @(if (@($PagesOverride).Count -gt 0) { $PagesOverride } elseif ($Mode -eq "full") { $FullPages } else { $QuickPages })
$Resolutions = @(if (@($ResolutionsOverride).Count -gt 0) { $ResolutionsOverride } elseif ($Mode -eq "full") { $FullResolutions } else { $QuickResolutions })
foreach ($Page in $Pages) {
    if ($Page -notin $FullPages) {
        throw "Unknown UI capture page: $Page"
    }
}
foreach ($Resolution in $Resolutions) {
    if ($Resolution -notmatch "^[0-9]{3,5}x[0-9]{3,5}$") {
        throw "Invalid UI capture resolution: $Resolution"
    }
}
if ($ScenarioId -ne "" -and $ScenarioId -notmatch "^[A-Za-z0-9][A-Za-z0-9_.-]*$") {
    throw "Invalid generated Scenario id: $ScenarioId"
}
$ExpectedCount = $Pages.Count * $Resolutions.Count * $Locales.Count
$CapturedCount = 0

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class UiMatrixNativeWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetClientRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);

}
"@

# PowerShell 5.1 is otherwise DPI-virtualized on this host. Native window sizes
# must use physical pixels so the requested client matrix can be measured exactly.
$perMonitorAwareV2 = [IntPtr](-4)
[UiMatrixNativeWindow]::SetProcessDpiAwarenessContext($perMonitorAwareV2) | Out-Null
[UiMatrixNativeWindow]::SetThreadDpiAwarenessContext($perMonitorAwareV2) | Out-Null

function Set-ExactClientSize {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [Parameter(Mandatory = $true)]
        [int]$Height
    )

    $handleDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $handle = [IntPtr]::Zero
    while ([DateTime]::UtcNow -lt $handleDeadline -and -not $Process.HasExited) {
        $Process.Refresh()
        $handle = $Process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) {
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if ($handle -eq [IntPtr]::Zero) {
        throw "Godot did not expose a window handle before capture."
    }

    [UiMatrixNativeWindow]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $clientRect = [UiMatrixNativeWindow+Rect]::new()
    $windowRect = [UiMatrixNativeWindow+Rect]::new()
    if (-not [UiMatrixNativeWindow]::GetClientRect($handle, [ref]$clientRect) -or
        -not [UiMatrixNativeWindow]::GetWindowRect($handle, [ref]$windowRect)) {
        throw "Unable to inspect the Godot window dimensions."
    }

    $clientWidth = $clientRect.Right - $clientRect.Left
    $clientHeight = $clientRect.Bottom - $clientRect.Top
    $windowWidth = $windowRect.Right - $windowRect.Left
    $windowHeight = $windowRect.Bottom - $windowRect.Top
    $nonClientWidth = $windowWidth - $clientWidth
    $nonClientHeight = $windowHeight - $clientHeight
    $windowDpi = [UiMatrixNativeWindow]::GetDpiForWindow($handle)
    $outerWidth = $Width + $nonClientWidth
    $outerHeight = $Height + $nonClientHeight
    $swpNoZOrder = 0x0004
    $swpNoActivate = 0x0010

    if (-not [UiMatrixNativeWindow]::SetWindowPos(
        $handle,
        [IntPtr]::Zero,
        0,
        0,
        $outerWidth,
        $outerHeight,
        $swpNoZOrder -bor $swpNoActivate
    )) {
        throw "Unable to resize the Godot window to a ${Width}x${Height} client area."
    }

    Write-Host "WINDOW_RESIZE dpi=$windowDpi before=${clientWidth}x${clientHeight} target=${Width}x${Height} outer=${outerWidth}x${outerHeight}"

    $sizeDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 10
        if ($Process.HasExited) {
            break
        }
        $clientRect = [UiMatrixNativeWindow+Rect]::new()
        if ([UiMatrixNativeWindow]::GetClientRect($handle, [ref]$clientRect)) {
            $clientWidth = $clientRect.Right - $clientRect.Left
            $clientHeight = $clientRect.Bottom - $clientRect.Top
            if ($clientWidth -eq $Width -and $clientHeight -eq $Height) {
                Write-Host "WINDOW_RESIZE_OK client=${clientWidth}x${clientHeight}"
                return $handle
            }
        }
    } while ([DateTime]::UtcNow -lt $sizeDeadline)

    throw "Godot client area did not reach ${Width}x${Height}; last observed ${clientWidth}x${clientHeight}."
}

function Save-ExactClientComposite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ViewportPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [Parameter(Mandatory = $true)]
        [int]$Height
    )

    $viewport = [System.Drawing.Bitmap]::FromFile($ViewportPath)
    $viewportWidth = $viewport.Width
    $viewportHeight = $viewport.Height
    if ($viewportWidth -gt $Width -or $viewportHeight -gt $Height) {
        $actualViewport = "${viewportWidth}x${viewportHeight}"
        $viewport.Dispose()
        throw "Godot viewport $actualViewport is larger than target client ${Width}x${Height}."
    }

    $sampledColors = [System.Collections.Generic.HashSet[int]]::new()
    $sampleStepX = [Math]::Max(1, [int]($viewportWidth / 32))
    $sampleStepY = [Math]::Max(1, [int]($viewportHeight / 18))
    for ($sampleY = 0; $sampleY -lt $viewportHeight; $sampleY += $sampleStepY) {
        for ($sampleX = 0; $sampleX -lt $viewportWidth; $sampleX += $sampleStepX) {
            $sampledColors.Add($viewport.GetPixel($sampleX, $sampleY).ToArgb()) | Out-Null
        }
    }
    if ($sampledColors.Count -lt 8) {
        $viewport.Dispose()
        throw "Godot viewport appears blank or unrendered (only $($sampledColors.Count) sampled colors): $ViewportPath"
    }

    $insetX = [int](($Width - $viewportWidth) / 2)
    $insetY = [int](($Height - $viewportHeight) / 2)
    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(255, 6, 8, 10))
        $graphics.DrawImageUnscaled($viewport, $insetX, $insetY)
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
        $viewport.Dispose()
    }
    Write-Host "CLIENT_COMPOSITE viewport=${viewportWidth}x${viewportHeight} target=${Width}x${Height} inset=${insetX},${insetY} sampled_colors=$($sampledColors.Count)"
}

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null

Write-Host "UI_MATRIX mode=$Mode run=$RunId expected=$ExpectedCount root=$RunRoot"

foreach ($Locale in $Locales) {
    foreach ($Resolution in $Resolutions) {
        $parts = $Resolution.Split("x")
        $expectedWidth = [int]$parts[0]
        $expectedHeight = [int]$parts[1]

        foreach ($Page in $Pages) {
            $outputDirectory = Join-Path (Join-Path $RunRoot $Locale) $Resolution
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
            $outputPath = Join-Path $outputDirectory "$Page.png"
            $viewportProbePath = Join-Path $outputDirectory ".$Page-viewport-probe.png"

            if (Test-Path -LiteralPath $outputPath) {
                throw "Refusing to overwrite an existing matrix capture: $outputPath. Choose a new -RunId."
            }

            $engineArguments = @(
                "--path", $ProjectPath,
                "--windowed",
                "--single-window",
                "--resolution", $Resolution,
                "--position", "0,0"
            )
            if ($ScenarioId -ne "") {
                $engineArguments += "res://tests/ui_scenario_capture.tscn"
            }
            $userArguments = @(
                "--",
                "--no-persistence",
                "--locale=$Locale",
                "--capture-view=$Page",
                "--capture-output=$viewportProbePath"
            )
            if ($ScenarioId -ne "") {
                $userArguments += "--ui-scenario=$ScenarioId"
            }
            $godotArguments = $engineArguments + $userArguments

            Write-Host "CAPTURE_START locale=$Locale resolution=$Resolution page=$Page scenario=$ScenarioId"
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $GodotPath
            $startInfo.Arguments = $godotArguments -join " "
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($startInfo)
            if ($null -eq $process) {
                throw "Godot process could not be started for $Locale/$Resolution/$Page"
            }
            $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
            $standardErrorTask = $process.StandardError.ReadToEndAsync()

            try {
                Set-ExactClientSize -Process $process -Width $expectedWidth -Height $expectedHeight | Out-Null

                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    throw "Godot capture timed out after $TimeoutSeconds seconds: $Locale/$Resolution/$Page"
                }
                if ($process.ExitCode -ne 0) {
                    throw "Godot capture failed with exit code $($process.ExitCode): $Locale/$Resolution/$Page"
                }
                $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
                $standardError = $standardErrorTask.GetAwaiter().GetResult()
                $godotOutput = ($standardOutput + [Environment]::NewLine + $standardError).Trim()
                if (-not [string]::IsNullOrWhiteSpace($godotOutput)) {
                    Write-Host $godotOutput
                }
                if ($godotOutput -match "SCRIPT ERROR:|Failed to load script|Failed to instantiate an autoload") {
                    throw "Godot reported a script/runtime error; capture is invalid: $Locale/$Resolution/$Page"
                }
                if (-not (Test-Path -LiteralPath $viewportProbePath -PathType Leaf)) {
                    throw "Godot exited without reaching its final rendered capture frame: $Locale/$Resolution/$Page"
                }
                Save-ExactClientComposite -ViewportPath $viewportProbePath -OutputPath $outputPath -Width $expectedWidth -Height $expectedHeight
                if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                    throw "Client screenshot was not created: $outputPath"
                }

                $image = [System.Drawing.Image]::FromFile($outputPath)
                try {
                    $actualWidth = $image.Width
                    $actualHeight = $image.Height
                }
                finally {
                    $image.Dispose()
                }
                if ($actualWidth -ne $expectedWidth -or $actualHeight -ne $expectedHeight) {
                    throw "Capture dimension mismatch for $outputPath. Expected $Resolution, got ${actualWidth}x${actualHeight}."
                }
            }
            finally {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit()
                }
                if (Test-Path -LiteralPath $viewportProbePath) {
                    [System.IO.File]::Delete($viewportProbePath)
                }
            }

            $CapturedCount += 1
            Write-Host "CAPTURE_OK locale=$Locale resolution=$Resolution page=$Page output=$outputPath"
        }
    }
}

if ($CapturedCount -ne $ExpectedCount) {
    throw "Incomplete matrix: expected $ExpectedCount captures, created $CapturedCount."
}

Write-Host "UI_MATRIX_PASS mode=$Mode run=$RunId captured=$CapturedCount root=$RunRoot"
