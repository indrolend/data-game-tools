$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $root "scripts\Invoke-AgentPlaytest.ps1"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("data-game-agent-fixture-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null

function Assert-Equal($actual, $expected, [string]$message) {
    if ($actual -ne $expected) { throw "$message expected=$expected actual=$actual" }
}

function Invoke-Fixture([string]$mode, [string]$goal = "observe", [int]$timeout = 2) {
    $env:DB_AGENT_FIXTURE_MODE = $mode
    $output = Join-Path $temporary ("evidence-" + $mode)
    $result = & pwsh -NoProfile -File $runner -ExecutablePath (Join-Path $temporary 'AgentPlaytestFixture.exe') -OutputDirectory $output -Goal $goal -ObservationTimeoutSeconds $timeout 2>&1
    [pscustomobject]@{ exit_code=$LASTEXITCODE; output=($result | Out-String); directory=$output }
}

try {
    & dotnet build (Join-Path $PSScriptRoot 'fixtures\AgentPlaytestFixture.csproj') -c Release -o $temporary --nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture build failed' }

    $valid = Invoke-Fixture valid
    Assert-Equal $valid.exit_code 0 'valid observation exit'
    $json = Get-Content (Join-Path $valid.directory 'result.json') -Raw | ConvertFrom-Json
    Assert-Equal $json.classification 'pass' 'valid observation classification'

    foreach ($case in @(
        @{ mode='schema3'; pattern='schema 4 or newer' },
        @{ mode='missing-soul'; pattern='omitted a required' },
        @{ mode='tick-mismatch'; pattern='disagree on schema or tick' },
        @{ mode='protocol-error'; pattern='fixture_failure' },
        @{ mode='nan-state'; pattern='schema 4 or newer' }
    )) {
        $failure = Invoke-Fixture $case.mode
        if ($failure.exit_code -eq 0) { throw "$($case.mode) unexpectedly passed" }
        if ($failure.output -notmatch $case.pattern) { throw "$($case.mode) missing expected fault: $($failure.output)" }
    }

    $silent = Invoke-Fixture silent observe 1
    if ($silent.exit_code -eq 0 -or $silent.output -notmatch 'timed out') { throw "silent fixture did not fail closed: $($silent.output)" }
    $identitySilent = Invoke-Fixture identity-silent observe 1
    if ($identitySilent.exit_code -eq 0 -or $identitySilent.output -notmatch 'identity probe timed out') { throw "silent identity probe did not fail closed: $($identitySilent.output)" }

    $stderr = Invoke-Fixture stderr
    Assert-Equal $stderr.exit_code 0 'stderr-drain exit'
    if ((Get-Item (Join-Path $stderr.directory 'transcript.log')).Length -lt 200000) { throw 'stderr was not retained in transcript' }

    $existing = Invoke-Fixture valid
    if ($existing.exit_code -eq 0 -or $existing.output -notmatch 'already exists') { throw 'existing evidence directory was overwritten' }

    Write-Output "AGENT_PLAYTEST_FAULT_TEST_OK cases=10"
} finally {
    Remove-Item Env:DB_AGENT_FIXTURE_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
