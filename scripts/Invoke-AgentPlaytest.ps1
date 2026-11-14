[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [string]$OutputDirectory,
    [int]$RoomSeed = 7,
    [ValidateRange(1, [int]::MaxValue)][int]$RoomIndex = 12,
    [ValidateSet("observe", "combat-cycle", "room-clear")][string]$Goal = "combat-cycle",
    [ValidateRange(1, 10000)][int]$MaximumActions = 40,
    [ValidateRange(0.0, 100.0)][double]$MinimumBattery = 12.0,
    [ValidateRange(1, 300)][int]$ObservationTimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
function Get-ExecutableIdentity {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    [void]$info.ArgumentList.Add('--build-identity-json')
    $probe = [Diagnostics.Process]::new(); $probe.StartInfo = $info
    if (-not $probe.Start()) { throw "Failed to launch identity probe: $exe" }
    $stdout = $probe.StandardOutput.ReadToEndAsync(); $stderr = $probe.StandardError.ReadToEndAsync()
    if (-not $probe.WaitForExit($ObservationTimeoutSeconds * 1000)) { $probe.Kill($true); throw "Executable identity probe timed out after $ObservationTimeoutSeconds seconds." }
    $text = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
    if ($probe.ExitCode -ne 0) { throw "Executable identity probe failed with exit $($probe.ExitCode): $errorText" }
    try { $value = $text | ConvertFrom-Json } catch { throw "Executable returned malformed build identity JSON: $($_.Exception.Message)" }
    if (-not $value.commit -or $value.commit -notmatch '^[0-9a-fA-F]{40}$') { throw "Executable did not provide a 40-hex commit identity: $exe" }
    $value
}
$identity = Get-ExecutableIdentity
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) ("artifacts\agent-playtest\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output directory already exists: $OutputDirectory" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$frame = Join-Path $OutputDirectory "observation.ppm"
$transcriptPath = Join-Path $OutputDirectory "transcript.log"
$transcript = [IO.StreamWriter]::new($transcriptPath, $false, [Text.UTF8Encoding]::new($false))

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $exe
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.CreateNoWindow = $true
foreach ($argument in @(
    "--agent-playtest", "--agent-frame", $frame,
    "--capture-room-seed", [string]$RoomSeed,
    "--capture-room-index", [string]$RoomIndex,
    "--capture-graphics-preset", "2", "--capture-shadows", "1",
    "--capture-width", "640", "--capture-height", "360",
    "--shadow-command", "shadow mode pretty"
)) { [void]$start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
if (-not $process.Start()) { throw "Failed to launch $exe" }
$stderrTask = $process.StandardError.ReadToEndAsync()

function Convert-AgentState([string]$line) {
    if ($line -notmatch '^AGENT_STATE schema=(\d+) tick=(\d+) .* room=(\d+) pos=([^,]+),([^,]+),([^ ]+) .* yaw=([^ ]+) pitch=([^ ]+) battery=([^ ]+) souls=(\d+) active_enemies=(\d+) exposed_souls=(\d+) goals=(\d+)/(\d+) clear=(\d+) dead=(\d+)') { return $null }
    $value = [ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2]; room=[int]$Matches[3]; x=[double]$Matches[4]; y=[double]$Matches[5]; z=[double]$Matches[6]; yaw=[double]$Matches[7]; pitch=[double]$Matches[8]; battery=[double]$Matches[9]; souls=[int]$Matches[10]; active_enemies=[int]$Matches[11]; exposed_souls=[int]$Matches[12]; deposited=[int]$Matches[13]; required=[int]$Matches[14]; clear=[bool][int]$Matches[15]; dead=[bool][int]$Matches[16] }
    foreach ($field in @('x','y','z','yaw','pitch','battery')) { if (-not [double]::IsFinite($value[$field])) { return $null } }
    $value
}

function Convert-AgentEnemy([string]$line) {
    if ($line -match '^AGENT_ENEMY schema=\d+ tick=\d+ valid=0') { return $null }
    if ($line -notmatch '^AGENT_ENEMY schema=(\d+) tick=(\d+) valid=1 id=(\d+) distance_m=([^ ]+) armor=([^ ]+) pos_m=([^,]+),([^,]+),([^ ]+)') { throw 'Malformed valid AGENT_ENEMY record.' }
    $value = [ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2]; id=[int]$Matches[3]; distance=[double]$Matches[4]; armor=[double]$Matches[5]; x=[double]$Matches[6]; y=[double]$Matches[7]; z=[double]$Matches[8] }
    foreach ($field in @('distance','armor','x','y','z')) { if (-not [double]::IsFinite($value[$field])) { throw "Non-finite AGENT_ENEMY field: $field" } }
    $value
}

function Convert-AgentObjective([string]$line) {
    if ($line -match '^AGENT_OBJECTIVE schema=\d+ tick=\d+ valid=0') { return $null }
    if ($line -notmatch '^AGENT_OBJECTIVE schema=(\d+) tick=(\d+) valid=1 id=(\d+) pos_m=([^,]+),([^,]+),([^ ]+) distance_m=([^ ]+)') { throw 'Malformed valid AGENT_OBJECTIVE record.' }
    $value = [ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2]; id=[int]$Matches[3]; x=[double]$Matches[4]; y=[double]$Matches[5]; z=[double]$Matches[6]; distance=[double]$Matches[7] }
    foreach ($field in @('x','y','z','distance')) { if (-not [double]::IsFinite($value[$field])) { throw "Non-finite AGENT_OBJECTIVE field: $field" } }
    $value
}

function Convert-AgentSoul([string]$line) {
    if ($line -match '^AGENT_SOUL schema=\d+ tick=\d+ valid=0') { return $null }
    if ($line -notmatch '^AGENT_SOUL schema=(\d+) tick=(\d+) valid=1 id=(\d+) pos_m=([^,]+),([^,]+),([^ ]+) distance_m=([^ ]+)') { throw 'Malformed valid AGENT_SOUL record.' }
    $value = [ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2]; id=[int]$Matches[3]; x=[double]$Matches[4]; y=[double]$Matches[5]; z=[double]$Matches[6]; distance=[double]$Matches[7] }
    foreach ($field in @('x','y','z','distance')) { if (-not [double]::IsFinite($value[$field])) { throw "Non-finite AGENT_SOUL field: $field" } }
    $value
}

function Read-AgentLine {
    $pending = $process.StandardOutput.ReadLineAsync()
    if (-not $pending.Wait([TimeSpan]::FromSeconds($ObservationTimeoutSeconds))) {
        throw "Agent observation timed out after $ObservationTimeoutSeconds seconds."
    }
    $pending.Result
}

function Read-AgentObservation {
    $observation = [ordered]@{ state=$null; enemy=$null; objective=$null; soul=$null }
    $seen = [ordered]@{ state=$false; objective=$false; soul=$false; enemy=$false }
    $envelopes = [Collections.Generic.List[object]]::new()
    while ($true) {
        $line = Read-AgentLine
        if ($null -eq $line) { throw "Agent process ended before an observation completed." }
        $transcript.WriteLine($line); $transcript.Flush()
        if ($line.StartsWith("AGENT_PLAYTEST_ERROR ")) { throw "Agent protocol reported: $line" }
        if ($line -match '^AGENT_(?:OBJECTIVE|SOUL|ENEMY) schema=(\d+) tick=(\d+)') {
            $envelopes.Add([ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2] })
        }
        if ($line.StartsWith("AGENT_STATE ")) { $seen.state=$true; $observation.state = Convert-AgentState $line }
        elseif ($line.StartsWith("AGENT_OBJECTIVE ")) { $seen.objective=$true; $observation.objective = Convert-AgentObjective $line }
        elseif ($line.StartsWith("AGENT_SOUL ")) { $seen.soul=$true; $observation.soul = Convert-AgentSoul $line }
        elseif ($line.StartsWith("AGENT_ENEMY ")) { $seen.enemy=$true; $observation.enemy = Convert-AgentEnemy $line; break }
    }
    if (-not $observation.state -or $observation.state.schema -lt 4) { throw "Agent schema 4 or newer is required." }
    if ($seen.Values -contains $false) { throw "Agent observation omitted a required schema-4 record." }
    foreach ($record in $envelopes) {
        if ($record.schema -ne $observation.state.schema -or $record.tick -ne $observation.state.tick) {
            throw "Agent observation records disagree on schema or tick."
        }
    }
    $observation
}

function Send-AgentCommand([string]$command) {
    $transcript.WriteLine("COMMAND $command"); $transcript.Flush()
    $process.StandardInput.WriteLine($command); $process.StandardInput.Flush()
    Read-AgentObservation
}

function Normalize-Angle([double]$angle) {
    while ($angle -gt [Math]::PI) { $angle -= 2.0 * [Math]::PI }
    while ($angle -lt -[Math]::PI) { $angle += 2.0 * [Math]::PI }
    $angle
}

$actions = [Collections.Generic.List[object]]::new()
$classification = "protocol_failure"
$reason = "unknown"
try {
    $observation = Read-AgentObservation
    $baselineState = $observation.state | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $initialSouls = $observation.state.souls
    if ($Goal -eq "observe") { $classification = "pass"; $reason = "schema_observed" }
    else {
        for ($action = 0; $action -lt $MaximumActions; ++$action) {
            $state = $observation.state
            if ($state.dead) { $classification = "fail"; $reason = "player_dead"; break }
            if ($Goal -eq "combat-cycle" -and $state.souls -gt $initialSouls) { $classification = "pass"; $reason = "combat_cycle_completed"; break }
            if ($Goal -eq "room-clear" -and $state.clear) { $classification = "pass"; $reason = "room_cleared"; break }
            if ($state.battery -lt $MinimumBattery) { $classification = "fail"; $reason = "battery_safety_floor"; break }
            if ($Goal -eq "room-clear" -and $state.souls -gt 0) {
                if (-not $observation.objective) { $classification = "fail"; $reason = "no_actionable_objective"; break }
                $objective = $observation.objective
                $dx = $objective.x - $state.x; $dy = $objective.y - ($state.y + 0.95); $dz = $objective.z - $state.z
                $desiredYaw = [Math]::Atan2(-$dx, -$dz)
                $yawDelta = Normalize-Angle ($desiredYaw - $state.yaw)
                $desiredPitch = [Math]::Atan2($dy, [Math]::Sqrt($dx*$dx + $dz*$dz))
                $pitchDelta = $desiredPitch - $state.pitch
                if ([Math]::Abs($yawDelta) -gt 0.035) {
                    $look = [Math]::Max(-400.0, [Math]::Min(400.0, -$yawDelta / 0.003))
                    $command = "step frames=1 lookX=$($look.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))"
                } elseif ([Math]::Abs($pitchDelta) -gt 0.025) {
                    $look = [Math]::Max(-400.0, [Math]::Min(400.0, -$pitchDelta / 0.003))
                    $command = "step frames=1 lookY=$($look.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))"
                } else { $command = "step frames=90 shoot=1" }
            }
            elseif ($state.exposed_souls -gt 0) {
                if (-not $observation.soul) { $classification = "fail"; $reason = "no_actionable_soul"; break }
                $soul = $observation.soul
                $desiredYaw = [Math]::Atan2(-($soul.x - $state.x), -($soul.z - $state.z))
                $delta = Normalize-Angle ($desiredYaw - $state.yaw)
                if ([Math]::Abs($delta) -gt 0.12) {
                    $look = [Math]::Max(-400.0, [Math]::Min(400.0, -$delta / 0.003))
                    $command = "step frames=1 lookX=$($look.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))"
                } elseif ($soul.distance -gt 1.65) {
                    $frames = [Math]::Max(1, [Math]::Min(60, [int](($soul.distance - 1.25) / 4.0 * 60.0)))
                    $command = "step frames=$frames moveZ=1"
                } else { $command = "step frames=90 vacuum=1" }
            }
            elseif (-not $observation.enemy) { $classification = "fail"; $reason = "no_actionable_enemy"; break }
            else {
                $enemy = $observation.enemy
                $desiredYaw = [Math]::Atan2(-($enemy.x - $state.x), -($enemy.z - $state.z))
                $delta = Normalize-Angle ($desiredYaw - $state.yaw)
                if ([Math]::Abs($delta) -gt 0.16) {
                    $look = [Math]::Max(-400.0, [Math]::Min(400.0, -$delta / 0.003))
                    $command = "step frames=1 lookX=$($look.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))"
                } elseif ($enemy.distance -gt 2.55) {
                    $frames = [Math]::Max(1, [Math]::Min(90, [int](($enemy.distance - 2.15) / 5.0 * 60.0)))
                    $command = "step frames=$frames moveZ=1 sprint=1"
                } else { $command = "step frames=18 melee=1" }
            }
            $before = $state.tick
            $observation = Send-AgentCommand $command
            $actions.Add([ordered]@{ index=$action; command=$command; tick_before=$before; tick_after=$observation.state.tick; battery=$observation.state.battery; souls=$observation.state.souls; active_enemies=$observation.state.active_enemies; exposed_souls=$observation.state.exposed_souls })
        }
        if ($classification -eq "protocol_failure") { $classification = "fail"; $reason = "action_budget_exhausted" }
    }
} catch {
    $fault = [ordered]@{
        schema='data-game.agent-playtest-fault/v1'; goal=$Goal; error_type=$_.Exception.GetType().FullName; error=$_.Exception.Message
        source=[ordered]@{ executable=$exe; executable_sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant(); build_commit=[string]$identity.commit }
        limits=[ordered]@{ maximum_actions=$MaximumActions; minimum_battery=$MinimumBattery; observation_timeout_seconds=$ObservationTimeoutSeconds }
        transcript='transcript.log'; recorded_at_utc=[DateTime]::UtcNow.ToString('o')
    }
    $fault | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'fault.json') -Encoding utf8NoBOM
    throw
} finally {
    if (-not $process.HasExited) { $process.StandardInput.WriteLine("quit"); $process.StandardInput.Flush(); $process.WaitForExit(5000) | Out-Null }
    if (-not $process.HasExited) { $process.Kill($true) }
    try {
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stderr) { $transcript.WriteLine("STDERR"); $transcript.Write($stderr) }
    } catch { $transcript.WriteLine("STDERR_READ_ERROR $($_.Exception.Message)") }
    $transcript.Dispose()
}

$files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Sort-Object FullName)
$hashes = @($files | ForEach-Object { [ordered]@{ path=[IO.Path]::GetRelativePath($OutputDirectory,$_.FullName).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
$runtimeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$receipt = [ordered]@{
    schema = "indro.development-transaction/v1"
    objective = $(if ($Goal -eq "combat-cycle") { "Complete one bounded autonomous combat and soul-capture cycle." } elseif ($Goal -eq "room-clear") { "Clear one room through bounded autonomous combat, soul capture, and objective deposits." } else { "Observe exact autonomous playtest runtime state." })
    verdict = $(if ($classification -eq "pass") { "PASS" } else { "FAIL" })
    authority = [ordered]@{ source_revision=[string]$identity.commit; runtime_sha256=$runtimeHash; adapter="data-game.agent-playtest/schema-4" }
    budgets = [ordered]@{ declared=[ordered]@{ actions=$MaximumActions; simulation_ticks=$MaximumActions*120 }; consumed=[ordered]@{ actions=$actions.Count; simulation_ticks=[long]$observation.state.tick } }
    observations = [ordered]@{ baseline=$baselineState; final=$observation.state }
    actions = $actions.ToArray()
    checks = @(
        [ordered]@{ id="goal-postcondition"; role="positive"; verdict=$(if($classification-eq"pass"){"PASS"}else{"FAIL"}); observation=$reason },
        [ordered]@{ id="declared-budgets"; role="regression"; verdict=$(if($actions.Count-le$MaximumActions-and$observation.state.tick-le($MaximumActions*120)){"PASS"}else{"FAIL"}) }
    )
    evidence = $hashes
    limitations = @($(if ($Goal -eq "room-clear") { "The room-clear policy proves one deterministic room fixture; it does not claim navigation across every generated premise." } else { "The combat-cycle policy proves one kill/capture primitive; it does not claim full-room completion." }))
    elapsed_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds,3)
}
$receiptPath = Join-Path $OutputDirectory "development-transaction.json"
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
$result = [ordered]@{
    schema = "data-game.agent-playtest/v1"
    classification = $classification
    reason = $reason
    goal = $Goal
    source = [ordered]@{ executable=$exe; executable_sha256=$runtimeHash; room_seed=$RoomSeed; room_index=$RoomIndex }
    limits = [ordered]@{ maximum_actions=$MaximumActions; minimum_battery=$MinimumBattery }
    actions = $actions.ToArray()
    final_state = $observation.state
    evidence = $hashes
    development_receipt = "development-transaction.json"
}
$resultPath = Join-Path $OutputDirectory "result.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
Write-Host "AGENT_PLAYTEST=$($classification.ToUpperInvariant()) goal=$Goal reason=$reason actions=$($actions.Count) tick=$($observation.state.tick) souls=$($observation.state.souls) battery=$($observation.state.battery)"
Write-Host "EVIDENCE_OK bundle=$OutputDirectory result=$resultPath"
if ($classification -ne "pass") { exit 10 }
