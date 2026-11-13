[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Users\indro\Projects\data-game",

    [ValidateSet("status", "configure", "build", "test", "smoke", "evidence", "godot-build", "godot-test")]
    [string]$Action = "status",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release",

    [ValidateSet("enemy-obstruction", "lighting-comparison", "soul-lifecycle", "shadow-stability")]
    [string]$Scenario = "enemy-obstruction",

    [string]$ExecutablePath,

    [Alias("LightingReplayState")]
    [string]$LightingControlState,

    [string[]]$LightingCommand,

    [string]$GodotExe = "godot_console.exe",

    [string]$GodotCppDirectory,

    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$resolvedGameRoot = (Resolve-Path -LiteralPath $GameRoot).Path
if (-not $GodotCppDirectory) {
    $GodotCppDirectory = Join-Path (Split-Path $resolvedGameRoot -Parent) "godot-cpp"
}
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
$sourcePathBytes = [Text.Encoding]::UTF8.GetBytes($resolvedGameRoot.ToLowerInvariant())
$sourcePathHash = [Security.Cryptography.SHA256]::HashData($sourcePathBytes)
$sourceKey = -join ($sourcePathHash[0..3] | ForEach-Object { $_.ToString("x2") })
$buildRoot = Join-Path $artifactRoot "build\$revision-$sourceKey-$Configuration"
$godotBuildRoot = Join-Path $artifactRoot "build\godot-$revision-$sourceKey-$Configuration"

Write-Host "Data source: $resolvedGameRoot"
Write-Host "Revision:    $commit"
Write-Host "Dirty:       $dirty"
Write-Host "Source key:  $sourceKey"
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

function Invoke-GodotBuild {
    if (-not (Test-Path -LiteralPath $GodotCppDirectory -PathType Container)) {
        throw "GodotCppDirectory does not exist: $GodotCppDirectory"
    }
    New-Item -ItemType Directory -Force -Path $godotBuildRoot | Out-Null
    Invoke-Checked cmake -S $resolvedGameRoot -B $godotBuildRoot `
        "-DDB_BUILD_GODOT_PRESENTATION=ON" `
        "-DGODOT_CPP_DIR=$GodotCppDirectory" `
        "-DGODOTCPP_DEFAULT_API_VERSION=4.7"
    Invoke-Checked cmake --build $godotBuildRoot --config $Configuration `
        --target DigitalBreakdownGodot --parallel
}

function Invoke-GodotTests {
    Invoke-GodotBuild
    $godotProject = Join-Path $resolvedGameRoot "godot"
    Invoke-Checked $GodotExe --headless --editor --path $godotProject --quit
    $contractScripts = @(
        "parent_smoke", "phone_presentation", "music_presentation", "menu_navigation",
        "restart_menu", "room_presentation", "field_island_traversal", "gameplay_loop",
        "all_room_gameplay_loops", "agent_playtest_hardening", "projectile_observation",
        "damage_probe", "diagnostic_utilities", "human_model_presentation",
        "hud_presentation", "lighting_presentation", "upgrade_presentation", "room_transition"
    )
    foreach ($contract in $contractScripts) {
        $output = @(& $GodotExe --headless --path $godotProject --script "res://tests/$contract.gd" 2>&1)
        $exitCode = $LASTEXITCODE
        $output | Write-Host
        if ($exitCode -ne 0) { throw "Godot contract '$contract' failed with exit code $exitCode." }
        if ($output | Select-String -Pattern "SCRIPT ERROR|ERROR:|FAIL:" -Quiet) {
            throw "Godot contract '$contract' emitted an error despite a zero exit code."
        }
    }
    Write-Host "GODOT_TESTS_OK contracts=$($contractScripts.Count)" -ForegroundColor Green
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

function Get-ExecutableBuildIdentity {
    param([string]$ExePath)
    
    # Extract version info from DigitalBreakdown.exe
    # This is a simple hash-based approach; the game can embed its build commit in BuildIdentity.cpp
    $fileInfo = Get-Item -LiteralPath $ExePath
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExePath).Hash.ToLowerInvariant()
    return @{
        path = $ExePath
        size = $fileInfo.Length
        modified = $fileInfo.LastWriteTimeUtc
        sha256 = $hash
    }
}

function Invoke-EvidenceWithExecutable {
    param(
        [string]$ExecutablePath,
        [string]$ExpectedRevision
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw "Specified executable does not exist: $ExecutablePath"
    }

    # Validate that the executable is from the expected source revision
    # For now, we trust the build root path contains the correct revision.
    # A more robust approach would embed the commit SHA in the binary itself.
    if (-not $ExecutablePath.Contains($ExpectedRevision)) {
        Write-Host "WARNING: Executable path does not contain expected revision $ExpectedRevision" -ForegroundColor Yellow
        Write-Host "Executable: $ExecutablePath" -ForegroundColor Yellow
        Write-Host "Proceeding anyway, but results may be unreliable." -ForegroundColor Yellow
    }

    $buildIdentity = Get-ExecutableBuildIdentity -ExePath $ExecutablePath
    
    $runId = "{0}-{1}{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $revision, $(if ($dirty) { "-dirty" } else { "" })
    $bundle = Join-Path $artifactRoot "evidence\$Scenario\$runId"
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    $stdoutPath = Join-Path $bundle "stdout.log"
    $stderrPath = Join-Path $bundle "stderr.log"

    $evidenceArguments = @("--evidence-scenario", $Scenario, "--evidence-output", $bundle, "--capture-width", "1280", "--capture-height", "720")
    if ($LightingControlState) {
        $resolvedLightingState = (Resolve-Path -LiteralPath $LightingControlState).Path
        $evidenceArguments += @("--lighting-control-state", $resolvedLightingState)
    }
    foreach ($command in $LightingCommand) {
        $evidenceArguments += @("--lighting-command", $command)
    }
    & $ExecutablePath @evidenceArguments 1> $stdoutPath 2> $stderrPath
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
        executable_sha256 = $buildIdentity.sha256
        executable_size = $buildIdentity.size
        executable_modified = $buildIdentity.modified
    }
    if ($manifest.PSObject.Properties.Name -contains "lighting_control") {
        $result["lighting_control"] = $manifest.lighting_control
    }
    $resultPath = Join-Path $bundle "result.json"
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    Write-Host "EVIDENCE_OK bundle=$bundle result=$resultPath video=$videoPath" -ForegroundColor Green
    $result | ConvertTo-Json -Depth 5
}

function Invoke-Evidence {
    Invoke-Build
    $executable = Get-DataExecutable
    Invoke-EvidenceWithExecutable -ExecutablePath $executable -ExpectedRevision $revision
}

function Invoke-ShadowStabilityEvidence {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    if(-not(Test-Path -LiteralPath $ExePath -PathType Leaf)){throw "Specified executable does not exist: $ExePath"}
    $runId="{0}-{1}{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss"),$revision,$(if($dirty){"-dirty"}else{""})
    $bundle=Join-Path $artifactRoot "evidence\shadow-stability\$runId";$frames=Join-Path $bundle 'frames';$contacts=Join-Path $bundle 'contacts';$logs=Join-Path $bundle 'logs';$rotations=Join-Path $bundle 'rotation'
    New-Item -ItemType Directory -Force -Path $frames,$contacts,$logs,$rotations|Out-Null
    $smoke=@(& $ExePath --room-inspector-smoke --capture-width 320 --capture-height 180 2>&1);$smokeExit=$LASTEXITCODE;$smoke|Set-Content -LiteralPath (Join-Path $logs 'room-inspector-smoke.log') -Encoding utf8NoBOM
    if($smokeExit-ne0){throw "Room inspector smoke failed with exit code $smokeExit. Bundle retained at $bundle"}
    $premises=@();foreach($line in $smoke){if([string]$line-match'^ROOM_REVIEW premise=(\S+) seed=(\d+) room=(\d+) rating=KEEP '){$premises+=[pscustomobject]@{name=$Matches[1].ToLowerInvariant().Replace('_','-');seed=[int]$Matches[2];room=[int]$Matches[3]}}}
    if($premises.Count-ne8){throw "Expected 8 KEEP premises, observed $($premises.Count). Bundle retained at $bundle"}
    $ffmpeg=Get-Command ffmpeg -ErrorAction SilentlyContinue;if(-not$ffmpeg){throw 'FFmpeg is required for shadow-stability contact sheets.'}
    $modes=@('off','cheap','normal','pretty');$records=[Collections.Generic.List[object]]::new();$failures=[Collections.Generic.List[string]]::new()
    foreach($premise in $premises){
        $inputs=@()
        foreach($mode in $modes){
            $frame=Join-Path $frames "$($premise.name)-$mode.ppm";$log=Join-Path $logs "$($premise.name)-$mode.log"
            $args=@('--capture-frame',$frame,'--capture-room-seed',[string]$premise.seed,'--capture-room-index',[string]$premise.room,'--capture-graphics-preset','2','--capture-shadows','1','--capture-width','640','--capture-height','360','--capture-hide-hud','--shadow-command',"shadow mode $mode")
            $output=@(& $ExePath @args 2>&1);$exit=$LASTEXITCODE;$output|Set-Content -LiteralPath $log -Encoding utf8NoBOM
            $observation=[string]($output|Where-Object{[string]$_ -like 'SHADOW_OBSERVATION *'}|Select-Object -Last 1);$requestedExpected=if($mode-eq'normal'){'mapped-normal'}elseif($mode-eq'pretty'){'mapped-pretty'}else{$mode};$requested='';$effective='';$cheapGround=-1;$mappedReady=-1;$directional=-1
            if($observation-match'requested=(\S+)'){$requested=$Matches[1]};if($observation-match'effective=(\S+)'){$effective=$Matches[1]};if($observation-match'cheap_ground=(\d+)'){$cheapGround=[int]$Matches[1]};if($observation-match'mapped_ready=(\d+)'){$mappedReady=[int]$Matches[1]};if($observation-match'directional=(\d+)'){$directional=[int]$Matches[1]}
            $mapped=$mode-in@('normal','pretty');$effectiveExpected=if($mapped-and$directional-eq0){'off'}else{$requestedExpected};$readyExpected=if($mapped-and$directional-eq1){1}else{0}
            $passed=$exit-eq0-and(Test-Path -LiteralPath $frame)-and$requested-eq$requestedExpected-and$effective-eq$effectiveExpected-and$cheapGround-eq$(if($mode-eq'cheap'){1}else{0})-and$mappedReady-eq$readyExpected
            if(-not$passed){$failures.Add("$($premise.name):$mode exit=$exit requested=$requested effective=$effective directional=$directional cheap_ground=$cheapGround mapped_ready=$mappedReady")}
            $records.Add([ordered]@{premise=$premise.name;seed=$premise.seed;room=$premise.room;mode=$mode;requested=$requested;effective_expected=$effectiveExpected;effective=$effective;directional=$directional;cheap_ground=$cheapGround;mapped_ready=$mappedReady;availability=$(if($mapped-and$directional-eq0){'non-directional-rig'}else{'available'});passed=$passed;frame="frames/$($premise.name)-$mode.ppm";frame_sha256=$(if(Test-Path $frame){(Get-FileHash -LiteralPath $frame -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});log="logs/$($premise.name)-$mode.log"})
            $inputs+=@('-i',$frame)
        }
        $contact=Join-Path $contacts "$($premise.name).png";& $ffmpeg.Source -hide_banner -loglevel error -y @inputs -filter_complex '[0:v][1:v][2:v][3:v]hstack=inputs=4' $contact
        if($LASTEXITCODE-ne0){$failures.Add("$($premise.name):contact-sheet")}
    }
    $rotationRecords=[Collections.Generic.List[object]]::new();$rotationDigests=[Collections.Generic.HashSet[string]]::new();$rotationFrameCount=0;$rotationPremise=$premises|Where-Object name -eq 'field-open'|Select-Object -First 1
    foreach($mode in $modes){
        $rotationBundle=Join-Path $rotations $mode;$rotationLog=Join-Path $logs "rotation-$mode.log"
        $rotationArgs=@('--evidence-scenario','shadow-rotation','--evidence-output',$rotationBundle,'--capture-room-seed',[string]$rotationPremise.seed,'--capture-room-index',[string]$rotationPremise.room,'--capture-width','640','--capture-height','360','--shadow-command',"shadow mode $mode")
        $rotationOutput=@(& $ExePath @rotationArgs 2>&1);$rotationExit=$LASTEXITCODE;$rotationOutput|Set-Content -LiteralPath $rotationLog -Encoding utf8NoBOM
        $rotationManifestPath=Join-Path $rotationBundle 'manifest.json';$rotationManifest=if(Test-Path -LiteralPath $rotationManifestPath){Get-Content -LiteralPath $rotationManifestPath -Raw|ConvertFrom-Json}else{$null}
        $observation=[string]($rotationOutput|Where-Object{[string]$_ -like 'CAPABILITY_OBSERVATION *'}|Select-Object -First 1);$requested='';$effective='';$observed=-1
        if($observation-match'requested=(\S+)'){$requested=$Matches[1]};if($observation-match'effective=(\S+)'){$effective=$Matches[1]};if($observation-match'observed=(\d+)'){$observed=[int]$Matches[1]}
        if($rotationManifest){[void]$rotationDigests.Add([string]$rotationManifest.authoritative_digest)}
        if($rotationManifest){$rotationFrameCount+=[int]$rotationManifest.frames}
        $rotationPassed=$rotationExit-eq0-and$rotationManifest-and$rotationManifest.classification-eq'pass'-and$rotationManifest.projection_stable
        if(-not$rotationPassed){$failures.Add("rotation:$mode exit=$rotationExit requested=$requested effective=$effective")}
        $video=Join-Path $rotations "$mode.mp4";if($rotationManifest){$pattern=Join-Path $rotationBundle 'frames\video\frame-%04d.ppm';& $ffmpeg.Source -hide_banner -loglevel error -y -framerate 10 -i $pattern -c:v libx264 -pix_fmt yuv420p -movflags +faststart $video;if($LASTEXITCODE-ne0){$failures.Add("rotation:$mode:video")}}
        $rotationRecords.Add([ordered]@{mode=$mode;requested=$requested;effective=$effective;observed=$observed;passed=$rotationPassed;frames=$(if($rotationManifest){$rotationManifest.frames}else{0});projection_stable=$(if($rotationManifest){$rotationManifest.projection_stable}else{$false});authoritative_state_unchanged=$(if($rotationManifest){[bool]$rotationManifest.capability.authoritative_state_unchanged}else{$false});authoritative_digest=$(if($rotationManifest){$rotationManifest.authoritative_digest}else{$null});render_average_ms=$(if($rotationManifest){$rotationManifest.render_average_ms}else{$null});render_maximum_ms=$(if($rotationManifest){$rotationManifest.render_maximum_ms}else{$null});manifest="rotation/$mode/manifest.json";timeline="rotation/$mode/timeline.ndjson";video="rotation/$mode.mp4";log="logs/rotation-$mode.log"})
    }
    if($rotationDigests.Count-ne1){$failures.Add("rotation:authoritative-digest-count=$($rotationDigests.Count)")}
    $identity=Get-ExecutableBuildIdentity $ExePath;$passed=$failures.Count-eq0
    $manifest=[ordered]@{schema_version=2;scenario='shadow-stability';classification=$(if($passed){'PASS'}else{'FAIL'});game_commit=$commit;game_dirty=$dirty;configuration=$Configuration;executable=$identity;premises=$premises;modes=$modes;captures=$records.ToArray();camera_rotation=$rotationRecords.ToArray();failures=$failures.ToArray()}
    $manifestPath=Join-Path $bundle 'manifest.json';$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
    $capabilityRecords=@($rotationRecords|ForEach-Object{[ordered]@{schema='capability.observation/v1';id='render.shadow.camera-stability';variant=$_.mode;requested=$_.requested;effective=$_.effective;observed=[bool]$_.observed;verdict=$(if($_.passed){'SUPPORTED'}else{'REJECTED'});authoritative_state_digest=$_.authoritative_digest;authoritative_state_unchanged=[bool]$_.authoritative_state_unchanged;properties=[ordered]@{projection_stable=[bool]$_.projection_stable;frames=[int]$_.frames};cost=[ordered]@{average=[double]$_.render_average_ms;maximum=[double]$_.render_maximum_ms;unit='ms';measurement_class='gpu-synchronized-render'};evidence=@($_.manifest,$_.timeline,$_.video,$_.log)}})
    $ledger=[ordered]@{schema='capability.ledger/v1';producer='data-game-tools';experiment='shadow-stability';classification=$(if($passed){'PASS'}else{'FAIL'});source=[ordered]@{game_commit=$commit;game_dirty=$dirty;configuration=$Configuration;executable_sha256=$identity.sha256};records=$capabilityRecords;limitations=@('cost includes GPU synchronization and is not a standalone benchmark','observed means the selected shadow path became effective; visual quality still requires inspection');evidence_manifest='sha256-manifest.json'}
    $ledgerPath=Join-Path $bundle 'capability-ledger.json';$ledger|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ledgerPath -Encoding utf8NoBOM
    $files=@(Get-ChildItem -LiteralPath $bundle -File -Recurse|Where-Object Name -ne 'sha256-manifest.json'|Sort-Object FullName);$hashes=@($files|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($bundle,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}});$hashes|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $bundle 'sha256-manifest.json') -Encoding utf8NoBOM
    $result=[ordered]@{schema_version=2;scenario='shadow-stability';passed=$passed;premises=$premises.Count;modes=$modes.Count;captures=$records.Count;rotation_frames=$rotationFrameCount;authoritative_digests=$rotationDigests.Count;capability_records=$capabilityRecords.Count;failures=$failures.Count;manifest='manifest.json';capability_ledger='capability-ledger.json';hash_manifest='sha256-manifest.json';representatives='contacts';executable_sha256=$identity.sha256};$resultPath=Join-Path $bundle 'result.json';$result|ConvertTo-Json|Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
    Write-Host "SHADOW_CAPTURE_MATRIX=$(if($passed){'PASS'}else{'FAIL'}) premises=$($premises.Count) modes=$($modes.Count) captures=$($records.Count)";Write-Host "SHADOW_PATH_ISOLATION=$(if($passed){'PASS'}else{'FAIL'}) failures=$($failures.Count)";Write-Host "CAMERA_SHADOW_STABILITY=$(if($passed){'PASS'}else{'FAIL'}) modes=$($modes.Count) frames=$rotationFrameCount authoritative_digests=$($rotationDigests.Count)";Write-Host "CAPABILITY_PROOF=$(if($passed){'PASS'}else{'FAIL'}) dimensions=requested,effective,observed,cost";Write-Host "EVIDENCE_OK bundle=$bundle result=$resultPath"
    if(-not$passed){throw "Shadow stability evidence failed. Bundle retained at $bundle"};$result|ConvertTo-Json
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
        if ($SkipBuild) {
            $executable = Get-DataExecutable
        } else {
            Invoke-Build
            $executable = Get-DataExecutable
        }
        Invoke-Checked $executable --smoke-test
    }
    "evidence" {
        if($Scenario-eq'shadow-stability' -and $ExecutablePath){Invoke-ShadowStabilityEvidence -ExePath (Resolve-Path -LiteralPath $ExecutablePath).Path
        } elseif ($SkipBuild) {
            $executable = Get-DataExecutable
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                throw "No existing executable found for skip-build. Run with -Action build first, or omit -SkipBuild."
            }
            Write-Host "Reusing existing executable: $executable" -ForegroundColor Cyan
            Invoke-EvidenceWithExecutable -ExecutablePath $executable -ExpectedRevision $revision
        } else {
            Invoke-Evidence
        }
    }
    "godot-build" { Invoke-GodotBuild }
    "godot-test" { Invoke-GodotTests }
}
