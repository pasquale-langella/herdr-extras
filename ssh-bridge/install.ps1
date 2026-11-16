#Requires -Version 5.1
param(
  [string]$AuthorizedKey = "",
  [int]$ListenPort = 2222,
  [int[]]$TailscalePorts = @(22, 2222),
  [switch]$SkipTailscale,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$SrcDir = $PSScriptRoot
$DestDir = Join-Path $env:USERPROFILE ".config\herdr-extras\herdr-ssh-bridge"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "HerdrSshBridge"

function Stop-RunningBridge {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'herdr-ssh-bridge.exe'" -ErrorAction SilentlyContinue)
  foreach ($p in $procs) {
    Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
  }
  if ($procs.Count -gt 0) {
    Start-Sleep -Milliseconds 300
  }
}

function Lock-PrivateFile([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls $Path /inheritance:r /grant:r "*$($sid):(F)" "*S-1-5-18:(F)" | Out-Null
}

if ($Uninstall) {
  Write-Host "==> Stopping herdr-ssh-bridge"
  Stop-RunningBridge
  Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue

  if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    foreach ($port in $TailscalePorts) {
      & tailscale serve --tcp $port off 2>$null | Out-Null
    }
    Write-Host "    Tailscale Serve TCP rules removed ($($TailscalePorts -join ', '))"
  }

  if (Test-Path $DestDir) {
    Remove-Item $DestDir -Recurse -Force
    Write-Host "    Removed $DestDir"
  }
  Write-Host "Done."
  exit 0
}

Write-Host "==> Checking prerequisites"
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
  throw "Go 1.23+ is required on PATH to build herdr-ssh-bridge (https://go.dev/dl/)."
}
$hcCandidate = Join-Path $env:LOCALAPPDATA "Programs\herdr-core\hc.exe"
if (-not (Test-Path $hcCandidate) -and -not (Get-Command hc -ErrorAction SilentlyContinue)) {
  throw "Herdr core (hc.exe) not found. Install Herdr desktop first."
}

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
foreach ($file in @("go.mod", "go.sum", "main.go")) {
  Copy-Item (Join-Path $SrcDir $file) (Join-Path $DestDir $file) -Force
}

Write-Host "==> Building herdr-ssh-bridge.exe"
$exePath = Join-Path $DestDir "herdr-ssh-bridge.exe"
$newExe = Join-Path $DestDir "herdr-ssh-bridge.new.exe"
if (Test-Path $newExe) { Remove-Item $newExe -Force }

$prevToolchain = $env:GOTOOLCHAIN
$goVerRaw = (& $goCmd.Source version) -join " "
if ($goVerRaw -match 'go1\.(\d+)' -and [int]$Matches[1] -ge 23) {
  # Avoid unnecessary Go toolchain downloads behind corporate VPNs/proxies
  $env:GOTOOLCHAIN = "local"
}
Push-Location $DestDir
try {
  & $goCmd.Source build -trimpath -ldflags="-s -w -H=windowsgui" -o $newExe . | Out-Host
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $newExe)) {
    throw "go build failed"
  }
} finally {
  Pop-Location
  $env:GOTOOLCHAIN = $prevToolchain
}

Stop-RunningBridge
Move-Item $newExe $exePath -Force
Write-Host "    $exePath"

$authFile = Join-Path $DestDir "authorized_keys"
if ($AuthorizedKey.Trim()) {
  $cleanKey = $AuthorizedKey.Trim()
  if ($cleanKey -notmatch '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp\d+)\s+\S+') {
    throw "AuthorizedKey does not look like a valid OpenSSH public key (expected 'ssh-ed25519 AAAA...')."
  }
  $lines = @()
  if (Test-Path $authFile) {
    $lines = @(Get-Content $authFile | Where-Object { $_ -and $_.Trim() })
  }
  if ($lines -notcontains $cleanKey) {
    $lines += $cleanKey
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($authFile, (($lines -join "`n") + "`n"), $utf8NoBom)
  Write-Host "    Authorized key saved to $authFile"
}
Lock-PrivateFile $authFile

$listenAddr = "127.0.0.1:$ListenPort"
$launchArgs = @()
if ($ListenPort -ne 2222) {
  $launchArgs += @("-listen", $listenAddr)
}
$runValue = "`"$exePath`""
if ($launchArgs.Count -gt 0) {
  $runValue = "$runValue $($launchArgs -join ' ')"
}

Write-Host "==> Registering logon startup & starting bridge"
Set-ItemProperty -Path $RunKey -Name $RunName -Value $runValue
if ($launchArgs.Count -gt 0) {
  Start-Process -WindowStyle Hidden -FilePath $exePath -ArgumentList $launchArgs
} else {
  Start-Process -WindowStyle Hidden -FilePath $exePath
}

$fpFile = Join-Path $DestDir "host_ed25519.fingerprint"
$privKey = Join-Path $DestDir "host_ed25519"
for ($i = 0; $i -lt 30 -and -not (Test-Path $fpFile); $i++) {
  Start-Sleep -Milliseconds 100
}
Lock-PrivateFile $privKey

$tsHost = "<your-tailscale-ip-or-magicdns>"
if (-not $SkipTailscale) {
  $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
  if (-not $tsCmd) {
    Write-Warning "tailscale CLI not found on PATH; skipped tailscale serve setup."
  } else {
    Write-Host "==> Configuring Tailscale Serve (tailnet-only TCP -> $listenAddr)"
    foreach ($port in $TailscalePorts) {
      & $tsCmd.Source serve --bg --tcp $port "tcp://$listenAddr" | Out-Host
    }
    try {
      $statusJson = (& $tsCmd.Source status --json) | ConvertFrom-Json
      $dns = ([string]$statusJson.Self.DNSName).TrimEnd(".")
      $ip = @($statusJson.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.' }) | Select-Object -First 1
      if ($ip -and $dns) { $tsHost = "$ip ($dns)" }
      elseif ($ip) { $tsHost = $ip }
      elseif ($dns) { $tsHost = $dns }
    } catch {}
  }
}

$homeAuth = Join-Path $env:USERPROFILE ".ssh\authorized_keys"
$hasAnyKey = ((Test-Path $authFile) -and (Get-Item $authFile).Length -gt 0) -or ((Test-Path $homeAuth) -and (Get-Item $homeAuth).Length -gt 0)
$fingerprint = if (Test-Path $fpFile) { (Get-Content $fpFile -Raw).Trim() } else { "(pending)" }

Write-Host ""
Write-Host "Done. Herdr SSH bridge is listening on $listenAddr."
Write-Host "  Host:             $tsHost"
Write-Host "  Port:             $($TailscalePorts[0])"
Write-Host "  Username:         $($env:USERNAME.ToLower())"
Write-Host "  Host fingerprint: $fingerprint"
if (-not $hasAnyKey) {
  Write-Warning "No SSH public keys found yet in $authFile or $homeAuth."
  Write-Host "Add your mobile device's public key with:"
  Write-Host "  .\ssh-bridge\install.ps1 -AuthorizedKey `"ssh-ed25519 AAAA... herdr-mobile`""
}
