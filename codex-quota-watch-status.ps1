$ErrorActionPreference = "Stop"
$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}
$stateFile = Join-Path $baseDir "watcher-state.json"
$leaseFile = Join-Path $baseDir "api-lease.json"
$logFile = Join-Path $baseDir "watcher.log"

Write-Host "Codex quota watcher"
Write-Host ""

if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    Write-Host "State: not started yet"
}
else {
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $running = $false
        if ($null -ne $state.pid) {
            $running = ($null -ne (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue))
        }

        Write-Host ("Running             : {0}" -f $running)
        Write-Host ("PID                 : {0}" -f $state.pid)
        Write-Host ("Heartbeat UTC       : {0}" -f $state.heartbeatUtc)
        Write-Host ("Last quota check UTC: {0}" -f $state.lastCheckUtc)
        Write-Host ("Subscription allowed: {0}" -f $state.lastOrdinaryUsageAllowed)
        Write-Host ("Expected reset epoch: {0}" -f $state.expectedResetAt)
        if ($null -ne $state.expectedResetAt) {
            try {
                $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$state.expectedResetAt).ToLocalTime()
                Write-Host ("Expected reset local: {0}" -f $local.ToString("yyyy-MM-dd HH:mm:ss zzz"))
            } catch {}
        }
        Write-Host ("Auto-switched to API: {0}" -f $state.autoSwitchedToApi)
        Write-Host ("Authorization mode  : {0}" -f $state.apiAuthorizationMode)
        Write-Host ("Last prompt result  : {0}" -f $state.lastPromptResult)
    }
    catch {
        Write-Warning "Could not parse watcher state: $($_.Exception.Message)"
    }
}

Write-Host ""
if (Test-Path -LiteralPath $leaseFile -PathType Leaf) {
    try {
        $lease = Get-Content -LiteralPath $leaseFile -Raw | ConvertFrom-Json
        Write-Host ("API lease expires UTC: {0}" -f $lease.expiresUtc)
    }
    catch {
        Write-Host "API lease: unreadable"
    }
}
else {
    Write-Host "API lease: none"
}

Write-Host ("Log: {0}" -f $logFile)
