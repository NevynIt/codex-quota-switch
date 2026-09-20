$ErrorActionPreference = "Stop"
$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}
$stateFile = Join-Path $baseDir "watcher-state.json"
$stopFile = Join-Path $baseDir "watcher-stop.request"

$pidValue = $null
if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $state.pid) { $pidValue = [int]$state.pid }
    }
    catch {}
}

New-Item -ItemType File -Path $stopFile -Force | Out-Null

if ($null -eq $pidValue) {
    Write-Host "Stop requested; watcher PID was not recorded."
    exit 0
}

for ($i = 0; $i -lt 30; $i++) {
    if ($null -eq (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
        Write-Host "Codex quota watcher stopped."
        exit 0
    }
    Start-Sleep -Milliseconds 500
}

Write-Warning "Watcher did not exit promptly. It will see the stop request on its next short sleep interval."
exit 1
