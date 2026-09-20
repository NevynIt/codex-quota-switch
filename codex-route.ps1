param(
    [switch]$StatusOnly,
    [switch]$ForceApi,
    [switch]$ForceSubscription,
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"

$subscriptionProvider = "openai"
$apiProvider = "openai-api"

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function Get-SecretFile {
    return (Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch\secret\openai-api-key.dpapi")
}

function Test-ApiKeyStored {
    $path = Get-SecretFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }

    try {
        $encrypted = [System.IO.File]::ReadAllText($path).Trim()
        if ([string]::IsNullOrWhiteSpace($encrypted)) {
            return $false
        }
        $secure = ConvertTo-SecureString -String $encrypted
        return ($secure.Length -gt 0)
    }
    catch {
        return $false
    }
}

function Get-ConfigPath {
    return (Join-Path (Get-CodexHome) "config.toml")
}

function Read-ConfigText {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ""
    }
    return [System.IO.File]::ReadAllText($path)
}

function Get-CurrentProvider {
    $text = Read-ConfigText
    if ([string]::IsNullOrEmpty($text)) {
        return $subscriptionProvider
    }

    $lines = [regex]::Split($text, "\r?\n")
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') {
            break
        }
        if ($line -match '^\s*model_provider\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }

    # Codex's built-in default provider is OpenAI.
    return $subscriptionProvider
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

function Set-CurrentProvider {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("openai", "openai-api")]
        [string]$Provider
    )

    $path = Get-ConfigPath
    $text = Read-ConfigText
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ([string]::IsNullOrEmpty($text)) {
        $newText = 'model_provider = "' + $Provider + '"' + $newline
    }
    else {
        $lines = [regex]::Split($text, "\r?\n")
        $tableIndex = -1
        $providerIndex = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[') {
                $tableIndex = $i
                break
            }
            if ($lines[$i] -match '^\s*model_provider\s*=') {
                $providerIndex = $i
            }
        }

        if ($providerIndex -ge 0) {
            $lines[$providerIndex] = 'model_provider = "' + $Provider + '"'
        }
        else {
            if ($tableIndex -lt 0) {
                $tableIndex = $lines.Count
            }

            $before = @()
            $after = @()
            if ($tableIndex -gt 0) {
                $before = @($lines[0..($tableIndex - 1)])
            }
            if ($tableIndex -lt $lines.Count) {
                $after = @($lines[$tableIndex..($lines.Count - 1)])
            }

            $lines = @($before) + @('model_provider = "' + $Provider + '"', '') + @($after)
        }

        $newText = ($lines -join $newline)
    }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Copy-Item -LiteralPath $path -Destination ($path + ".codex-route.bak") -Force
    }

    Write-Utf8NoBomAtomic -Path $path -Text $newText
}

function Read-RpcResponse {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][datetime]$Deadline
    )

    while ([datetime]::UtcNow -lt $Deadline) {
        $remainingMs = [int][Math]::Max(
            1,
            [Math]::Min(2147483000, ($Deadline - [datetime]::UtcNow).TotalMilliseconds)
        )

        $task = $Process.StandardOutput.ReadLineAsync()
        if (-not $task.Wait($remainingMs)) {
            throw "Timed out waiting for Codex app-server response id $Id."
        }

        $line = $task.Result
        if ($null -eq $line) {
            throw "Codex app-server closed stdout before response id $Id."
        }

        try {
            $message = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($null -ne $message.id -and [int]$message.id -eq $Id) {
            return $message
        }
    }

    throw "Timed out waiting for Codex app-server response id $Id."
}

function Get-SubscriptionQuotaState {
    if ($env:OS -ne "Windows_NT") {
        throw "This package is designed for Windows."
    }

    # Force this *probe process* to use the built-in OpenAI provider, regardless of
    # whether config.toml currently routes ordinary Codex work through openai-api.
    # This preserves the ChatGPT login in auth.json and lets account/rateLimits/read
    # ask the subscription backend for its authoritative ordinaryUsageAllowed flag.
    $probeCommand = '& codex -c ''model_provider="openai"'' app-server --stdio'
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($probeCommand)
    $encoded = [Convert]::ToBase64String($bytes)

    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershell)) {
        $powershell = "powershell.exe"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell
    $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $stderrTask = $null
    try {
        if (-not $process.Start()) {
            throw "Could not start Codex app-server."
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)

        $init = @{
            jsonrpc = "2.0"
            id = 1
            method = "initialize"
            params = @{
                clientInfo = @{
                    name = "codex-quota-switch"
                    title = "Codex quota switch"
                    version = "1.0.0"
                }
                capabilities = @{
                    experimentalApi = $true
                }
            }
        } | ConvertTo-Json -Compress -Depth 8

        $process.StandardInput.WriteLine($init)
        $process.StandardInput.Flush()

        $initResponse = Read-RpcResponse -Process $process -Id 1 -Deadline $deadline
        if ($null -ne $initResponse.error) {
            throw "Codex app-server initialize failed: $($initResponse.error.message)"
        }

        $initialized = @{
            jsonrpc = "2.0"
            method = "initialized"
        } | ConvertTo-Json -Compress -Depth 4

        $process.StandardInput.WriteLine($initialized)

        $request = @{
            jsonrpc = "2.0"
            id = 2
            method = "account/rateLimits/read"
            params = @{}
        } | ConvertTo-Json -Compress -Depth 6

        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()

        $response = Read-RpcResponse -Process $process -Id 2 -Deadline $deadline
        if ($null -ne $response.error) {
            throw "account/rateLimits/read failed: $($response.error.message)"
        }
        if ($null -eq $response.result) {
            throw "account/rateLimits/read returned no result."
        }

        $result = $response.result
        $ordinaryProperty = $result.PSObject.Properties["ordinaryUsageAllowed"]

        $ordinaryUsageAllowed = $null
        if ($null -ne $ordinaryProperty -and $null -ne $ordinaryProperty.Value) {
            $ordinaryUsageAllowed = [bool]$ordinaryProperty.Value
        }

        $usedPercent = $null
        $resetAt = $null
        if ($null -ne $result.rateLimits -and $null -ne $result.rateLimits.primary) {
            $usedPercent = $result.rateLimits.primary.usedPercent
            $resetAt = $result.rateLimits.primary.resetsAt
        }

        return [pscustomobject]@{
            OrdinaryUsageAllowed = $ordinaryUsageAllowed
            UsedPercent = $usedPercent
            ResetsAt = $resetAt
            Raw = $result
        }
    }
    catch {
        $detail = $_.Exception.Message
        if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
            $stderr = $stderrTask.Result
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $detail = $detail + " Codex stderr: " + $stderr.Trim()
            }
        }
        throw $detail
    }
    finally {
        try { $process.StandardInput.Close() } catch {}
        try {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        catch {}
        try { $process.WaitForExit(1000) | Out-Null } catch {}
        $process.Dispose()
    }
}

$modeCount = 0
if ($StatusOnly) { $modeCount++ }
if ($ForceApi) { $modeCount++ }
if ($ForceSubscription) { $modeCount++ }
if ($modeCount -gt 1) {
    throw "Use at most one of -StatusOnly, -ForceApi, or -ForceSubscription."
}

$current = Get-CurrentProvider

if (-not $ForceApi -and -not $ForceSubscription) {
    if ($current -notin @($subscriptionProvider, $apiProvider)) {
        Write-Output "NO CHANGE: current provider '$current' is not managed by codex-route."
        Write-Output "Use -ForceSubscription or -ForceApi if you intentionally want to replace it."
        exit 3
    }
}

if ($ForceApi) {
    $target = $apiProvider
    $reason = "forced API mode"
}
elseif ($ForceSubscription) {
    $target = $subscriptionProvider
    $reason = "forced subscription mode"
}
else {
    try {
        $quota = Get-SubscriptionQuotaState
    }
    catch {
        Write-Output "NO CHANGE: could not safely determine subscription allowance."
        Write-Output $_.Exception.Message
        exit 4
    }

    if ($null -eq $quota.OrdinaryUsageAllowed) {
        Write-Output "NO CHANGE: Codex did not provide ordinaryUsageAllowed; refusing to guess from percentages."
        Write-Output "Current provider: $current"
        exit 5
    }

    if ($quota.OrdinaryUsageAllowed) {
        $target = $subscriptionProvider
        $reason = "subscription allowance available"
    }
    else {
        $target = $apiProvider
        $reason = "subscription allowance unavailable"
    }

    if ($StatusOnly) {
        $state = if ($quota.OrdinaryUsageAllowed) { "available" } else { "unavailable" }
        $extra = ""
        if ($null -ne $quota.UsedPercent) {
            $extra = "; reported bucket used=$($quota.UsedPercent)%"
        }
        Write-Output "STATUS: subscription=$state; current provider=$current; desired provider=$target$extra"
        exit 0
    }
}

if ($target -eq $apiProvider -and -not (Test-ApiKeyStored)) {
    Write-Output "NO CHANGE: $reason, but no usable DPAPI-protected API key is stored."
    Write-Output "Run: codex-api-key set"
    exit 6
}

if ($current -eq $target) {
    Write-Output "NO CHANGE: provider=$current ($reason)."
    exit 0
}

Set-CurrentProvider -Provider $target
Write-Output "CHANGED: $current -> $target ($reason)."
Write-Output "Reload each VS Code window using 'Developer: Reload Window'."
Write-Output "If the VS Code provider proxy is enabled, you can reopen the SAME thread there; otherwise use codex-vscode-resume."
exit 10
