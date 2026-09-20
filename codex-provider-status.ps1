$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}

$statusInstallDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    $installDir
}
else {
    Join-Path $baseDir "bin"
}

$realCodexFile = Join-Path $statusInstallDir "real-codex-path.txt"
$facadeExe = Join-Path $statusInstallDir "codex.exe"
$secretFile = Join-Path $baseDir "secret\openai-api-key.dpapi"

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function Get-CurrentProvider {
    $configPath = Join-Path (Get-CodexHome) "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return "openai (default)"
    }

    foreach ($line in Get-Content -LiteralPath $configPath -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*model_provider\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }
    return "openai (default)"
}

function Get-VSCodeCliExecutable {
    $paths = @(
        (Join-Path $env:APPDATA "Code\User\settings.json"),
        (Join-Path $env:APPDATA "Code - Insiders\User\settings.json")
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $text = [System.IO.File]::ReadAllText($path)
        $m = [regex]::Match($text, '["'']chatgpt\.cliExecutable["'']\s*:\s*("(?:\\.|[^"\\])*")')
        if ($m.Success) {
            try {
                return [pscustomobject]@{
                    SettingsPath = $path
                    Value = ($m.Groups[1].Value | ConvertFrom-Json)
                }
            }
            catch {
                return [pscustomobject]@{
                    SettingsPath = $path
                    Value = $m.Groups[1].Value
                }
            }
        }
    }

    return $null
}

$realCodex = if (Test-Path -LiteralPath $realCodexFile -PathType Leaf) {
    [System.IO.File]::ReadAllText($realCodexFile).Trim()
} else {
    "(not recorded)"
}

$vscode = Get-VSCodeCliExecutable

Write-Host "Codex Provider Router status"
Write-Host ""
Write-Host ("Current provider : {0}" -f (Get-CurrentProvider))
Write-Host ("Real codex.exe   : {0}" -f $realCodex)
$resolved = Get-Command codex -ErrorAction SilentlyContinue
Write-Host ("Shell codex       : {0}" -f $(if ($null -ne $resolved) { $resolved.Source } else { "(not found)" }))
Write-Host ("Facade executable: {0}" -f $(if (Test-Path -LiteralPath $facadeExe) { $facadeExe } else { "(missing)" }))
Write-Host ("API key blob     : {0}" -f $(if (Test-Path -LiteralPath $secretFile) { "present" } else { "missing" }))

if ($null -ne $vscode) {
    Write-Host ("VS Code setting   : {0}" -f $vscode.Value)
    Write-Host ("Settings file     : {0}" -f $vscode.SettingsPath)
}
else {
    Write-Host "VS Code setting   : (chatgpt.cliExecutable not set)"
}

Write-Host ""
Write-Host "Subscription allowance:"
& (Join-Path $installDir "codex-route.ps1") -StatusOnly
exit $LASTEXITCODE


Write-Host ""
$watchStatus = Join-Path $installDir "codex-quota-watch-status.ps1"
if (Test-Path -LiteralPath $watchStatus -PathType Leaf) {
    & $watchStatus
}
