#!/usr/bin/env python3
"""Launch cursor-agent and inject OSC 7501 for Herdr (Windows).

Cursor hooks (status.js) write ~/.cursor/herdr-status/state-<HC_TERMINAL_ID>.txt.
This wrapper shares Herdr's console with cursor-agent (no nested ConPTY — that
broke typing) and writes OSC 7501 onto the same stdout stream Herdr reads.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

APP = "cursor"
DIR = Path.home() / ".cursor" / "herdr-status"


def state_file() -> Path:
    tid = os.environ.get("HC_TERMINAL_ID") or "unknown"
    return DIR / f"state-{tid}.txt"


def emit(state: str) -> None:
    seq = f"\x1b]7501;state={state}:app={APP}\x1b\\".encode()
    try:
        sys.stdout.buffer.write(seq)
        sys.stdout.buffer.flush()
    except Exception:
        pass


def watch_state(stop: threading.Event) -> None:
    last: str | None = None
    path = state_file()
    while not stop.is_set():
        try:
            if path.is_file():
                text = path.read_text(encoding="utf-8", errors="ignore").strip()
                if text and text != last:
                    last = text
                    emit(text)
        except Exception:
            pass
        stop.wait(0.15)


def find_cursor_agent() -> list[str]:
    """Resolve the real Cursor Agent CLI by absolute path (never via PATH).

    Prefer node + index.js in the latest versions\\* folder so we do not wrap
    an extra PowerShell layer around the agent.
    """
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "cursor-agent"
    versions = local / "versions"
    if versions.is_dir():
        dirs = [
            d
            for d in versions.iterdir()
            if d.is_dir() and (d / "index.js").is_file() and (d / "node.exe").is_file()
        ]
        # Names look like 2026.11.13-eacade1 — lexical sort is fine for YYYY.MM.DD-…
        dirs.sort(key=lambda d: d.name, reverse=True)
        if dirs:
            latest = dirs[0]
            return [str(latest / "node.exe"), str(latest / "index.js")]

    ps1 = local / "cursor-agent.ps1"
    if ps1.is_file():
        return [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ps1),
        ]
    cmd = local / "cursor-agent.cmd"
    if cmd.is_file():
        return [str(cmd)]
    raise FileNotFoundError(
        f"Cursor Agent CLI not found under {local} (expected versions/*/node.exe)"
    )


def main() -> int:
    if not os.environ.get("HC_TERMINAL_ID"):
        argv = find_cursor_agent() + sys.argv[1:]
        if os.name == "nt":
            raise SystemExit(subprocess.call(argv))
        os.execvp(argv[0], argv)

    DIR.mkdir(parents=True, exist_ok=True)
    state_file().write_text("idle\n", encoding="utf-8")
    emit("idle")

    argv = find_cursor_agent() + sys.argv[1:]
    env = os.environ.copy()
    env["CURSOR_HERDR_WRAPPED"] = "1"
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("COLORTERM", "truecolor")
    # Avoid the PATH shim re-entering this wrapper.
    bin_shim = str(Path(__file__).resolve().parent / "bin")
    path = env.get("PATH", "")
    if bin_shim:
        parts = [
            p
            for p in path.split(os.pathsep)
            if p and p.rstrip("\\/") != bin_shim.rstrip("\\/")
        ]
        env["PATH"] = os.pathsep.join(parts)

    stop = threading.Event()
    threading.Thread(target=watch_state, args=(stop,), daemon=True).start()

    # Inherit stdin/stdout/stderr from Herdr's ConPTY — no nested winpty.
    # Parent only injects OSC on stdout while the agent owns the console.
    try:
        proc = subprocess.Popen(argv, env=env, stdin=None, stdout=None, stderr=None)
        raise SystemExit(proc.wait())
    finally:
        stop.set()
        emit("clear")
        try:
            state_file().write_text("clear\n", encoding="utf-8")
        except Exception:
            pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
