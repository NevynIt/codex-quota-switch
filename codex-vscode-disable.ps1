$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path (Split-Path -Parent $installDir) "vscode-proxy-state.json"

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "No VS Code proxy state file exists. Nothing to restore automatically."
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$settingsPath = [string]$state.settingsPath

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    Write-Host "VS Code settings file no longer exists: $settingsPath"
    exit 0
}

$text = [System.IO.File]::ReadAllText($settingsPath)
$pattern = '(?m)(["'']chatgpt\.cliExecutable["'']\s*:\s*)("(?:\\.|[^"\\])*")'
$match = [regex]::Match($text, $pattern)

if (-not $match.Success) {
    Write-Host "chatgpt.cliExecutable is no longer present. Nothing to change."
    exit 0
}

$current = $null
try { $current = $match.Groups[2].Value | ConvertFrom-Json } catch {}

if (-not [string]::Equals([string]$current, [string]$state.proxyValue, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "chatgpt.cliExecutable has changed since the proxy was enabled:"
    Write-Warning "  $current"
    Write-Warning "It was left untouched."
    exit 2
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.before-codex-proxy-disable-$stamp.bak" -Force

if ([bool]$state.hadSetting) {
    $oldJson = ([string]$state.oldValue) | ConvertTo-Json -Compress
    $replacement = '${1}' + $oldJson
}
else {
    # Empty means "use the extension's bundled/default CLI".
    $replacement = '${1}""'
}

$newText = [regex]::Replace($text, $pattern, $replacement, 1)
[System.IO.File]::WriteAllText($settingsPath, $newText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Disabled the Codex VS Code facade."
Write-Host "Reload VS Code with: Developer: Reload Window"
