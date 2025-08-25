echo.
echo ========================================
echo  DynDNS-Update Service Manager gestartet
echo ========================================

@echo off
:: ===============================================
:: DynDNS-Update Service Manager Batch Script
:: Version: 1.4 (2025-08-25)
:: (C) 2025 Joerg Wannemacher. Alle Rechte vorbehalten.
:: Nutzung und Weitergabe nur mit Erlaubnis des Autors.
:: ===============================================
setlocal

:: ====== Installer (dieses Skript) – Version & Self-Update-Quellen ======
set "InstallerVersion=1.4.1"
:: Anpassen auf dein Repo/Pfade:
set "InstallerVersionUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.version"
set "InstallerScriptUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.bat"

:: ====== Basispfade / Variablen ======
set "Maindir=C:\SYS\DynDNS"
set "Settingsdir=%Maindir%\Settings"
set "Logdir=%Maindir%\Logs"
set "Script=%Maindir%\Script\DynDNS-Update.ps1"
set "Toolsdir=%Maindir%\Tools"
set "PsExec=%Toolsdir%\PsExec64.exe"
set "NSSM=%Toolsdir%\nssm.exe"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "Service=DynDNS-Update"

:: Optionale Update-Quellen (für -UpdateNow)
set "UpdateInfoUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/DynDNS-Update.version"
set "UpdateScriptUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/DynDNS-Update.ps1"

:: ====== Adminrechte pruefen ======
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Starte Skript mit Administratorrechten neu...
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

:: =======================================================================
:: SELF-UPDATE BLOCK (fuer diese install_ddns.bat) - laeuft direkt beim Start
:: =======================================================================
set "SelfPath=%~f0"
set "SelfName=%~nx0"
set "TmpNew=%TEMP%\%SelfName%.new"
set "Updater=%TEMP%\update_%RANDOM%_%RANDOM%.cmd"

echo.
echo [INFO] Pruefe auf neuere Version des Installers...

for /f "usebackq tokens=*" %%v in (`
  powershell -NoProfile -Command "try{ (Invoke-WebRequest -UseBasicParsing -Uri '%InstallerVersionUrl%' -TimeoutSec 12).Content.Trim() }catch{''}"
`) do set "RemoteInstallerVersion=%%v"

if defined RemoteInstallerVersion (
    echo Installer lokal : %InstallerVersion%
    echo Installer remote: %RemoteInstallerVersion%

    powershell -NoProfile -Command ^
      "$v1=[Version]'%InstallerVersion%'; $v2=[Version]'%RemoteInstallerVersion%'; if($v2 -gt $v1){exit 1}else{exit 0}"
    if errorlevel 1 (
        echo [INFO] Neuere Installer-Version gefunden. Lade Update...
        del /f /q "%TmpNew%" >nul 2>&1
        powershell -NoProfile -Command ^
          "Invoke-WebRequest -UseBasicParsing -Uri '%InstallerScriptUrl%' -OutFile '%TmpNew%' -TimeoutSec 25"

        if exist "%TmpNew%" (
            echo [OK] Installer-Update geladen. Ersetze Datei und starte neu...
            rem Updater-Stub: wartet kurz, ersetzt Datei, startet neu, raeumt sich auf
            >"%Updater%" echo @echo off
            >>"%Updater%" echo setlocal
            >>"%Updater%" echo ping 127.0.0.1 -n 2 ^>nul
            >>"%Updater%" echo copy /Y "%TmpNew%" "%SelfPath%" ^>nul
            >>"%Updater%" echo if errorlevel 1 goto :retry
            >>"%Updater%" echo del /f /q "%TmpNew%" ^>nul 2^>^&1
            >>"%Updater%" echo start "" "%SelfPath%"
            >>"%Updater%" echo (ping 127.0.0.1 -n 2 ^>nul ^& del /f /q "%%~f0") ^>nul 2^>^&1
            >>"%Updater%" echo exit /b
            >>"%Updater%" echo :retry
            >>"%Updater%" echo ping 127.0.0.1 -n 2 ^>nul
            >>"%Updater%" echo goto :^retry
            start "" "%Updater%"
            exit /b
        ) else (
            echo [FEHLER] Installer-Update konnte nicht heruntergeladen werden. Fahre ohne Update fort.
        )
    ) else (
        echo [OK] Installer ist aktuell.
    )
) else (
    echo [WARNUNG] Konnte Remote-Installer-Version nicht abrufen. Fahre ohne Update fort.
)

:: ====== Tools und Script pruefen ======
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

:: ====== Ordnererstellung ======
if not exist "%Settingsdir%" mkdir "%Settingsdir%"
if not exist "%Logdir%" mkdir "%Logdir%"

:: ====== EULA fuer psexec automatisch akzeptieren ======
"%PsExec%" /accepteula >nul 2>&1

:: ====== Dienststatus-Variable initialisieren ======
set "DienstExistiert=0"

:: Pruefen, ob Dienst existiert
sc query "%Service%" | find /I "SERVICE_NAME" >nul 2>&1
if %errorlevel%==0 set "DienstExistiert=1"

:MENU
cls
echo ========================================
echo      DynDNS-Update Service Manager V1.4
echo ========================================

if "%DienstExistiert%"=="1" goto DIENST_EXISTIERT
goto DIENST_NICHT_EXISTIERT

:DIENST_EXISTIERT
echo Der Dienst "%Service%" ist bereits installiert.
echo.
echo Was moechten Sie tun?
echo [N]eu installieren
echo [L]oeschen
echo [S]tatus pruefen
echo [A]bbrechen
set "Wahl="
set /p "Wahl=Bitte Auswahl eingeben (N/L/S/A): "
if /I "%Wahl%"=="N" goto NEUINSTALL
if /I "%Wahl%"=="L" goto LOESCHEN
if /I "%Wahl%"=="S" goto STATUS
if /I "%Wahl%"=="A" goto ENDE
goto MENU

:DIENST_NICHT_EXISTIERT
echo --- Dienst NICHT installiert ---
echo [I]nstallieren
echo [A]bbrechen
set "Wahl="
set /p "Wahl=Bitte Auswahl eingeben (I/A): "
if /I "%Wahl%"=="I" goto NEUINSTALL
if /I "%Wahl%"=="A" goto ENDE
goto MENU

:NEUINSTALL
echo.
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

echo.
echo Starte PowerShell via PsExec...
"%PsExec%" -i -s "%PS%" -ExecutionPolicy Bypass -NoProfile -File "%Script%"
set "PsExecResult=%errorlevel%"
echo PsExec beendet mit Fehlerlevel: %PsExecResult%
if %PsExecResult% neq 0 (
    echo [WARNUNG] PsExec wurde mit Fehler beendet. Installation wird fortgesetzt...
)

:: ====== Update-Check (vor der Dienstinstallation) ======
echo.
echo Fuehre Update-Check durch...
"%PS%" -ExecutionPolicy Bypass -NoProfile -File "%Script%" -UpdateNow ^
  -UpdateInfoUrl   "%UpdateInfoUrl%" ^
  -UpdateScriptUrl "%UpdateScriptUrl%"
if %errorlevel% neq 0 (
    echo [WARNUNG] Update-Check wurde mit Fehler beendet.
) else (
    echo [OK] Update-Check abgeschlossen.
)

echo.
echo Installiere/ersetze Dienst...
"%NSSM%" stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm >nul 2>&1

"%NSSM%" install %Service% "%PS%" -ExecutionPolicy Bypass -File "%Script%"
if %errorlevel% neq 0 (
    echo [FEHLER] Service-Installation mit NSSM fehlgeschlagen!
    pause
    exit /b 1
)

:: ====== Service-Konfiguration ======
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
goto CHECK

:LOESCHEN
echo.
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
echo.
echo Stoppe und loesche Dienst...
net stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm
if %errorlevel% neq 0 (
    echo [FEHLER] Service-Deinstallation fehlgeschlagen!
    pause
    exit /b 1
)
goto CHECKDEL

:STATUS
echo.
echo === SERVICE STATUS ===
sc query "%Service%" 2>nul
if %errorlevel% neq 0 (
    echo Service "%Service%" ist nicht installiert.
) else (
    echo.
    echo === SERVICE KONFIGURATION ===
    sc qc "%Service%" 2>nul
)
echo.
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
echo.
pause
goto MENU

:CHECK
:: Dienststatus erneut pruefen und melden
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
goto ENDE

:CHECKDEL
:: Dienststatus erneut pruefen
sc query "%Service%" >nul 2>&1
if %errorlevel%==0 (
    echo [FEHLER] Dienst '%Service%' wurde nicht vollstaendig geloescht!
) else (
    echo [OK] Dienst '%Service%' erfolgreich geloescht!
    set "DienstExistiert=0"
)
goto ENDE

:ENDE
echo.
echo Script beendet. Druecken Sie eine Taste...
pause
exit /b
