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
      # Avoid BOM from Set-Content -Encoding utf8 on Windows PowerShell 5.1
      $utf8NoBom = New-Object System.Text.UTF8Encoding $false
      [System.IO.File]::WriteAllText($mainIds, $text, $utf8NoBom)
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
$bin = Join-Path $dest "bin"
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Get-ChildItem (Join-Path $Root "cursor-status") -Force | ForEach-Object {
  if ($_.Name -eq "bin") {
    Copy-Item (Join-Path $_.FullName "*") $bin -Force
  } elseif ($_.Extension -eq ".exe") {
    # Built below from .cs; skip copying a stale checked-in binary if present
  } else {
    Copy-Item $_.FullName $dest -Force -Recurse
  }
}

Write-Host "==> Building cursor-herdr.exe (so Herdr launches an .exe, not python/cmd)"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
  $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) {
  throw "csc.exe not found (needs .NET Framework 4.x developer pack / Windows .NET Framework)"
}
$cs = Join-Path $dest "cursor-herdr-launch.cs"
$exe = Join-Path $dest "cursor-herdr.exe"
& $csc /nologo /target:exe /out:$exe $cs | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
  throw "Failed to build cursor-herdr.exe"
}
Write-Host "    $exe"

Write-Host "==> Wiring Cursor hooks"
node (Join-Path $dest "install-hooks.js") install

Write-Host "==> Prepending herdr-status\bin on User PATH (bare cursor-agent -> wrapper)"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$parts = @($userPath -split ";" | Where-Object { $_ -and $_.Trim() })
$parts = @($parts | Where-Object { $_.TrimEnd("\") -ne $bin.TrimEnd("\") })
$newUserPath = ($bin + ";" + ($parts -join ";")).TrimEnd(";")
[Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
if ($env:Path -notlike "*$bin*") {
  $env:Path = "$bin;$env:Path"
}
Write-Host "    User PATH += $bin"

Write-Host "==> Pointing Herdr Cursor menu at cursor-herdr.exe"
$programsPath = Join-Path $env:USERPROFILE ".config\herdr-app\programs.json"
$herdrApp = Join-Path $env:USERPROFILE ".config\herdr-app"
New-Item -ItemType Directory -Force -Path $herdrApp | Out-Null

# Merge cursor.run into programs.json (PS 5.1-safe; keep other program entries).
# Strip a UTF-8 BOM if present — Herdr's JSON parser rejects BOM ("expected value at line 1").
$programs = @{}
if (Test-Path $programsPath) {
  $raw = Get-Content $programsPath -Raw
  if ($raw) {
    if ($raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    if ($raw.Trim()) {
      $existing = $raw | ConvertFrom-Json
      if ($existing.programs) {
        foreach ($prop in $existing.programs.PSObject.Properties) {
          $programs[$prop.Name] = $prop.Value
        }
      }
    }
  }
}
$match = New-Object System.Collections.Generic.List[string]
$match.Add("cursor-agent") | Out-Null
$match.Add("cursor-herdr.py") | Out-Null
$match.Add("cursor-herdr.exe") | Out-Null
$match.Add("agent") | Out-Null
if ($programs.ContainsKey("cursor") -and $programs["cursor"].match) {
  foreach ($m in @($programs["cursor"].match)) {
    if ($m -and -not $match.Contains([string]$m)) { $match.Add([string]$m) | Out-Null }
  }
}
$programs["cursor"] = [pscustomobject]@{
  run   = @($exe)
  match = @($match.ToArray())
}
$programsObj = New-Object psobject
foreach ($k in $programs.Keys) {
  $programsObj | Add-Member NoteProperty $k $programs[$k]
}
$out = [pscustomobject]@{ programs = $programsObj }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($programsPath, (($out | ConvertTo-Json -Depth 8) + "`n"), $utf8NoBom)
Write-Host "    programs.json: cursor.run -> $exe"

Write-Host ""
Write-Host "Done."
Write-Host "Agents / New -> Cursor, and bare cursor-agent inside Herdr, use the OSC wrapper."
Write-Host "programs.json is written UTF-8 without BOM (required by Herdr)."
