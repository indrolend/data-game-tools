# Data Game Tools

External diagnostics, playtesting, capture, and tuning tools for [Data](https://github.com/indrolend/data-game).

`data-game` is the sole authority for product source, runtime assets, build configuration, tests, packaging, and releases. This repository consumes a chosen `data-game` checkout; it must not copy game source, protocol constants, assets, or runtime behavior.

## Run the product contract

```powershell
.\Invoke-DataGame.ps1 -Action test -Configuration Release
```

The Windows workstation defaults to `C:\Users\indro\Projects\data-game`. Pass
`-GameRoot` only when deliberately testing another checkout.

Supported actions are `status`, `configure`, `build`, `test`, `smoke`, and `evidence`. Build output and generated evidence stay under this repository's ignored `artifacts/` directory, leaving the product checkout clean. Each invocation reports the exact product commit and whether its checkout is dirty.

Build directories include a short hash of the resolved source checkout path in
addition to commit and configuration. This prevents separate worktrees at the
same commit—especially dirty experimental worktrees—from silently sharing a
CMake cache or executable.

## SSH-first command surface

`Dev.ps1` is a thin, noninteractive entry point over the existing Git,
CommandHUD, and `Invoke-DataGame.ps1` authorities. It works in a local
PowerShell terminal and in an SSH PowerShell session without requiring a
browser, tunnel, MCP server, or full-screen interface.

```powershell
.\Dev.ps1 status
.\Dev.ps1 doctor
.\Dev.ps1 worktrees
.\Dev.ps1 build
.\Dev.ps1 tests
.\Dev.ps1 godot-build
.\Dev.ps1 godot-test
.\Dev.ps1 evidence -Scenario enemy-obstruction
```

Use `-Json` with read-only inspection commands when a compact machine-readable
result is preferable on a remote client.

```powershell
.\Invoke-DataGame.ps1 -Action evidence -Scenario enemy-obstruction
```

`shadow-stability` consumes the product-owned room inspector and runtime shadow command/observation interfaces. It captures off, cheap, mapped-normal, and mapped-pretty for all eight representative premises, verifies path isolation (including directional, local-fixture, and unavailable sources), and emits representative contact sheets plus a complete hash manifest. An already verified developer executable may be supplied with `-ExecutablePath` to avoid rebuilding during rapid iteration.

Verify a retained bundle without rerunning the renderer with `scripts/Test-ShadowStabilityEvidence.ps1 -Bundle <path>`; this is the compact CommandHUD/Indro handoff surface.

The evidence action runs the product-owned deterministic scenario, encodes its
tick-addressable clean frames into a compact H.264 video, removes bulky temporary
video frames after successful encoding, and writes `result.json` beside the
manifest, telemetry, event frames, assertions, logs, and video.

Visual capture and richer evidence bundles should be added here as thin orchestration over explicit product/test interfaces. If a diagnostic needs copied gameplay logic to work, the product is missing a testable boundary; add that boundary to `data-game` instead of duplicating it here.

To maintain stable pointers to the newest generated image and video while an
evidence workflow is running, start the repository-local watcher in another
PowerShell session:

```powershell
.\scripts\Watch-LatestGameEvidence.ps1
```

It atomically updates ignored `artifacts/evidence/latest.png` and `latest.mp4`.
Use `-EvidenceRoot <path>` only when watching another explicit evidence root.

See [AUTHORITY.md](AUTHORITY.md) before adding another repository, launcher, or orchestration layer.
