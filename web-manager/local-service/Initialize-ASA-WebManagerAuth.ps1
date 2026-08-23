param(
    [Security.SecureString]$Password,
    [ValidatePattern('^[A-Za-z0-9_-]{3,32}$')][string]$Username = 'gustav',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '.secrets\auth.json')
)

$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $ConfigPath) {
    Write-Output "Web manager authentication is already configured at $ConfigPath"
    exit 0
}

if (-not $Password) {
    $first = Read-Host 'Create a password for ASA Control Deck' -AsSecureString
    $second = Read-Host 'Repeat the password' -AsSecureString
    $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
    $secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
    try {
        $firstText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr)
        $secondText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPtr)
        if ($firstText -cne $secondText) { throw 'The passwords did not match.' }
        $Password = $first
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr)
        $firstText = $null
        $secondText = $null
    }
}

$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    if ($plain.Length -lt 12) { throw 'Use at least 12 characters for the web manager password.' }
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $iterations = 210000
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($plain, $salt, $iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $verifier = $derive.GetBytes(32) } finally { $derive.Dispose() }

    $folder = Split-Path -Parent $ConfigPath
    [void](New-Item -ItemType Directory -Path $folder -Force)
    [ordered]@{
        Version = 1
        Scheme = 'Basic-PBKDF2-SHA256'
        Username = $Username
        Salt = [Convert]::ToBase64String($salt)
        Iterations = $iterations
        Verifier = [Convert]::ToBase64String($verifier)
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Output "ASA Control Deck password configured for username '$Username'. The password itself was not saved."
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    $plain = $null
}
