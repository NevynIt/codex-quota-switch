param(
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 15,

    [switch]$Json
)

$ErrorActionPreference = "Stop"

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

function Get-Quota {
    if ($env:OS -ne "Windows_NT") {
        throw "This package is designed for Windows."
    }

    # Force only this probe to the built-in OpenAI/ChatGPT provider, irrespective
    # of the provider currently selected for normal Codex work.
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
                    name = "codex-quota-watch"
                    title = "Codex quota watcher"
                    version = "2.0.0"
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

        $process.StandardInput.WriteLine((@{
            jsonrpc = "2.0"
            method = "initialized"
        } | ConvertTo-Json -Compress -Depth 4))

        $request = @{
            jsonrpc = "2.0"
            id = 2
            method = "account/rateLimits/read"
            params = @{
                excludeResetCreditDetails = $true
            }
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

        return $response.result
    }
    catch {
        $detail = $_.Exception.Message
        if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
            $stderr = $stderrTask.Result
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $detail += " Codex stderr: " + $stderr.Trim()
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

function Add-Window {
    param(
        [System.Collections.ArrayList]$List,
        [AllowNull()]$Window,
        [string]$Kind,
        [string]$LimitId
    )

    if ($null -eq $Window) { return }

    $reset = $null
    if ($null -ne $Window.resetsAt) {
        $reset = [int64]$Window.resetsAt
    }

    [void]$List.Add([pscustomobject]@{
        LimitId = $LimitId
        Kind = $Kind
        UsedPercent = [int]$Window.usedPercent
        ResetsAt = $reset
    })
}

$result = Get-Quota
$ordinaryProperty = $result.PSObject.Properties["ordinaryUsageAllowed"]
$ordinary = $null
if ($null -ne $ordinaryProperty -and $null -ne $ordinaryProperty.Value) {
    $ordinary = [bool]$ordinaryProperty.Value
}

$windows = New-Object System.Collections.ArrayList

if ($null -ne $result.rateLimits) {
    $limitId = if ($null -ne $result.rateLimits.limitId) { [string]$result.rateLimits.limitId } else { "default" }
    Add-Window -List $windows -Window $result.rateLimits.primary -Kind "primary" -LimitId $limitId
    Add-Window -List $windows -Window $result.rateLimits.secondary -Kind "secondary" -LimitId $limitId
}

if ($null -ne $result.rateLimitsByLimitId) {
    foreach ($prop in $result.rateLimitsByLimitId.PSObject.Properties) {
        $snap = $prop.Value
        if ($null -eq $snap) { continue }
        Add-Window -List $windows -Window $snap.primary -Kind "primary" -LimitId ([string]$prop.Name)
        Add-Window -List $windows -Window $snap.secondary -Kind "secondary" -LimitId ([string]$prop.Name)
    }
}

$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$futureExhausted = @(
    $windows |
    Where-Object { $null -ne $_.ResetsAt -and $_.ResetsAt -gt $nowEpoch -and $_.UsedPercent -ge 100 } |
    Sort-Object ResetsAt
)
$futureAny = @(
    $windows |
    Where-Object { $null -ne $_.ResetsAt -and $_.ResetsAt -gt $nowEpoch } |
    Sort-Object ResetsAt
)

$nextReset = $null
if ($futureExhausted.Count -gt 0) {
    $nextReset = [int64]$futureExhausted[0].ResetsAt
}
elseif ($futureAny.Count -gt 0) {
    $nextReset = [int64]$futureAny[0].ResetsAt
}

$out = [pscustomobject]@{
    checkedAtUtc = [DateTime]::UtcNow.ToString("o")
    ordinaryUsageAllowed = $ordinary
    nextResetAt = $nextReset
    windows = @($windows)
    raw = $result
}

if ($Json) {
    $out | ConvertTo-Json -Compress -Depth 20
}
else {
    $state = if ($null -eq $ordinary) { "unknown" } elseif ($ordinary) { "available" } else { "unavailable" }
    Write-Host "Subscription: $state"
    if ($null -ne $nextReset) {
        $local = [DateTimeOffset]::FromUnixTimeSeconds($nextReset).ToLocalTime()
        Write-Host ("Next reset hint: {0}" -f $local.ToString("yyyy-MM-dd HH:mm:ss zzz"))
    }
    $windows | Format-Table LimitId, Kind, UsedPercent, ResetsAt -AutoSize
}
