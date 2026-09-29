# Core.Auth.ps1 - the provider-agnostic auth CONTRACT: validating an already-acquired token's
# claims against the tenant allow-list. This is deliberately thin. Core does not know how any
# provider acquires a token (client secret, device code, certificate/JWT assertion, ...) - that
# stays in tools/microsoft/Ms.Auth.ps1. Core only enforces the safety boundary on the RESULT:
# whatever identity a provider authenticated as, it must be inside allowedTenantIds and match the
# configured tenant.

function Assert-LabTenant {
    param([Parameter(Mandatory)][string]$TenantId, [string]$Source = 'config')
    $pol = Get-LabPolicy
    if (-not $pol.allowedTenantIds -or $pol.allowedTenantIds.Count -eq 0) {
        throw "SAFETY: config/lab.policy.json allowedTenantIds is empty. Add your test tenant id before the lab will talk to any tenant."
    }
    if ($TenantId -notin $pol.allowedTenantIds) {
        throw "SAFETY: tenant '$TenantId' (from $Source) is not in allowedTenantIds. Refusing. This lab may only target your own test tenant."
    }
}

# Validates the identity actually issued to us, not just what config claims. Any provider that
# acquires a Microsoft Entra token is expected to call this with the token's decoded claims
# before using it.
function Assert-LabTokenClaims {
    param([Parameter(Mandatory)]$Claims)
    Assert-LabTenant -TenantId $Claims.tid -Source 'access token (tid claim)'
    $cfg = Get-LabConfig
    if ($cfg.tenant.id -and $Claims.tid -ne $cfg.tenant.id) {
        throw "SAFETY: token tenant '$($Claims.tid)' does not match configured tenant '$($cfg.tenant.id)'."
    }
}
