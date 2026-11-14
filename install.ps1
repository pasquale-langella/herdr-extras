#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

Write-Host "==> Installing pane-ids mod"
$mod = Join-Path $env:USERPROFILE ".config\herdr-app\mods\pane-ids"
New-Item -ItemType Directory -Force -Path $mod | Out-Null
Copy-Item (Join-Path $Root "mods\pane-ids\*") $mod -Force

if (Get-Command herdr-app -ErrorAction SilentlyContinue) {
  $layoutDir = Join-Path $env:USERPROFILE ".config\herdr-app\layouts"
  $mainIds = Join-Path $layoutDir "main-ids.json"
  if (-not (Test-Path $mainIds)) {
    herdr-app do layout.clone --name main --as main-ids | Out-Null
  }
  if (Test-Path $mainIds) {
    $text = Get-Content $mainIds -Raw
    if ($text -match '"mod":\s*"pane"') {
      $text = $text -replace '"mod":\s*"pane"', '"mod": "pane-ids"'
      Set-Content -Path $mainIds -Value $text -NoNewline
    }
  }
  herdr-app do layout.switch --name main-ids | Out-Null
  herdr-app check $mod
  Write-Host "    layout: main-ids (pane header mod = pane-ids)"
} else {
  Write-Warning "herdr-app not on PATH; copied mod only. Clone/switch layout yourself."
}

Write-Host "==> Installing cursor-status bridge"
$dest = Join-Path $env:USERPROFILE ".cursor\herdr-status"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $Root "cursor-status\*") $dest -Force

Write-Host "==> Ensuring pywinpty"
python -m pip install --user pywinpty | Out-Host

Write-Host "==> Wiring Cursor hooks"
node (Join-Path $dest "install-hooks.js") install

Write-Host ""
Write-Host "Done."
Write-Host "Launch Cursor in Herdr with:"
$py = (Get-Command python).Source
Write-Host @"
herdr-app do terminal.open --place right --name cursor --folder "`$PWD" --argv '["$py","$dest\cursor-herdr.py","--trust"]'
"@
