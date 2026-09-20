param(
    [double]$Hours,
    [datetime]$Until,
    [switch]$Clear,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}
$leaseFile = Join-Path $baseDir "api-lease.json"
$apiKeyTest = Join-Path $installDir "codex-api-key.ps1"

function Show-Status {
    if (-not (Test-Path -LiteralPath $leaseFile -PathType Leaf)) {
        Write-Host "No unattended API lease is active."
        return
    }

    try {
        $lease = Get-Content -LiteralPath $leaseFile -Raw | ConvertFrom-Json
        $expires = [DateTime]::Parse(
            [string]$lease.expiresUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()

        if ($expires -gt [DateTime]::UtcNow) {
            Write-Host ("Unattended API lease is active until {0}." -f $expires.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz"))
        }
        else {
            Write-Host ("The unattended API lease expired at {0}." -f $expires.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz"))
        }
    }
    catch {
        Write-Warning "Could not parse API lease."
    }
}

$actions = 0
if ($Hours -gt 0) { $actions++ }
if ($PSBoundParameters.ContainsKey("Until")) { $actions++ }
if ($Clear) { $actions++ }
if ($Status) { $actions++ }

if ($actions -eq 0) {
    Show-Status
    exit 0
}
if ($actions -gt 1) {
    throw "Choose exactly one of -Hours, -Until, -Clear, or -Status."
}

if ($Status) {
    Show-Status
    exit 0
}

if ($Clear) {
    Remove-Item -LiteralPath $leaseFile -Force -ErrorAction SilentlyContinue
    Write-Host "Unattended API lease cleared."
    Write-Host "If the watcher had switched the default to API under this lease, it will return the DEFAULT provider to subscription on its next check. Existing API sessions are not stopped."
    exit 0
}

& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $apiKeyTest test
if ($LASTEXITCODE -ne 0) {
    throw "A usable DPAPI-protected API key is required before granting an unattended API lease."
}

$expiresUtc = if ($Hours -gt 0) {
    [DateTime]::UtcNow.AddHours($Hours)
}
else {
    $Until.ToUniversalTime()
}

if ($expiresUtc -le [DateTime]::UtcNow) {
    throw "Lease expiry must be in the future."
}

$lease = [ordered]@{
    createdUtc = [DateTime]::UtcNow.ToString("o")
    expiresUtc = $expiresUtc.ToString("o")
    user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
$lease | ConvertTo-Json | Set-Content -LiteralPath $leaseFile -Encoding UTF8

Write-Host ("Unattended API fallback is permitted until {0}." -f $expiresUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz"))
Write-Host ""
Write-Host "This authorizes the watcher to switch the DEFAULT provider to metered API without a live confirmation if the ChatGPT allowance is depleted."
Write-Host "It does NOT stop an already-running API session when the lease expires. Use a dedicated API project with an enforced hard spend limit for a true spending backstop."
