@echo off
setlocal
rem PATH shim: inside Herdr, route cursor-agent through the OSC 7501 wrapper
rem so the session appears in the Agents pane. Outside Herdr (or already
rem wrapped), run the real Cursor Agent CLI by absolute path.

if defined HC_TERMINAL_ID if not defined CURSOR_HERDR_WRAPPED (
  set "CURSOR_HERDR_WRAPPED=1"
  if exist "%~dp0..\cursor-herdr.exe" (
    "%~dp0..\cursor-herdr.exe" %*
    exit /b %ERRORLEVEL%
  )
  python -u "%~dp0..\cursor-herdr.py" %*
  exit /b %ERRORLEVEL%
)

if exist "%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd" (
  call "%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd" %*
  exit /b %ERRORLEVEL%
)

echo cursor-agent: not found under %%LOCALAPPDATA%%\cursor-agent\ 1>&2
exit /b 1
