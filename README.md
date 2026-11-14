# Herdr extras (Windows)

Two small add-ons for [Herdr](https://herdr.dev) on Windows:

1. **`pane-ids`** — pane headers show the terminal address (`t4`, `t10`, …)
2. **`cursor-status`** — Cursor Agent CLI appears in the Agents sidebar (OSC 7501)

Cursor Agent does not emit OSC 7501 itself. On Windows, Cursor hooks also cannot write into Herdr’s ConPTY. This package uses hooks to record state plus a thin launcher that shares Herdr’s console with Cursor and injects OSC 7501 onto the same stdout stream.

> Related: the macOS/Linux-only approach is [juliorr/herdr-cursor-status](https://github.com/juliorr/herdr-cursor-status).

## Requirements

- Herdr desktop (`herdr-app` + `hc`)
- Node.js (for Cursor hooks)
- Python 3 (real install under `%LOCALAPPDATA%\Programs\Python\…`, not only the Store alias)
- .NET Framework 4.x `csc.exe` (ships with Windows; used once to build `cursor-herdr.exe`)
- Cursor Agent CLI (`cursor-agent`)

## Install (PowerShell)

From this repo:

```powershell
.\install.ps1
```

That installs both add-ons, builds `~\.cursor\herdr-status\cursor-herdr.exe`, writes `programs.json` (UTF-8 **without** BOM), and prepends `~\.cursor\herdr-status\bin` on your User PATH.

After install, these report into the Agents pane and stay interactive:

- Herdr **Agents / New** → Cursor
- `herdr-app do tab.new --argv '["cursor-agent"]' --task "..."`
- `hc run --bg --name cursor cursor-agent "..."`
- Typing `cursor-agent` / `agent` in a Herdr shell

Confirm:

```powershell
herdr-app status   # errors should be empty (no programs.json BOM error)
where.exe cursor-agent
# first hit: ...\.cursor\herdr-status\bin\cursor-agent.cmd
hc ls
# expect agent=cursor and a status (idle/working/…)
```

Outside Herdr (no `HC_TERMINAL_ID`), the shim calls the real Cursor Agent CLI unchanged.

## Limits

- **No `blocked` state** — Cursor has no safe hook for approval waits.
- Restart Cursor sessions after installing hooks (hooks load at startup).
- A `cursor-agent` started by absolute path under `%LOCALAPPDATA%\cursor-agent\...` skips the PATH shim (Agents menu / `programs.json` still use the wrapper).
- `pane-ids` is a clone of Herdr’s shipped `pane` mod; re-clone after big Herdr upgrades if headers drift.

## Uninstall

```powershell
node "$env:USERPROFILE\.cursor\herdr-status\install-hooks.js" uninstall
$bin = "$env:USERPROFILE\.cursor\herdr-status\bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) {
  $next = ($userPath -split ";" | Where-Object { $_ -and $_.TrimEnd("\") -ne $bin.TrimEnd("\") }) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $next, "User")
}
Remove-Item "$env:USERPROFILE\.cursor\herdr-status" -Recurse -Force
Remove-Item "$env:USERPROFILE\.config\herdr-app\mods\pane-ids" -Recurse -Force
# If programs.json only had the cursor override, remove it; otherwise edit out programs.cursor.run
Remove-Item "$env:USERPROFILE\.config\herdr-app\programs.json" -ErrorAction SilentlyContinue
herdr-app do layout.switch --name main
```

## Layout

```
mods/pane-ids/              Herdr pane header mod (shows tN)
cursor-status/              Windows Cursor → OSC 7501 bridge
  status.js                 Cursor hooks → state file
  cursor-herdr.py           Shares console; injects OSC 7501
  cursor-herdr-launch.cs    Source for cursor-herdr.exe trampoline
  cursor-herdr.cmd          Convenience launcher
  bin/cursor-agent.cmd      PATH shim (Herdr → wrapper; else real CLI)
  bin/agent.cmd             Same for the `agent` alias
  install-hooks.js          Merge/remove ~/.cursor/hooks.json entries
install.ps1                 One-shot installer (builds .exe, programs.json, PATH)
```

## License

MIT
