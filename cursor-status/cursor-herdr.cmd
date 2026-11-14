@echo off
if exist "%~dp0cursor-herdr.exe" (
  "%~dp0cursor-herdr.exe" %*
) else (
  python -u "%~dp0cursor-herdr.py" %*
)
