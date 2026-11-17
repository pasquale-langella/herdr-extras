<#
.SYNOPSIS
  Sets the CPU priority class that Windows applies when coding agents / Herdr start.
.DESCRIPTION
  Uses Image File Execution Options (PerfOptions\CpuPriorityClass), so it applies however the
  program is launched. Run once from an elevated PowerShell; survives reboots.
  Default is Normal, which REMOVES any override (also cleans up earlier High installs).
  Avoid Realtime: it starves input/disk/audio threads and every child process inherits it.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1 -Priority AboveNormal
  powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1 -Priority High -IncludeNode
#>
#Requires -RunAsAdministrator
param(
  [ValidateSet('Normal','AboveNormal','High')] [string]$Priority = 'Normal',
  [switch]$IncludeNode   # node.exe is shared by many tools; only touched when requested (always cleaned on Normal)
)
$classes = @{ Normal = 2; AboveNormal = 6; High = 3 }
$exes = 'claude.exe','copilot.exe','cursor-herdr.exe','herdr-app.exe','herdr-core.exe','hc.exe'
if ($IncludeNode -or $Priority -eq 'Normal') { $exes += 'node.exe' }
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

foreach ($e in $exes) {
  $k = "$base\$e\PerfOptions"
  if ($Priority -eq 'Normal') {
    Remove-Item $k -Force -ErrorAction SilentlyContinue
    "$e -> Normal (override removed)"
  } else {
    New-Item $k -Force | Out-Null
    New-ItemProperty $k -Name CpuPriorityClass -PropertyType DWord -Value $classes[$Priority] -Force | Out-Null
    "$e -> $Priority"
  }
}
if ($Priority -eq 'Normal') {
  Unregister-ScheduledTask -TaskName AgentPriorityHigh -Confirm:$false -ErrorAction SilentlyContinue
}
"Done. Restart agents/Herdr; running processes keep their current priority."
