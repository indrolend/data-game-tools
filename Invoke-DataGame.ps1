[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Users\indro\Projects\data-game",

    [ValidateSet("status", "configure", "build", "test", "smoke")]
    [string]$Action = "status",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$resolvedGameRoot = (Resolve-Path -LiteralPath $GameRoot).Path
$cmakeFile = Join-Path $resolvedGameRoot "CMakeLists.txt"
if (-not (Test-Path -LiteralPath $cmakeFile -PathType Leaf)) {
    throw "GameRoot is not a Data source checkout: $resolvedGameRoot"
}

$commit = (& git -C $resolvedGameRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the Data source revision."
}

$status = (& git -C $resolvedGameRoot status --short | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the Data source status."
}

$dirty = -not [string]::IsNullOrWhiteSpace($status)
$revision = $commit.Substring(0, 12)
$artifactRoot = Join-Path $PSScriptRoot "artifacts"
$buildRoot = Join-Path $artifactRoot "build\$revision-$Configuration"

Write-Host "Data source: $resolvedGameRoot"
Write-Host "Revision:    $commit"
Write-Host "Dirty:       $dirty"
Write-Host "Artifacts:   $artifactRoot"

if ($Action -eq "status") {
    if ($dirty) {
        Write-Host $status
    }
    return
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Program,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Configure {
    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    Invoke-Checked cmake -S $resolvedGameRoot -B $buildRoot "-DCMAKE_BUILD_TYPE=$Configuration"
}

function Invoke-Build {
    Invoke-Configure
    Invoke-Checked cmake --build $buildRoot --config $Configuration
}

switch ($Action) {
    "configure" {
        Invoke-Configure
    }
    "build" {
        Invoke-Build
    }
    "test" {
        Invoke-Build
        Invoke-Checked ctest --test-dir $buildRoot -C $Configuration --output-on-failure
    }
    "smoke" {
        Invoke-Build
        $executableCandidates = @(
            (Join-Path $buildRoot "bin\$Configuration\DigitalBreakdown.exe"),
            (Join-Path $buildRoot "$Configuration\DigitalBreakdown.exe"),
            (Join-Path $buildRoot "bin\DigitalBreakdown.exe"),
            (Join-Path $buildRoot "DigitalBreakdown.exe"),
            (Join-Path $buildRoot "bin\DigitalBreakdown"),
            (Join-Path $buildRoot "DigitalBreakdown")
        )
        $executable = $executableCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $executable) {
            throw "Built Data executable was not found under $buildRoot."
        }
        Invoke-Checked $executable --smoke-test
    }
}
