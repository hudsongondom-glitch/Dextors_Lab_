<#
Resolves what a lab app registration can actually do: translates every permission GUID in its
requiredResourceAccess into human names, and reports which permissions have been consented.

Read-only. Answers "why did that API call 401?" without portal archaeology.

  PASS         = permissions resolved for the requested identity.
  INCONCLUSIVE = Graph could not be read (needs Application.Read.All or Directory.Read.All).

  .\lab.ps1 INSPECT lab/inspect-app-permissions -Identity msg-app
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,            # which configured identity to inspect; default = all
    [string]$AuthAs = 'msg-app'   # which identity to authenticate with
)

$Recipe = @{
    Name        = 'lab/inspect-app-permissions'
    Product     = 'lab'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Resolve app registration permission GUIDs to names and show what is consented.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady
$run = Start-LabRun -Name 'inspect-app-permissions' -Mode INSPECT -Product lab -Target $Target -DryRun:$DryRun `
    -Request 'Translate the lab app registrations'' permission GUIDs into names and report consent state.' `
    -Plan @('Acquire a Graph token', 'Read each application''s requiredResourceAccess', 'Resolve resource service principals', 'Map every GUID to a permission name', 'Report granted vs requested')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Set the client secret for the authenticating identity.'; return }

$cfg = Get-LabConfig
$graph = Get-LabAccessToken -Api Graph -Identity $AuthAs
$spCache = @{}

function Resolve-ResourceSp {
    param([string]$AppId)
    if ($spCache.ContainsKey($AppId)) { return $spCache[$AppId] }
    $r = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$AppId')?`$select=id,appId,displayName,appRoles,oauth2PermissionScopes" -Token $graph -Label "sp-$AppId"
    $spCache[$AppId] = $(if ($r.Ok) { $r.Json } else { $null })
    return $spCache[$AppId]
}

$names = if ($Identity) { @($Identity) } else { @($cfg.identities.PSObject.Properties.Name) }
$anyOk = $false

foreach ($n in $names) {
    $ident = Get-LabIdentity -Name $n
    Write-LabStep "$n  [$($ident.displayName)]  clientId=$($ident.clientId)"

    $app = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/applications(appId='$($ident.clientId)')?`$select=id,appId,displayName,requiredResourceAccess" -Token $graph -Label "app-$n"
    if (-not $app.Ok) {
        Add-LabEvidenceNote "$n : could not read application object (HTTP $($app.Status) code=$($app.Error.Code)) - needs Application.Read.All or Directory.Read.All"
        continue
    }
    $anyOk = $true

    # What has actually been consented, app-only.
    $sp = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($ident.clientId)')?`$select=id,displayName" -Token $graph -Label "sp-self-$n"
    $granted = @()
    if ($sp.Ok) {
        $g = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.Json.id)/appRoleAssignments" -Token $graph -Label "grants-$n"
        if ($g.Ok) { $granted = @($g.Json.value.appRoleId) }
    }

    foreach ($rra in $app.Json.requiredResourceAccess) {
        $res = Resolve-ResourceSp -AppId $rra.resourceAppId
        $resName = if ($res) { $res.displayName } else { $rra.resourceAppId }
        Write-Host "    resource: $resName"
        foreach ($ra in $rra.resourceAccess) {
            $name = '<unresolved>'
            if ($res) {
                $name = if ($ra.type -eq 'Role') { ($res.appRoles | Where-Object { $_.id -eq $ra.id }).value }
                else { ($res.oauth2PermissionScopes | Where-Object { $_.id -eq $ra.id }).value }
                if (-not $name) { $name = '<not found on resource>' }
            }
            $kind = if ($ra.type -eq 'Role') { 'app-only ' } else { 'delegated' }
            $state = if ($ra.type -ne 'Role') { '(user consent)' } elseif ($ra.id -in $granted) { 'GRANTED' } else { 'NOT GRANTED' }
            Write-Host ("      {0}  {1,-42} {2}" -f $kind, $name, $state)
            Add-LabEvidenceNote "$n | $resName | $kind | $name | $state"
        }
    }
}

Complete-LabRun -Verdict $(if ($anyOk) { 'PASS' } else { 'INCONCLUSIVE' }) `
    -Summary "Permission map resolved for: $($names -join ', '). 'NOT GRANTED' on an app-only permission means admin consent is still missing." | Out-Null
