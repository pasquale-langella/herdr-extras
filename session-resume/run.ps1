# Herdr session resume watcher. Started at logon by the HerdrSessionResume task.
$ErrorActionPreference = "Stop"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Error "node is not on PATH"
  exit 1
}
& $node.Source (Join-Path $PSScriptRoot "watch.js")
exit $LASTEXITCODE
