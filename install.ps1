param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch\bin"),
    [switch]$SkipVSCodeProxy,
    [switch]$ForceVSCodeProxy,
    [switch]$SkipWatcher
)

$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This installer is designed for Windows."
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tmp = Join-Path $dir (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Path)), $PID)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $utf8)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function Ensure-TopLevelProvider {
    param([Parameter(Mandatory = $true)][string]$ConfigText)

    $newline = if ($ConfigText.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ([string]::IsNullOrEmpty($ConfigText)) {
        return 'model_provider = "openai"' + $newline
    }

    $lines = [regex]::Split($ConfigText, "\r?\n")
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*model_provider\s*=') { return $ConfigText }
    }

    $tableIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') {
            $tableIndex = $i
            break
        }
    }

    if ($tableIndex -lt 0) {
        return ($ConfigText.TrimEnd("`r", "`n") + $newline + 'model_provider = "openai"' + $newline)
    }

    $before = @()
    $after = @()
    if ($tableIndex -gt 0) { $before = @($lines[0..($tableIndex - 1)]) }
    $after = @($lines[$tableIndex..($lines.Count - 1)])

    return ((@($before) + @('model_provider = "openai"', '') + @($after)) -join $newline)
}

# Resolve the real Codex executable BEFORE this package changes PATH or VS Code.
# On an upgrade, `codex` may already resolve to our own wrapper; in that case
# retain the previously recorded real executable.
$recordedRealCodex = Join-Path $InstallDir "real-codex-path.txt"
$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
$resolvedCodex = if ($null -ne $codexCommand) { [string]$codexCommand.Source } else { $null }
$facadeCandidate = Join-Path $InstallDir "codex.exe"

if (-not [string]::IsNullOrWhiteSpace($resolvedCodex) -and
    [string]::Equals($resolvedCodex, $facadeCandidate, [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $recordedRealCodex -PathType Leaf)) {
    $realCodex = [System.IO.File]::ReadAllText($recordedRealCodex).Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace($resolvedCodex)) {
    $realCodex = $resolvedCodex
}
elseif (Test-Path -LiteralPath $recordedRealCodex -PathType Leaf) {
    $realCodex = [System.IO.File]::ReadAllText($recordedRealCodex).Trim()
}
else {
    throw "codex is not on PATH. Install/fix the standalone Codex CLI first, then rerun this installer."
}

if ([string]::IsNullOrWhiteSpace($realCodex) -or -not (Test-Path -LiteralPath $realCodex -PathType Leaf)) {
    throw "Could not resolve the real Codex executable."
}

if ([System.IO.Path]::GetExtension($realCodex) -ne ".exe") {
    throw "The provider wrapper needs a real codex.exe. Resolved instead: $realCodex"
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$payload = @(
    "codex-route.ps1",
    "codex-route.cmd",
    "codex-api-key.ps1",
    "codex-api-key.cmd",
    "codex-api-token.ps1",
    "codex-vscode-resume.ps1",
    "codex-vscode-resume.cmd",
    "codex-vscode-enable.ps1",
    "codex-vscode-enable.cmd",
    "codex-vscode-disable.ps1",
    "codex-vscode-disable.cmd",
    "codex-provider-facade.cs",
    "codex-provider-status.ps1",
    "codex-provider-status.cmd",
    "codex-quota-read.ps1",
    "codex-quota-watch.ps1",
    "codex-quota-watch-start.ps1",
    "codex-quota-watch-start.cmd",
    "codex-quota-watch-stop.ps1",
    "codex-quota-watch-stop.cmd",
    "codex-quota-watch-status.ps1",
    "codex-quota-watch-status.cmd",
    "codex-api-lease.ps1",
    "codex-api-lease.cmd"
)

foreach ($name in $payload) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Installer payload is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir $name) -Force
}

Write-Utf8NoBomAtomic -Path (Join-Path $InstallDir "real-codex-path.txt") -Text ($realCodex + [Environment]::NewLine)

# Build the ONE facade executable used by BOTH the shell and VS Code.
$facadeSource = [System.IO.File]::ReadAllText((Join-Path $InstallDir "codex-provider-facade.cs"))

# Package sanity check: the facade must construct quoted model_provider values
# without nested C# backslash escaping. This catches packaging regressions before
# invoking the compiler.
if ($facadeSource -notmatch [regex]::Escape('model_provider=" + ((char)34) + provider + ((char)34)')) {
    throw "Packaged facade source failed its model_provider quoting sanity check."
}

$facadeExe = Join-Path $InstallDir "codex.exe"
Remove-Item -LiteralPath $facadeExe -Force -ErrorAction SilentlyContinue

Add-Type `
    -TypeDefinition $facadeSource `
    -Language CSharp `
    -ReferencedAssemblies @("System.dll", "System.Core.dll", "System.Web.Extensions.dll") `
    -OutputAssembly $facadeExe `
    -OutputType ConsoleApplication

if (-not (Test-Path -LiteralPath $facadeExe -PathType Leaf)) {
    throw "Failed to build Codex provider facade."
}

$facadeVersion = & $facadeExe --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "The Codex provider facade was built, but pass-through to the real Codex executable failed: $facadeVersion"
}

# Put the wrapper directory FIRST in the user PATH so normal shell `codex`
# calls resolve to our transparent wrapper before the standalone Codex install.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @()
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$remaining = @()
foreach ($part in $parts) {
    if (-not [string]::Equals(
        $part.TrimEnd('\'),
        $InstallDir.TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $remaining += $part
    }
}

$newUserPath = if ($remaining.Count -eq 0) {
    $InstallDir
}
else {
    $InstallDir + ';' + ($remaining -join ';')
}

$pathChanged = -not [string]::Equals($newUserPath, $userPath, [StringComparison]::OrdinalIgnoreCase)
if ($pathChanged) {
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
}

# Configure Codex custom API provider.
$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome "config.toml"
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

$configText = ""
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $configText = [System.IO.File]::ReadAllText($configPath)
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $configPath -Destination "$configPath.before-codex-provider-router-$stamp.bak" -Force
}

$configText = Ensure-TopLevelProvider -ConfigText $configText

$providerExists = $configText -match '(?m)^\s*\[model_providers\.openai-api\]\s*$'
if (-not $providerExists) {
    $tokenScript = Join-Path $InstallDir "codex-api-token.ps1"
    $tokenScriptToml = ConvertTo-TomlString $tokenScript

    $providerBlock = @"

# Added by CodexProviderRouter.
[model_providers.openai-api]
name = "OpenAI API (metered)"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
requires_openai_auth = false

[model_providers.openai-api.auth]
command = "powershell.exe"
args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $tokenScriptToml]
timeout_ms = 5000
refresh_interval_ms = 0
"@

    if (-not [string]::IsNullOrEmpty($configText) -and -not $configText.EndsWith("`n")) {
        $configText += [Environment]::NewLine
    }
    $configText += $providerBlock
}
else {
    Write-Warning "config.toml already contains [model_providers.openai-api]; that provider block was left unchanged."
}

Write-Utf8NoBomAtomic -Path $configPath -Text $configText

Write-Host ""
Write-Host "Installed CodexProviderRouter"
Write-Host "  Real Codex: $realCodex"
Write-Host "  Commands:   $InstallDir"
Write-Host "  Config:     $configPath"
Write-Host "  Facade:     $facadeExe"
Write-Host ""

if ($pathChanged) {
    Write-Host "Moved the command directory to the front of your user PATH."
    Write-Host "Open a new terminal once so `codex` resolves to the transparent wrapper."
}

if (-not $SkipVSCodeProxy) {
    $enable = Join-Path $InstallDir "codex-vscode-enable.ps1"
    $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $enable)
    if ($ForceVSCodeProxy) { $args += "-Force" }

    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "VS Code proxy was not enabled automatically. Run: codex-vscode-enable -Force"
    }
}


if (-not $SkipWatcher) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $watcherPath = Join-Path $InstallDir "codex-quota-watch.ps1"
    $runCommand = 'powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watcherPath + '"'

    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "CodexQuotaWatch" -Value $runCommand

    $watchStart = Join-Path $InstallDir "codex-quota-watch-start.ps1"
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $watchStart
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Quota watcher did not confirm a clean start. Run: codex-quota-watch-status"
    }
    Write-Host "Quota watcher enabled for this user and configured to start at logon."
}

Write-Host ""
Write-Host "Next:"
Write-Host "  codex-api-key set"
Write-Host "  codex-api-key test"
Write-Host "  codex login status"
Write-Host "  codex-route"
Write-Host "  codex-quota-watch-status"
Write-Host "  codex-api-lease -Hours 8   # optional unattended fallback"
Write-Host ""
Write-Host "After any CHANGED result, reload VS Code: Developer: Reload Window"
