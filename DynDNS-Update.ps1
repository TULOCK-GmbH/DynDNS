# Version: 2.3.0 (AutoUpdate on start + MakeVersionFile + SHA256 verify + LocalMachine DPAPI + dual GitHub URLs + Health-Log + safe Stop-Logging + URL redaction + self-check)

param(
    [int]$IntervalSec = 60,
    [int]$LogMaxSizeMB = 10,
    [switch]$NoPing,
    [int]$HealthEvery = 5,

    [switch]$UpdateNow,                      
    [switch]$NoAutoUpdate,                   
    [int]$AutoUpdateHours = 24,              

    [string]$UpdateInfoUrl = "",             
    [string]$UpdateScriptUrl = "",           
    [string]$UpdateHashUrl = "",             

    [switch]$MakeVersionFile,                
    [string]$OutPath                         
)

# --- enforce TLS 1.2 ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# === find script path ===
if ($PSScriptRoot) { $selfPath = Join-Path $PSScriptRoot ($MyInvocation.MyCommand.Name) }
else { $selfPath = $MyInvocation.MyCommand.Path }

# locations
$Install          = "C:\SYS\DynDNS"
$settingsFile     = "$Install\Settings\dyndns_settings.txt"
$pwFile           = "$Install\Settings\dyndns_password.txt"
$infoUrlFile      = "$Install\Settings\github_infourl.sec"
$scriptUrlFile    = "$Install\Settings\github_scripturl.sec"
$hashUrlFile      = "$Install\Settings\github_hashurl.sec"
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

# =========================================================
# URL redaction / safe logging
# =========================================================
$Global:RedactPatterns = @(
    'Home-Netz/DynDNS-Updater',
    'home-netz/dyndns-updater'
)

function Redact-Text([string]$text){
    if ([string]::IsNullOrEmpty($text)) { return $text }
    foreach ($pat in $Global:RedactPatterns) {
        $text = $text -replace ('(?i)' + [regex]::Escape($pat)), '***'
    }
    return $text
}

function Safe-Url([string]$url){
    try {
        if ([string]::IsNullOrWhiteSpace($url)) { return "" }
        $u = [Uri]$url
        $file = [System.IO.Path]::GetFileName($u.AbsolutePath)
        if ([string]::IsNullOrEmpty($file)) { $file = "***" }
        return "{0}/{1}" -f $u.Host, $file
    } catch {
        return "***"
    }
}

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

# Logging with rotation + redaction + color
function Write-Log([string]$msg, [string]$level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$level] $msg"
    $entry = Redact-Text $entry
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

# --- LocalMachine DPAPI helpers ---
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

# --- encrypted update URLs ---
function Set-UpdateUrls {
    param(
        [string]$InfoUrl,
        [string]$ScriptUrl,
        [string]$HashUrl
    )
    if ([string]::IsNullOrWhiteSpace($InfoUrl))   { $InfoUrl   = Read-Host "enter GitHub raw URL to version file" }
    if ([string]::IsNullOrWhiteSpace($ScriptUrl)) { $ScriptUrl = Read-Host "enter GitHub raw URL to script file" }
    if ([string]::IsNullOrWhiteSpace($HashUrl))   { $HashUrl   = Read-Host "optional: raw URL to SHA256 file (Enter to skip)" }
    if ([string]::IsNullOrWhiteSpace($InfoUrl) -or [string]::IsNullOrWhiteSpace($ScriptUrl)) {
        Write-Log "missing URL(s)." "WARN"; return
    }
    Protect-String $InfoUrl   | Set-Content -Path $infoUrlFile
    Protect-String $ScriptUrl | Set-Content -Path $scriptUrlFile
    if (-not [string]::IsNullOrWhiteSpace($HashUrl)) {
        Protect-String $HashUrl | Set-Content -Path $hashUrlFile
    }
    Write-Log "update URLs saved (machine-bound encrypted)." "INFO"
}
function Get-UpdateUrls {
    $info = $null; $script = $null; $hash = $null
    if (Test-Path $infoUrlFile)   { $info   = Unprotect-String (Get-Content $infoUrlFile   -Raw) }
    if (Test-Path $scriptUrlFile) { $script = Unprotect-String (Get-Content $scriptUrlFile -Raw) }
    if (Test-Path $hashUrlFile)   { $hash   = Unprotect-String (Get-Content $hashUrlFile   -Raw) }
    return [pscustomobject]@{ InfoUrl = $info; ScriptUrl = $script; HashUrl = $hash }
}
function Delete-UpdateUrls {
    if (Test-Path $infoUrlFile)   { Remove-Item $infoUrlFile   -Force }
    if (Test-Path $scriptUrlFile) { Remove-Item $scriptUrlFile -Force }
    if (Test-Path $hashUrlFile)   { Remove-Item $hashUrlFile   -Force }
    Write-Log "update URLs removed." "INFO"
}

# --- password handling ---
function Save-Password([string]$plainPw){
    Protect-String $plainPw | Set-Content $pwFile
    Write-Log "DynDNS password saved (machine-bound encrypted)." "INFO"
}
function Load-Password(){
    $encPw = Get-Content $pwFile -Raw
    $plain = Unprotect-String $encPw
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "password decrypt empty" }
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
    } catch { Write-Log ("remote version fetch failed: {0}" -f $_.Exception.Message) "ERROR" }
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
    } catch { Write-Log ("hash fetch failed: {0}" -f $_.Exception.Message) "ERROR" }
    return $null
}

# --- Self-Update ---
function Self-Update([string]$InfoUrl,[string]$ScriptUrl,[string]$HashUrl) {
    if ([string]::IsNullOrWhiteSpace($InfoUrl) -or [string]::IsNullOrWhiteSpace($ScriptUrl)) {
        Write-Log "update URLs are empty. Set them via -UpdateInfoUrl/-UpdateScriptUrl or Set-UpdateUrls." "ERROR"
        return
    }
    Write-Log ("self-update: info={0}"   -f (Safe-Url $InfoUrl))   "INFO"
    Write-Log ("self-update: script={0}" -f (Safe-Url $ScriptUrl)) "INFO"
    if ($HashUrl) { Write-Log ("self-update: hash={0}" -f (Safe-Url $HashUrl)) "INFO" }

    $localVer = Get-LocalVersion
    $vText = ""
    $refV  = [ref]$vText
    $remoteVer = Get-RemoteVersionFromInfo -Url $InfoUrl -outText $refV
    if (-not $remoteVer) { Write-Log "could not read remote version" "ERROR"; return }
    Write-Log ("local version: {0} / remote version: {1}" -f $localVer, $remoteVer) "INFO"
    if ($remoteVer -le $localVer) { Write-Log "already up-to-date" "INFO"; return }

    $expectedHash = Parse-ExpectedHash $vText
    if (-not $expectedHash -and $HashUrl) { $expectedHash = Get-ExpectedHashFromUrl $HashUrl }
    if (-not $expectedHash) { Write-Log "no expected hash found. proceeding without hash verification." "WARN" }

    try {
        $resp = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        $remoteTxt = ($resp.Content | Out-String)
        if ($expectedHash) {
            $actualHash = Compute-StringSHA256 $remoteTxt
            if ($actualHash -ne $expectedHash) {
                Write-Log ("SHA256 mismatch. expected={0} actual={1}" -f $expectedHash, $actualHash) "ERROR"; return
            }
            Write-Log ("SHA256 verified: {0}" -f $actualHash) "INFO"
        }
        try { [void][ScriptBlock]::Create($remoteTxt) }
        catch { Write-Log ("downloaded script failed syntax check: {0}" -f $_.Exception.Message) "ERROR"; return }

        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $remoteTxt -Encoding UTF8
        $backup = "$selfPath.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Copy-Item -Path $selfPath -Destination $backup -Force
        Copy-Item -Path $tmp -Destination $selfPath -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log ("updated script to version {0}. backup: {1}" -f $remoteVer, $backup) "INFO"
        Write-Host "Self-update complete. Please re-run the script." -ForegroundColor Green
    } catch { Write-Log ("self-update failed: {0}" -f $_.Exception.Message) "ERROR" }
}

# --- MakeVersionFile ---
function Make-VersionFile {
    param([string]$ScriptPath,[string]$OutPath)
    try {
        if (-not (Test-Path $ScriptPath -PathType Leaf)) { throw "script not found: $ScriptPath" }
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
    } catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

# === create folders ===
if (!(Test-Path $Install)) {
    New-Item -ItemType Directory -Path $Install -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Install "Settings") -Force | Out-Null
}

# === MakeVersionFile ===
if ($MakeVersionFile) { Make-VersionFile
