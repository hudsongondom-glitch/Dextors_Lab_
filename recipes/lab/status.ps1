<#
End-to-end readiness check across every product the lab targets. Read-only, non-interactive:
never starts a device-code sign-in, so it is safe to run any time.

  DONE = report produced. Per-product state is in the table it prints.
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
    Name        = 'lab/status'
    Product     = 'lab'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Readiness of every product: identities, credentials, and a live probe per API.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')
. (Join-Path $PSScriptRoot '..\..\tools\microsoft\Spo.Rest.ps1')

$run = Start-LabRun -Name 'status' -Mode INSPECT -Product lab `
    -Request 'Report readiness of Graph, SharePoint (REST + Graph), Dataverse and Power BI.' `
    -Plan @('Check identities and credentials', 'Probe each API', 'Summarise what remains')

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row { param($Product, $State, $Detail) $rows.Add([pscustomobject]@{ Product = $Product; State = $State; Detail = $Detail }) }

# --- identities --------------------------------------------------------------
Write-LabStep 'identities'
$cfg = Get-LabConfig
foreach ($n in @($cfg.identities.PSObject.Properties.Name)) {
    $id = $cfg.identities.$n
    $cred = switch ($id.authMode) {
        'clientsecret' { if ([Environment]::GetEnvironmentVariable($id.secretEnvVar)) { 'secret set' } else { 'SECRET MISSING' } }
        'certificate' { if (Test-Path (Join-Path (Get-LabHome) $id.certPath)) { 'pfx present' } else { 'PFX MISSING' } }
        'devicecode' { if (Get-LabCachedRefreshToken -Key "$($cfg.tenant.id)|$($id.clientId)") { 'signed in (cached)' } else { 'not signed in yet' } }
        default { 'unknown authMode' }
    }
    $ready = if ($id.clientId) { $cred } else { 'NO CLIENT ID' }
    Write-Host ("    {0,-20} {1,-13} {2,-18} {3}" -f $n, $id.authMode, $ready, $(if ($id.reserved) { '(reserved)' } else { '' }))
    Add-LabEvidenceNote "identity ${n}: authMode=$($id.authMode) $ready$(if ($id.reserved) { ' [reserved]' })"
}

# --- Graph -------------------------------------------------------------------
Write-LabStep 'Microsoft Graph (app-only)'
try {
    $g = Get-LabAccessToken -Api Graph -Identity 'msg-app' -NoPrompt
    $claims = ConvertFrom-LabJwt $g
    $org = Invoke-LabRequest -Uri 'https://graph.microsoft.com/v1.0/organization' -Token $g -Label 'graph-org'
    Add-Row 'Graph' $(if ($org.Ok) { 'READY' } else { "HTTP $($org.Status)" }) "roles: $($claims.roles -join ', ')"
    $graphSites = Invoke-LabRequest -Uri 'https://graph.microsoft.com/v1.0/sites/root' -Token $g -Label 'graph-sites-root'
    Add-Row 'SharePoint (Graph)' $(if ($graphSites.Ok) { 'READY' } else { "HTTP $($graphSites.Status)" }) `
        $(if ($graphSites.Ok) { $graphSites.Json.webUrl } else { 'Graph Sites.* not consented (optional if using SPO REST)' })
}
catch { Add-Row 'Graph' 'ERROR' $_.Exception.Message }

# --- SharePoint REST ---------------------------------------------------------
Write-LabStep 'SharePoint REST (certificate app-only)'
try {
    $spoTgt = Get-LabTarget -Name 'spo-main'
    $st = Get-LabAccessToken -Api SharePoint -Target $spoTgt -Identity 'msg-app-cert' -NoPrompt
    $web = Get-SpoWeb -Target $spoTgt -Token $st
    if ($web.Ok) { Add-Row 'SharePoint (REST)' 'READY' "$($web.Json.Title) - $($web.Json.Url)" }
    else { Add-Row 'SharePoint (REST)' "HTTP $($web.Status)" "$($web.Raw)" }
}
catch { Add-Row 'SharePoint (REST)' 'BLOCKED' (($_.Exception.Message -split 'Trace ID')[0]) }

# --- Dataverse ---------------------------------------------------------------
Write-LabStep 'Dataverse (delegated)'
try {
    $dvTgt = Get-LabTarget -Name 'dataverse-main'
    $dt = Get-LabAccessToken -Api Dataverse -Target $dvTgt -NoPrompt
    $who = Invoke-LabRequest -Uri "$($dvTgt.environmentUrl.TrimEnd('/'))/api/data/v9.2/WhoAmI" -Token $dt -Label 'dv-whoami'
    Add-Row 'Dataverse' $(if ($who.Ok) { 'READY' } else { "HTTP $($who.Status) $($who.Error.Code)" }) `
        $(if ($who.Ok) { "UserId $($who.Json.UserId)" } else { $who.Error.Message })
}
catch { Add-Row 'Dataverse' 'NOT SIGNED IN' $_.Exception.Message }

# --- Power BI ----------------------------------------------------------------
Write-LabStep 'Power BI / Fabric (delegated)'
$pbiIdent = Get-LabIdentity -Name 'kslab-pbi'
if (-not $pbiIdent.clientId) { Add-Row 'Power BI' 'NOT CONFIGURED' 'identities.kslab-pbi.clientId is empty - app not created yet' }
else {
    try {
        $pbiTgt = Get-LabTarget -Name 'powerbi-main'
        $pt = Get-LabAccessToken -Api PowerBI -Target $pbiTgt -NoPrompt
        $ws = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($pbiTgt.workspaceId)/reports" -Token $pt -Label 'pbi-reports'
        Add-Row 'Power BI' $(if ($ws.Ok) { 'READY' } else { "HTTP $($ws.Status)" }) `
            $(if ($ws.Ok) { "$(@($ws.Json.value).Count) report(s) in workspace" } else { $ws.Error.Code })
    }
    catch { Add-Row 'Power BI' 'NOT SIGNED IN' $_.Exception.Message }
}

# --- report ------------------------------------------------------------------
Write-Host ''
Write-Host ('  {0,-20} {1,-16} {2}' -f 'PRODUCT', 'STATE', 'DETAIL')
Write-Host ('  ' + ('-' * 100))
foreach ($r in $rows) {
    $c = if ($r.State -eq 'READY') { 'Green' } elseif ($r.State -match 'NOT CONFIGURED|NOT SIGNED IN') { 'Yellow' } else { 'Red' }
    Write-Host ('  {0,-20} ' -f $r.Product) -NoNewline
    Write-Host ('{0,-16} ' -f $r.State) -NoNewline -ForegroundColor $c
    Write-Host ([string]$r.Detail).Substring(0, [Math]::Min(70, ([string]$r.Detail).Length))
    Add-LabEvidenceNote "$($r.Product): $($r.State) - $($r.Detail)"
}

$ready = @($rows | Where-Object State -eq 'READY').Count
Complete-LabRun -Verdict DONE -Summary "$ready of $($rows.Count) product paths READY." | Out-Null
