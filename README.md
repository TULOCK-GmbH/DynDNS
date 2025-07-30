# DynDNS PowerShell Script mit automatischem GitHub-Update und Dienst-Neustart

Ein robustes PowerShell-Skript zur zuverlässigen DynDNS-Aktualisierung –  
mit automatischer Update-Prüfung auf GitHub und sicherem Neustart des Windows-Dienstes nach Updates.

---

## Funktionen

- Prüft die öffentliche IP-Adresse über mehrere unabhängige Dienste (Fallback)
- Vergleicht die IP mit dem aktuellen DNS-A-Eintrag (z. B. `kunde.soc-tulock.de`)
- Führt nur bei Änderung ein DynDNS-Update durch
- Initialisiert und speichert Zugangsdaten (Kundennummer/Subdomain & DynDNS-Passwort)
- Automatische tägliche Update-Prüfung: Holt neue Versionen von GitHub
- Neustart des Windows-Dienstes nach erfolgreichem Update
- Sicheres Logging & Heartbeat
- Backup der letzten Scriptversion (`.bak`)

---

## Vorbereitung

### 1. Dateien im Repository

- `DynDNS-Update.ps1` – Das Hauptskript  
- `DynDNS-Update.version` – Die aktuelle Versionsnummer (z.B. `1.0.2`)

### 2. Self-Update-Links im Skript anpassen

Im Skript stehen folgende Variablen (bereits für dein Repo vorbereitet):

```powershell
$updateInfoUrl   = "https://raw.githubusercontent.com/Home-Netz/DynDNS-Updater/main/DynDNS-Update.version"
$updateScriptUrl = "https://raw.githubusercontent.com/Home-Netz/DynDNS-Updater/main/DynDNS-Update.ps1"
