<#
Bootstraps a lab state directory (LAB_HOME) on a machine that has never run the lab.

Creates <LAB_HOME>/{config,runs,artifacts}, seeds lab.config.json and lab.policy.json from the
shipped templates, nominates exactly one tenant as the enforced boundary, and reports what still
has to be filled in. Idempotent: existing files are left alone unless -Force is passed.

This is the only recipe that runs before configuration exists, so it seeds the policy first and
starts its run afterwards - every other recipe can assume both files are present.

  DONE = LAB_HOME is seeded and the tenant boundary is set. The printed next steps list whatever
         still needs a value; none of them are errors on a first run.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,

    [string]$TenantId,                       # your test tenant's Directory ID
    [string]$TenantDomain,                   # e.g. contosolab.onmicrosoft.com - resolves TenantId if omitted
    [string]$LabName = 'dextors-lab',
    [string]$ResourcePrefix
)

$Recipe = @{
    Name        = 'lab/init'
    Product     = 'lab'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Seed LAB_HOME (config, policy, evidence dirs) and set the tenant boundary. Run this first on a new machine.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$home_ = Initialize-LabHome
$cfgPath = Join-Path $home_ 'config\lab.config.json'
$polPath = Join-Path $home_ 'config\lab.policy.json'
$secPath = Join-Path $home_ 'config\lab.secrets.local.json'
$tplDir = Join-Path (Get-LabRoot) 'templates'

Write-Host ''
Write-Host "  LAB_HOME  $home_" -ForegroundColor Cyan
Write-Host "  code      $(Get-LabRoot)" -ForegroundColor DarkGray
Write-Host ''

# --- policy first: Start-LabRun cannot read a policy that does not exist yet ----------------
$polExisted = Test-Path $polPath
if (-not $polExisted -or $Force) {
    Copy-Item (Join-Path $tplDir 'lab.policy.template.json') $polPath -Force
    Write-Host "  seeded  config/lab.policy.json" -ForegroundColor Green
}
else { Write-Host "  kept    config/lab.policy.json (exists; -Force to replace)" -ForegroundColor DarkGray }

$cfgExisted = Test-Path $cfgPath
if (-not $cfgExisted -or $Force) {
    if (-not $ResourcePrefix) { $ResourcePrefix = ($LabName -replace '[^A-Za-z0-9]', '') }
    (Get-Content (Join-Path $tplDir 'lab.config.template.json') -Raw).
        Replace('__LAB_NAME__', $LabName).
        Replace('__RESOURCE_PREFIX__', $ResourcePrefix).
        Replace('__TENANT_ID__', '').
        Replace('__TENANT_DOMAIN__', ($TenantDomain ?? '')) |
        Set-Content $cfgPath -Encoding utf8
    Write-Host "  seeded  config/lab.config.json" -ForegroundColor Green
}
else { Write-Host "  kept    config/lab.config.json (exists; -Force to replace)" -ForegroundColor DarkGray }

if (-not (Test-Path $secPath)) {
    [pscustomobject]@{
        _comment = 'Git-ignored. Loaded into environment variables at framework start; an existing session variable always wins. Fill in only what you use.'
    } | ConvertTo-Json -Depth 3 | Set-Content $secPath -Encoding utf8
    Write-Host "  seeded  config/lab.secrets.local.json (empty)" -ForegroundColor Green
}

# The dependency model is reference data the recipes read from LAB_HOME, not code.
$modelSrc = Join-Path (Get-LabRoot) 'config\d365-dependency-model.json'
$modelDst = Join-Path $home_ 'config\d365-dependency-model.json'
if ((Test-Path $modelSrc) -and -not (Test-Path $modelDst)) {
    Copy-Item $modelSrc $modelDst
    Write-Host "  seeded  config/d365-dependency-model.json" -ForegroundColor Green
}

Reset-LabConfigCache

$run = Start-LabRun -Name 'init' -Mode BUILD -Product lab -DryRun:$DryRun `
    -Request "Seed LAB_HOME at $home_ and nominate the tenant boundary." `
    -Plan @('Create LAB_HOME tree', 'Seed config and policy from templates', 'Resolve and record the tenant', 'Report what remains')

Add-LabEvidenceNote "LAB_HOME=$home_ labRoot=$(Get-LabRoot)"

# --- tenant ---------------------------------------------------------------------------------
$cfg = Get-LabConfig
if (-not $TenantId -and -not $TenantDomain) {
    $TenantId = $cfg.tenant.id
    $TenantDomain = $cfg.tenant.domain
}

# The OpenID discovery document is unauthenticated and returns the tenant GUID in its issuer,
# so a domain is enough to bootstrap - the operator does not have to go and find the GUID.
if (-not $TenantId -and $TenantDomain) {
    Write-LabStep "resolving tenant id for $TenantDomain"
    $disc = Invoke-LabRequest -Uri "https://login.microsoftonline.com/$TenantDomain/v2.0/.well-known/openid-configuration" -Label 'tenant-discovery'
    if ($disc.Ok -and $disc.Json.issuer -match '([0-9a-f-]{36})') {
        $TenantId = $Matches[1]
        Write-Host "  resolved tenant id $TenantId" -ForegroundColor Green
        Add-LabEvidenceNote "resolved tenant id $TenantId from domain $TenantDomain"
    }
    else {
        Add-LabEvidenceNote "could not resolve tenant id from domain '$TenantDomain' (HTTP $($disc.Status))"
    }
}

if ($TenantId) {
    $cfg.tenant.id = $TenantId
    if ($TenantDomain) { $cfg.tenant.domain = $TenantDomain }
    $cfg | Select-Object -Property * -ExcludeProperty _path | ConvertTo-Json -Depth 12 | Set-Content $cfgPath -Encoding utf8

    # The boundary is one tenant. Adding rather than replacing would let a second tenant
    # accumulate silently, which is exactly what this list exists to prevent.
    $pol = Get-Content $polPath -Raw | ConvertFrom-Json
    $pol.allowedTenantIds = @($TenantId)
    $pol | ConvertTo-Json -Depth 8 | Set-Content $polPath -Encoding utf8
    Reset-LabConfigCache

    Write-Host "  boundary set: allowedTenantIds = [$TenantId]" -ForegroundColor Green
    Add-LabEvidenceNote "policy allowedTenantIds set to [$TenantId]"
}

# --- what remains ---------------------------------------------------------------------------
$cfg = Get-LabConfig
$todo = [System.Collections.Generic.List[string]]::new()
if (-not $cfg.tenant.id) { $todo.Add('tenant.id is empty - rerun with -TenantDomain <your>.onmicrosoft.com or -TenantId <guid>') }
$noClient = @($cfg.identities.PSObject.Properties | Where-Object { -not $_.Value.clientId }).Count
if ($noClient) { $todo.Add("$noClient identity/identities have no clientId - run: lab.ps1 BUILD lab/setup-app-registration") }
foreach ($t in $cfg.targets.PSObject.Properties) {
    $empty = @($t.Value.PSObject.Properties | Where-Object { $_.Name -notlike '_*' -and $_.Name -notin 'product', 'identity' -and -not $_.Value }).Name
    if ($empty) { $todo.Add("targets.$($t.Name): $($empty -join ', ') not set (only needed when you use that product)") }
}

Write-Host ''
if ($todo.Count) {
    Write-Host '  Next steps' -ForegroundColor Yellow
    $todo | ForEach-Object { Write-Host "    - $_" }
}
Write-Host ''
Write-Host '  Then:  lab.ps1 INSPECT lab/status' -ForegroundColor Cyan
Write-Host ''

$todo | ForEach-Object { Add-LabEvidenceNote "todo: $_" }

Complete-LabRun -Verdict DONE `
    -Summary "LAB_HOME seeded at $home_. Tenant boundary: $(if ($cfg.tenant.id) { $cfg.tenant.id } else { 'NOT SET' }). $($todo.Count) item(s) still to configure." | Out-Null
