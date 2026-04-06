param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

Write-Host "Preparing cirebronx release $Version"

python .\scripts\bump_version.py $Version
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

zig build test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

zig build -Doptimize=ReleaseSafe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git add .
git commit -m "Release cirebronx $Version"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git tag "v$Version"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Next:"
Write-Host "  git push origin main"
Write-Host "  git push origin v$Version"
Write-Host "  gh release create v$Version --title `"cirebronx v$Version`" --notes `"Release $Version.`" .\\zig-out\\bin\\cirebronx.exe"
