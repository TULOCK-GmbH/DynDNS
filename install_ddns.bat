@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM =========================================================
REM  install_DDNS.bat – v1.2.2
REM  Self-Update (VBS) + DynDNS Service Manager
REM  (C) 2025 Joerg Wannemacher
REM =========================================================


REM =================== Basis-Pfade ===================
set "Maindir=C:\SYS\DynDNS"
set "Logdir=%Maindir%\Logs"
if not exist "%Logdir%" mkdir "%Logdir%" >nul 2>&1

REM Haupt-Installer-Log (Service-Manager Aktionen)
set "INST_Log=%Logdir%\install_ddns_installer.log"

REM =================== Self-Update Config ===================
set "InstallerVersion=1.2.2"
set "VersionUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.version"
set "ScriptUrl=https://raw.githubusercontent.com/TULOCK-GmbH/DynDNS/main/install_ddns.bat"

REM =================== Self-Update Pfade/Logs ===================
set "SelfPath=%~f0"
set "SelfName=%~nx0"
set "TmpVer=%Logdir%\%SelfName%.ver"
set "TmpNew=%Logdir%\%SelfName%.new"
set "RestartFlag=%Logdir%\%SelfName%.restarted"
set "UpdaterVbs=%Logdir%\%SelfName%_upd.vbs"
set "SU_Log=%Logdir%\install_ddns_update.log"

call :LOG "--- BOOT --- start %SelfName% v=%InstallerVersion%"
call :LOG_VERSION


REM ===== Self-Update: Restart nach Update? -> einmalig ueberspringen
if exist "%RestartFlag%" (
  del /q "%RestartFlag%" >nul 2>&1
  >>"%SU_Log%" echo [%date% %time%] RESTART_SKIP
  call :LOG "SelfUpdate: RESTART_SKIP (Updateblock uebersprungen)"
  call :LOG_VERSION
  goto :AFTER_SELFUPDATE
)


REM ===== Self-Update: Downloader ermitteln (certutil -> curl -> bitsadmin)
set "DL="
where certutil >nul 2>&1 && set "DL=cert"
if not defined DL where curl >nul 2>&1 && set "DL=curl"
if not defined DL where bitsadmin >nul 2>&1 && set "DL=bits"
if not defined DL (
  >>"%SU_Log%" echo [%date% %time%] ERR_NO_DOWNLOADER
  call :LOG "SelfUpdate: ERR_NO_DOWNLOADER"
  goto :AFTER_SELFUPDATE
)


REM ===== Self-Update: Remote-Version holen
del /q "%TmpVer%" "%TmpNew%" "%UpdaterVbs%" >nul 2>&1
call :SU_DOWNLOAD "%VersionUrl%" "%TmpVer%" "%DL%"
if not exist "%TmpVer%" (
  >>"%SU_Log%" echo [%date% %time%] WARN_VER_FETCH_FAIL
  call :LOG "SelfUpdate: WARN_VER_FETCH_FAIL"
  goto :AFTER_SELFUPDATE
)

set "RemoteVersion="
for /f "usebackq delims=" %%L in ("%TmpVer%") do if not defined RemoteVersion set "RemoteVersion=%%L"
del /q "%TmpVer%" >nul 2>&1

for /f "tokens=* delims= " %%A in ("%RemoteVersion%") do set "RemoteVersion=%%A"
set "RemoteVersion=%RemoteVersion: =%"

if not defined RemoteVersion (
  >>"%SU_Log%" echo [%date% %time%] WARN_VER_EMPTY
  call :LOG "SelfUpdate: WARN_VER_EMPTY"
  goto :AFTER_SELFUPDATE
)
>>"%SU_Log%" echo [%date% %time%] REMOTE=%RemoteVersion% LOCAL=%InstallerVersion%
call :LOG "SelfUpdate: REMOTE=%RemoteVersion% LOCAL=%InstallerVersion%"


REM ===== Self-Update: Versionen vergleichen
set "RESULT="
call :SU_VERCMP "%InstallerVersion%" "%RemoteVersion%" RESULT
if not defined RESULT (
  >>"%SU_Log%" echo [%date% %time%] WARN_CMP_FAIL
  call :LOG "SelfUpdate: WARN_CMP_FAIL"
  goto :AFTER_SELFUPDATE
)

if "%RESULT%"=="1" (
  >>"%SU_Log%" echo [%date% %time%] UPDATE_AVAILABLE
  call :LOG "SelfUpdate: UPDATE_AVAILABLE"
  call :SU_DOWNLOAD "%ScriptUrl%" "%TmpNew%" "%DL%"
  if not exist "%TmpNew%" (
    >>"%SU_Log%" echo [%date% %time%] ERR_DL_FAIL
    call :LOG "SelfUpdate: ERR_DL_FAIL"
    goto :AFTER_SELFUPDATE
  )
  for %%S in ("%TmpNew%") do set "DL_SIZE=%%~zS"
  >>"%SU_Log%" echo [%date% %time%] DL_OK size=%DL_SIZE%
  call :LOG "SelfUpdate: DL_OK size=%DL_SIZE%"

  >"%RestartFlag%" echo restarted

  REM ===== Robuster Neustart via kleinem VBS-Updater (line-by-line) =====
  call :SU_WRITE_VBS "%UpdaterVbs%" "%TmpNew%" "%SelfPath%"
  start "" wscript.exe "%UpdaterVbs%"
  call :LOG "SelfUpdate: start updater VBS -> exit old instance"
  goto :EOF
)


:AFTER_SELFUPDATE
REM =========================================================
REM  DynDNS-Update Service Manager
REM =========================================================

echo(
echo ========================================
echo  DynDNS-Update Service Manager gestartet
echo ========================================
echo Installer-Version : %InstallerVersion%
call :LOG "ServiceManager: started UI (v=%InstallerVersion%)"

set "Settingsdir=%Maindir%\Settings"
set "Script=%Maindir%\Script\DynDNS-Update.ps1"
set "Toolsdir=%Maindir%\Tools"
set "PsExec=%Toolsdir%\PsExec64.exe"
set "NSSM=%Toolsdir%\nssm.exe"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "Service=DynDNS-Update"

:: Adminrechte pruefen (PS vorhanden? sonst mshta-Fallback)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Starte Skript mit Administratorrechten neu...
    call :LOG "Elevate: not admin -> elevating"
    if exist "%PS%" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    ) else (
        mshta "vbscript:Execute(""CreateObject("" + Chr(34) + ""Shell.Application"" + Chr(34) + "").ShellExecute "" + Chr(34) + ""%~f0"" + Chr(34) + "", "" "", """", ""runas"", 1 :close"")"
    )
    goto :EOF
)

:: Tools und Script pruefen
if not exist "%PsExec%" (
    echo [FEHLER] PsExec fehlt: %PsExec%
    call :LOG "Check: PsExec MISSING at %PsExec%"
    pause
    goto :EOF
)
if not exist "%NSSM%" (
    echo [FEHLER] NSSM fehlt: %NSSM%
    call :LOG "Check: NSSM MISSING at %NSSM%"
    pause
    goto :EOF
)
if not exist "%Script%" (
    echo [FEHLER] DynDNS-Update.ps1 fehlt: %Script%
    call :LOG "Check: Script MISSING at %Script%"
    pause
    goto :EOF
)

:: Ordnererstellung
if not exist "%Settingsdir%" mkdir "%Settingsdir%" >nul 2>&1
if not exist "%Logdir%" mkdir "%Logdir%" >nul 2>&1

:: EULA fuer psexec akzeptieren
"%PsExec%" /accepteula >nul 2>&1

:: Dienststatus-Variable
set "DienstExistiert=0"
sc query "%Service%" | find /I "SERVICE_NAME" >nul 2>&1
if %errorlevel%==0 set "DienstExistiert=1"

:SM_MENU
cls
echo ========================================
echo      DynDNS-Update Service Manager V1.2
echo ========================================
if "%DienstExistiert%"=="1" goto SM_EXIST
goto SM_NOTEXIST

:SM_EXIST
echo Der Dienst "%Service%" ist bereits installiert.
echo(
echo [N]eu installieren
echo [L]oeschen
echo [S]tatus pruefen
echo [A]bbrechen
set /p "Wahl=Bitte Auswahl (N/L/S/A): "
if /I "%Wahl%"=="N" call :LOG "Menu: choice=N (reinstall)" & goto SM_NEU
if /I "%Wahl%"=="L" call :LOG "Menu: choice=L (remove)"    & goto SM_DEL
if /I "%Wahl%"=="S" call :LOG "Menu: choice=S (status)"    & goto SM_STATUS
if /I "%Wahl%"=="A" call :LOG "Menu: choice=A (abort)"     & goto SM_END
goto SM_MENU

:SM_NOTEXIST
echo --- Dienst NICHT installiert ---
echo [I]nstallieren
echo [A]bbrechen
set /p "Wahl=Bitte Auswahl (I/A): "
if /I "%Wahl%"=="I" call :LOG "Menu: choice=I (install)" & goto SM_NEU
if /I "%Wahl%"=="A" call :LOG "Menu: choice=A (abort)"   & goto SM_END
goto SM_MENU

:SM_NEU
echo(
echo Loesche alte TXT/LOG-Dateien...
del /q "%Settingsdir%\*.*" >nul 2>&1
del /q "%Logdir%\*.log"    >nul 2>&1
call :LOG "Action: cleanup settings+logs"

echo Starte PowerShell via PsExec...
"%PsExec%" -i -s "%PS%" -ExecutionPolicy Bypass -NoProfile -File "%Script%"
set "PsExecResult=%errorlevel%"
call :LOG "PsExec exit=%PsExecResult%"
if %PsExecResult% neq 0 (
    echo [WARNUNG] PsExec meldete einen Fehler, Installation wird fortgesetzt...
    call :LOG "PsExec WARN: continue anyway"
)

echo Installiere/ersetze Dienst...
call :LOG "NSSM: stop/remove/install %Service%"
"%NSSM%" stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm >nul 2>&1
"%NSSM%" install %Service% "%PS%" -ExecutionPolicy Bypass -File "%Script%"

"%NSSM%" set %Service% DisplayName "Dynamisches DNS Update"
"%NSSM%" set %Service% Description "Aktualisiert DynDNS alle 1 Minute."
"%NSSM%" set %Service% AppStdout "%Logdir%\service.log"
"%NSSM%" set %Service% AppStderr "%Logdir%\service-error.log"

call :LOG "Service: start %Service%"
net start %Service% >nul 2>&1
goto SM_CHECK

:SM_DEL
echo(
echo Stoppe und loesche Dienst...
call :LOG "Service: stop/remove %Service%"
net stop %Service% >nul 2>&1
"%NSSM%" remove %Service% confirm
goto SM_CHECKDEL

:SM_STATUS
echo(
call :LOG "Service: status/query %Service%"
sc query "%Service%" 2>nul
sc qc "%Service%" 2>nul
echo(
if exist "%Logdir%\service.log" (
    for %%i in ("%Logdir%\service.log") do echo Logdatei Groesse: %%~zi Bytes
) else (
    echo Keine Service-Log-Datei gefunden.
)
if exist "%Logdir%\service-error.log" (
    for %%i in ("%Logdir%\service-error.log") do echo Error-Log Groesse: %%~zi Bytes
) else (
    echo Keine Service-Error-Log-Datei gefunden.
)
echo(
pause
goto SM_MENU

:SM_CHECK
timeout /t 3 >nul
sc query "%Service%" | find "RUNNING" >nul
if %errorlevel%==0 (
    echo [OK] Dienst laeuft!
    echo Logs: %Logdir%
    call :LOG "Service: RUNNING"
) else (
    echo [FEHLER] Dienst NICHT gestartet!
    echo Bitte pruefen: %Logdir%
    call :LOG "Service: NOT RUNNING"
)
goto SM_END

:SM_CHECKDEL
sc query "%Service%" >nul 2>&1
if %errorlevel%==0 (
    echo [FEHLER] Dienst nicht vollstaendig geloescht!
    call :LOG "Service: remove FAILED"
) else (
    echo [OK] Dienst geloescht!
    call :LOG "Service: removed OK"
    set "DienstExistiert=0"
)
goto SM_END

:SM_END
echo(
echo Script beendet. Taste druecken...
call :LOG "--- END ---"
pause
goto :EOF



REM =================== Funktionen ===================

:LOG
REM Append eine Zeile ins Installer-Hauptlog
>>"%INST_Log%" echo [%date% %time%] %*
goto :eof

:LOG_VERSION
REM schreibt die aktuelle Installer-Version in beide Logs
>>"%SU_Log%"   echo [%date% %time%] VERSION=%InstallerVersion% FILE=%SelfName%
call :LOG "VERSION=%InstallerVersion% FILE=%SelfName%"
goto :eof


:SU_DOWNLOAD
REM %1=URL %2=OUT %3=DL(curl|bits|cert)
set "URL=%~1"
set "OUT=%~2"
set "DL=%~3"
del /q "%OUT%" >nul 2>&1
if /I "%DL%"=="cert" (
  certutil -urlcache -split -f "%URL%" "%OUT%" >nul 2>&1 & goto :eof
)
if /I "%DL%"=="curl" (
  curl -sL "%URL%" -o "%OUT%" 2>nul & goto :eof
)
if /I "%DL%"=="bits" (
  bitsadmin /transfer ddnstmp /download /priority FOREGROUND "%URL%" "%OUT%" >nul 2>&1 & goto :eof
)
goto :eof


:SU_VERCMP
REM -1 = B < A, 0 = gleich, 1 = B > A
setlocal EnableDelayedExpansion
set "A=%~1"
set "B=%~2"
for /f "tokens=1-4 delims=." %%a in ("%A%") do (set a1=%%a&set a2=%%b&set a3=%%c&set a4=%%d)
for /f "tokens=1-4 delims=." %%a in ("%B%") do (set b1=%%a&set b2=%%b&set b3=%%c&set b4=%%d)
for %%v in (a1 a2 a3 a4 b1 b2 b3 b4) do if "!%%v!"=="" set "%%v=0"
for %%i in (1 2 3 4) do (
  set /a da=!a%%i!, db=!b%%i!
  if !db! gtr !da! (endlocal & set "%~3=1" & goto :eof)
  if !db! lss !da! (endlocal & set "%~3=-1" & goto :eof)
)
endlocal & set "%~3=0"
goto :eof


:SU_WRITE_VBS
REM %1=UpdaterVbs %2=SrcTmpNew %3=DstSelfPath
setlocal DisableDelayedExpansion
set "UP=%~1"
set "SRC=%~2"
set "DST=%~3"
del /q "%UP%" >nul 2>&1
>>"%UP%" echo WScript.Sleep 400
>>"%UP%" echo Dim fso: Set fso=CreateObject("Scripting.FileSystemObject")
>>"%UP%" echo Dim sh : Set sh = CreateObject("WScript.Shell")
>>"%UP%" echo Dim src, dst, i
>>"%UP%" echo src="%SRC%": dst="%DST%"
>>"%UP%" echo If Not fso.FileExists(src) Then WScript.Quit 1
>>"%UP%" echo On Error Resume Next
>>"%UP%" echo For i = 1 To 5
>>"%UP%" echo   fso.CopyFile src, dst, True
>>"%UP%" echo   If Err.Number = 0 Then Exit For
>>"%UP%" echo   Err.Clear
>>"%UP%" echo   WScript.Sleep 400
>>"%UP%" echo Next
>>"%UP%" echo fso.DeleteFile src, True
>>"%UP%" echo sh.Run """" ^& dst ^& """", 1, False
>>"%UP%" echo On Error Resume Next
>>"%UP%" echo fso.DeleteFile WScript.ScriptFullName, True
endlocal & goto :eof
