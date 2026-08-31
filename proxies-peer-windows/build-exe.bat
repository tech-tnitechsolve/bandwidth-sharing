@echo off
setlocal
cd /d "%~dp0"
echo ==================================================
echo   Build a standalone proxies-peer.exe
echo   (the .exe runs WITHOUT Node.js installed)
echo ==================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo  [X] Node.js is needed to BUILD the exe (not to run it).
  echo      Install it from https://nodejs.org and retry.
  pause
  exit /b 1
)

echo  Installing dependencies...
call npm install --no-audit --no-fund
echo.
echo  Packaging (downloads the Node runtime once, ~40 MB)...
call npx --yes pkg . --targets node18-win-x64 --output build\proxies-peer.exe
if errorlevel 1 (
  echo  [X] Build failed.
  pause
  exit /b 1
)
echo.
echo  [OK] Built build\proxies-peer.exe
echo  Copy proxies-peer.exe and config.json into the same folder, then
echo  double-click proxies-peer.exe to run it on any Windows machine.
echo.
pause
