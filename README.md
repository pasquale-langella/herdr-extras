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
node "$dest\install-hooks.js"
```

Launch Cursor **through the wrapper** (not bare `cursor-agent`):

```powershell
herdr-app do terminal.open --place right --name cursor --folder "$PWD" `
  --argv "[`"python`",`"$env:USERPROFILE\.cursor\herdr-status\cursor-herdr.py`",`"--trust`"]"
```

Confirm:

```powershell
hc ls
# expect app=cursor and a status (idle/working/…)
```

## Limits

- **No `blocked` state** — Cursor has no safe hook for approval waits.
- Restart Cursor sessions after installing hooks (hooks load at startup).
- This pane only reports status when started via `cursor-herdr.py`.
- `pane-ids` is a clone of Herdr’s shipped `pane` mod; re-clone after big Herdr upgrades if headers drift.

## Uninstall

```powershell
node "$env:USERPROFILE\.cursor\herdr-status\install-hooks.js" uninstall
Remove-Item "$env:USERPROFILE\.cursor\herdr-status" -Recurse -Force
Remove-Item "$env:USERPROFILE\.config\herdr-app\mods\pane-ids" -Recurse -Force
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
install.ps1             One-shot installer
```

## License

MIT
