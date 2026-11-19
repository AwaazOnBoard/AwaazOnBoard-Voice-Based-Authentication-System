@echo off
setlocal EnableExtensions EnableDelayedExpansion
title AwaazOnboard launcher
cd /d "%~dp0"

rem ==================================================================
rem  AwaazOnboard: starts the full demo on this computer
rem    PostgreSQL 15 (Docker)            localhost:5432
rem    Awaaz identity provider (FastAPI) http://localhost:8000
rem    FinSecure bank API (FastAPI)      http://localhost:8001
rem    Awaaz admin console (Next.js)     http://localhost:3000
rem    FinSecure bank UI (Next.js)       http://localhost:3001
rem  Double-click to start. Press any key in this window to stop.
rem  Requires: Docker Desktop running, Node.js, backend\venv.
rem ==================================================================

set "ROOT=%~dp0"
set "PY=%ROOT%backend\venv\Scripts\python.exe"
set "PG_NAME=awaaz-pg"
set "DATABASE_URL=postgresql://admin:secret@localhost:5432/awaazonboard"
set "AWAAZ_API_INTERNAL_URL=http://127.0.0.1:8000"
set "AWAAZ_API_URL=http://127.0.0.1:8000"

echo.
echo  AwaazOnboard demo launcher
echo  ==========================
echo.

rem ---- 0. Prerequisites ---------------------------------------------
if not exist "%PY%" (
  echo  [X] Python environment not found: backend\venv
  echo      Create it as described in README.md, then run this file again.
  goto :fail
)
where npm >nul 2>&1
if errorlevel 1 (
  echo  [X] Node.js is not installed or npm is not on PATH.
  goto :fail
)
if not exist "%ROOT%frontend\node_modules" (
  echo  Installing admin console packages, first run only...
  pushd "%ROOT%frontend" & call npm install & popd
)
if not exist "%ROOT%bank-frontend\node_modules" (
  echo  Installing bank UI packages, first run only...
  pushd "%ROOT%bank-frontend" & call npm install & popd
)
docker info >nul 2>&1
if errorlevel 1 (
  echo  [X] Docker Desktop is not running.
  echo      Start Docker Desktop, wait for "Engine running", then run this file again.
  goto :fail
)

rem ---- 1. PostgreSQL ------------------------------------------------
echo  [1/5] PostgreSQL
docker start %PG_NAME% >nul 2>&1
if errorlevel 1 (
  echo        creating container %PG_NAME%, first run only...
  docker run -d --name %PG_NAME% -p 5432:5432 -e POSTGRES_USER=admin -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=awaazonboard -v awaaz_pg:/var/lib/postgresql/data postgres:15-alpine >nul
  if errorlevel 1 (
    echo  [X] Could not start PostgreSQL. Port 5432 may be used by another PostgreSQL installation.
    goto :fail
  )
)
set /a n=0
:wait_pg
docker exec %PG_NAME% pg_isready -U admin -d awaazonboard >nul 2>&1
if not errorlevel 1 goto :pg_ready
set /a n+=1
if !n! geq 60 (
  echo  [X] PostgreSQL did not become ready within 60 seconds.
  goto :fail
)
timeout /t 1 /nobreak >nul
goto :wait_pg
:pg_ready
echo        ready on localhost:5432

rem ---- 2-5. Services, each in its own window -----------------------
set "CMD_AWAAZ="%PY%" -m uvicorn main:app --host 127.0.0.1 --port 8000"
set "CMD_BANK="%PY%" -m uvicorn bank_main:app --host 127.0.0.1 --port 8001"
set "CMD_CONSOLE=npm run dev -- -p 3000"
set "CMD_BANKUI=npm run dev -- -p 3001"
call :launch 8000 "Awaaz backend - port 8000" "%ROOT%backend"       CMD_AWAAZ   "[2/5] Awaaz identity provider"
call :launch 8001 "Bank backend - port 8001"  "%ROOT%bank-backend"  CMD_BANK    "[3/5] FinSecure bank API"
call :launch 3000 "Admin console - port 3000" "%ROOT%frontend"      CMD_CONSOLE "[4/5] Awaaz admin console"
call :launch 3001 "Bank UI - port 3001"       "%ROOT%bank-frontend" CMD_BANKUI  "[5/5] FinSecure bank UI"

rem ---- Wait for the identity provider and check its database --------
echo.
echo  Waiting for the identity provider to load its models.
echo  This takes one to three minutes; the first run ever can take longer.
set /a n=0
:wait_api
curl -s -o nul -w "%%{http_code}" http://127.0.0.1:8000/health 2>nul | findstr "200" >nul
if not errorlevel 1 goto :api_ready
set /a n+=1
if !n! geq 120 (
  echo  [!] The identity provider has not answered after 10 minutes.
  echo      Check the "Awaaz backend - port 8000" window for errors.
  goto :running
)
timeout /t 5 /nobreak >nul
goto :wait_api
:api_ready
echo        identity provider is up

set "PGCONN=0"
for /f %%c in ('docker exec %PG_NAME% psql -U admin -d awaazonboard -tAc "select count(*)-1 from pg_stat_activity where datname='awaazonboard'"') do set "PGCONN=%%c"
set "PGTABLES=0"
for /f %%c in ('docker exec %PG_NAME% psql -U admin -d awaazonboard -tAc "select count(*) from information_schema.tables where table_schema='public'"') do set "PGTABLES=%%c"
echo.
if !PGCONN! gtr 0 (
  echo  [OK] Identity provider is connected to PostgreSQL: !PGCONN! open connections, !PGTABLES! tables.
) else (
  echo  [!] The identity provider is NOT connected to PostgreSQL.
  echo      It has fallen back to a temporary in-memory database; enrolments will be lost on exit.
  echo      Check the "Awaaz backend - port 8000" window for the reason.
)

:running
start "" http://localhost:3001
start "" http://localhost:3000
echo.
echo  ------------------------------------------------------------
echo   FinSecure bank UI    http://localhost:3001
echo   Awaaz admin console  http://localhost:3000
echo   Awaaz API docs       http://localhost:8000/docs
echo  ------------------------------------------------------------
echo.
echo  Leave this window open during the demo.
echo  Press any key here to stop all services.
pause >nul

rem ---- Stop everything ----------------------------------------------
echo  Stopping services...
for %%p in (8000 8001 3000 3001) do call :kill_port %%p
for %%t in ("Awaaz backend - port 8000" "Bank backend - port 8001" "Admin console - port 3000" "Bank UI - port 3001") do taskkill /FI "WINDOWTITLE eq %%~t*" /T /F >nul 2>&1
docker stop %PG_NAME% >nul 2>&1
echo  Stopped. Enrolments are kept in the PostgreSQL volume for next time.
timeout /t 3 /nobreak >nul
exit /b 0

rem ==================================================================
:launch
rem %1 port, %2 window title, %3 folder, %4 command, %5 label
netstat -ano | findstr /R /C:":%~1 .*LISTENING" >nul
if not errorlevel 1 (
  echo  %~5: already running on port %~1, left as is
  exit /b 0
)
echo  %~5: starting on port %~1
start "%~2" /D "%~3" cmd /k "!%~4!"
exit /b 0

:kill_port
for /f "tokens=5" %%i in ('netstat -ano ^| findstr /R /C:":%~1 .*LISTENING"') do taskkill /PID %%i /T /F >nul 2>&1
exit /b 0

:fail
echo.
echo  The demo was not started. Press any key to close.
pause >nul
exit /b 1
