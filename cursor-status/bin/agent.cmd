@echo off
setlocal
rem Same as cursor-agent.cmd: Cursor also ships an `agent` launcher.
if defined HC_TERMINAL_ID if not defined CURSOR_HERDR_WRAPPED (
  set "CURSOR_HERDR_WRAPPED=1"
  if exist "%~dp0..\cursor-herdr.exe" (
    "%~dp0..\cursor-herdr.exe" %*
    exit /b %ERRORLEVEL%
  )
  python -u "%~dp0..\cursor-herdr.py" %*
  exit /b %ERRORLEVEL%
)

if exist "%LOCALAPPDATA%\cursor-agent\agent.cmd" (
  call "%LOCALAPPDATA%\cursor-agent\agent.cmd" %*
  exit /b %ERRORLEVEL%
)
if exist "%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd" (
  call "%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd" %*
  exit /b %ERRORLEVEL%
)

echo agent: Cursor Agent CLI not found under %%LOCALAPPDATA%%\cursor-agent\ 1>&2
exit /b 1
