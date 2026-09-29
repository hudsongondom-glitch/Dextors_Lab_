<#
Generates a self-signed certificate for Entra app-only auth and stores its password in the
git-ignored secrets file. Needed because SharePoint REST rejects secret-based app-only tokens
("Unsupported app only token") - it requires a certificate credential.

  DONE = certificate created; the .cer must then be uploaded to the app registration by hand.

Creates no cloud resources. Local files only.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity = 'msg-app',
    [int]$Years = 1
)

$Recipe = @{
    Name        = 'lab/setup-app-certificate'
    Product     = 'lab'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create a self-signed cert for certificate-based app-only auth (required by SharePoint REST).'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$run = Start-LabRun -Name 'setup-app-certificate' -Mode BUILD -Product lab -DryRun:$DryRun `
    -Request "Create a certificate credential for identity '$Identity'." `
    -Plan @('Generate self-signed cert', 'Write PFX (private) and CER (public)', 'Store the PFX password in the secrets file', 'Print upload instructions')

$ident = Get-LabIdentity -Name $Identity
if ([string]::IsNullOrWhiteSpace($ident.clientId)) {
    Stop-LabRunBlocked -Problems @("Identity '$Identity' has no clientId in config/lab.config.json.") -NextStep 'Fill in the clientId and rerun.'
    return
}

$root = Get-LabHome
$pfx = Join-Path $root "config\lab-cert-$Identity.local.pfx"
$cer = Join-Path $root "config\lab-cert-$Identity.local.cer"

if ((Test-Path $pfx) -and -not $Force) {
    Complete-LabRun -Verdict DONE -Summary "Certificate already exists: $(Split-Path $pfx -Leaf). Pass -Force to replace it." | Out-Null
    return
}

# Random password, stored alongside the other lab secrets.
$pw = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$info = New-LabSigningCertificate -Subject "dextors-lab-$Identity" -Years $Years -PfxPath $pfx -CerPath $cer -Password $pw

$secretsPath = Join-Path $root 'config\lab.secrets.local.json'
$secrets = if (Test-Path $secretsPath) { Get-Content $secretsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$pwEnv = if ($ident.certPasswordEnvVar) { $ident.certPasswordEnvVar } else { 'LAB_CERT_PASSWORD' }
$secrets | Add-Member -NotePropertyName $pwEnv -NotePropertyValue $pw -Force
$secrets | ConvertTo-Json -Depth 5 | Set-Content $secretsPath -Encoding utf8

Add-LabEvidenceNote "certificate created for '$Identity' ($($ident.displayName))"
Add-LabEvidenceNote "thumbprint $($info.Thumbprint), valid until $($info.NotAfter.ToString('u'))"
Add-LabEvidenceNote "PFX (private, git-ignored): $(Split-Path $pfx -Leaf)"
Add-LabEvidenceNote "CER (public, upload this):  $(Split-Path $cer -Leaf)"
Add-LabEvidenceNote "PFX password stored in config/lab.secrets.local.json as $pwEnv"

Write-Host ''
Write-Host '  UPLOAD THE PUBLIC KEY:' -ForegroundColor Yellow
Write-Host "  1. portal.azure.com -> Microsoft Entra ID -> App registrations -> $($ident.displayName)"
Write-Host '  2. Certificates & secrets -> Certificates tab -> Upload certificate'
Write-Host "  3. Choose:  $cer"
Write-Host '  4. Add. The listed thumbprint must match:'
Write-Host "        $($info.Thumbprint)" -ForegroundColor Cyan
Write-Host "  5. Then set identity '$Identity' authMode to 'certificate' and rerun your recipe."
Write-Host ''

Complete-LabRun -Verdict DONE -Summary "Certificate generated for '$Identity'. Upload the .cer to the app registration, then switch authMode to 'certificate'." | Out-Null
