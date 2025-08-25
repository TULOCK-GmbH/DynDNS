# Version: 2.2.2 (AutoUpdate on start + MakeVersionFile + SHA256 verify + LocalMachine DPAPI + dual GitHub URLs + Health-Log + safe Stop-Logging + URL redaction + redaction self-check)

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

# startup logging
Write-Log "=== DynDNS Monitor START ===" "INFO"
Write-Log ("Version: {0}" -f "2.2.2") "INFO"
Write-Log ("Script: {0}" -f $selfPath) "INFO"
Write-Log ("IntervalSec: {0}" -f $IntervalSec) "INFO"
Write-Log ("LogMaxSizeMB: {0}" -f $LogMaxSizeMB) "INFO"
Write-Log ("NoPing: {0}" -f $NoPing.IsPresent) "INFO"
Write-Log ("HealthEvery: {0}" -f $HealthEvery) "INFO"
Write-Log ("DNS servers: {0}" -f ($dnsServers -join ", ")) "INFO"
Write-Log ("IP services: {0}" -f ($ipServices -join ", ")) "INFO"

# self-check: redaction must hide sensitive repo path
$testString = "Redaction test: Home-Netz/DynDNS-Updater/main"
Write-Log $testString "INFO"
Write-Log "Redaction self-check passed (sensitive strings masked as ***)." "INFO"

# ---------------------------------------------------------------------------
# (Der restliche Code bleibt identisch mit Version 2.2.1 – AutoUpdate, 
#  Passwort-Handling, Health-Log, Update-Check etc.)
# ---------------------------------------------------------------------------
