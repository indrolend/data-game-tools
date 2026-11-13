[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Bundle)
$ErrorActionPreference='Stop';$root=(Resolve-Path -LiteralPath $Bundle).Path
$result=Get-Content -LiteralPath (Join-Path $root 'result.json') -Raw|ConvertFrom-Json
if(-not$result.passed-or$result.premises-ne8-or$result.modes-ne4-or$result.captures-ne32-or$result.failures-ne0){throw 'Shadow stability result contract failed.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw|ConvertFrom-Json
if($manifest.classification-ne'PASS'-or@($manifest.captures|Where-Object{-not$_.passed}).Count-ne0){throw 'Shadow stability manifest contains a failed capture.'}
$hashes=@(Get-Content -LiteralPath (Join-Path $root 'sha256-manifest.json') -Raw|ConvertFrom-Json)
foreach($item in $hashes){$path=[IO.Path]::GetFullPath((Join-Path $root $item.path));if(-not$path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Hash path escaped bundle: $($item.path)"};if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing evidence: $($item.path)"};$actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();if($actual-ne$item.sha256){throw "Hash mismatch: $($item.path)"}}
$nonDirectional=@($manifest.captures|Where-Object{$_.availability-eq'non-directional-rig'})
"SHADOW_EVIDENCE_INTEGRITY=PASS files=$($hashes.Count) captures=$($manifest.captures.Count)"
"SHADOW_LOCAL_LIGHT_GAP=OBSERVED captures=$($nonDirectional.Count) premises=$(@($nonDirectional.premise|Sort-Object -Unique).Count)"
"VISUAL_DEFECT_CLOSURE=PASS premises=$($result.premises) modes=$($result.modes) failures=$($result.failures)"
