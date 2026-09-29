<#
Creates the Entra app registrations the lab needs and writes their client ids into
<LAB_HOME>/config/lab.config.json.

Replaces roughly twenty portal clicks per app: create, add permissions across three different
resource APIs, enable public client flows, create the service principal. What it cannot replace
is admin consent - only a tenant admin can grant it, and Entra requires that to happen in a
browser. The recipe ends by printing the consent URL for each app.

Bootstrapping is circular: creating an app registration needs a token, and a token needs an app
registration. It is broken with the Microsoft Graph PowerShell first-party public client, which
exists in every tenant and supports device code. Nothing is created under it; it is used only to
call Graph as the signed-in admin. Override with -BootstrapClientId if your tenant blocks it.

Permissions are declared by NAME and their GUIDs resolved from the tenant at run time, so the
recipe cannot drift against hardcoded identifiers and reports honestly when a name is unknown.

  DONE = every requested app exists and its client id is recorded. Consent state is reported per
         app but is NOT part of the verdict - it happens in the browser, after this runs.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,

    [ValidateSet('all', 'graph', 'dataverse', 'powerbi')][string]$App = 'all',
    [string]$BootstrapClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',   # Microsoft Graph PowerShell
    [switch]$NoConsentUrl
)

$Recipe = @{
    Name        = 'lab/setup-app-registration'
    Product     = 'lab'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create the Entra app registrations the lab needs, add their permissions, and record the client ids.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -SkipMicrosoftIdentity
$cfg = try { Get-LabConfig } catch { $null }
if ($cfg -and -not $cfg.tenant.id) { $problems += 'config/lab.config.json -> tenant.id is empty. Run: lab.ps1 BUILD lab/init -TenantDomain <your>.onmicrosoft.com' }

$run = Start-LabRun -Name 'setup-app-registration' -Mode BUILD -Product lab -DryRun:$DryRun `
    -Request "Create and configure the lab's Entra app registration(s): $App." `
    -Plan @('Sign in as an administrator', 'Resolve permission names to GUIDs', 'Create or reuse each app', 'Enable public client flows', 'Record client ids', 'Print the consent URL')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Run lab/init first.'; return }

$GRAPH = '00000003-0000-0000-c000-000000000000'
$SPO = '00000003-0000-0ff1-ce00-000000000000'
$PBI = '00000009-0000-0000-c000-000000000000'
$DVERSE = '00000007-0000-0000-c000-000000000000'

# Declared by name; GUIDs resolved below. Role = application permission, Scope = delegated.
$plan = [ordered]@{
    graph     = @{
        DisplayName = "$($cfg.labName) graph"
        Identities  = @('msg-app', 'msg-app-cert')
        PublicClient = $false
        Why         = 'Graph app-only + SharePoint REST app-only (certificate)'
        Permissions = @(
            @{ Resource = $GRAPH; Type = 'Role'; Names = @('Directory.Read.All', 'User.Read.All', 'Sites.ReadWrite.All', 'Group.ReadWrite.All', 'Mail.Read', 'MailboxSettings.Read') }
            @{ Resource = $SPO; Type = 'Role'; Names = @('Sites.FullControl.All') }
        )
    }
    dataverse = @{
        DisplayName = "$($cfg.labName) dataverse"
        Identities  = @('dverse-app', 'dverse-app-appauth')
        PublicClient = $true
        Why         = 'Dataverse delegated (device code)'
        Permissions = @(
            @{ Resource = $DVERSE; Type = 'Scope'; Names = @('user_impersonation') }
            @{ Resource = $GRAPH; Type = 'Scope'; Names = @('User.Read') }
        )
    }
    powerbi   = @{
        DisplayName = "$($cfg.labName) powerbi"
        Identities  = @('kslab-pbi', 'kslab-pbi-appauth')
        PublicClient = $true
        Why         = 'Power BI / Fabric delegated (device code)'
        Permissions = @(
            @{ Resource = $PBI; Type = 'Scope'; Names = @('Workspace.ReadWrite.All', 'Dataset.ReadWrite.All', 'Report.ReadWrite.All', 'Dataflow.ReadWrite.All') }
            @{ Resource = $GRAPH; Type = 'Scope'; Names = @('User.Read') }
        )
    }
}
$wanted = if ($App -eq 'all') { @($plan.Keys) } else { @($App) }

# --- bootstrap sign-in ------------------------------------------------------------------------
# A throwaway in-memory identity: never written to config, but it still goes through
# Get-LabAccessToken so the tenant claim assertion applies to it like any other credential.
$cfg.identities | Add-Member -NotePropertyName '_bootstrap' -NotePropertyValue ([pscustomobject]@{
        clientId = $BootstrapClientId; displayName = 'Graph PowerShell (bootstrap)'; authMode = 'devicecode'
    }) -Force

Write-LabStep 'signing in as an administrator'
Write-Host '  This must be an account that can create app registrations (Application Administrator or higher).' -ForegroundColor DarkGray
$scopes = 'https://graph.microsoft.com/Application.ReadWrite.All https://graph.microsoft.com/Directory.Read.All'
$tok = Get-LabAccessToken -Api Graph -Identity '_bootstrap' -Scope $scopes
$me = Invoke-LabRequest -Uri 'https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,id' -Token $tok -Label 'whoami'
if ($me.Ok) { Add-LabEvidenceNote "signed in as $($me.Json.userPrincipalName)" }

# --- resolve permission names to GUIDs ---------------------------------------------------------
$spCache = @{}
function Resolve-Permission {
    param([string]$ResourceAppId, [string]$Type, [string[]]$Names)
    if (-not $spCache.ContainsKey($ResourceAppId)) {
        $r = Invoke-LabRequest -Label "sp-$ResourceAppId" -Token $tok `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$ResourceAppId')?`$select=id,displayName,appRoles,oauth2PermissionScopes"
        $spCache[$ResourceAppId] = if ($r.Ok) { $r.Json } else { $null }
        if (-not $r.Ok) { Write-LabLog "resource $ResourceAppId not found in this tenant (HTTP $($r.Status)) - its permissions will be skipped" -Level WARN }
    }
    $sp = $spCache[$ResourceAppId]
    if (-not $sp) { return @() }
    $catalog = if ($Type -eq 'Role') { $sp.appRoles } else { $sp.oauth2PermissionScopes }
    $out = @()
    foreach ($n in $Names) {
        $hit = @($catalog | Where-Object { $_.value -eq $n })[0]
        if ($hit) { $out += @{ id = $hit.id; type = $Type } }
        else { Write-LabLog "permission '$n' ($Type) not found on $($sp.displayName) - skipped" -Level WARN }
    }
    return $out
}

# --- create or reuse each app ------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($key in $wanted) {
    $spec = $plan[$key]
    Write-LabStep "$key -> $($spec.DisplayName)  [$($spec.Why)]"

    $rra = @()
    foreach ($p in $spec.Permissions) {
        $acc = Resolve-Permission -ResourceAppId $p.Resource -Type $p.Type -Names $p.Names
        if ($acc.Count) { $rra += @{ resourceAppId = $p.Resource; resourceAccess = $acc } }
    }

    $esc = $spec.DisplayName.Replace("'", "''")
    $found = Invoke-LabRequest -Token $tok -Label "find-$key" `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$esc'&`$select=id,appId,displayName"
    $existing = if ($found.Ok) { @($found.Json.value)[0] } else { $null }

    $body = @{
        displayName            = $spec.DisplayName
        signInAudience         = 'AzureADMyOrg'
        isFallbackPublicClient = [bool]$spec.PublicClient      # 'Allow public client flows' = Yes
        requiredResourceAccess = $rra
    }

    if ($existing -and -not $Force) {
        Write-Host "    reusing existing app $($existing.appId)" -ForegroundColor DarkGray
        $patch = Invoke-LabRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($existing.id)" `
            -Token $tok -Body $body -Label "update-$key"
        $appId = $existing.appId; $objId = $existing.id
        $created = $false
        if (-not $patch.Ok -and -not $patch.DryRun) { Write-LabLog "could not update permissions on $($spec.DisplayName): $($patch.Error.Message)" -Level WARN }
    }
    else {
        $new = Invoke-LabRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Token $tok -Body $body -Label "create-$key"
        if ($new.DryRun) { $results.Add([pscustomobject]@{ App = $key; AppId = '(dry-run)'; State = 'DRY-RUN' }); continue }
        if (-not $new.Ok) {
            Write-LabLog "failed to create $($spec.DisplayName): HTTP $($new.Status) $($new.Error.Code) $($new.Error.Message)" -Level ERROR
            $results.Add([pscustomobject]@{ App = $key; AppId = '-'; State = "FAILED $($new.Status)" })
            continue
        }
        $appId = $new.Json.appId; $objId = $new.Json.id
        $created = $true
        Write-Host "    created $appId" -ForegroundColor Green
        # The display name is caller-chosen rather than New-LabResourceName-generated, so flag it
        # explicitName or cleanup will refuse to touch it.
        Add-LabResource -Type 'entra-application' -Id $objId -Name $spec.DisplayName -Api 'graph' `
            -DeleteUri "https://graph.microsoft.com/v1.0/applications/$objId" `
            -Extra @{ explicitName = $true; note = 'app registration created by lab/setup-app-registration' } | Out-Null
    }

    # The service principal is what consent is actually granted against; a bare app has none.
    $spGet = Invoke-LabRequest -Token $tok -Label "sp-exists-$key" `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$appId')?`$select=id"
    if (-not $spGet.Ok) {
        $spNew = Invoke-LabRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Token $tok -Body @{ appId = $appId } -Label "sp-create-$key"
        if ($spNew.Ok) { Write-Host '    service principal created' -ForegroundColor DarkGray }
    }

    foreach ($idName in $spec.Identities) {
        if ($cfg.identities.PSObject.Properties[$idName]) { $cfg.identities.$idName.clientId = $appId }
    }
    Add-LabEvidenceNote "$key app '$($spec.DisplayName)' appId=$appId $(if ($created) { 'created' } else { 'reused' }); identities: $($spec.Identities -join ', ')"
    $results.Add([pscustomobject]@{ App = $key; AppId = $appId; State = $(if ($created) { 'CREATED' } else { 'REUSED' }) })
}

# --- persist client ids -------------------------------------------------------------------------
if (-not $DryRun) {
    $cfgPath = Join-Path (Get-LabHome) 'config\lab.config.json'
    $cfg | Select-Object -Property * -ExcludeProperty _path, _bootstrap |
        ConvertTo-Json -Depth 12 | Set-Content $cfgPath -Encoding utf8
    Reset-LabConfigCache
    Write-Host ''
    Write-Host "  client ids written to $cfgPath" -ForegroundColor Green
}

# --- report ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host ('  {0,-12} {1,-40} {2}' -f 'APP', 'CLIENT ID', 'STATE')
Write-Host ('  ' + ('-' * 74))
foreach ($r in $results) { Write-Host ('  {0,-12} {1,-40} {2}' -f $r.App, $r.AppId, $r.State) }

if (-not $NoConsentUrl -and $results.Count) {
    Write-Host ''
    Write-Host '  Admin consent - open each URL and approve. This cannot be automated.' -ForegroundColor Yellow
    foreach ($r in $results | Where-Object { $_.AppId -match '^[0-9a-f-]{36}$' }) {
        Write-Host "    $($r.App): https://login.microsoftonline.com/$($cfg.tenant.id)/adminconsent?client_id=$($r.AppId)"
    }
}
Write-Host ''
Write-Host '  Then:  lab.ps1 INSPECT lab/status' -ForegroundColor Cyan
Write-Host ''

$ok = @($results | Where-Object State -in 'CREATED', 'REUSED').Count
Complete-LabRun -Verdict $(if ($ok -eq $results.Count) { 'DONE' } else { 'INCONCLUSIVE' }) `
    -Summary "$ok of $($results.Count) app registration(s) ready. Admin consent still has to be granted in a browser." | Out-Null
