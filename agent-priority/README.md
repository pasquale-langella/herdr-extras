# agent-priority

Controls the CPU priority Windows gives coding agents (`claude`, `copilot`, Cursor agent) and Herdr
(`herdr-app`, `herdr-core`, `hc`, `cursor-herdr`) at launch. Admin needed once; persists across reboots.

```powershell
# elevated PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1                       # Normal (default, resets)
powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1 -Priority AboveNormal # mild boost
powershell -NoProfile -ExecutionPolicy Bypass -File .\set-agent-priority.ps1 -Priority High -IncludeNode
```

**Why Normal is the default:** High/Realtime on many long-running agent processes (every child inherits it)
makes the laptop unresponsive. If you want a boost, `AboveNormal` is the safe choice. Never use Realtime.

`-IncludeNode` also applies to every `node.exe` on the machine (Playwright MCP, Cursor agent, ...).
Check with: `Get-Process claude,copilot,herdr-core | select Name,PriorityClass`
