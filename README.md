# Herdr extras (Windows)

Four add-ons for [Herdr](https://herdr.dev) on Windows:

1. **`pane-ids`** — pane headers show the terminal address (`t4`, `t10`, …)
2. **`cursor-status`** — Cursor Agent CLI appears in the Agents sidebar (OSC 7501)
3. **`session-resume`** — after herdr-core restarts, reopen the chat that was in each tab
4. **`ssh-bridge`** *(opt-in)* — connect Herdr Mobile / remote `hc` over Tailscale on Entra ID (`AzureAD\…`) and corporate Windows machines

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

That installs the add-ons, builds `~\.cursor\herdr-status\cursor-herdr.exe`, writes `programs.json` (UTF-8 **without** BOM), prepends `~\.cursor\herdr-status\bin` on your User PATH, and starts the session-resume watcher from `~\.config\herdr-extras\session-resume`.

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

`install.ps1` copies this watcher on its own (not inside the Cursor status bridge), adds `HerdrSessionResume` to your user logon startup (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), and starts it. Cursor hooks drop the conversation id in `~\.config\herdr-extras\session-resume\inbox`. It has to see a chat once before a restart; the panes that were already PowerShell when you installed it are not rebuilt.

## Mobile / Tailscale SSH bridge (opt-in)

Connecting Herdr Mobile (or another machine's `hc`) to a Windows laptop often fails for three OS/corporate reasons:

1. **Entra ID (`AzureAD\…`) OpenSSH bug** — Windows `sshd` running as `SYSTEM` fails S4U token creation (`sshd: fatal: ga_init, unable to resolve user azuread\…`).
2. **Inbound firewall / VPN locks** — corporate firewalls and GlobalProtect block inbound SSH ports unless configured with admin rights, and mobile clients invoke POSIX `sh -c '… exec "$p" connect'` wrappers that `cmd.exe` rejects.
3. **Endpoint AV `CreateProcess` stalls** — spawning `hc.exe` per SSH channel can stall 30s+ under Windows Defender / endpoint scanning, tripping mobile `hello` timeouts.

`ssh-bridge` runs a zero-elevation Go SSH server as your logged-in Windows user on `127.0.0.1:2222`, speaks Ed25519 public-key auth only, whitelists `herdr-core` `connect` / `--version` (direct, `sh -c`, and `cmd /d /c`), connects directly in-process to `\\.\pipe\herdr-core-<user>-<session>.sock` using overlapped Named Pipe I/O (starting `hc server start` automatically if needed), and exposes port `22` exclusively to your tailnet via `tailscale serve`.

Requires [Go 1.23+](https://go.dev/dl/) and [Tailscale](https://tailscale.com/). Install with your phone's SSH public key:

```powershell
.\ssh-bridge\install.ps1 -AuthorizedKey "ssh-ed25519 AAAA... herdr-mobile"
```

Or alongside the full installer:

```powershell
.\install.ps1 -WithSshBridge -SshAuthorizedKey "ssh-ed25519 AAAA... herdr-mobile"
```

On Herdr Mobile, connect to your laptop's Tailscale IP (or MagicDNS name), port `22`, and trust the printed host key fingerprint on first connect (TOFU). Keys and logs stay strictly local in `~\.config\herdr-extras\herdr-ssh-bridge`.

Uninstall the SSH bridge at any time:

```powershell
.\ssh-bridge\install.ps1 -Uninstall
```

## Limits

- **Prompt bar contrast** — inside Herdr, the launcher sets `TERM_THEME` from `settings.json` `appearance` (or the Windows app theme when that is unset) so Cursor does not paint a black input row on a light terminal. A `TERM_THEME` already in the environment is left alone. Restart the Cursor tab after changing appearance.
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
Remove-Item "$env:USERPROFILE\.config\herdr-extras\session-resume" -Recurse -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "HerdrSessionResume" -ErrorAction SilentlyContinue
.\ssh-bridge\install.ps1 -Uninstall
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
session-resume/             After a core restart, resume the chat that was in the tab
  logic.js                  Shell-vs-agent decisions and session matching
  watch.js                  Polls `hc` and types the resume command
  run.ps1                   Logon entrypoint
ssh-bridge/                 Opt-in Tailscale / mobile SSH → named-pipe bridge
  main.go                   User-mode SSH server + overlapped named-pipe proxy
  go.mod / go.sum           Go module (golang.org/x/crypto/ssh, golang.org/x/sys)
  install.ps1               Builds .exe, registers self-healing Scheduled Task + tailscale serve (-Uninstall to remove)
install.ps1                 One-shot installer (builds .exe, programs.json, PATH, logon startup)
```

## License

MIT
