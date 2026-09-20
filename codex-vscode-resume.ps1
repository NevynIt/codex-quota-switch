param(
    [ValidateRange(1, 500)]
    [int]$Limit = 30,

    [switch]$AllSources,

    [switch]$NoCd
)

$ErrorActionPreference = "Stop"

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $HOME ".codex")
}

function One-Line {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$Max = 90
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $s = ($Text -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) {
        return $s.Substring(0, $Max - 1) + "…"
    }
    return $s
}

function Get-ThreadTitles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    $titles = @{}
    $indexPath = Join-Path $CodexHome "session_index.jsonl"

    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $titles
    }

    foreach ($line in Get-Content -LiteralPath $indexPath -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json
            $id = [string]$row.id
            $name = [string]$row.thread_name

            # Process in file order so a later rename/update wins.
            if (-not [string]::IsNullOrWhiteSpace($id) -and
                -not [string]::IsNullOrWhiteSpace($name)) {
                $titles[$id] = $name
            }
        }
        catch {
            # A damaged index line should not stop session discovery.
        }
    }

    return $titles
}

function Get-FirstUserMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # We normally find the first user message almost immediately.
    # Cap the scan so a very large rollout does not make the menu slow.
    foreach ($line in Get-Content -LiteralPath $Path -TotalCount 200 -ErrorAction SilentlyContinue) {
        try {
            $row = $line | ConvertFrom-Json

            if ($row.type -eq "event_msg" -and
                $row.payload.type -eq "user_message" -and
                -not [string]::IsNullOrWhiteSpace([string]$row.payload.message)) {
                return [string]$row.payload.message
            }

            if ($row.type -eq "response_item" -and
                $row.payload.type -eq "message" -and
                $row.payload.role -eq "user") {

                $pieces = @()
                foreach ($item in @($row.payload.content)) {
                    if ($item.type -eq "input_text" -and
                        -not [string]::IsNullOrWhiteSpace([string]$item.text)) {
                        $pieces += [string]$item.text
                    }
                }

                if ($pieces.Count -gt 0) {
                    return ($pieces -join " ")
                }
            }
        }
        catch {
            # Ignore malformed/non-JSON lines.
        }
    }

    return $null
}

function Get-SessionMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($line in Get-Content -LiteralPath $Path -TotalCount 30 -ErrorAction SilentlyContinue) {
        try {
            $row = $line | ConvertFrom-Json
            if ($row.type -eq "session_meta") {
                return $row.payload
            }
        }
        catch {
        }
    }

    return $null
}

function Get-CurrentProvider {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    $configPath = Join-Path $CodexHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return "openai (default)"
    }

    foreach ($line in Get-Content -LiteralPath $configPath -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[') {
            break
        }

        if ($line -match '^\s*model_provider\s*=\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }

    return "openai (default)"
}

$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
    Write-Error "codex is not on PATH."
}

$codexHome = Get-CodexHome
$sessionsRoot = Join-Path $codexHome "sessions"

if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
    Write-Error "Codex sessions directory does not exist: $sessionsRoot"
}

$titles = Get-ThreadTitles -CodexHome $codexHome

$files = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

$sessions = @()

foreach ($file in $files) {
    $meta = Get-SessionMeta -Path $file.FullName
    if ($null -eq $meta) {
        continue
    }

    $source = [string]$meta.source
    $originator = [string]$meta.originator

    $isVsCode = ($source -eq "vscode" -or $originator -eq "codex_vscode")
    if (-not $AllSources -and -not $isVsCode) {
        continue
    }

    $id = [string]$meta.id
    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = [string]$meta.session_id
    }
    if ([string]::IsNullOrWhiteSpace($id)) {
        continue
    }

    $title = $null
    if ($titles.ContainsKey($id)) {
        $title = [string]$titles[$id]
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-FirstUserMessage -Path $file.FullName
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "(untitled)"
    }

    $sessions += [pscustomobject]@{
        Id       = $id
        Title    = $title
        Modified = $file.LastWriteTime
        Provider = [string]$meta.model_provider
        Cwd      = [string]$meta.cwd
        Source   = $source
        File     = $file.FullName
    }

    if ($sessions.Count -ge $Limit) {
        break
    }
}

if ($sessions.Count -eq 0) {
    if ($AllSources) {
        Write-Host "No Codex sessions were found under $sessionsRoot."
    }
    else {
        Write-Host "No VS Code Codex sessions were found under $sessionsRoot."
        Write-Host "Try: codex-vscode-resume -AllSources"
    }
    exit 1
}

$currentProvider = Get-CurrentProvider -CodexHome $codexHome

Write-Host ""
Write-Host "Current Codex provider: $currentProvider"
Write-Host "Recent Codex conversations:"
Write-Host ""

for ($i = 0; $i -lt $sessions.Count; $i++) {
    $s = $sessions[$i]
    $number = $i + 1
    $stamp = $s.Modified.ToString("yyyy-MM-dd HH:mm")
    $title = One-Line -Text $s.Title -Max 100
    $cwd = One-Line -Text $s.Cwd -Max 110
    $provider = if ([string]::IsNullOrWhiteSpace($s.Provider)) { "(unknown)" } else { $s.Provider }

    Write-Host ("[{0,2}] {1}  {2}" -f $number, $stamp, $title)
    Write-Host ("     provider={0}" -f $provider)

    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        Write-Host ("     {0}" -f $cwd)
    }

    Write-Host ""
}

while ($true) {
    $answer = Read-Host "Conversation number (Q to quit)"

    if ($answer -match '^(q|quit|exit)$') {
        exit 0
    }

    $choice = 0
    if ([int]::TryParse($answer, [ref]$choice) -and
        $choice -ge 1 -and
        $choice -le $sessions.Count) {
        break
    }

    Write-Host "Enter a number from 1 to $($sessions.Count), or Q."
}

$selected = $sessions[$choice - 1]

Write-Host ""
Write-Host ("Resuming: {0}" -f (One-Line -Text $selected.Title -Max 120))
Write-Host ("Thread:   {0}" -f $selected.Id)
Write-Host ("Provider: {0}" -f $currentProvider)

$oldLocation = Get-Location
try {
    if (-not $NoCd -and
        -not [string]::IsNullOrWhiteSpace($selected.Cwd) -and
        (Test-Path -LiteralPath $selected.Cwd -PathType Container)) {

        Set-Location -LiteralPath $selected.Cwd
        Write-Host ("CWD:      {0}" -f $selected.Cwd)
    }
    elseif (-not $NoCd -and -not [string]::IsNullOrWhiteSpace($selected.Cwd)) {
        Write-Warning "Saved conversation CWD no longer exists; keeping current directory."
    }

    Write-Host ""

    # IMPORTANT: a normal config.toml model_provider change is not enough when
    # resuming an existing thread. Codex normally restores the provider that was
    # persisted with the thread. Supplying model_provider as a CLI session flag
    # makes the resume use the current selected provider explicitly.
    $forcedProvider = $currentProvider
    if ($forcedProvider -eq "openai (default)") {
        $forcedProvider = "openai"
    }

    $providerOverride = 'model_provider="' + $forcedProvider + '"'
    Write-Host ("Resume override: {0}" -f $providerOverride)
    Write-Host ""

    & codex -c $providerOverride resume $selected.Id
    $exitCode = $LASTEXITCODE
}
finally {
    Set-Location -LiteralPath $oldLocation
}

exit $exitCode
