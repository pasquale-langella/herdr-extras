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

## Same chat after a restart

Herdr keeps the tabs, then puts PowerShell back in a pane when `herdr-core` itself stops (reboot, logoff, or the core process ending). It does not relaunch the agent. `session-resume` does that part:

1. While an agent is open, the watcher remembers the terminal, the tab, the folder, and the chat id.
2. Cursor's id comes from the existing hooks (`conversation_id`). Claude's id comes from `~\.claude\projects`. Copilot's id comes from `~\.copilot\session-store.db`.
3. The next time the core is running and that pane is an untouched PowerShell (the recovery shell), the watcher types one resume command into it:
   - Cursor: `cursor-herdr.exe --resume <chat>`
   - Claude: `claude --resume <session>`
   - Copilot: `copilot --resume <session>`

The saved conversation comes back. The old terminal scrollback does not. A shell you have already typed in (more than a few commands) is left alone. Two recovery shells in the same tab are matched by pane when Herdr kept the pane id, and left alone when that is ambiguous.

`install.ps1` adds `HerdrSessionResume` to your user logon startup (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) and starts the watcher. It has to see a chat once before a restart; the panes that were already PowerShell when you installed it are not rebuilt.

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
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "HerdrSessionResume" -ErrorAction SilentlyContinue
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
  session-resume/           After a core restart, resume the chat that was in the tab
    logic.js                Shell-vs-agent decisions and session matching
    watch.js                Polls `hc` and types the resume command
    run.ps1                 Logon entrypoint
install.ps1                 One-shot installer (builds .exe, programs.json, PATH, logon startup)
```

## License

MIT
