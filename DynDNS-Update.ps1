# Version: 2.1.1 (AutoUpdate on start + MakeVersionFile + SHA256 verify + LocalMachine DPAPI + dual GitHub URLs + Health-Log + safe Stop-Logging) 

param(
    [int]$IntervalSec = 60,
    [int]$LogMaxSizeMB = 10,
    [switch]$NoPing,
    [int]$HealthEvery = 5,

    [switch]$UpdateNow,                      # run self-update immediately and exit
    [switch]$NoAutoUpdate,                   # opt-out: skip auto-update on start
    [int]$AutoUpdateHours = 24,              # minimum hours between auto-update checks

    [string]$UpdateInfoUrl = "",             # raw URL to version file (e.g. DynDNS-Update.version)
    [string]$UpdateScriptUrl = "",           # raw URL to script file (e.g. DynDNS-Update.ps1)
    [string]$UpdateHashUrl = "",             # optional raw URL to SHA256 hash file (text containing hex)

    [switch]$MakeVersionFile,                # generate DynDNS-Update.version and exit
    [string]$OutPath                         # optional output path for version file
)

# --- enforce TLS 1.2 ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# === find script path ===
if ($PSScriptRoot) { $selfPath = Join-Path $PSScriptRoot ($MyInvocation.MyCommand.Name) }
else { $selfPath = $MyInvocation.MyCommand.Path }

# locations
$Install          = "C:\SYS\DynDNS"
$settingsFile     = "$Install\Settings\dyndns_settings.txt"
$pwFile           = "$Install\Settings\dyndns_password.txt"     # Base64(ProtectedData LocalMachine)
$infoUrlFile      = "$Install\Settings\github_infourl.sec"      # Base64(ProtectedData LocalMachine)
$scriptUrlFile    = "$Install\Settings\github_scripturl.sec"    # Base64(ProtectedData LocalMachine)
$hashUrlFile      = "$Install\Settings\github_hashurl.sec"      # Base64(ProtectedData LocalMachine)
$autoStampFile    = "$Install\Settings\autoupdate_lastcheck.txt"
$ipFile           = "$Install\Logs\old_ip.txt"
$heartbeatFile    = "$Install\Logs\heartbeat.txt"
$logFile          = "$Install\Logs\ip_monitor.log"
$updateLogFile    = "$Install\Logs\dyndns_update.log"

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
if ($AutoUpdateHours -lt 1){ $AutoUpdateHours = 1 }

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

# --- encrypted update URLs (info + script + optional hash) ---
function Set-UpdateUrls {
    param(
        [string]$InfoUrl,
        [string]$ScriptUrl,
        [string]$HashUrl
    )
    if ([string]::IsNullOrWhiteSpace($InfoUrl))   { $InfoUrl   = Read-Host "enter GitHub raw URL to version file (e.g. DynDNS-Update.version)" }
    if ([string]::IsNullOrWhiteSpace($ScriptUrl)) { $ScriptUrl = Read-Host "enter GitHub raw URL to script (e.g. DynDNS-Update.ps1)" }
    if ([string]::IsNullOrWhiteSpace($HashUrl))   { $HashUrl   = Read-Host "optional: raw URL to SHA256 file (press Enter to skip)" }

    if ([string]::IsNullOrWhiteSpace($InfoUrl) -or [string]::IsNullOrWhiteSpace($ScriptUrl)) {
        Write-Log "missing URL(s)." "WARN"
        return
    }
    try {
        Protect-String $InfoUrl   | Set-Content -Path $infoUrlFile
        Protect-String $ScriptUrl | Set-Content -Path $scriptUrlFile
        if (-not [string]::IsNullOrWhiteSpace($HashUrl)) {
            Protect-String $HashUrl | Set-Content -Path $hashUrlFile
        }
        Write-Log "update URLs saved (machine-bound encrypted)." "INFO"
    } catch {
        Write-Log ("failed to save update URLs: {0}" -f $_.Exception.Message) "ERROR"
    }
}
function Get-UpdateUrls {
    $info = $null; $script = $null; $hash = $null
    if (Test-Path $infoUrlFile)   { try { $info   = Unprotect-String (Get-Content $infoUrlFile   -Raw) } catch { Write-Log "failed to read info URL." "ERROR" } }
    if (Test-Path $scriptUrlFile) { try { $script = Unprotect-String (Get-Content $scriptUrlFile -Raw) } catch { Write-Log "failed to read script URL." "ERROR" } }
    if (Test-Path $hashUrlFile)   { try { $hash   = Unprotect-String (Get-Content $hashUrlFile   -Raw) } catch { Write-Log "failed to read hash URL." "ERROR" } }
    return [pscustomobject]@{ InfoUrl = $info; ScriptUrl = $script; HashUrl = $hash }
}
function Delete-UpdateUrls {
    try {
        if (Test-Path $infoUrlFile)   { Remove-Item $infoUrlFile   -Force }
        if (Test-Path $scriptUrlFile) { Remove-Item $scriptUrlFile -Force }
        if (Test-Path $hashUrlFile)   { Remove-Item $hashUrlFile   -Force }
        Write-Log "update URLs removed." "INFO"
    } catch {
        Write-Log ("failed to remove update URLs: {0}" -f $_.Exception.Message) "ERROR"
    }
}

# --- DynDNS password (machine-bound) ---
function Save-Password([string]$plainPw){
    $encPw = Protect-String $plainPw
    $encPw | Set-Content $pwFile
    Write-Log "DynDNS password saved (machine-bound encrypted)." "INFO"
}
function Load-Password(){
    $encPw = Get-Content $pwFile -ErrorAction Stop -Raw
    $plain = Unprotect-String $encPw
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "password decrypt returned empty string" }
    return $plain
}

# --- version/hash helpers ---
function Get-LocalVersion {
    try {
        $content = Get-Content -Path $selfPath -Raw -ErrorAction Stop
        if ($content -match '(?m)^#\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
            return [version]$Matches[1]
        }
    } catch {}
    return [version]"0.0.0"
}
function Get-RemoteVersionFromInfo([string]$Url, [ref]$outText) {
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $txt  = ($resp.Content | Out-String)
        $outText.Value = $txt
        if ($txt -match '([0-9]+\.[0-9]+\.[0-9]+)') {
            return [version]$Matches[1]
        }
    } catch {
        Write-Log ("remote version fetch failed: {0}" -f $_.Exception.Message) "ERROR"
    }
    return $null
}
function Parse-ExpectedHash([string]$versionText){
    if ([string]::IsNullOrWhiteSpace($versionText)) { return $null }
    if ($versionText -match '(?im)sha256\s*=\s*([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    if ($versionText -match '(?im)^\s*([0-9a-fA-F]{64})\s*$')     { return $Matches[1].ToLower() }
    return $null
}
function Compute-StringSHA256([string]$text){
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $hash  = $sha.ComputeHash($bytes)
        -join ($hash | ForEach-Object { $_.ToString("x2") })
    } finally { $sha.Dispose() }
}
function Get-ExpectedHashFromUrl([string]$Url){
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $txt  = ($resp.Content | Out-String)
        $h = Parse-ExpectedHash $txt
        if ($h) { return $h }
        if ($txt -match '(?im)^\s*([0-9a-fA-F]{64})\b') { return $Matches[1].ToLower() }
    } catch {
        Write-Log ("hash fetch failed: {0}" -f $_.Exception.Message) "ERROR"
    }
    return $null
}

# --- self update using info+script (+ optional hash) ---
function Self-Update([string]$InfoUrl,[string]$ScriptUrl,[string]$HashUrl) {
    if ([string]::IsNullOrWhiteSpace($InfoUrl) -or [string]::IsNullOrWhiteSpace($ScriptUrl)) {
        Write-Log "update URLs are empty. Set them via -UpdateInfoUrl/-UpdateScriptUrl or Set-UpdateUrls." "ERROR"
        return
    }
    Write-Log ("self-update: info={0}" -f $InfoUrl) "INFO"
    Write-Log ("self-update: script={0}" -f $ScriptUrl) "INFO"
    if (-not [string]::IsNullOrWhiteSpace($HashUrl)) { Write-Log ("self-update: hash={0}" -f $HashUrl) "INFO" }

    $localVer = Get-LocalVersion
    $vText = ""
    $refV  = [ref]$vText
    $remoteVer = Get-RemoteVersionFromInfo -Url $InfoUrl -outText $refV
    if (-not $remoteVer) {
        Write-Log "could not read remote version" "ERROR"
        return
    }
    Write-Log ("local version: {0} / remote version: {1}" -f $localVer, $remoteVer) "INFO"

    if ($remoteVer -le $localVer) {
        Write-Log "already up-to-date" "INFO"
        return
    }

    $expectedHash = Parse-ExpectedHash $vText
    if (-not $expectedHash -and -not [string]::IsNullOrWhiteSpace($HashUrl)) {
        $expectedHash = Get-ExpectedHashFromUrl $HashUrl
    }
    if (-not $expectedHash) {
        Write-Log "no expected hash found. proceeding without hash verification." "WARN"
    }

    try {
        $resp = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        $remoteTxt = ($resp.Content | Out-String)

        if ($expectedHash) {
            $actualHash = Compute-StringSHA256 $remoteTxt
            if ($actualHash -ne $expectedHash) {
                Write-Log ("SHA256 mismatch. expected={0} actual={1}" -f $expectedHash, $actualHash) "ERROR"
                return
            }
            Write-Log ("SHA256 verified: {0}" -f $actualHash) "INFO"
        }

        try { [void][ScriptBlock]::Create($remoteTxt) }
        catch {
            Write-Log ("downloaded script failed syntax check: {0}" -f $_.Exception.Message) "ERROR"
            return
        }

        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $remoteTxt -Encoding UTF8

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

# --- MakeVersionFile: build DynDNS-Update.version from this script ---
function Make-VersionFile {
    param(
        [string]$ScriptPath,
        [string]$OutPath
    )
    try {
        if (-not (Test-Path $ScriptPath -PathType Leaf)) {
            throw "script not found: $ScriptPath"
        }
        if ([string]::IsNullOrWhiteSpace($OutPath)) {
            $dir = Split-Path -Path $ScriptPath -Parent
            $OutPath = Join-Path $dir "DynDNS-Update.version"
        }

        $content = Get-Content -Path $ScriptPath -Raw

        $ver = $null
        if ($content -match '(?m)^\s*#\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $ver = $Matches[1] }
        if (-not $ver) { throw "no version header found in $ScriptPath" }

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($content)
            $hash  = $sha.ComputeHash($bytes)
            $hex   = -join ($hash | ForEach-Object { $_.ToString("x2") })
        } finally { $sha.Dispose() }

        $lines = @("version=$ver","sha256=$hex")
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($OutPath, ($lines -join [Environment]::NewLine), $utf8NoBom)

        Write-Host "[INFO] wrote version file: $OutPath" -ForegroundColor Green
        Write-Host "version=$ver"
        Write-Host "sha256=$hex"
    }
    catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# create folders
if (!(Test-Path $Install)) {
    Write-Host "=== creating folder structure ==="
    New-Item -ItemType Directory -Path $Install -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Settings") -Force | Out-Null
}

# MakeVersionFile path (generate version file and exit)
if ($MakeVersionFile) {
    Make-VersionFile -ScriptPath $selfPath -OutPath $OutPath
    exit 0
}

# UpdateNow path (stores URLs from params; uses stored if empty)
if ($UpdateNow) {
    $saved = $false
    if (-not [string]::IsNullOrWhiteSpace($UpdateInfoUrl))   { Protect-String $UpdateInfoUrl   | Set-Content -Path $infoUrlFile;   $saved = $true }
    if (-not [string]::IsNullOrWhiteSpace($UpdateScriptUrl)) { Protect-String $UpdateScriptUrl | Set-Content -Path $scriptUrlFile; $saved = $true }
    if (-not [string]::IsNullOrWhiteSpace($UpdateHashUrl))   { Protect-String $UpdateHashUrl   | Set-Content -Path $hashUrlFile }
    if ($saved) { Write-Log "update URLs saved from parameters (machine-bound encrypted)." "INFO" }

    $urls = Get-UpdateUrls
    $infoUrl   = $UpdateInfoUrl;   if ([string]::IsNullOrWhiteSpace($infoUrl))   { $infoUrl   = $urls.InfoUrl }
    $scriptUrl = $UpdateScriptUrl; if ([string]::IsNullOrWhiteSpace($scriptUrl)) { $scriptUrl = $urls.ScriptUrl }
    $hashUrl   = $UpdateHashUrl;   if ([string]::IsNullOrWhiteSpace($hashUrl))   { $hashUrl   = $urls.HashUrl }

    if ([string]::IsNullOrWhiteSpace($infoUrl) -or [string]::IsNullOrWhiteSpace($scriptUrl)) {
        Write-Host "no update URLs provided or stored. set them with:" -ForegroundColor Yellow
        Write-Host "  -UpdateInfoUrl <url> -UpdateScriptUrl <url> -UpdateNow" -ForegroundColor Yellow
        Write-Host "or persist them interactively:  Set-UpdateUrls" -ForegroundColor Yellow
        return
    }
    Self-Update -InfoUrl $infoUrl -ScriptUrl $scriptUrl -HashUrl $hashUrl
    return
}

# === AutoUpdate on start (ALWAYS unless -NoAutoUpdate) ===
if (-not $NoAutoUpdate) {
    $doCheck = $true
    if (Test-Path $autoStampFile) {
        try {
            $stamp = Get-Content $autoStampFile -Raw | Get-Date
            $hours = (New-TimeSpan -Start $stamp -End (Get-Date)).TotalHours
            if ($hours -lt $AutoUpdateHours) { $doCheck = $false }
        } catch {}
    }
    if ($doCheck) {
        $urls = Get-UpdateUrls
        $infoUrl   = if ([string]::IsNullOrWhiteSpace($UpdateInfoUrl))   { $urls.InfoUrl }   else { $UpdateInfoUrl }
        $scriptUrl = if ([string]::IsNullOrWhiteSpace($UpdateScriptUrl)) { $urls.ScriptUrl } else { $UpdateScriptUrl }
        $hashUrl   = if ([string]::IsNullOrWhiteSpace($UpdateHashUrl))   { $urls.HashUrl }   else { $UpdateHashUrl }

        if (-not [string]::IsNullOrWhiteSpace($infoUrl) -and -not [string]::IsNullOrWhiteSpace($scriptUrl)) {
            Write-Log ("AutoUpdate check (period {0}h)..." -f $AutoUpdateHours) "INFO"
            Self-Update -InfoUrl $infoUrl -ScriptUrl $scriptUrl -HashUrl $hashUrl
            (Get-Date).ToString("o") | Set-Content $autoStampFile
        } else {
            Write-Log "AutoUpdate skipped: URLs not set." "WARN"
        }
    } else {
        Write-Log "AutoUpdate skipped: period not reached." "INFO"
    }
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
    try { Save-Password $plainPw } catch { Write-Log ("failed to save password: {0}" -f $_.Exception.Message) "ERROR"; exit 1 }

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
    $plainPassword = Load-Password
} catch {
    Write-Log "password decrypt failed. prompting for reset..." "WARN"
    try {
        $pw = Read-Host "enter DynDNS password (will be re-saved machine-bound)" -AsSecureString
        $plainPw = [System.Net.NetworkCredential]::new("", $pw).Password
        if ($plainPw.Length -lt 6) { throw "password too short." }
        Save-Password $plainPw
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
Write-Log ("Version: {0}" -f "2.1.1") "INFO"
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
            } catch {
                continue
            }
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

        Start-Sleep -Seconds $IntervalSec
    }
}
finally {
    Write-Log ("=== DynDNS Monitor STOP === Domain={0}, lastIP={1}, lastDNS={2}" -f $fullDomain, $lastIP, $lastDNS) "INFO"
}
