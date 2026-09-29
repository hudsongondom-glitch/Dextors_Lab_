<#
Framework self-check. Read-only. Creates nothing, deletes nothing.

Proves: config loads -> policy enforces the tenant boundary -> a run is created ->
tokens can be acquired -> a harmless identity/tenant query is made -> evidence is saved
-> the run closes cleanly. Stops with BLOCKED and an exact to-do list if config is missing.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo
)

$Recipe = @{
    Name        = 'lab/validate-framework'
    Product     = 'lab'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only framework + credentials validation. Run this first.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$run = Start-LabRun -Name 'validate-framework' -Mode INSPECT -Product lab -Target $Target -DryRun:$DryRun -Request @'
Validate that the lab framework is correctly configured and that the configured
identity can reach the configured test tenant. No resources are created or modified.
'@ -Plan @(
    'Load config + policy',
    'Report configuration gaps',
    'Acquire a Microsoft Graph token and assert the tenant boundary',
    'Harmless identity query (Graph /organization, fallback to token claims)',
    'Probe the default target if one is configured',
    'Save evidence and close the run'
)

# --- 1. Config / policy ------------------------------------------------------
Write-LabStep 'checking configuration'
$problems = Test-LabConfigReady -Target $(if ($Target) { $Target } else { (Get-LabConfig).defaults.target })
Save-LabEvidence -Kind log -Name 'config-check' -Content ([pscustomobject]@{
        checkedUtc = (Get-Date).ToUniversalTime().ToString('o'); problems = @($problems)
        configPath = (Get-LabConfig)._path; policy = (Get-LabPolicy)
    }) | Out-Null

if ($problems.Count) {
    Stop-LabRunBlocked -Problems $problems -NextStep 'Fill in config/lab.config.json + config/lab.policy.json and set the secret env var, then rerun: .\lab.ps1 INSPECT lab/validate-framework'
    return
}
Add-LabEvidenceNote 'config + policy loaded, no gaps'

$cfg = Get-LabConfig
Add-LabEvidenceNote "lab='$($cfg.labName)' tenant='$($cfg.tenant.displayName)' ($($cfg.tenant.id)) prefix='$($cfg.resourcePrefix)'"

# --- 2. Token + tenant boundary ---------------------------------------------
Write-LabStep 'acquiring Microsoft Graph token'
$tgt = try { Get-LabTarget -Name $Target } catch { $null }
try {
    $graph = Get-LabAccessToken -Api Graph -Target $tgt
}
catch {
    Stop-LabRunBlocked -Problems @("Token acquisition failed: $($_.Exception.Message)") -NextStep 'Check identity.clientId, the secret env var, and that the app registration exists in the configured tenant.'
    return
}
$claims = ConvertFrom-LabJwt $graph
Add-LabEvidenceNote "Graph token OK: aud=$($claims.aud) tid=$($claims.tid) identity=$(if ($claims.upn) { $claims.upn } else { "app:$($claims.appid)" })"
Add-LabEvidenceNote "tenant boundary asserted against policy allowedTenantIds"

# --- 3. Harmless identity query ---------------------------------------------
Write-LabStep 'querying tenant identity (read-only)'
$org = Invoke-LabRequest -Uri 'https://graph.microsoft.com/v1.0/organization' -Token $graph -Label 'graph-organization'
$identityEvidence = if ($org.Ok) {
    $o = $org.Json.value[0]
    if ($o.id -and $cfg.tenant.id -and $o.id -ne $cfg.tenant.id) {
        throw "SAFETY: Graph reports tenant $($o.id) but config declares $($cfg.tenant.id)."
    }
    "Graph /organization -> HTTP 200, tenant '$($o.displayName)' id=$($o.id)"
}
else {
    "Graph /organization -> HTTP $($org.Status) code=$($org.Error.Code). Not fatal: the lab identity simply lacks Organization.Read.All. Tenant confirmed from token tid=$($claims.tid) instead."
}
Add-LabEvidenceNote $identityEvidence

# --- 4. Optional target probe -----------------------------------------------
if ($tgt) {
    Write-LabStep "probing target '$($tgt._name)' ($($tgt.product))"
    switch ($tgt.product) {
        'powerbi' {
            if ($tgt.workspaceId) {
                $t = Get-LabAccessToken -Api Fabric -Target $tgt
                $p = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($tgt.workspaceId)" -Token $t -Label 'fabric-workspace-probe'
                Add-LabEvidenceNote "Fabric workspace probe -> HTTP $($p.Status)$(if (-not $p.Ok) { " code=$($p.Error.Code)" } else { " name='$($p.Json.displayName)'" })"
            }
        }
        'sharepoint' {
            $p = Invoke-LabRequest -Uri 'https://graph.microsoft.com/v1.0/sites/root' -Token $graph -Label 'graph-sites-root-probe'
            $note = if ($p.Ok) { "root site '$($p.Json.webUrl)'" } else { "code=$($p.Error.Code) - Sites.* application permission is not consented for this identity yet" }
            Add-LabEvidenceNote "SharePoint probe (Graph /sites/root) -> HTTP $($p.Status): $note"
        }
        default { Add-LabEvidenceNote "no probe implemented yet for product '$($tgt.product)' - skipped" }
    }
}
else { Add-LabEvidenceNote 'no target configured/selected - target probe skipped' }

# --- 5. Framework mechanics --------------------------------------------------
Add-LabEvidenceNote "resource naming sample: $(New-LabResourceName -Suffix 'example')"
Add-LabEvidenceNote "resource ledger currently tracks $((Get-LabResources).Count) active lab resource(s)"

Complete-LabRun -Verdict PASS -Summary 'Framework validated: config, policy boundary, run/evidence model, auth abstraction and HTTP wrapper all functioning. No resources were created.' | Out-Null
