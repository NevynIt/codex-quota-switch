param(
    [Parameter(Position = 0)]
    [ValidateSet("set", "test", "remove", "path")]
    [string]$Action = "test"
)

$ErrorActionPreference = "Stop"

$secretDir = Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch\secret"
$secretFile = Join-Path $secretDir "openai-api-key.dpapi"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Test-StoredKey {
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
        return $false
    }

    try {
        $encrypted = [System.IO.File]::ReadAllText($secretFile).Trim()
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

switch ($Action.ToLowerInvariant()) {
    "set" {
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null

        Write-Host "Paste your OpenAI API key. Input is hidden."
        $secure = Read-Host "API key" -AsSecureString
        if ($secure.Length -eq 0) {
            throw "No API key was entered."
        }

        # On Windows, omitting -Key uses DPAPI. The resulting blob is not the API key.
        $encrypted = ConvertFrom-SecureString -SecureString $secure

        $tmp = "$secretFile.tmp-$PID"
        try {
            Write-Utf8NoBom -Path $tmp -Text ($encrypted + [Environment]::NewLine)
            Move-Item -LiteralPath $tmp -Destination $secretFile -Force
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Stored the API key as a DPAPI-protected blob:"
        Write-Host "  $secretFile"
        Write-Host "The plaintext key was not written to config.toml or to your user environment."
    }

    "test" {
        if (Test-StoredKey) {
            Write-Host "OK: the stored API key can be decrypted by the current Windows user."
            exit 0
        }

        Write-Host "NOT READY: no usable stored API key was found."
        Write-Host "Run: codex-api-key set"
        exit 2
    }

    "remove" {
        if (Test-Path -LiteralPath $secretFile) {
            Remove-Item -LiteralPath $secretFile -Force
            Write-Host "Removed the stored API-key blob."
        }
        else {
            Write-Host "No stored API-key blob exists."
        }
    }

    "path" {
        Write-Output $secretFile
    }
}
