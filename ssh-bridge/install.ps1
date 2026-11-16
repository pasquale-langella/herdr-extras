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
$TaskName = "HerdrSshBridge"

function Stop-RunningBridge {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $procs = @(Get-Process -Name "herdr-ssh-bridge" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { break }
    foreach ($p in $procs) {
      Stop-Process -Id ([int]$p.Id) -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 250
  }
}

function Wait-TcpPort([int]$Port, [int]$TimeoutSeconds = 240) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
      $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(250) -and $client.Connected) {
        $client.EndConnect($iar)
        return $true
      }
    } catch {
    } finally {
      $client.Close()
    }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Lock-PrivateFile([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls $Path /inheritance:r /grant:r "*$($sid):(F)" "*S-1-5-18:(F)" | Out-Null
}

if ($Uninstall) {
  Write-Host "==> Stopping herdr-ssh-bridge"
  Stop-RunningBridge
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
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
$hashFile = Join-Path $DestDir ".source-sha256"
$srcConcat = (@("go.mod", "go.sum", "main.go") | ForEach-Object { (Get-FileHash (Join-Path $DestDir $_) -Algorithm SHA256).Hash }) -join ":"
$prevHash = if (Test-Path $hashFile) { (Get-Content $hashFile -Raw).Trim() } else { "" }

if ((Test-Path $exePath) -and ($prevHash -eq $srcConcat)) {
  Write-Host "    $exePath (up to date, skipping rebuild)"
} else {
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
  for ($i = 0; $i -lt 20; $i++) {
    try {
      if (Test-Path $exePath) { Remove-Item $exePath -Force -ErrorAction Stop }
      Move-Item $newExe $exePath -Force -ErrorAction Stop
      break
    } catch {
      if ($i -eq 19) { throw }
      Stop-RunningBridge
      Start-Sleep -Milliseconds 250
    }
  }
  Set-Content -Path $hashFile -Value $srcConcat -Encoding ascii
  Write-Host "    $exePath"
}

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
$startedViaTask = $false
try {
  $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  if ($launchArgs.Count -gt 0) {
    $action = New-ScheduledTaskAction -Execute $exePath -Argument ($launchArgs -join " ") -WorkingDirectory $DestDir
  } else {
    $action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $DestDir
  }
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
  $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
  Start-ScheduledTask -TaskName $TaskName
  $startedViaTask = $true
  Write-Host "    Scheduled Task: $TaskName (logon + auto-restart, outside terminal Job Objects)"
} catch {
  Write-Warning "Task Scheduler registration failed ($($_.Exception.Message)); falling back to HKCU Run."
  Set-ItemProperty -Path $RunKey -Name $RunName -Value $runValue
  if ($launchArgs.Count -gt 0) {
    Start-Process -WindowStyle Hidden -FilePath $exePath -ArgumentList $launchArgs
  } else {
    Start-Process -WindowStyle Hidden -FilePath $exePath
  }
}

if (-not (Wait-TcpPort -Port $ListenPort -TimeoutSeconds 240)) {
  throw "herdr-ssh-bridge did not start listening on $listenAddr within 240s (startedViaTask=$startedViaTask)."
}

$fpFile = Join-Path $DestDir "host_ed25519.fingerprint"
$privKey = Join-Path $DestDir "host_ed25519"
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
