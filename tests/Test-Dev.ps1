$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$dev = Join-Path $root "Dev.ps1"
$gameRoot = "C:\Users\indro\Projects\data-game"

$status = & $dev status -GameRoot $gameRoot -Json | ConvertFrom-Json
if ($status.schema_version -ne 1) { throw "Unexpected status schema." }
if ($status.project -ne "data-game") { throw "Unexpected project identity." }
if ($status.root -ne (Resolve-Path -LiteralPath $gameRoot).Path) { throw "Unexpected project root." }
if (-not $status.commit -or $status.commit.Length -ne 40) { throw "Invalid commit identity." }

$worktrees = @(& $dev worktrees -GameRoot $gameRoot -Json | ConvertFrom-Json)
if ($worktrees.Count -lt 1) { throw "No worktrees reported." }
if (-not ($worktrees.path -contains (Resolve-Path -LiteralPath $gameRoot).Path.Replace("\", "/"))) {
    throw "Authoritative worktree was not reported."
}

$doctor = & $dev doctor -GameRoot $gameRoot -Json | ConvertFrom-Json
if (-not ($doctor.commands | Where-Object { $_.name -eq "ssh" -and $_.ready })) { throw "SSH was not ready." }
if (-not ($doctor.services | Where-Object { $_.name -eq "sshd" -and $_.status -eq "Running" })) { throw "sshd was not running." }

Write-Output "DEV_TEST_OK worktrees=$($worktrees.Count) commit=$($status.commit)"
