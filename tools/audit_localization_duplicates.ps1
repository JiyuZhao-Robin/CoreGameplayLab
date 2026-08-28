[CmdletBinding()]
param(
    [string]$ProjectPath = "D:\Projects\standalone\core_gameplay_lab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$catalogs = @(
    (Join-Path $ProjectPath "data\localization_en.json"),
    (Join-Path $ProjectPath "data\localization_zh_CN.json")
)

$findingCount = 0
foreach ($catalog in $catalogs) {
    if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
        throw "Missing localization catalog: $catalog"
    }

    # jq's streaming parser preserves every scalar path before normal object
    # materialization, so duplicate JSON keys cannot be silently overwritten.
    $paths = @(& jq --stream -c 'select(length == 2) | .[0]' $catalog)
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid localization JSON: $catalog"
    }
    $duplicates = @($paths | Group-Object | Where-Object Count -gt 1)
    foreach ($duplicate in $duplicates) {
        Write-Host "DUPLICATE_LOCALIZATION_KEY catalog=$catalog count=$($duplicate.Count) path=$($duplicate.Name)"
    }
    $findingCount += $duplicates.Count
}

if ($findingCount -gt 0) {
    throw "Localization duplicate-key audit failed with $findingCount duplicate or case-colliding paths."
}

Write-Host "PASS: localization catalogs contain no duplicate or case-colliding scalar paths"
