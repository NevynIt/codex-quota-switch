$ErrorActionPreference = "Stop"

$secretDir = Join-Path $env:LOCALAPPDATA "CodexQuotaSwitch\secret"
$secretFile = Join-Path $secretDir "openai-api-key.dpapi"

try {
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
        [Console]::Error.WriteLine("OpenAI API key is not stored. Run: codex-api-key set")
        exit 2
    }

    $encrypted = [System.IO.File]::ReadAllText($secretFile).Trim()
    if ([string]::IsNullOrWhiteSpace($encrypted)) {
        throw "Stored API-key blob is empty."
    }

    # With no explicit -Key, Windows PowerShell uses Windows DPAPI.
    $secure = ConvertTo-SecureString -String $encrypted

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw "Stored API key decrypted to an empty value."
        }

        # IMPORTANT: stdout must contain only the bearer token.
        [Console]::Out.Write($plain)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
    }
}
catch {
    [Console]::Error.WriteLine("Could not retrieve the OpenAI API key: $($_.Exception.Message)")
    exit 2
}
