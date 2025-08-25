# Version: 1.7.0 (LocalMachine DPAPI + GitHub Self-Update + Health-Log + safe Stop-Logging)

param(
    [int]$IntervalSec = 60,
    [int]$LogMaxSizeMB = 10,
    [switch]$NoPing,
    [int]$HealthEvery = 5,
    [switch]$UpdateNow,                 # trigger self-update and exit
    [string]$GitHubRawUrl = ""          # raw URL to this script in GitHub (e.g. https://raw.githubusercontent.com/<org>/<repo>/main/dyndns_tulock.ps1)
)

# --- enforce TLS 1.2 ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# === find script path ===
if ($PSScriptRoot) { $selfPath = Join-Path $PSScriptRoot ($MyInvocation.MyCommand.Name) }
else { $selfPath = $MyInvocation.MyCommand.Path }

# locations
$Install        = "C:\SYS\DynDNS"
$settingsFile   = "$Install\Settings\dyndns_settings.txt"
$pwFile         = "$Install\Settings\dyndns_password.txt"   # now stores Base64(ProtectedData LocalMachine)
$ghUrlFile      = "$Install\Settings\github_url.sec"        # now stores Base64(ProtectedData LocalMachine)
$ipFile         = "$Install\Logs\old_ip.txt"
$heartbeatFile  = "$Install\Logs\heartbeat.txt"
$logFile        = "$Install\Logs\ip_monitor.log"
$updateLogFile  = "$Install\Logs\dyndns_update.log"

# IP services
$ipServices = @(
    "https://ifconfig.me/ip",
    "https://api.ipify.org",
    "https://checkip.amazonaws.com",
    "https://ipecho.net/plain",
    "https://icanhazip.com"
)

# DNS servers
$dnsServers = @("8.8.8.8", "1.1.1.1", "208.67.222.222")

# config checks
if ($IntervalSec -lt 10)   { Write-Host "IntervalSec < 10s, set to 10s." -ForegroundColor Yellow; $IntervalSec = 10 }
if ($IntervalSec -gt 86400){ Write-Host "IntervalSec > 86400s, set to 86400s." -ForegroundColor Yellow; $IntervalSec = 86400 }
if ($LogMaxSizeMB -lt 1)   { Write-Host "LogMaxSizeMB < 1, set to 1 MB." -ForegroundColor Yellow; $LogMaxSizeMB = 1 }
if ($HealthEvery -lt 1)    { Write-Host "HealthEvery < 1, set to 1." -ForegroundColor Yellow; $HealthEvery = 1 }

# IPv4 test
function Test-IPv4([string]$ip) {
    if (-not $ip) { return $false }
    if ($ip -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { return $false }
    return ($ip.Split('.') | ForEach-Object { ($_ -as [int]) -ge 0 -and ($_ -as [int]) -le 255 }) -notcontains $false
}

# Logging with rotation + color
function Write-Log([string]$msg, [string]$level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$level] $msg"

    try {
        if (Test-Path $logFile) {
            $sizeMB = (Get-Item $logFile).Length / 1MB
            if ($sizeMB -gt $LogMaxSizeMB) {
                $backupLog = "$logFile.old"
                if (Test-Path $backupLog) { Remove-Item $backupLog -Force }
                Rename-Item $logFile $backupLog
                Write-Host ("Log rotated ({0:N2} MB)" -f $sizeMB) -ForegroundColor Yellow
            }
        }
        Add-Content -Path $logFile -Value $entry
    } catch {
        Write-Host "write log failed: $_" -ForegroundColor DarkYellow
    }

    switch ($level.ToUpper()) {
        "ERROR" { Write-Host $entry -ForegroundColor Red }
        "WARN"  { Write-Host $entry -ForegroundColor Yellow }
        "INFO"  { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }
}

# --- LocalMachine DPAPI helpers (machine-bound encryption) ---
Add-Type -AssemblyName System.Security

function Protect-String([string]$plain){
    if ([string]::IsNullOrEmpty($plain)) { return "" }
    $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
    $prot  = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($prot)
}
function Unprotect-String([string]$b64){
    if ([string]::IsNullOrEmpty($b64)) { return "" }
    $prot  = [Convert]::FromBase64String($b64)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($prot,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

# --- encrypted GitHub URL helpers (LocalMachine DPAPI) ---
function Set-GitHubUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $Url = Read-Host "enter GitHub raw URL"
    }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-Log "no URL provided." "WARN"
        return
    }
    try {
        $enc = Protect-String $Url
        $enc | Set-Content -Path $ghUrlFile
        Write-Log "GitHub URL saved (machine-bound encrypted)." "INFO"
    } catch {
        Write-Log ("failed to save GitHub URL: {0}" -f $_.Exception.Message) "ERROR"
    }
}
function Get-GitHubUrl {
    if (Test-Path $ghUrlFile) {
        try {
            $b64 = Get-Content $ghUrlFile -Raw
            return Unprotect-String $b64
        } catch {
            Write-Log ("failed to load GitHub URL: {0}" -f $_.Exception.Message) "ERROR"
        }
    }
    return $null
}
function Delete-GitHubUrl {
    try {
        if (Test-Path $ghUrlFile) { Remove-Item $ghUrlFile -Force }
        Write-Log "GitHub URL removed." "INFO"
    } catch {
        Write-Log ("failed to remove GitHub URL: {0}" -f $_.Exception.Message) "ERROR"
    }
}

# --- GitHub self-update helpers ---
function Get-LocalVersion {
    try {
        $content = Get-Content -Path $selfPath -Raw -ErrorAction Stop
        if ($content -match '(?m)^#\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
            return [version]$Matches[1]
        }
    } catch {}
    return [version]"0.0.0"
}
function Get-RemoteVersion([string]$Url, [ref]$remoteContent) {
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $txt  = ($resp.Content | Out-String)
        $remoteContent.Value = $txt
        if ($txt -match '(?m)^#\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
            return [version]$Matches[1]
        }
    } catch {
        Write-Log ("remote version fetch failed: {0}" -f $_.Exception.Message) "ERROR"
    }
    return $null
}
function Self-Update([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-Log "GitHubRawUrl is empty. Set -GitHubRawUrl or call Set-GitHubUrl." "ERROR"
        return
    }
    Write-Log ("self-update: checking {0}" -f $Url) "INFO"

    $localVer  = Get-LocalVersion
    $remoteTxt = ""
    $refRemote = [ref]$remoteTxt
    $remoteVer = Get-RemoteVersion -Url $Url -remoteContent $refRemote

    if (-not $remoteVer) {
        Write-Log "could not read remote version" "ERROR"
        return
    }

    Write-Log ("local version: {0} / remote version: {1}" -f $localVer, $remoteVer) "INFO"

    if ($remoteVer -le $localVer) {
        Write-Log "already up-to-date" "INFO"
        return
    }

    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $remoteTxt -Encoding UTF8

        # quick syntax check of downloaded script
        try {
            [void][ScriptBlock]::Create((Get-Content $tmp -Raw))
        } catch {
            Write-Log ("downloaded script failed syntax check: {0}" -f $_.Exception.Message) "ERROR"
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return
        }

        $backup = "$selfPath.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Copy-Item -Path $selfPath -Destination $backup -Force
        Copy-Item -Path $tmp -Destination $selfPath -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        Write-Log ("updated script to version {0}. backup: {1}" -f $remoteVer, $backup) "INFO"
        Write-Host "Self-update complete. Please re-run the script." -ForegroundColor Green
    } catch {
        Write-Log ("self-update failed: {0}" -f $_.Exception.Message) "ERROR"
    }
}

# create folders
if (!(Test-Path $Install)) {
    Write-Host "=== creating folder structure ==="
    New-Item -ItemType Directory -Path $Install -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Settings") -Force | Out-Null
}

# optional: run self-update and exit
if ($UpdateNow) {
    # persist once if provided via parameter
    if (-not (Test-Path $ghUrlFile) -and -not [string]::IsNullOrWhiteSpace($GitHubRawUrl)) {
        Set-GitHubUrl -Url $GitHubRawUrl
    }
    $urlToUse = $GitHubRawUrl
    if ([string]::IsNullOrWhiteSpace($urlToUse)) {
        $urlToUse = Get-GitHubUrl
    }
    if ([string]::IsNullOrWhiteSpace($urlToUse)) {
        Write-Host "no GitHub URL provided or stored. set it with:" -ForegroundColor Yellow
        Write-Host "  -GitHubRawUrl <url> -UpdateNow     (one-time)" -ForegroundColor Yellow
        Write-Host "or persist it:" -ForegroundColor Yellow
        Write-Host "  call Set-GitHubUrl                 (interactive)" -ForegroundColor Yellow
        return
    }
    Self-Update -Url $urlToUse
    return
}

# initialization (first run)
if (!(Test-Path $settingsFile) -or !(Test-Path $pwFile)) {
    Write-Host "==== DynDNS settings init ====" -ForegroundColor Cyan

    do {
        $subdomain = (Read-Host "Please enter ONLY the customer id (letters or digits)").Trim()
        if ($subdomain -notmatch '^[a-zA-Z0-9]+$') {
            Write-Host "only letters/digits allowed." -ForegroundColor Red
            continue
        }
        break
    } while ($true)

    do {
        $pw = Read-Host "enter DynDNS password" -AsSecureString
        $plainPw = [System.Net.NetworkCredential]::new("", $pw).Password
        if ($plainPw.Length -lt 6) {
            Write-Host "password too short." -ForegroundColor Red
            continue
        }
        break
    } while ($true)

    # save settings
    $subdomain | Set-Content $settingsFile

    # save password with LocalMachine DPAPI
    try {
        $encPw = Protect-String $plainPw
        $encPw | Set-Content $pwFile
        Write-Log "DynDNS password saved (machine-bound encrypted)." "INFO"
    } catch {
        Write-Log ("failed to save password: {0}" -f $_.Exception.Message) "ERROR"
        exit 1
    }

    Write-Host "settings saved." -ForegroundColor Green
    Write-Log "DynDNS initialized." "INFO"
    exit 0
}

# load settings + password (machine-bound)
try {
    $subdomain = (Get-Content $settingsFile -ErrorAction Stop).Trim()
} catch {
    Write-Log "ERROR loading settings file: $_" "ERROR"
    exit 1
}

try {
    $encPw = Get-Content $pwFile -ErrorAction Stop -Raw
    $plainPassword = Unprotect-String $encPw
    if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw "password decrypt returned empty string" }
} catch {
    Write-Log "password decrypt failed. prompting for reset..." "WARN"
    try {
        $pw = Read-Host "enter DynDNS password (will be re-saved machine-bound)" -AsSecureString
        $plainPw = [System.Net.NetworkCredential]::new("", $pw).Password
        if ($plainPw.Length -lt 6) { throw "password too short." }
        Protect-String $plainPw | Set-Content $pwFile
        $plainPassword = $plainPw
        Write-Log "password re-saved (machine-bound)." "INFO"
    } catch {
        Write-Log "could not recover password: $_" "ERROR"
        exit 1
    }
}

$fullDomain = "$subdomain.soc-tulock.de"
$url = "https://dynamicdns.key-systems.net/update.php?hostname=$fullDomain&password=$plainPassword&ip=auto"

# startup logging
Write-Log "=== DynDNS Monitor START ===" "INFO"
Write-Log ("Version: {0}" -f "1.7.0") "INFO"
Write-Log ("Script: {0}" -f $selfPath) "INFO"
Write-Log ("Domain: {0}" -f $fullDomain) "INFO"
Write-Log ("IntervalSec: {0}" -f $IntervalSec) "INFO"
Write-Log ("LogMaxSizeMB: {0}" -f $LogMaxSizeMB) "INFO"
Write-Log ("NoPing: {0}" -f $NoPing.IsPresent) "INFO"
Write-Log ("HealthEvery: {0}" -f $HealthEvery) "INFO"
Write-Log ("DNS servers: {0}" -f ($dnsServers -join ", ")) "INFO"
Write-Log ("IP services: {0}" -f ($ipServices -join ", ")) "INFO"

# engine exit event
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $using:logFile -Value "$ts [INFO] === DynDNS Monitor STOP (engine exiting) ==="
} | Out-Null

# get public IP
function Get-PublicIP {
    foreach ($service in $ipServices) {
        try {
            $ip = (Invoke-RestMethod -Uri $service -TimeoutSec 15 -ErrorAction Stop).ToString().Trim()
            if (Test-IPv4 $ip) {
                Write-Log ("IP from {0}: {1}" -f $service, $ip) "INFO"
                return $ip
            }
        } catch {
            Write-Log ("WARN: {0} not reachable: {1}" -f $service, $_.Exception.Message) "WARN"
        }
    }
    return $null
}

# loop vars for stop logging
$loopCount = 0
$lastIP = $null
$lastDNS = $null

try {
    while ($true) {
        $loopCount++

        $currentIP = Get-PublicIP
        if (-not $currentIP) {
            Write-Log "no IP detected." "ERROR"
            Start-Sleep -Seconds $IntervalSec
            continue
        }

        # query DNS
        $dnsAIP = $null
        foreach ($dnsServer in $dnsServers) {
            try {
                $dnsEntry = Resolve-DnsName $fullDomain -Type A -Server $dnsServer -ErrorAction Stop
                $dnsAIP = ($dnsEntry | Where-Object { $_.QueryType -eq 'A' } | Select-Object -First 1).IPAddress
                if (Test-IPv4 $dnsAIP) { break }
            } catch { continue }
        }

        if (-not $dnsAIP) {
            Write-Log "DNS query failed." "ERROR"
            Start-Sleep -Seconds $IntervalSec
            continue
        }

        # compare + update
        if ($currentIP -ne $dnsAIP) {
            Write-Log ("Update needed: DNS={0} / IP={1}" -f $dnsAIP, $currentIP) "WARN"
            try {
                if (-not $NoPing) {
                    try { Test-Connection -ComputerName "dynamicdns.key-systems.net" -Count 1 -Quiet | Out-Null } catch {}
                }
                Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing -OutFile $updateLogFile -ErrorAction Stop
                Write-Log "DynDNS update successful." "INFO"
            } catch {
                Write-Log "ERROR during DynDNS update: $_" "ERROR"
            }
        } else {
            Write-Log ("DNS ok: {0}" -f $currentIP) "INFO"
        }

        # files
        try { $currentIP | Set-Content $ipFile } catch {}
        try { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content $heartbeatFile } catch {}

        # health log
        if ($loopCount % $HealthEvery -eq 0) {
            Write-Log ("HEALTH: Domain={0}, IP={1}, DNS={2}" -f $fullDomain, $currentIP, $dnsAIP) "INFO"
        }

        # vars for stop log
        $lastIP = $currentIP
        $lastDNS = $dnsAIP

        Start-Sleep -Seconds $IntervalSec
    }
}
finally {
    Write-Log ("=== DynDNS Monitor STOP === Domain={0}, lastIP={1}, lastDNS={2}" -f $fullDomain, $lastIP, $lastDNS) "INFO"
}
