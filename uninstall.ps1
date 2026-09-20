param(
    [switch]$KeepSecret,
    [switch]$KeepVSCodeSetting
)

$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch\bin"
$baseDir = Split-Path -Parent $installDir
$secretDir = Join-Path $baseDir "secret"

$watchStop = Join-Path $installDir "codex-quota-watch-stop.ps1"
if (Test-Path -LiteralPath $watchStop -PathType Leaf) {
    try { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $watchStop | Out-Null } catch {}
}

try {
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "CodexQuotaWatch" -ErrorAction SilentlyContinue
}
catch {}


if (-not $KeepVSCodeSetting) {
    $disable = Join-Path $installDir "codex-vscode-disable.ps1"
    if (Test-Path -LiteralPath $disable -PathType Leaf) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $disable
    }
}

if (-not $KeepSecret -and (Test-Path -LiteralPath $secretDir)) {
    Remove-Item -LiteralPath $secretDir -Recurse -Force
    Write-Host "Removed the DPAPI-protected API-key blob."
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $parts = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not [string]::Equals($_.TrimEnd('\'), $installDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    })
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
}

if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}

Write-Host "Removed commands, facade executable, and PATH entry."
Write-Host "The [model_providers.openai-api] block in ~/.codex/config.toml is intentionally left in place."
