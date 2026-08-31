@echo off
setlocal
cd /d "%~dp0"
echo ==================================================
echo   Proxies.sx Peer for Windows  -  Setup
echo ==================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo  [X] Node.js is not installed.
  echo      1. Download the "LTS" installer from https://nodejs.org
  echo      2. Install it ^(accept the defaults^)
  echo      3. Run this setup.bat again
  echo.
  pause
  exit /b 1
)

for /f "tokens=*" %%v in ('node -v') do set NODEV=%%v
echo  [OK] Node.js %NODEV% found.
echo.

echo  Installing dependencies ^(runs once, needs internet^)...
call npm install --omit=dev --no-audit --no-fund
if errorlevel 1 (
  echo  [X] npm install failed. Check your internet connection and retry.
  pause
  exit /b 1
)
echo  [OK] Dependencies installed.
echo.

if not exist "config.json" (
  copy /y "config.example.json" "config.json" >nul
  echo  [OK] Created config.json from the template.
) else (
  echo  [OK] config.json already exists - leaving it untouched.
)
echo.
echo ==================================================
echo   NEXT STEPS
echo   1. Open config.json with Notepad.
echo   2. Set "apiKey" to your psx_ key from
echo      https://client.proxies.sx/account  (API Keys).
echo   3. Save it, then double-click start.bat to begin.
echo ==================================================
echo.
pause
