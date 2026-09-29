# Workstation authority

The bootstrap phase is over. There are three active systems:

| System | Authority | Responsibility |
| --- | --- | --- |
| Data | `indrolend/data-game/main` | Product source, builds, behavioral tests, packages, releases |
| Data Game Tools | `indrolend/data-game-tools/main` | External diagnostics, capture, playtesting, and tuning |
| Indro | `indrolend/Indro/main` | CommandHUD and bounded cross-machine execution |

On the Windows workstation their canonical checkouts are:

- `C:\Users\indro\Projects\data-game`
- `C:\Users\indro\Projects\data-game-tools`
- `C:\Users\indro\Projects\Indro`

Older Digital Breakdown repositories, branches, worktrees, launchers, and capture
directories are historical evidence. They do not become authority because a tool
or document still names them.

## Change rule

One task changes one system unless a concrete integration contract requires two.
Before adding an abstraction, schema, worker, launcher, or repository, demonstrate
the blocking need in the existing three-system arrangement.

CommandHUD transports bounded requests and compact results. It does not own game
source, runtime truth, or visual judgment. Data Game Tools consumes an exact Data
revision and never copies gameplay implementation or assets.
