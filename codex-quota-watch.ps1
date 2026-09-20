param(
    [ValidateRange(1, 120)]
    [int]$PollMinutes = 10,

    [ValidateRange(10, 600)]
    [int]$PromptTimeoutSeconds = 120,

    [ValidateRange(1, 240)]
    [int]$SnoozeMinutes = 30,

    [ValidateRange(0, 30)]
    [int]$RecoveryWarningMinutes = 2,

    [switch]$Once
)

$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ([string]::Equals((Split-Path -Leaf $installDir), "bin", [StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $installDir
}
else {
    Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch"
}
$stateFile = Join-Path $baseDir "watcher-state.json"
$logFile = Join-Path $baseDir "watcher.log"
$stopFile = Join-Path $baseDir "watcher-stop.request"
$leaseFile = Join-Path $baseDir "api-lease.json"
$quotaReader = Join-Path $installDir "codex-quota-read.ps1"
$routeScript = Join-Path $installDir "codex-route.ps1"

New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message)

    try {
        if (Test-Path -LiteralPath $logFile -PathType Leaf) {
            $info = Get-Item -LiteralPath $logFile
            if ($info.Length -gt 2MB) {
                Move-Item -LiteralPath $logFile -Destination ($logFile + ".1") -Force
            }
        }
        Add-Content -LiteralPath $logFile -Value ("{0} {1}" -f [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"), $Message)
    }
    catch {}
}

function Save-State {
    param([hashtable]$State)

    $State["pid"] = $PID
    $State["heartbeatUtc"] = [DateTime]::UtcNow.ToString("o")
    $json = $State | ConvertTo-Json -Depth 12
    $tmp = "$stateFile.tmp-$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $stateFile -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Load-State {
    $state = @{
        pid = $PID
        heartbeatUtc = [DateTime]::UtcNow.ToString("o")
        lastCheckUtc = $null
        lastOrdinaryUsageAllowed = $null
        expectedResetAt = $null
        warnedResetAt = $null
        autoSwitchedToApi = $false
        apiAuthorizationMode = $null
        nextPromptUtc = $null
        declinedUntilRecovery = $false
        lastPromptResult = $null
        lastProvider = $null
    }

    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        return $state
    }

    try {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            $state[$p.Name] = $p.Value
        }
    }
    catch {
        Write-Log "Could not parse watcher state; starting fresh: $($_.Exception.Message)"
    }

    return $state
}

function Get-CurrentProvider {
    $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    } else {
        Join-Path $HOME ".codex"
    }

    $config = Join-Path $codexHome "config.toml"
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        return "openai"
    }

    foreach ($line in Get-Content -LiteralPath $config -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*model_provider\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }
    return "openai"
}

function Get-Lease {
    if (-not (Test-Path -LiteralPath $leaseFile -PathType Leaf)) {
        return $null
    }

    try {
        $lease = Get-Content -LiteralPath $leaseFile -Raw | ConvertFrom-Json
        $expires = [DateTime]::Parse(
            [string]$lease.expiresUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()

        return [pscustomobject]@{
            Active = ($expires -gt [DateTime]::UtcNow)
            ExpiresUtc = $expires
            Raw = $lease
        }
    }
    catch {
        Write-Log "Could not read API lease: $($_.Exception.Message)"
        return $null
    }
}

function Show-Popup {
    param(
        [string]$Text,
        [string]$Title = "Codex Provider Router",
        [int]$Seconds = 30,
        [int]$Type = 64
    )

    try {
        $shell = New-Object -ComObject WScript.Shell
        return [int]$shell.Popup($Text, $Seconds, $Title, $Type)
    }
    catch {
        Write-Log "Popup failed: $($_.Exception.Message)"
        return -1
    }
}

function Invoke-Route {
    param(
        [ValidateSet("api", "subscription")]
        [string]$Target
    )

    $routeArgs = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $routeScript
    )

    if ($Target -eq "api") {
        $routeArgs += "-ForceApi"
    }
    else {
        $routeArgs += "-ForceSubscription"
    }

    & powershell.exe @routeArgs | ForEach-Object { Write-Log ("route: " + $_) }
    return $LASTEXITCODE
}

function Read-Quota {
    $json = & $quotaReader -Json
    if ($LASTEXITCODE -ne 0) {
        throw "Quota reader exited with code $LASTEXITCODE."
    }
    return ($json | ConvertFrom-Json)
}

function Format-Reset {
    param($Epoch)

    if ($null -eq $Epoch) {
        return "an unknown time"
    }

    try {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Epoch).ToLocalTime().ToString("ddd yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return "an unknown time"
    }
}

function Parse-Utc {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        return [DateTime]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Sleep-Until {
    param([DateTime]$WhenUtc)

    while ([DateTime]::UtcNow -lt $WhenUtc) {
        if (Test-Path -LiteralPath $stopFile -PathType Leaf) {
            return $false
        }

        $remaining = ($WhenUtc - [DateTime]::UtcNow).TotalSeconds
        $seconds = [int][Math]::Max(1, [Math]::Min(10, $remaining))
        Start-Sleep -Seconds $seconds
    }
    return $true
}

# Per-user/per-session single instance.
$mutexName = "Local\CodexQuotaWatch_" + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value.Replace("-", "_")
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$acquired = $false
try {
    try {
        $acquired = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    if (-not $acquired) {
        Write-Log "Another watcher instance is already running."
        exit 0
    }

    $state = Load-State
    Write-Log "Watcher started. Poll interval=$PollMinutes minutes."

    while ($true) {
        if (Test-Path -LiteralPath $stopFile -PathType Leaf) {
            Write-Log "Stop requested."
            break
        }

        $now = [DateTime]::UtcNow
        $provider = Get-CurrentProvider
        $state["lastProvider"] = $provider

        # If something outside the watcher changed provider away from API, stop
        # claiming ownership of an earlier automatic API switch.
        if ([bool]$state["autoSwitchedToApi"] -and $provider -ne "openai-api") {
            $state["autoSwitchedToApi"] = $false
            $state["apiAuthorizationMode"] = $null
            Write-Log "Provider changed externally to '$provider'; cleared watcher API ownership."
        }

        $lease = Get-Lease

        # A time-limited unattended lease prevents NEW API sessions after expiry.
        # Existing API-backed Codex sessions are deliberately not terminated.
        if ([bool]$state["autoSwitchedToApi"] -and
            [string]$state["apiAuthorizationMode"] -eq "lease" -and
            ($null -eq $lease -or -not $lease.Active) -and
            $provider -eq "openai-api") {

            Write-Log "Unattended API lease expired; returning default provider to subscription."
            $code = Invoke-Route -Target "subscription"
            if ($code -eq 0 -or $code -eq 10) {
                $state["autoSwitchedToApi"] = $false
                $state["apiAuthorizationMode"] = $null
                Show-Popup `
                    -Title "Codex API lease expired" `
                    -Seconds 20 `
                    -Type 64 `
                    -Text "The unattended API lease expired. The default provider has been returned to the ChatGPT subscription.`n`nExisting API-backed sessions were NOT stopped and can continue until they finish or you reload them." | Out-Null
                $provider = Get-CurrentProvider
            }
        }

        try {
            $quota = Read-Quota
            $ordinary = $quota.ordinaryUsageAllowed
            $state["lastCheckUtc"] = [DateTime]::UtcNow.ToString("o")
            $state["lastOrdinaryUsageAllowed"] = $ordinary

            if ($null -ne $quota.nextResetAt) {
                $state["expectedResetAt"] = [int64]$quota.nextResetAt
            }

            if ($null -eq $ordinary) {
                Write-Log "Quota state unavailable; no provider change."
            }
            elseif ([bool]$ordinary) {
                # Recovery: authoritative backend says ordinary included usage is allowed.
                if ([bool]$state["autoSwitchedToApi"] -and $provider -eq "openai-api") {
                    Write-Log "Subscription recovered. Warning user before restoring subscription."
                    Show-Popup `
                        -Title "Codex subscription available again" `
                        -Seconds 20 `
                        -Type 64 `
                        -Text "Your included Codex subscription allowance is available again.`n`nThe default provider will now switch back to the ChatGPT subscription. Existing API-backed sessions are NOT stopped; reload them when convenient if you want them to use the subscription." | Out-Null

                    $code = Invoke-Route -Target "subscription"
                    if ($code -eq 0 -or $code -eq 10) {
                        $provider = Get-CurrentProvider
                        $state["autoSwitchedToApi"] = $false
                        $state["apiAuthorizationMode"] = $null
                        Write-Log "Default provider restored to subscription."
                    }
                }

                # New availability cycle: clear depletion-specific prompt state.
                $state["declinedUntilRecovery"] = $false
                $state["nextPromptUtc"] = $null
                $state["lastPromptResult"] = $null
                $state["warnedResetAt"] = $null
            }
            else {
                # Depleted.
                $expected = $state["expectedResetAt"]
                $resetText = Format-Reset -Epoch $expected

                if ($provider -eq "openai") {
                    if ($null -ne $lease -and $lease.Active) {
                        Write-Log "Subscription depleted and unattended API lease is active; switching to API."
                        $code = Invoke-Route -Target "api"
                        if ($code -eq 0 -or $code -eq 10) {
                            $provider = Get-CurrentProvider
                            $state["autoSwitchedToApi"] = $true
                            $state["apiAuthorizationMode"] = "lease"
                            $state["declinedUntilRecovery"] = $false
                            Show-Popup `
                                -Title "Codex switched to metered API" `
                                -Seconds 20 `
                                -Type 48 `
                                -Text ("The ChatGPT Codex allowance is depleted. An unattended API lease is active until {0}.`n`nThe DEFAULT provider has switched to metered API. Existing sessions were not restarted." -f $lease.ExpiresUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm")) | Out-Null
                        }
                    }
                    elseif (-not [bool]$state["declinedUntilRecovery"]) {
                        $nextPrompt = Parse-Utc -Value $state["nextPromptUtc"]
                        if ($null -eq $nextPrompt -or $now -ge $nextPrompt) {
                            $message = @"
Your included Codex subscription allowance is depleted.

Expected reset hint: $resetText

Switch the DEFAULT provider to the metered OpenAI API?

Existing running sessions will NOT be stopped or migrated.

Yes = switch to API until subscription recovers
No = stay on subscription until it recovers
Cancel = ask again in $SnoozeMinutes minutes

If you do not answer within $PromptTimeoutSeconds seconds, nothing billable is enabled and the watcher will ask again later.
"@
                            # Yes/No/Cancel (3) + Question icon (32) = 35
                            $answer = Show-Popup -Text $message -Title "Codex subscription depleted" -Seconds $PromptTimeoutSeconds -Type 35

                            if ($answer -eq 6) {
                                Write-Log "User approved API fallback."
                                $code = Invoke-Route -Target "api"
                                if ($code -eq 0 -or $code -eq 10) {
                                    $provider = Get-CurrentProvider
                                    $state["autoSwitchedToApi"] = $true
                                    $state["apiAuthorizationMode"] = "prompt"
                                    $state["lastPromptResult"] = "yes"
                                }
                            }
                            elseif ($answer -eq 7) {
                                Write-Log "User declined API fallback until subscription recovery."
                                $state["declinedUntilRecovery"] = $true
                                $state["lastPromptResult"] = "no"
                            }
                            elseif ($answer -eq 2) {
                                Write-Log "User snoozed API fallback prompt."
                                $state["nextPromptUtc"] = $now.AddMinutes($SnoozeMinutes).ToString("o")
                                $state["lastPromptResult"] = "cancel"
                            }
                            else {
                                # Timeout or popup failure: fail safe.
                                Write-Log "API fallback prompt timed out/unavailable; no switch."
                                $state["nextPromptUtc"] = $now.AddMinutes([Math]::Max($SnoozeMinutes, 60)).ToString("o")
                                $state["lastPromptResult"] = "timeout"
                            }
                        }
                    }
                }

                # Warn shortly before the advisory reset if this watcher owns an
                # API switch. We still re-read ordinaryUsageAllowed before changing.
                if ([bool]$state["autoSwitchedToApi"] -and $null -ne $expected) {
                    try {
                        $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$expected).UtcDateTime
                        $warnAt = $resetUtc.AddMinutes(-$RecoveryWarningMinutes)

                        if ($now -ge $warnAt -and
                            [string]$state["warnedResetAt"] -ne [string]$expected) {

                            $state["warnedResetAt"] = [string]$expected
                            Write-Log "Showing pre-reset warning for $expected."
                            Show-Popup `
                                -Title "Codex subscription reset approaching" `
                                -Seconds 20 `
                                -Type 64 `
                                -Text ("Codex reports a subscription reset around {0}.`n`nThe watcher will verify the allowance after that time. If the backend confirms it is available, the DEFAULT provider will switch back to the subscription. Existing API sessions will keep running until you reload or finish them." -f $resetUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")) | Out-Null
                        }
                    }
                    catch {}
                }
            }

            Save-State -State $state
        }
        catch {
            Write-Log "Quota probe failed: $($_.Exception.Message)"
            $state["lastCheckUtc"] = [DateTime]::UtcNow.ToString("o")
            Save-State -State $state
        }

        if ($Once) {
            break
        }

        # Normal 10-minute poll, but wake earlier near a known reset, shortly
        # after a reset, or at an unattended API lease expiry.
        $now = [DateTime]::UtcNow
        $next = $now.AddMinutes($PollMinutes)

        $expected = $state["expectedResetAt"]
        if ($null -ne $expected) {
            try {
                $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$expected).UtcDateTime
                $warnAt = $resetUtc.AddMinutes(-$RecoveryWarningMinutes)
                $probeAt = $resetUtc.AddSeconds(15)

                if ($warnAt -gt $now -and $warnAt -lt $next) {
                    $next = $warnAt
                }
                if ($probeAt -gt $now -and $probeAt -lt $next) {
                    $next = $probeAt
                }

                # If the predicted reset has just passed but the backend still
                # says unavailable, probe once per minute for a short grace window.
                if ($resetUtc -le $now -and $now -lt $resetUtc.AddMinutes(10)) {
                    $soon = $now.AddMinutes(1)
                    if ($soon -lt $next) { $next = $soon }
                }
            }
            catch {}
        }

        $lease = Get-Lease
        if ($null -ne $lease -and $lease.Active -and $lease.ExpiresUtc -gt $now -and $lease.ExpiresUtc -lt $next) {
            $next = $lease.ExpiresUtc
        }

        if (-not (Sleep-Until -WhenUtc $next)) {
            Write-Log "Stop request noticed while sleeping."
            break
        }
    }
}
finally {
    try {
        $state = Load-State
        $state["pid"] = $null
        $state["heartbeatUtc"] = [DateTime]::UtcNow.ToString("o")
        $json = $state | ConvertTo-Json -Depth 12
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($stateFile, $json, $utf8)
    }
    catch {}

    if ($acquired) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    try { $mutex.Dispose() } catch {}
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
    Write-Log "Watcher stopped."
}
