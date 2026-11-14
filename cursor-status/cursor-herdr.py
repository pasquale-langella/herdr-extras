#!/usr/bin/env python3
"""Launch cursor-agent under a ConPTY and inject OSC 7501 for Herdr.

Cursor hooks (status.js) write ~/.cursor/herdr-status/state-<HC_TERMINAL_ID>.txt.
This wrapper polls that file and emits OSC 7501 on its own stdout, which is the
stream Herdr reads — hooks cannot reach the ConPTY on Windows themselves.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

from winpty import PtyProcess

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
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "cursor-agent"
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
    return ["cursor-agent"]


def pump_stdin(proc: PtyProcess, stop: threading.Event) -> None:
    try:
        while not stop.is_set() and proc.isalive():
            data = sys.stdin.buffer.read(1024)
            if not data:
                break
            proc.write(data.decode("utf-8", errors="ignore"))
    except Exception:
        pass


def main() -> int:
    if not os.environ.get("HC_TERMINAL_ID"):
        os.execvp("cursor-agent", ["cursor-agent", *sys.argv[1:]])

    DIR.mkdir(parents=True, exist_ok=True)
    state_file().write_text("idle\n", encoding="utf-8")
    emit("idle")

    cols, rows = 120, 40
    try:
        size = os.get_terminal_size()
        cols, rows = size.columns, size.lines
    except OSError:
        pass

    argv = find_cursor_agent() + sys.argv[1:]
    cmdline = subprocess.list2cmdline(argv)
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("COLORTERM", "truecolor")

    proc = PtyProcess.spawn(cmdline, dimensions=(rows, cols), env=env)

    stop = threading.Event()
    threading.Thread(target=watch_state, args=(stop,), daemon=True).start()
    threading.Thread(target=pump_stdin, args=(proc, stop), daemon=True).start()

    try:
        while proc.isalive():
            try:
                chunk = proc.read(4096)
            except EOFError:
                break
            if not chunk:
                time.sleep(0.01)
                continue
            if isinstance(chunk, str):
                chunk = chunk.encode("utf-8", errors="ignore")
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    finally:
        stop.set()
        emit("clear")
        try:
            state_file().write_text("clear\n", encoding="utf-8")
        except Exception:
            pass

    return int(proc.exitstatus or 0)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
