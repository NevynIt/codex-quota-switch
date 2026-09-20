param(
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}
$watcher = Join-Path $installDir "codex-quota-watch.ps1"
$stateFile = Join-Path $baseDir "watcher-state.json"
$stopFile = Join-Path $baseDir "watcher-stop.request"

function Get-WatcherPid {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $state.pid) { return [int]$state.pid }
    }
    catch {}
    return $null
}

$pidValue = Get-WatcherPid
if ($null -ne $pidValue) {
    $p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if ($null -ne $p) {
        if (-not $Restart) {
            Write-Host "Codex quota watcher is already running (PID $pidValue)."
            exit 0
        }

        New-Item -ItemType File -Path $stopFile -Force | Out-Null
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            if ($null -eq (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) { break }
        }
    }
}

Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue

$args = @(
    "-NoLogo",
    "-NoProfile",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$watcher`""
) -join " "

Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden
Start-Sleep -Seconds 2

$pidValue = Get-WatcherPid
if ($null -ne $pidValue -and $null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
    Write-Host "Codex quota watcher started (PID $pidValue)."
    exit 0
}

Write-Warning "Watcher was launched but its heartbeat has not appeared yet. Check: codex-quota-watch-status"
exit 1
