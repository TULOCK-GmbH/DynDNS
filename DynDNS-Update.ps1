# Version: 1.0.0

# === Skriptpfad ermitteln (robust fuer alle Umgebungen) ===
if ($PSScriptRoot) {
    $selfPath = Join-Path $PSScriptRoot ($MyInvocation.MyCommand.Name)
} else {
    $selfPath = $MyInvocation.MyCommand.Path
}

# Speicherorte
$Install = "C:\SYS\DynDNS"
$settingsFile   = "$Install\Settings\dyndns_settings.txt"
$pwFile         = "$Install\Settings\dyndns_password.txt"
$ipFile         = "$Install\Logs\old_ip.txt"
$heartbeatFile  = "$Install\Logs\heartbeat.txt"
$logFile        = "$Install\Logs\ip_monitor.log"

# Update-Infos (GitHub RAW-Links!)
$updateCheckFile = "$Install\Logs\last_update_check.log"
$updateInfoUrl   = "https://raw.githubusercontent.com/Home-Netz/DynDNS-Updater/main/DynDNS-Update.version"
$updateScriptUrl = "https://raw.githubusercontent.com/Home-Netz/DynDNS-Updater/main/DynDNS-Update.ps1"

# Liste der IP-Abfrage-Dienste (Fallback-Prinzip)
$ipServices = @(
    "https://ifconfig.me/ip",
    "https://api.ipify.org",
    "https://checkip.amazonaws.com"
)

# Logging-Funktion
function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp $msg"
}

# --- Automatische Update-Pruefung: Nur 1x taeglich, Script startet sich bei Update selbst neu ---
function Get-LocalVersion {
    Get-Content $selfPath | Select-String -Pattern "^# Version:" | ForEach-Object {
        $_.ToString().Split(":")[1].Trim()
    }
}
function Check-For-Update {
    $now = Get-Date
    $doCheck = $true
    if (Test-Path $updateCheckFile) {
        $lastCheck = Get-Content $updateCheckFile | Get-Date
        if ($lastCheck.Date -eq $now.Date) { $doCheck = $false }
    }
    if ($doCheck) {
        try {
            $localVersion  = Get-LocalVersion
            $remoteVersion = (Invoke-RestMethod -Uri $updateInfoUrl -TimeoutSec 10).Trim()
            if ($remoteVersion -ne $localVersion) {
                Write-Host "Neue Script-Version $remoteVersion gefunden (deine Version: $localVersion). Lade herunter..." -ForegroundColor Cyan
                Write-Log  "Neue Script-Version $remoteVersion gefunden, Update wird geladen..."
                Invoke-WebRequest -Uri $updateScriptUrl -OutFile "$selfPath.new"
                Copy-Item $selfPath "$selfPath.bak" -Force
                Move-Item "$selfPath.new" $selfPath -Force
                $now | Set-Content $updateCheckFile
                Write-Host "Update erfolgreich. Script startet sich neu..." -ForegroundColor Cyan
                Write-Log  "Update erfolgreich geladen. Script startet sich selbst neu."
                Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$selfPath`""
                exit
            } else {
                Write-Host "Kein Update noetig (Version: $localVersion)." -ForegroundColor Green
                $now | Set-Content $updateCheckFile
            }
        } catch {
            Write-Host "Konnte nicht nach Updates suchen: $_" -ForegroundColor Yellow
            Write-Log  "Konnte nicht nach Updates suchen: $_"
            $now | Set-Content $updateCheckFile
        }
    }
}
Check-For-Update

# --- Erstellung der Ordner ---
IF (!(Test-Path $Install)) {
    Write-Host "=== Erstelle Ordnerstruktur ==="
    New-Item -ItemType Directory -Path $Install -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Settings") -Force | Out-Null
}
else {
    Write-Host "=== Ordner existieren bereits ==="
}

# --- INITIALISIERUNG (nur beim ersten Start) ---
if (!(Test-Path $settingsFile) -or !(Test-Path $pwFile)) {
    Write-Host "==== DynDNS-Einstellungen Initialisierung ====" -ForegroundColor Cyan
    $subdomain = Read-Host "Bitte NUR die Kundennummer (z.B. 12345) eingeben"
    $pw = Read-Host "Bitte Passwort fuer DynDNS eingeben" -AsSecureString

    # Subdomain speichern
    $subdomain | Set-Content $settingsFile
    # Passwort verschluesselt speichern
    $pw | ConvertFrom-SecureString | Set-Content $pwFile

    Write-Host "Einstellungen gespeichert. Skript startet jetzt regulaer..." -ForegroundColor Green
    Write-Log "DynDNS-Subdomain und Passwort initialisiert."
    exit 0   # <--- Script sauber beenden nach Initialisierung!
}

# --- Subdomain & Passwort laden ---
$subdomain      = Get-Content $settingsFile
$securePassword = Get-Content $pwFile | ConvertTo-SecureString
$plainPassword  = [System.Net.NetworkCredential]::new("", $securePassword).Password
$url = "https://dynamicdns.key-systems.net/update.php?hostname=$subdomain.soc-tulock.de&password=$plainPassword&ip=auto"

function Get-PublicIP {
    foreach ($service in $ipServices) {
        try {
            $ip = Invoke-RestMethod -Uri $service -TimeoutSec 10
            if ($ip -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                Write-Log ("IP erfolgreich ueber {0}: {1}" -f $service, $ip)
                return $ip.Trim()
            }
        } catch {
            Write-Log ("WARNUNG: {0} konnte nicht abgefragt werden: {1}" -f $service, $_)
        }
    }
    return $null
}

while ($true) {
    $currentIP = Get-PublicIP
    if (-not $currentIP) {
        Write-Host "Konnte aktuelle IP von keinem Dienst abrufen. Warte 1 Minute..." -ForegroundColor Yellow
        Write-Log "FEHLER: Konnte aktuelle IP von keinem Dienst abrufen."
        Start-Sleep -Seconds 60
        continue
    }

    # DNS A-Record abfragen (Oeffentlicher Resolver, fuer Zuverlaessigkeit)
    try {
        $dnsEntry = Resolve-DnsName "$subdomain.soc-tulock.de" -Type A -Server "8.8.8.8" -ErrorAction Stop
        $dnsAIP = ($dnsEntry | Where-Object { $_.QueryType -eq 'A' }).IPAddress
        Write-Log ("DNS-A-Eintrag fuer {0}.soc-tulock.de: {1}" -f $subdomain, $dnsAIP)
    } catch {
        Write-Host "Konnte DNS-A-Eintrag nicht abfragen! Warte 1 Minute..." -ForegroundColor Yellow
        Write-Log ("FEHLER: Konnte DNS-A-Eintrag nicht abfragen: {0}" -f $_)
        Start-Sleep -Seconds 60
        continue
    }

    # Vergleich Online-IP mit DNS-A-Record
    if ($currentIP -eq $dnsAIP) {
        Write-Host "DNS-A-Eintrag ist bereits aktuell ($currentIP). Kein DynDNS-Update noetig." -ForegroundColor Green
        Write-Log ("DNS-A-Eintrag stimmt mit Online-IP ueberein: {0}" -f $currentIP)
    } else {
        Write-Host "DNS-A-Eintrag ($dnsAIP) stimmt NICHT mit aktueller IP ($currentIP) ueberein. DynDNS-Update wird durchgefuehrt..." -ForegroundColor Red
        Write-Log ("DNS-A-Eintrag stimmt NICHT mit aktueller IP ueberein. DynDNS-Update wird durchgefuehrt.")

        try {
            if (-not (Test-Connection -ComputerName "dynamicdns.key-systems.net" -Count 1 -Quiet)) {
                throw "DynDNS-Server nicht erreichbar"
            }
            Invoke-WebRequest -Uri $url -OutFile "$Install\Logs\dyndns_update.log"
            Write-Host "DynDNS-Update ausgefuehrt und geloggt." -ForegroundColor Cyan
            Write-Log "DynDNS-Update erfolgreich."
        } catch {
            Write-Host "DynDNS-Update fehlgeschlagen!" -ForegroundColor DarkRed
            Write-Log ("FEHLER beim DynDNS-Update: {0}" -f $_)
        }
    }

    # Aktuelle IP speichern & Heartbeat aktualisieren
    $currentIP | Set-Content $ipFile
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content $heartbeatFile
    Start-Sleep -Seconds 60
}
