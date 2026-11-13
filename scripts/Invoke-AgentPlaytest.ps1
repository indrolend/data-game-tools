[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [string]$OutputDirectory,
    [int]$RoomSeed = 7,
    [int]$RoomIndex = 12,
    [ValidateSet("observe", "combat-cycle")][string]$Goal = "combat-cycle",
    [int]$MaximumActions = 40,
    [double]$MinimumBattery = 12.0
)

$ErrorActionPreference = "Stop"
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
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

function Convert-AgentState([string]$line) {
    if ($line -notmatch '^AGENT_STATE schema=(\d+) tick=(\d+) .* room=(\d+) pos=([^,]+),([^,]+),([^ ]+) .* yaw=([^ ]+) pitch=([^ ]+) battery=([^ ]+) souls=(\d+) active_enemies=(\d+) exposed_souls=(\d+) goals=(\d+)/(\d+) clear=(\d+) dead=(\d+)') { return $null }
    [ordered]@{ schema=[int]$Matches[1]; tick=[long]$Matches[2]; room=[int]$Matches[3]; x=[double]$Matches[4]; y=[double]$Matches[5]; z=[double]$Matches[6]; yaw=[double]$Matches[7]; pitch=[double]$Matches[8]; battery=[double]$Matches[9]; souls=[int]$Matches[10]; active_enemies=[int]$Matches[11]; exposed_souls=[int]$Matches[12]; deposited=[int]$Matches[13]; required=[int]$Matches[14]; clear=[bool][int]$Matches[15]; dead=[bool][int]$Matches[16] }
}

function Convert-AgentEnemy([string]$line) {
    if ($line -match '^AGENT_ENEMY schema=\d+ tick=\d+ valid=0') { return $null }
    if ($line -notmatch '^AGENT_ENEMY schema=\d+ tick=\d+ valid=1 id=(\d+) distance_m=([^ ]+) armor=([^ ]+) pos_m=([^,]+),([^,]+),([^ ]+)') { return $null }
    [ordered]@{ id=[int]$Matches[1]; distance=[double]$Matches[2]; armor=[double]$Matches[3]; x=[double]$Matches[4]; y=[double]$Matches[5]; z=[double]$Matches[6] }
}

function Read-AgentObservation {
    $observation = [ordered]@{ state=$null; enemy=$null; objective=$null }
    while ($true) {
        $line = $process.StandardOutput.ReadLine()
        if ($null -eq $line) { throw "Agent process ended before an observation completed." }
        $transcript.WriteLine($line); $transcript.Flush()
        if ($line.StartsWith("AGENT_STATE ")) { $observation.state = Convert-AgentState $line }
        elseif ($line.StartsWith("AGENT_OBJECTIVE ")) { $observation.objective = $line }
        elseif ($line.StartsWith("AGENT_ENEMY ")) { $observation.enemy = Convert-AgentEnemy $line; break }
    }
    if (-not $observation.state -or $observation.state.schema -lt 3) { throw "Agent schema 3 or newer is required." }
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
    $initialSouls = $observation.state.souls
    if ($Goal -eq "observe") { $classification = "pass"; $reason = "schema_observed" }
    else {
        for ($action = 0; $action -lt $MaximumActions; ++$action) {
            $state = $observation.state
            if ($state.dead) { $classification = "fail"; $reason = "player_dead"; break }
            if ($state.souls -gt $initialSouls) { $classification = "pass"; $reason = "combat_cycle_completed"; break }
            if ($state.battery -lt $MinimumBattery) { $classification = "fail"; $reason = "battery_safety_floor"; break }
            if ($state.exposed_souls -gt 0) { $command = "step frames=120 vacuum=1" }
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
                } else { $command = "step frames=30 melee=1" }
            }
            $before = $state.tick
            $observation = Send-AgentCommand $command
            $actions.Add([ordered]@{ index=$action; command=$command; tick_before=$before; tick_after=$observation.state.tick; battery=$observation.state.battery; souls=$observation.state.souls; active_enemies=$observation.state.active_enemies; exposed_souls=$observation.state.exposed_souls })
        }
        if ($classification -eq "protocol_failure") { $classification = "fail"; $reason = "action_budget_exhausted" }
    }
} finally {
    if (-not $process.HasExited) { $process.StandardInput.WriteLine("quit"); $process.StandardInput.Flush(); $process.WaitForExit(5000) | Out-Null }
    if (-not $process.HasExited) { $process.Kill($true) }
    $transcript.Dispose()
}

$files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Sort-Object FullName)
$hashes = @($files | ForEach-Object { [ordered]@{ path=[IO.Path]::GetRelativePath($OutputDirectory,$_.FullName).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
$result = [ordered]@{
    schema = "data-game.agent-playtest/v1"
    classification = $classification
    reason = $reason
    goal = $Goal
    source = [ordered]@{ executable=$exe; executable_sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant(); room_seed=$RoomSeed; room_index=$RoomIndex }
    limits = [ordered]@{ maximum_actions=$MaximumActions; minimum_battery=$MinimumBattery }
    actions = $actions.ToArray()
    final_state = $observation.state
    evidence = $hashes
}
$resultPath = Join-Path $OutputDirectory "result.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
Write-Host "AGENT_PLAYTEST=$($classification.ToUpperInvariant()) goal=$Goal reason=$reason actions=$($actions.Count) tick=$($observation.state.tick) souls=$($observation.state.souls) battery=$($observation.state.battery)"
Write-Host "EVIDENCE_OK bundle=$OutputDirectory result=$resultPath"
if ($classification -ne "pass") { exit 10 }
