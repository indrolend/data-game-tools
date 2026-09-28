# Data Game Tools

External diagnostics, playtesting, capture, and tuning tools for [Data](https://github.com/indrolend/data-game).

`data-game` is the sole authority for product source, runtime assets, build configuration, tests, packaging, and releases. This repository consumes a chosen `data-game` checkout; it must not copy game source, protocol constants, assets, or runtime behavior.

## Run the product contract

```powershell
.\Invoke-DataGame.ps1 -GameRoot C:\path\to\data-game -Action test -Configuration Release
```

Supported actions are `status`, `configure`, `build`, `test`, and `smoke`. Build output and generated evidence stay under this repository's ignored `artifacts/` directory, leaving the product checkout clean. Each invocation reports the exact product commit and whether its checkout is dirty.

Visual capture and richer evidence bundles should be added here as thin orchestration over explicit product/test interfaces. If a diagnostic needs copied gameplay logic to work, the product is missing a testable boundary; add that boundary to `data-game` instead of duplicating it here.

