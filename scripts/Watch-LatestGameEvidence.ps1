param(
    [string]$EvidenceRoot,
    [ValidateRange(1, 60)][int]$PollSeconds = 2
)

$ErrorActionPreference = 'Continue'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$root = if ($EvidenceRoot) { [IO.Path]::GetFullPath($EvidenceRoot) } else { Join-Path $repositoryRoot 'artifacts\evidence' }
$null = New-Item -ItemType Directory -Path $root -Force
$log = Join-Path $root 'latest-watcher.log'
$last = @{}
function Publish-Latest($ext, $destination, $patterns) {
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in $patterns -and $_.Name -notin @('latest.png','latest.mp4') -and $_.DirectoryName -ne $root } | Sort-Object LastWriteTimeUtc -Descending)
    if ($files.Count -eq 0) { return }
    $source = $files[0]
    $key = "$($source.FullName)|$($source.Length)|$($source.LastWriteTimeUtc.Ticks)"
    if ($last[$ext] -eq $key) { return }
    try {
        $a = Get-Item -LiteralPath $source.FullName
        Start-Sleep -Milliseconds 350
        $b = Get-Item -LiteralPath $source.FullName
        if ($a.Length -ne $b.Length -or $a.LastWriteTimeUtc -ne $b.LastWriteTimeUtc -or $b.Length -eq 0) { return }
        $temp = Join-Path $root "latest.$ext.tmp.$PID.$ext"
        if ($source.Extension -ieq '.ppm') {
            if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg is required to convert PPM evidence' }
            & ffmpeg -hide_banner -loglevel error -y -i $source.FullName -frames:v 1 $temp
            if ($LASTEXITCODE -ne 0) { throw "ffmpeg exit code $LASTEXITCODE" }
        } else { Copy-Item -LiteralPath $source.FullName -Destination $temp -Force }
        Move-Item -LiteralPath $temp -Destination $destination -Force
        $last[$ext] = $key
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) $destination <= $($source.FullName)"
    } catch {
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) ERROR $($_.Exception.Message)"
        Remove-Item -LiteralPath (Join-Path $root "latest.$ext.tmp.$PID.$ext") -ErrorAction SilentlyContinue
    }
}
while ($true) {
    Publish-Latest 'png' (Join-Path $root 'latest.png') @('.png','.ppm')
    Publish-Latest 'mp4' (Join-Path $root 'latest.mp4') @('.mp4')
    Start-Sleep -Seconds $PollSeconds
}
