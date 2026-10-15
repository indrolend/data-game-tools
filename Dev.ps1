[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "status", "projects", "project", "git", "worktrees", "tests", "build", "evidence", "agents", "doctor")]
    [string]$Action = "help",

    [Parameter(Position = 1)]
    [string]$Name = "data-game",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release",

    [ValidateSet("enemy-obstruction", "lighting-comparison", "soul-lifecycle")]
    [string]$Scenario = "enemy-obstruction",

    [string]$GameRoot = "C:\Users\indro\Projects\data-game",

    [switch]$Json
)

$ErrorActionPreference = "Stop"
$toolRoot = $PSScriptRoot
$dataGameCommand = Join-Path $toolRoot "Invoke-DataGame.ps1"

function Get-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & git -C $GameRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git failed: $($output -join [Environment]::NewLine)" }
    ($output | Out-String).TrimEnd()
}

function Get-ProjectState {
    $head = Get-GitText @("rev-parse", "HEAD")
    $branch = Get-GitText @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "DETACHED" }
    $upstream = (& git -C $GameRoot rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>$null | Out-String).Trim()
    $upstreamHead = if ($LASTEXITCODE -eq 0 -and $upstream) {
        Get-GitText @("rev-parse", $upstream)
    } else { $null }
    $changes = @(& git -C $GameRoot status --porcelain=v1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to read repository status." }
    $ahead = 0
    $behind = 0
    if ($upstream) {
        $counts = (Get-GitText @("rev-list", "--left-right", "--count", "$upstream...HEAD")) -split "\s+"
        $behind = [int]$counts[0]
        $ahead = [int]$counts[1]
    }
    [ordered]@{
        schema_version = 1
        project = "data-game"
        root = (Resolve-Path -LiteralPath $GameRoot).Path
        branch = $branch
        commit = $head
        upstream = $upstream
        upstream_commit = $upstreamHead
        ahead = $ahead
        behind = $behind
        dirty = $changes.Count -gt 0
        change_count = $changes.Count
    }
}

function Write-ProjectState {
    $state = Get-ProjectState
    if ($Json) { $state | ConvertTo-Json; return }
    "PROJECT=$($state.project)"
    "ROOT=$($state.root)"
    "BRANCH=$($state.branch)"
    "COMMIT=$($state.commit)"
    "UPSTREAM=$($state.upstream)"
    "UPSTREAM_COMMIT=$($state.upstream_commit)"
    "AHEAD=$($state.ahead)"
    "BEHIND=$($state.behind)"
    "DIRTY=$($state.dirty.ToString().ToLowerInvariant())"
    "CHANGES=$($state.change_count)"
}

function Write-Doctor {
    $commands = foreach ($command in @("pwsh", "git", "cmake", "ctest", "ssh", "tailscale", "starship", "commandhud")) {
        $found = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
        [ordered]@{ name = $command; ready = $null -ne $found; path = if ($found) { $found.Source } else { $null } }
    }
    $services = foreach ($serviceName in @("sshd", "Tailscale")) {
        $service = Get-Service $serviceName -ErrorAction SilentlyContinue
        [ordered]@{ name = $serviceName; installed = $null -ne $service; status = if ($service) { [string]$service.Status } else { "missing" }; start_type = if ($service) { [string]$service.StartType } else { $null } }
    }
    $result = [ordered]@{
        schema_version = 1
        project = Get-ProjectState
        commands = $commands
        services = $services
        ssh_session = [bool]$env:SSH_CONNECTION
        computer = $env:COMPUTERNAME
    }
    if ($Json) { $result | ConvertTo-Json -Depth 5; return }
    Write-ProjectState
    "SSH_SESSION=$($result.ssh_session.ToString().ToLowerInvariant())"
    "COMPUTER=$($result.computer)"
    foreach ($command in $commands) { "COMMAND $($command.name) ready=$($command.ready.ToString().ToLowerInvariant()) path=$($command.path)" }
    foreach ($service in $services) { "SERVICE $($service.name) installed=$($service.installed.ToString().ToLowerInvariant()) status=$($service.status) start_type=$($service.start_type)" }
}

switch ($Action) {
    "help" {
        @"
dev status                 project revision and dirty state
dev projects               verified CommandHUD projects
dev project data-game      select and inspect the authoritative project
dev git                    concise Git status
dev worktrees              registered worktrees and dirty state
dev tests                  build and run product tests
dev build                  build the product
dev evidence               build and capture deterministic evidence
dev agents                 available trusted agent runners
dev doctor                 SSH-safe workstation readiness

Options: -Configuration Release -Scenario enemy-obstruction -Json
"@
    }
    "status" { Write-ProjectState }
    "projects" { & commandhud projects $(if ($Json) { "--json" }) }
    "project" {
        if ($Name -ne "data-game") { throw "Unknown project '$Name'. The authoritative project name is data-game." }
        Write-ProjectState
    }
    "git" { Get-GitText @("status", "--short", "--branch") }
    "worktrees" {
        $paths = @((Get-GitText @("worktree", "list", "--porcelain")) -split "`r?`n" | Where-Object { $_ -like "worktree *" } | ForEach-Object { $_.Substring(9) })
        $items = foreach ($path in $paths) {
            $status = @(& git -C $path status --porcelain=v1 2>$null)
            [ordered]@{ path = $path; dirty = $status.Count -gt 0; change_count = $status.Count }
        }
        if ($Json) { $items | ConvertTo-Json; return }
        foreach ($item in $items) { "WORKTREE dirty=$($item.dirty.ToString().ToLowerInvariant()) changes=$($item.change_count) path=$($item.path)" }
    }
    "tests" { & $dataGameCommand -GameRoot $GameRoot -Action test -Configuration $Configuration; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
    "build" { & $dataGameCommand -GameRoot $GameRoot -Action build -Configuration $Configuration; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
    "evidence" { & $dataGameCommand -GameRoot $GameRoot -Action evidence -Configuration $Configuration -Scenario $Scenario; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
    "agents" { & commandhud agents $(if ($Json) { "--json" }) }
    "doctor" { Write-Doctor }
}
