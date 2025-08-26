@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM =========================================================
REM  install_DDNS.bat – Self-Update + DynDNS Service Manager
REM  (C) 2025 Joerg Wannemacher
REM =========================================================

REM =================== Self-Update Konfiguration ===================
set "InstallerVersion=1.0.1"
set "VersionUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.version"
set "ScriptUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.bat"

REM =================== Self-Update Temp/Pfade/Logs =================
set "SelfPath=%~f0"
set "SelfName=%~nx0"
set "TmpVer=%TEMP%\%SelfName%.ver"
set "TmpNew=%TEMP%\%SelfName%.new"
set "RestartFlag=%TEMP%\%SelfName%.restarted"
set "Updater=%TEMP%\%SelfName%_upd.cmd"
set "SU_Log=%TEMP%\install_ddns_update.log"

REM ===== Self-Update: Restart nach Update? -> Skip Self-Update einmalig
if exist "%RestartFlag%" (
  del /q "%RestartFlag%" >nul 2>&1
  >>"%SU_Log%" echo [%date% %time%] RESTART_SKIP
  goto :AFTER_SELFUPDATE
)

REM ===== Self-Update: Downloader ermitteln (certutil -> curl -> bitsadmin)
set "DL="
where certutil >nul 2>&1 && set "DL=cert"
if not defined DL where curl >nul 2>&1 && set "DL=curl"
if not defined DL where bitsadmin >nul 2>&1 && set "DL=bits"

if not defined DL (
  >>"%SU_Log%" echo [%date% %time%] ERR_NO_DOWNLOADER
  goto :AFTER_SELFUPDATE
)

REM ===== Self-Update: Remote-Version holen
del /q "%TmpVer%" "%TmpNew%" "%Updater%" >nul 2>&1
call :SU_DOWNLOAD "%VersionUrl%" "%TmpVer%" "%DL%"
if not exist "%TmpVer%" (
  >>"%SU_Log%" echo [%date% %time%] WARN_VER_FETCH_FAIL
  goto :AFTER_SELFUPDATE
)

set "RemoteVersion="
for /f "usebackq delims=" %%L in ("%TmpVer%") do if not defined RemoteVersion set "RemoteVersion=%%L"
del /q "%TmpVer%" >nul 2>&1

for /f "tokens=* delims= " %%A in ("%RemoteVersion%") do set "RemoteVersion=%%A"
set "RemoteVersion=%RemoteVersion: =%"

if not defined RemoteVersion (
  >>"%SU_Log%" echo [%date% %time%] WARN_VER_EMPTY
  goto :AFTER_SELFUPDATE
)
>>"%SU_Log%" echo [%date% %time%] REMOTE=%RemoteVersion% LOCAL=%InstallerVersion%

REM ===== Self-Update: Versionen vergleichen
set "RESULT="
call :SU_VERCMP "%InstallerVersion%" "%RemoteVersion%" RESULT
if not defined RESULT (
  >>"%SU_Log%" echo [%date% %time%] WARN_CMP_FAIL
  goto :AFTER_SELFUPDATE
)

if "%RESULT%"=="1" (
  >>"%SU_Log%" echo [%date% %time%] UPDATE_AVAILABLE
  call :SU_DOWNLOAD "%ScriptUrl%" "%TmpNew%" "%DL%"
  if not exist "%TmpNew%" (
    >>"%SU_Log%" echo [%date% %time%] ERR_DL_FAIL
    goto :AFTER_SELFUPDATE
  )
  for %%S in ("%TmpNew%") do set "DL_SIZE=%%~zS"
  >>"%SU_Log%" echo [%date% %time%] DL_OK size=%DL_SIZE%

  >"%RestartFlag%" echo restarted

  call :SU_WRITE_UPDATER "%Updater%" "%SelfPath%" "%TmpNew%" "%RestartFlag%" "%SU_Log%"
  start "" "%Updater%"
  >>"%SU_Log%" echo [%date% %time%] UPDATER_STARTED %Updater%
  goto :EOF
)

REM ===== (kein Update oder lokal neuer) -> Normal weiter
:AFTER_SELFUPDATE

REM =========================================================
REM  DynDNS-Update Service Manager (dein Script)
REM =========================================================

echo(
echo ========================================
echo  DynDNS-Update Service Manager gestartet
echo ========================================

@echo off
setlocal EnableExtensions

:: ===============================================
:: DynDNS-Update Service Manager Batch Script
:: (C) 2025 Joerg Wannemacher. Alle Rechte vorbehalten.
:: Nutzung und Weitergabe nur mit Erlaubnis des Autors.
:: ===============================================

:: Installationsort
set "Maindir=C:\SYS\DynDNS"
set "Settingsdir=%Maindir%\Settings"
set "Logdir=%Maindir%\Logs"
set "Script=%Maindir%\Script\DynDNS-Update.ps1"
set "Toolsdir=%Maindir%\Tools"
set "PsExec=%Toolsdir%\PsExec64.exe"
set "NSSM=%Toolsdir%\nssm.exe"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "Service=DynDNS-Update"

:: Adminrechte pruefen (mit PS; Fallback via mshta falls PS fehlt)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Starte Skript mit Administratorrechten neu...
    if exist "%PS%" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    ) else (
        mshta "vbscript:Execute(""CreateObject("" + Chr(34) + ""Shell.Application"" + Chr(34) + "").ShellExecute "" + Chr(34) + ""%~f0"" + Chr(34) + "", "" "", """", ""runas"", 1 :close"")"
    )
    exit /b
)

:: Tools und Script pruefen
if not exist "%PsExec%" (
    echo [FEHLER] PsExec wurde nicht gefunden unter: %PsExec%
    echo Bitte installieren Sie PsExec im Tools-Verzeichnis.
    pause
    exit /b 1
)
if not exist "%NSSM%" (
    echo [FEHLER] NSSM wurde nicht gefunden unter: %NSSM%
    echo Bitte installieren Sie NSSM im Tools-Verzeichnis.
    pause
    exit /b 1
)
if not exist "%Script%" (
    echo [FEHLER] PowerShell-Script nicht gefunden: %Script%
    echo Bitte stellen Sie sicher, dass das DynDNS-Update.ps1 Script vorhanden ist.
    pause
    exit /b 1
)

:: Ordnererstellung
if not exist "%Settingsdir%" mkdir "%Settingsdir%"
if not exist "%Logdir%" mkdir "%Logdir%"

:: EULA fuer psexec automatisch akzeptieren
"%PsExec%" /accepteula >nul 2>&1

:: Dienststatus-Variable initialisieren
set "DienstExistiert=0"

:: Pruefen, ob Dienst existiert
sc query "%Service%" | find /I "SERVICE_NAME" >nul 2>&1
if %errorlevel%==0 set "DienstExistiert=1"

:SM_MENU
cls
echo ========================================
echo      DynDNS-Update Service Manager V1.0.1
echo ========================================

if "%DienstExistiert%"=="1" goto SM_DIENST_EXISTIERT
goto SM_DIENST_NICHT_EXISTIERT

:SM_DIENST_EXISTIERT
echo Der Dienst "%Service%" ist bereits installiert.
echo(
echo Was moechten Sie tun?
echo [N]eu installieren
echo [L]oeschen
echo [S]tatus pruefen
echo [A]bbrechen
set "Wahl="
set /p "Wahl=Bitte Auswahl eingeben (N/L/S/A): "
if /I "%Wahl%"=="N" goto SM_NEUINSTALL
if /I "%Wahl%"=="L" goto SM_LOESCHEN
if /I "%Wahl%"=="S" goto SM_STATUS
if /I "%Wahl%"=="A" goto SM_ENDE
goto SM_MENU

:SM_DIENST_NICHT_EXISTIERT
echo --- Dienst NICHT installiert ---
echo [I]nstallieren
echo [A]bbrechen
set "Wahl="
set /p "Wahl=Bitte Auswahl eingeben (I/A): "
if /I "%Wahl%"=="I" goto SM_NEUINSTALL
if /I "%Wahl%"=="A" goto SM_ENDE
goto SM_MENU

:SM_NEUINSTALL
echo(
echo Pruefe auf alte TXT/LOG-Dateien in %Maindir% ...
if exist "%Settingsdir%\*.txt" (
    del /q "%Settingsdir%\*.*"
    if %errorlevel%==0 (
        echo Alle TXT-Dateien wurden geloescht.
    ) else (
        echo [WARNUNG] Fehler beim Loeschen der TXT-Dateien.
    )
) else (
    echo Keine TXT-Dateien gefunden.
)
if exist "%Logdir%\*.log" (
    del /q "%Logdir%\*.*"
    if %errorlevel%==0 (
        echo Alle LOG-Dateien wurden geloescht.
    ) else (
        echo [WARNUNG] Fehler beim Loeschen der LOG-Dateien.
    )
) else (
    echo Keine LOG-Dateien gefunden.
)
echo(
echo Starte PowerShell via PsExec...
"%PsExec%" -i -s "%PS%" -ExecutionPolicy Bypass -NoProfile -File "%Script%"
set "PsExecResult=%errorlevel%"
echo PsExec beendet mit Fehlerlevel: %PsExecResult%
if %PsExecResult% neq 0 (
    echo [WARNUNG] PsExec wurde mit Fehler beendet. Installation wird fortgesetzt...
)

echo Installiere/ersetze Dienst...
"%NSSM%" stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm >nul 2>&1

"%NSSM%" install %Service% "%PS%" -ExecutionPolicy Bypass -File "%Script%"
if %errorlevel% neq 0 (
    echo [FEHLER] Service-Installation mit NSSM fehlgeschlagen!
    pause
    exit /b 1
)

:: Service-Konfiguration
"%NSSM%" set %Service% DisplayName "Dynamisches DNS Update"
"%NSSM%" set %Service% Description "Aktualisiert automatisch die DynDNS-Adresse alle 1 Minute."
"%NSSM%" set %Service% AppRestartDelay 30000
"%NSSM%" set %Service% AppStdout "%Logdir%\service.log"
"%NSSM%" set %Service% AppStderr "%Logdir%\service-error.log"
"%NSSM%" set %Service% AppRotateFiles 1
"%NSSM%" set %Service% AppRotateOnline 1
"%NSSM%" set %Service% AppRotateBytes 1048576

echo Service-Konfiguration abgeschlossen.
echo Starte Service...
net start %Service% >nul 2>&1
if %errorlevel% neq 0 (
    echo [FEHLER] Service konnte nicht gestartet werden!
    echo Pruefe die Logs unter: %Logdir%
    pause
    exit /b 1
)
goto SM_CHECK

:SM_LOESCHEN
echo(
echo Pruefe auf alte TXT/LOG-Dateien in %Maindir% ...
if exist "%Settingsdir%\*.txt" (
    del /q "%Settingsdir%\*.*"
    if %errorlevel%==0 (
        echo Alle TXT-Dateien wurden geloescht.
    ) else (
        echo [WARNUNG] Fehler beim Loeschen der TXT-Dateien.
    )
) else (
    echo Keine TXT-Dateien gefunden.
)
if exist "%Logdir%\*.log" (
    del /q "%Logdir%\*.*"
    if %errorlevel%==0 (
        echo Alle LOG-Dateien wurden geloescht.
    ) else (
        echo [WARNUNG] Fehler beim Loeschen der LOG-Dateien.
    )
) else (
    echo Keine LOG-Dateien gefunden.
)
echo(
echo Stoppe und loesche Dienst...
net stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm
if %errorlevel% neq 0 (
    echo [FEHLER] Service-Deinstallation fehlgeschlagen!
    pause
    exit /b 1
)
goto SM_CHECKDEL

:SM_STATUS
echo(
echo === SERVICE STATUS ===
sc query "%Service%" 2>nul
if %errorlevel% neq 0 (
    echo Service "%Service%" ist nicht installiert.
) else (
    echo(
    echo === SERVICE KONFIGURATION ===
    sc qc "%Service%" 2>nul
)
echo(
echo === LOG-DATEIEN ===
if exist "%Logdir%\service.log" (
    echo Service-Log gefunden: %Logdir%\service.log
    for %%i in ("%Logdir%\service.log") do echo Groesse: %%~zi Bytes
) else (
    echo Keine Service-Log-Datei gefunden.
)
if exist "%Logdir%\service-error.log" (
    echo Error-Log gefunden: %Logdir%\service-error.log
    for %%i in ("%Logdir%\service-error.log") do echo Groesse: %%~zi Bytes
) else (
    echo Keine Error-Log-Datei gefunden.
)
echo(
pause
goto SM_MENU

:SM_CHECK
echo Warte 3 Sekunden auf Service-Start...
timeout /t 3 >nul
sc query "%Service%" | find "RUNNING" >nul
if %errorlevel%==0 (
    echo [OK] Dienst '%Service%' laeuft erfolgreich!
    echo Logs werden geschrieben nach: %Logdir%
) else (
    echo [FEHLER] Dienst '%Service%' ist NICHT gestartet!
    echo Pruefe die Logs unter: %Logdir%
)
goto SM_ENDE

:SM_CHECKDEL
sc query "%Service%" >nul 2>&1
if %errorlevel%==0 (
    echo [FEHLER] Dienst '%Service%' wurde nicht vollstaendig geloescht!
) else (
    echo [OK] Dienst '%Service%' erfolgreich geloescht!
    set "DienstExistiert=0"
)
goto SM_ENDE

:SM_ENDE
echo(
echo Script beendet. Druecken Sie eine Taste...
pause
exit /b


REM =================== Self-Update: Funktionen ===================

:SU_DOWNLOAD
REM %1=URL %2=OUT %3=DL(curl|bits)
set "URL=%~1"
set "OUT=%~2"
set "DL=%~3"
del /q "%OUT%" >nul 2>&1
if /I "%DL%"=="cert" (
  certutil -urlcache -split -f "%URL%" "%OUT%" >nul 2>&1
  goto :eof
)
if /I "%DL%"=="curl" (
  curl -sL "%URL%" -o "%OUT%" 2>nul
  goto :eof
)
if /I "%DL%"=="bits" (
  bitsadmin /transfer ddnstmp /download /priority FOREGROUND "%URL%" "%OUT%" >nul 2>&1
  goto :eof
)
goto :eof

:SU_VERCMP
REM Vergleicht A vs B (Semver bis 4 Teile). Ergebnis in %3:
REM -1 = B < A, 0 = gleich, 1 = B > A
setlocal EnableDelayedExpansion
set "A=%~1"
set "B=%~2"
for /f "tokens=1-4 delims=." %%a in ("%A%") do (set a1=%%a&set a2=%%b&set a3=%%c&set a4=%%d)
for /f "tokens=1-4 delims=." %%a in ("%B%") do (set b1=%%a&set b2=%%b&set b3=%%c&set b4=%%d)
for %%v in (a1 a2 a3 a4 b1 b2 b3 b4) do if "!%%v!"=="" set "%%v=0"
for %%v in (a1 a2 a3 a4 b1 b2 b3 b4) do (
  for /f "delims=0123456789" %%x in ("!%%v!") do (endlocal & set "%~3=" & goto :eof)
)
for %%i in (1 2 3 4) do (
  set /a da=!a%%i!, db=!b%%i!
  if !db! gtr !da! (endlocal & set "%~3=1"  & goto :eof)
  if !db! lss !da! (endlocal & set "%~3=-1" & goto :eof)
)
endlocal & set "%~3=0"
goto :eof

:SU_WRITE_UPDATER
REM %1=UpdaterPath %2=SelfPath %3=TmpNew %4=RestartFlag %5=LogPath
setlocal DisableDelayedExpansion
set "UP=%~1"
set "SP=%~2"
set "TN=%~3"
set "RF=%~4"
set "LG=%~5"
> "%UP%" (
  echo @echo off
  echo setlocal
  echo ^>^>"%LG%" echo [%%date%% %%time%%] UPDATER_START
  echo ping 127.0.0.1 -n 2 ^>nul
  echo if not exist "%TN%" ^( ^>^>"%LG%" echo [%%date%% %%time%%] ERR_NO_TMP ^& exit /b ^)
  echo copy /Y "%TN%" "%SP%" ^>nul
  echo if errorlevel 1 goto :retry
  echo del /q "%TN%" ^>nul 2^>^&1
  echo if not exist "%RF%" echo restarted^>"%RF%"
  echo start "" "%SP%"
  echo ^>^>"%LG%" echo [%%date%% %%time%%] UPDATER_RESTARTED
  echo ping 127.0.0.1 -n 1 ^>nul
  echo del /q "%%~f0" ^>nul 2^>^&1
  echo exit /b
  echo :retry
  echo ^>^>"%LG%" echo [%%date%% %%time%%] UPDATER_RETRY_COPY
  echo ping 127.0.0.1 -n 2 ^>nul
  echo copy /Y "%TN%" "%SP%" ^>nul
  echo if errorlevel 1 goto :retry
  echo del /q "%TN%" ^>nul 2^>^&1
  echo if not exist "%RF%" echo restarted^>"%RF%"
  echo start "" "%SP%"
  echo ^>^>"%LG%" echo [%%date%% %%time%%] UPDATER_RESTARTED2
  echo ping 127.0.0.1 -n 1 ^>nul
  echo del /q "%%~f0" ^>nul 2^>^&1
)
endlocal & goto :eof
