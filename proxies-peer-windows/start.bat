@echo off
setlocal
cd /d "%~dp0"
title Proxies.sx Peer

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js not found. Run setup.bat first.
  pause
  exit /b 1
)
if not exist "node_modules\ws" (
  echo Dependencies are missing. Run setup.bat first.
  pause
  exit /b 1
)
if not exist "config.json" (
  echo config.json is missing. Run setup.bat first.
  pause
  exit /b 1
)

:loop
echo.
echo [%date% %time%] Starting Proxies.sx peer...
node peer.js
echo.
echo [%date% %time%] Peer stopped (exit code %errorlevel%). Restarting in 10s...
echo Close this window to stop sharing completely.
timeout /t 10 /nobreak >nul
goto loop
