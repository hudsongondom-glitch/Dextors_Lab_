# Ms.Cert.ps1 - certificate credentials for Entra app-only auth.
#
# WHY THIS EXISTS: SharePoint REST/CSOM rejects app-only tokens obtained with a CLIENT SECRET
# ("Unsupported app only token", appidacr=1). It only accepts certificate-backed app-only tokens
# (appidacr=2). Microsoft Graph accepts either. Since SPO REST is a primary API for this lab,
# certificate auth is required - it is not optional polish.

function ConvertTo-LabBase64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Creates a self-signed signing certificate, writes the PFX (private, git-ignored) and the CER
# (public, for upload to the app registration). Returns the thumbprint and paths.
function New-LabSigningCertificate {
    param(
        [string]$Subject = 'dextors-lab',
        [int]$Years = 1,
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][string]$CerPath,
        [Parameter(Mandatory)][string]$Password
    )
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$Subject", $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears($Years))

    [IO.File]::WriteAllBytes($PfxPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password))
    [IO.File]::WriteAllBytes($CerPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

    [pscustomobject]@{
        Thumbprint = $cert.Thumbprint
        NotAfter   = $cert.NotAfter
        PfxPath    = $PfxPath
        CerPath    = $CerPath
    }
}

function Get-LabCertificate {
    param([Parameter(Mandatory)][string]$PfxPath, [Parameter(Mandatory)][string]$Password)
    if (-not (Test-Path $PfxPath)) { throw "Certificate not found: $PfxPath. Run: .\lab.ps1 BUILD lab/setup-app-certificate" }
    $bytes = [IO.File]::ReadAllBytes($PfxPath)
    # X509Certificate2's byte[] constructor is obsolete on modern .NET; prefer the loader.
    $cert = if ([Type]::GetType('System.Security.Cryptography.X509Certificates.X509CertificateLoader')) {
        [System.Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($bytes, $Password)
    }
    else {
        [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $Password)
    }
    # Preflight: fail with a clear reason now, not with an opaque AADSTS error after Entra
    # rejects a token request signed with an expired (or not-yet-valid) certificate.
    $now = Get-Date
    if ($now -lt $cert.NotBefore) {
        throw "Certificate $PfxPath is not valid yet (NotBefore $($cert.NotBefore.ToString('u'))). Check the system clock or regenerate the certificate."
    }
    if ($now -gt $cert.NotAfter) {
        throw "Certificate $PfxPath expired $($cert.NotAfter.ToString('u')). Run: .\lab.ps1 BUILD lab/setup-app-certificate -Identity <name> -Force, then re-upload the .cer."
    }
    $cert
}

# Builds the signed client_assertion JWT that Entra accepts in place of a client secret.
function New-LabClientAssertion {
    param(
        [Parameter(Mandatory)]$Certificate,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TokenUri
    )
    $x5t = ConvertTo-LabBase64Url -Bytes $Certificate.GetCertHash()      # SHA-1 thumbprint bytes
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = $x5t } | ConvertTo-Json -Compress
    $payload = @{
        aud = $TokenUri; iss = $ClientId; sub = $ClientId
        jti = [guid]::NewGuid().ToString(); nbf = $now; exp = $now + 600
    } | ConvertTo-Json -Compress

    $unsigned = (ConvertTo-LabBase64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' +
                (ConvertTo-LabBase64Url ([Text.Encoding]::UTF8.GetBytes($payload)))

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'Certificate has no usable RSA private key.' }
    $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    "$unsigned.$(ConvertTo-LabBase64Url $sig)"
}
