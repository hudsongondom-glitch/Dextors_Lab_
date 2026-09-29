<#
Determines, empirically, whether the Dataverse Web API is reachable for a Dataverse for Teams
environment - the environment type auto-provisioned when a Power Apps/Copilot Studio app or flow
is added inside a Microsoft Teams team. Microsoft's own comparison doc states Dataverse for Teams
has "Professional developer > API access: No" versus a full Dataverse environment; this recipe
tests that claim directly against a real Teams environment rather than trusting the doc alone.
It exists to answer a specific question: does a Dataverse-style backup connector (Keepit's
dynamics365 connector included) have a working path to a Teams environment's table/app/flow
data, or does the environment's storage engine (Dataverse) block that path even though the data
itself has nothing to do with the Microsoft 365 Group/Teams chat/SharePoint surface?

Two steps, both read-only:
  1. Resolve the environment's Web API URL via the Global Discovery Service. Neither the
     admin-center "Environment ID" nor "Organization ID" is a hostname, so this is the only way
     to get from those to a callable https://org<id>.crm.dynamics.com endpoint.
  2. Run the same WhoAmI + EntityDefinitions probe powerplatform/inspect-dataverse uses against a
     full Dataverse environment, against the resolved URL.

  PASS         = the environment was found in Global Discovery AND WhoAmI + EntityDefinitions
                 both succeeded - contradicts the documented "No API access" and means a
                 Dataverse-style connector has a working path to this environment's data.
  FAIL         = the environment was found in Global Discovery but a Web API call was refused
                 (typically 403 / 0x80072560, or a distinct Teams-environment error code) -
                 confirms the documented restriction with an exact error code as evidence.
  INCONCLUSIVE = the environment was not found in Global Discovery at all (wrong id, no access,
                 or the environment genuinely doesn't expose itself there), so the API question
                 couldn't even be asked.

  .\lab.ps1 INSPECT powerplatform/inspect-teams-environment -EnvironmentId <guid> -OrganizationId <guid>
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$EnvironmentId,      # Power Platform admin center -> environment -> Environment ID
    [string]$OrganizationId,     # same page -> Organization ID; either one is enough
    [string]$Identity
)

$Recipe = @{
    Name        = 'powerplatform/inspect-teams-environment'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only: resolve a Dataverse for Teams environment''s Web API URL via Global Discovery, then probe WhoAmI + EntityDefinitions to test whether the documented "no API access" restriction actually blocks calls.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$discoTargetName = 'dataverse-globaldisco'
$problems = Test-LabConfigReady -Target $discoTargetName -RequiredTargetFields @('environmentUrl')
if (-not $EnvironmentId -and -not $OrganizationId) { $problems = @($problems) + '-EnvironmentId or -OrganizationId is required (Power Platform admin center -> the Teams environment -> Details).' }
$run = Start-LabRun -Name 'pp-inspect-teams-environment' -Mode INSPECT -Product powerplatform -Target $discoTargetName -DryRun:$DryRun `
    -Request "Determine whether the Dataverse Web API is reachable for the Teams-type environment EnvironmentId=$EnvironmentId / OrganizationId=$OrganizationId." `
    -Plan @(
    'Acquire a Dataverse-audience token against the Global Discovery Service',
    'GET Instances, match by EnvironmentId or Id (OrganizationId)',
    'If found: acquire a token against the resolved ApiUrl and call WhoAmI + EntityDefinitions',
    'Report PASS/FAIL/INCONCLUSIVE with the exact HTTP status/error code as evidence'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Ensure targets.dataverse-globaldisco exists in config/lab.config.json.'; return }

$discoTgt = Get-LabTarget -Name $discoTargetName
# The synthetic target built below for the resolved environment carries no "identity" field of its
# own, so Get-LabIdentity would silently fall back to config's top-level default (app-only) instead
# of the delegated identity that just proved it can see this environment in Global Discovery. Pin
# it explicitly so the WhoAmI probe uses the SAME identity, not a different, unrelated one.
if (-not $Identity) { $Identity = $discoTgt.identity }

# ---------------------------------------------------------------- resolve via Global Discovery

Write-LabStep 'resolving environment via Global Discovery Service'
$dvDisco = Get-DvContext -Target $discoTgt -Identity $Identity
$disco = Get-DvGlobalDiscoveryInstances -Dv $dvDisco
if (-not $disco.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Global Discovery call failed: HTTP $($disco.Status) code=$($disco.Error.Code)" -Evidence @($disco.Error.Message) | Out-Null
    return
}
Add-LabEvidenceNote "Global Discovery returned $($disco.Instances.Count) instance(s) visible to this identity"

$match = $disco.Instances | Where-Object { $_.EnvironmentId -eq $EnvironmentId -or $_.Id -eq $OrganizationId } | Select-Object -First 1
if (-not $match) {
    Write-Host "    not found among $($disco.Instances.Count) visible instance(s):"
    foreach ($i in $disco.Instances) { Write-Host ("      {0,-30} EnvironmentId={1} State={2}" -f $i.FriendlyName, $i.EnvironmentId, $i.State) }
    Add-LabEvidenceNote "no instance matched EnvironmentId=$EnvironmentId or OrganizationId=$OrganizationId"
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Environment not visible to this identity via Global Discovery ($($disco.Instances.Count) other instance(s) were)." | Out-Null
    return
}
Write-Host "    found: $($match.FriendlyName)  ApiUrl=$($match.ApiUrl)  State=$($match.State)"
Add-LabEvidenceNote "matched: FriendlyName=$($match.FriendlyName) ApiUrl=$($match.ApiUrl) UniqueName=$($match.UniqueName) State=$($match.State) Region=$($match.Region) Version=$($match.Version) IsUserSysAdmin=$($match.IsUserSysAdmin)"

# ---------------------------------------------------------------- probe the resolved environment

$envTgt = [pscustomobject]@{ _name = 'teams-environment-resolved'; environmentUrl = $match.ApiUrl }

Write-LabStep "probing WhoAmI against $($match.ApiUrl)"
$dv = Get-DvContext -Target $envTgt -Identity $Identity
$who = Get-DvWhoAmI -Dv $dv
if (-not $who.Ok) {
    Add-LabEvidenceNote "WhoAmI failed: HTTP $($who.Status) code=$($who.Error.Code) message=$($who.Error.Message)"
    Complete-LabRun -Verdict FAIL -Summary "Environment resolved via Global Discovery, but the Dataverse Web API refused WhoAmI: HTTP $($who.Status) code=$($who.Error.Code). Matches the documented 'no professional-developer API access' restriction for Dataverse for Teams." -Evidence @(
        $who.Error.Message
        'https://learn.microsoft.com/power-apps/teams/data-platform-compare#business-intelligence-professional-developer-and-maker-features'
        'Under DELEGATED auth this code most likely means the signed-in user has no Dataverse security role in this environment (Teams owners/members get one automatically; a service-principal-style identity typically does not).'
    ) | Out-Null
    return
}
Add-LabEvidenceNote "WhoAmI OK: UserId=$($who.Json.UserId) BusinessUnitId=$($who.Json.BusinessUnitId) OrganizationId=$($who.Json.OrganizationId)"

Write-LabStep 'probing EntityDefinitions (custom tables)'
$tables = Invoke-DvRequest -Dv $dv -Path "EntityDefinitions?`$select=LogicalName,EntitySetName&`$filter=IsCustomEntity eq true" -Label 'dv-entitydefinitions'
if (-not $tables.Ok) {
    Add-LabEvidenceNote "EntityDefinitions failed: HTTP $($tables.Status) code=$($tables.Error.Code) message=$($tables.Error.Message)"
    Complete-LabRun -Verdict FAIL -Summary "WhoAmI succeeded but EntityDefinitions was refused: HTTP $($tables.Status) code=$($tables.Error.Code). Identity access works; metadata/table enumeration is what's blocked." -Evidence @($tables.Error.Message) | Out-Null
    return
}
$t = @($tables.Json.value)
@($t | Sort-Object LogicalName) | ForEach-Object { Write-Host ("    {0}" -f $_.LogicalName) }
Write-Host "    $($t.Count) custom table(s) visible"
Add-LabEvidenceNote "$($t.Count) custom table(s): $((@($t.LogicalName) | Sort-Object) -join ', ')"

# ---------------------------------------------------------------- verdict

Complete-LabRun -Verdict PASS -Summary "Dataverse Web API IS reachable for this Teams environment ($($match.FriendlyName)): WhoAmI and EntityDefinitions both succeeded against $($match.ApiUrl). This contradicts the doc table's 'API access: No' for at least these two calls - a Dataverse-style connector has a working read path here." -Evidence @(
    "$($t.Count) custom table(s) enumerated"
) | Out-Null
