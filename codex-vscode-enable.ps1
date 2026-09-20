param(
    [switch]$Force,
    [string]$SettingsPath
)

$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$facadeExe = Join-Path $installDir "codex.exe"
$statePath = Join-Path (Split-Path -Parent $installDir) "vscode-proxy-state.json"

if (-not (Test-Path -LiteralPath $facadeExe -PathType Leaf)) {
    throw "Codex provider facade has not been built: $facadeExe"
}

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $candidates = @(
        (Join-Path $env:APPDATA "Code\User\settings.json"),
        (Join-Path $env:APPDATA "Code - Insiders\User\settings.json")
    )

    $SettingsPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = $candidates[0]
    }
}

$settingsDir = Split-Path -Parent $SettingsPath
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $text = [System.IO.File]::ReadAllText($SettingsPath)
}
else {
    $text = "{}"
}

$pattern = '(?m)(["'']chatgpt\.cliExecutable["'']\s*:\s*)("(?:\\.|[^"\\])*")'
$match = [regex]::Match($text, $pattern)

$oldValue = $null
$hadSetting = $false

if ($match.Success) {
    $hadSetting = $true
    try {
        $oldValue = $match.Groups[2].Value | ConvertFrom-Json
    }
    catch {
        $oldValue = $match.Groups[2].Value.Trim('"')
    }

    if (-not $Force -and
        -not [string]::IsNullOrWhiteSpace($oldValue) -and
        -not [string]::Equals($oldValue, $facadeExe, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "chatgpt.cliExecutable is already set to:"
        Write-Warning "  $oldValue"
        Write-Warning "It was not replaced. Re-run with -Force if you want CodexQuotaSwitch to take control."
        exit 2
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.codex-provider-proxy-$stamp.bak" -Force
}

$state = [ordered]@{
    settingsPath = $SettingsPath
    hadSetting = $hadSetting
    oldValue = $oldValue
    proxyValue = $facadeExe
}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

$jsonValue = $facadeExe | ConvertTo-Json -Compress

if ($match.Success) {
    $replacement = '${1}' + $jsonValue
    $newText = [regex]::Replace($text, $pattern, $replacement, 1)
}
else {
    $brace = $text.IndexOf('{')
    if ($brace -lt 0) {
        throw "VS Code settings file does not contain a JSON object opening brace: $SettingsPath"
    }

    $insertion = [Environment]::NewLine + '  "chatgpt.cliExecutable": ' + $jsonValue + ','
    $newText = $text.Insert($brace + 1, $insertion)
}

[System.IO.File]::WriteAllText($SettingsPath, $newText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Enabled Codex provider facade for VS Code:"
Write-Host "  chatgpt.cliExecutable = $facadeExe"
Write-Host ""
Write-Host "Reload VS Code with: Developer: Reload Window"
Write-Host "VS Code now launches the same codex.exe facade used by the shell; app-server thread start/resume follows the current model_provider."
