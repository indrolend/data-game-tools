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
.\Dev.ps1 evidence -Scenario enemy-obstruction
```

Use `-Json` with read-only inspection commands when a compact machine-readable
result is preferable on a remote client.

```powershell
.\Invoke-DataGame.ps1 -Action evidence -Scenario enemy-obstruction
```

The evidence action runs the product-owned deterministic scenario, encodes its
tick-addressable clean frames into a compact H.264 video, removes bulky temporary
video frames after successful encoding, and writes `result.json` beside the
manifest, telemetry, event frames, assertions, logs, and video.

Visual capture and richer evidence bundles should be added here as thin orchestration over explicit product/test interfaces. If a diagnostic needs copied gameplay logic to work, the product is missing a testable boundary; add that boundary to `data-game` instead of duplicating it here.

See [AUTHORITY.md](AUTHORITY.md) before adding another repository, launcher, or orchestration layer.
