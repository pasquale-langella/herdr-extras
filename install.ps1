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

Write-Host "==> Pointing Herdr Cursor menu at the OSC wrapper"
$py = (Get-Command python).Source
$wrapper = Join-Path $dest "cursor-herdr.py"
$programsPath = Join-Path $env:USERPROFILE ".config\herdr-app\programs.json"
$herdrApp = Join-Path $env:USERPROFILE ".config\herdr-app"
New-Item -ItemType Directory -Force -Path $herdrApp | Out-Null

# Merge cursor.run into programs.json (PS 5.1-safe; keep other program entries).
$programs = @{}
if (Test-Path $programsPath) {
  $raw = Get-Content $programsPath -Raw
  if ($raw.Trim()) {
    $existing = $raw | ConvertFrom-Json
    if ($existing.programs) {
      foreach ($prop in $existing.programs.PSObject.Properties) {
        $programs[$prop.Name] = $prop.Value
      }
    }
  }
}
$match = New-Object System.Collections.Generic.List[string]
$match.Add("cursor-agent") | Out-Null
$match.Add("cursor-herdr.py") | Out-Null
if ($programs.ContainsKey("cursor") -and $programs["cursor"].match) {
  foreach ($m in @($programs["cursor"].match)) {
    if ($m -and -not $match.Contains([string]$m)) { $match.Add([string]$m) | Out-Null }
  }
}
$programs["cursor"] = [pscustomobject]@{
  run   = @($py, $wrapper)
  match = @($match.ToArray())
}
$programsObj = New-Object psobject
foreach ($k in $programs.Keys) {
  $programsObj | Add-Member NoteProperty $k $programs[$k]
}
$out = [pscustomobject]@{ programs = $programsObj }
($out | ConvertTo-Json -Depth 8) | Set-Content -Path $programsPath -Encoding utf8
Write-Host "    programs.json: cursor.run -> $py $wrapper"

Write-Host ""
Write-Host "Done."
Write-Host "Herdr's Agents / New menu Cursor entry now launches the wrapper."
Write-Host "Manual launch (same argv):"
Write-Host @"
herdr-app do terminal.open --place right --name cursor --folder "`$PWD" --argv '["$py","$wrapper"]'
"@
Write-Host "Bare cursor-agent still will not appear in Agents until Cursor emits OSC 7501."
