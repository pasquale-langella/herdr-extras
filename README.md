# Herdr extras (Windows)

Two small add-ons for [Herdr](https://herdr.dev) on Windows:

1. **`pane-ids`** — pane headers show the terminal address (`t4`, `t10`, …)
2. **`cursor-status`** — Cursor Agent CLI appears in the Agents sidebar (OSC 7501)

Cursor Agent does not emit OSC 7501 itself. On Windows, Cursor hooks also cannot write into Herdr’s ConPTY. This package uses hooks to record state plus a small ConPTY wrapper that injects OSC 7501 into the stream Herdr reads.

> Related: the macOS/Linux-only approach is [juliorr/herdr-cursor-status](https://github.com/juliorr/herdr-cursor-status).

## Requirements

- Herdr desktop (`herdr-app` + `hc`)
- Node.js (for Cursor hooks)
- Python 3 + [`pywinpty`](https://pypi.org/project/pywinpty/) (for the Cursor wrapper)
- Cursor Agent CLI (`cursor-agent`)

## Install (PowerShell)

From this repo:

```powershell
.\install.ps1
```

That installs both add-ons and writes `~/.config/herdr-app/programs.json` so Herdr’s **Cursor** Agents / New-menu entry launches the OSC wrapper. After install, starting Cursor from that menu should show it in the Agents pane.

Or step by step:

### 1. Terminal ids in pane headers

```powershell
$mod = "$env:USERPROFILE\.config\herdr-app\mods\pane-ids"
New-Item -ItemType Directory -Force -Path $mod | Out-Null
Copy-Item .\mods\pane-ids\* $mod -Force

herdr-app do layout.clone --name main --as main-ids
# point the pane header at pane-ids (if the clone still says "pane"):
$layout = "$env:USERPROFILE\.config\herdr-app\layouts\main-ids.json"
(Get-Content $layout -Raw) -replace '"mod": "pane"','"mod": "pane-ids"' | Set-Content $layout -NoNewline
herdr-app do layout.switch --name main-ids
herdr-app check $mod
```

### 2. Cursor in the Agents pane

```powershell
pip install pywinpty
$dest = "$env:USERPROFILE\.cursor\herdr-status"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item .\cursor-status\* $dest -Force
node "$dest\install-hooks.js" install
```

Point Herdr’s Cursor menu at the wrapper (merge into existing `programs.json` if you already have one):

```powershell
$py = (Get-Command python).Source
$wrapper = "$env:USERPROFILE\.cursor\herdr-status\cursor-herdr.py"
$programsPath = "$env:USERPROFILE\.config\herdr-app\programs.json"
@{
  programs = @{
    cursor = @{
      run = @($py, $wrapper)
      match = @("cursor-agent", "cursor-herdr.py")
    }
  }
} | ConvertTo-Json -Depth 6 | Set-Content $programsPath -Encoding utf8
```

**Agents-menu starts** then go through `cursor-herdr.py` automatically. Manual launch (same argv):

```powershell
herdr-app do terminal.open --place right --name cursor --folder "$PWD" `
  --argv "[`"$((Get-Command python).Source)`",`"$env:USERPROFILE\.cursor\herdr-status\cursor-herdr.py`"]"
```

Confirm:

```powershell
hc ls
# expect agent=cursor and a status (idle/working/…)
```

Bare `cursor-agent` (without the wrapper) still will not appear in Agents.

## Limits

- **No `blocked` state** — Cursor has no safe hook for approval waits.
- Restart Cursor sessions after installing hooks (hooks load at startup).
- Status only reports when the session was started via `cursor-herdr.py` (Agents menu after install, or the argv above).
- `pane-ids` is a clone of Herdr’s shipped `pane` mod; re-clone after big Herdr upgrades if headers drift.

## Uninstall

```powershell
node "$env:USERPROFILE\.cursor\herdr-status\install-hooks.js" uninstall
Remove-Item "$env:USERPROFILE\.cursor\herdr-status" -Recurse -Force
Remove-Item "$env:USERPROFILE\.config\herdr-app\mods\pane-ids" -Recurse -Force
# If programs.json only had the cursor override, remove it; otherwise edit out programs.cursor.run
Remove-Item "$env:USERPROFILE\.config\herdr-app\programs.json" -ErrorAction SilentlyContinue
herdr-app do layout.switch --name main
```

## Layout

```
mods/pane-ids/          Herdr pane header mod (shows tN)
cursor-status/          Windows Cursor → OSC 7501 bridge
  status.js             Cursor hooks → state file
  cursor-herdr.py       ConPTY wrapper that emits OSC 7501
  cursor-herdr.cmd      Convenience launcher
  install-hooks.js      Merge/remove ~/.cursor/hooks.json entries
install.ps1             One-shot installer (also writes programs.json)
```

## License

MIT
