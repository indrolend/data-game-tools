[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Users\indro\Projects\data-game",

    [ValidateSet("status", "configure", "build", "test", "smoke", "evidence")]
    [string]$Action = "status",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release",

    [ValidateSet("enemy-obstruction")]
    [string]$Scenario = "enemy-obstruction"
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

function Get-DataExecutable {
    $candidates = @(
        (Join-Path $buildRoot "bin\$Configuration\DigitalBreakdown.exe"),
        (Join-Path $buildRoot "$Configuration\DigitalBreakdown.exe"),
        (Join-Path $buildRoot "bin\DigitalBreakdown.exe"),
        (Join-Path $buildRoot "DigitalBreakdown.exe"),
        (Join-Path $buildRoot "bin\DigitalBreakdown"),
        (Join-Path $buildRoot "DigitalBreakdown")
    )
    $executable = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $executable) { throw "Built Data executable was not found under $buildRoot." }
    $executable
}

function Invoke-Evidence {
    Invoke-Build
    $executable = Get-DataExecutable
    $runId = "{0}-{1}{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $revision, $(if ($dirty) { "-dirty" } else { "" })
    $bundle = Join-Path $artifactRoot "evidence\$Scenario\$runId"
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    $stdoutPath = Join-Path $bundle "stdout.log"
    $stderrPath = Join-Path $bundle "stderr.log"

    & $executable --evidence-scenario $Scenario --evidence-output $bundle --capture-width 1280 --capture-height 720 1> $stdoutPath 2> $stderrPath
    $nativeExit = $LASTEXITCODE
    if ($nativeExit -ne 0) { throw "Evidence scenario failed with exit code $nativeExit. Bundle retained at $bundle" }

    $manifestPath = Join-Path $bundle "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Evidence scenario did not produce manifest.json." }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $videoFrames = @(Get-ChildItem -LiteralPath (Join-Path $bundle $manifest.video_frames.directory) -Filter "*.ppm" | Sort-Object Name)
    if ($videoFrames.Count -eq 0) { throw "Evidence scenario produced no continuous video frames." }

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) { throw "FFmpeg is required to encode continuous evidence. Raw frames remain at $bundle" }
    $concatPath = Join-Path $bundle "video-frames.txt"
    $frameDuration = 1.0 / [double]$manifest.video_frames.frame_rate
    $concatLines = foreach ($frame in $videoFrames) {
        "file '$($frame.FullName.Replace("'", "''"))'"
        "duration $($frameDuration.ToString([Globalization.CultureInfo]::InvariantCulture))"
    }
    $concatLines += "file '$($videoFrames[-1].FullName.Replace("'", "''"))'"
    $concatLines | Set-Content -LiteralPath $concatPath -Encoding ascii
    $videoPath = Join-Path $bundle "evidence.mp4"
    & $ffmpeg.Source -y -loglevel error -f concat -safe 0 -i $concatPath -r ([string]$manifest.video_frames.frame_rate) -vf "format=yuv420p" -movflags "+faststart" $videoPath
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg failed. Raw frames remain at $bundle" }

    $rawFrameDirectory = [IO.Path]::GetFullPath((Join-Path $bundle $manifest.video_frames.directory))
    $bundleRoot = [IO.Path]::GetFullPath($bundle) + [IO.Path]::DirectorySeparatorChar
    if (-not $rawFrameDirectory.StartsWith($bundleRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Raw frame path escaped the evidence bundle; refusing cleanup."
    }
    Remove-Item -LiteralPath $rawFrameDirectory -Recurse -Force

    $result = [ordered]@{
        schema_version = 1
        classification = $manifest.classification
        scenario = $manifest.scenario
        game_commit = $commit
        game_dirty = $dirty
        configuration = $Configuration
        tick_rate = $manifest.tick_rate
        ticks = $manifest.ticks
        video_frame_rate = $manifest.video_frames.frame_rate
        video_frame_count = $videoFrames.Count
        manifest = "manifest.json"
        timeline = "timeline.ndjson"
        events = "events.ndjson"
        assertions = "assertions.json"
        video = "evidence.mp4"
        video_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $videoPath).Hash.ToLowerInvariant()
    }
    $resultPath = Join-Path $bundle "result.json"
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    Write-Host "EVIDENCE_OK bundle=$bundle result=$resultPath video=$videoPath" -ForegroundColor Green
    $result | ConvertTo-Json -Depth 5
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
        $executable = Get-DataExecutable
        Invoke-Checked $executable --smoke-test
    }
    "evidence" {
        Invoke-Evidence
    }
}
