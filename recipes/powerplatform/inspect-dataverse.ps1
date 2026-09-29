<#
Read-only inspection of a Dataverse test environment via the Web API.
Creates nothing, changes nothing. First proof that the Dataverse path works end to end.

  PASS         = WhoAmI succeeded and tables could be enumerated.
  INCONCLUSIVE = auth or permissions prevented the read.

Note: the Dataverse audience is the environment URL itself, not a fixed Microsoft resource.
A service principal must also exist as an Application User inside the environment with a
security role - that step is manual (Power Platform admin center) and is reported here if missing.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity        # override, e.g. -Identity dverse-app-appauth to test app-context
)

$Recipe = @{
    Name        = 'powerplatform/inspect-dataverse'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only Dataverse WhoAmI + table enumeration via the Web API.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$targetName = if ($Target) { $Target } else { 'dataverse-main' }
$problems = Test-LabConfigReady -Target $targetName -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dataverse-inspect' -Mode INSPECT -Product powerplatform -Target $targetName -DryRun:$DryRun `
    -Request 'Confirm the lab identity can authenticate to a Dataverse test environment and read metadata.' `
    -Plan @('Acquire a Dataverse-audience token', 'WhoAmI', 'Enumerate a few tables', 'Report the identity as seen by Dataverse')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$targetName with an environmentUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $targetName
$base = $tgt.environmentUrl.TrimEnd('/')
$api = "$base/api/data/v9.2"

Write-LabStep "acquiring Dataverse token (audience = $base)"
$token = Get-LabAccessToken -Api Dataverse -Target $tgt -Identity $Identity

Write-LabStep 'WhoAmI'
$who = Invoke-LabRequest -Uri "$api/WhoAmI" -Token $token -Label 'dataverse-whoami'
if (-not $who.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "WhoAmI failed: HTTP $($who.Status) code=$($who.Error.Code)" -Evidence @(
        $who.Error.Message
        'Under DELEGATED auth (authMode=devicecode), 403 / 0x80072560 means the signed-in USER is not a Dataverse user in this environment, or has no security role.'
        'Fix: Power Platform admin center -> Environments -> <env> -> Settings -> Users + permissions -> Users -> confirm the signed-in user exists and has a security role.'
        'Under APP-ONLY auth the same code instead means the service principal has no Application User record.'
    ) | Out-Null
    return
}
Add-LabEvidenceNote "WhoAmI OK: UserId=$($who.Json.UserId) BusinessUnitId=$($who.Json.BusinessUnitId) OrganizationId=$($who.Json.OrganizationId)"

Write-LabStep 'enumerating tables'
# EntityDefinitions rejects $top with 0x80060888 "The query parameter is not supported" - the
# metadata endpoint is not a normal collection. Filter server-side, trim client-side.
$tables = Invoke-LabRequest -Uri "$api/EntityDefinitions?`$select=LogicalName,EntitySetName&`$filter=IsCustomEntity eq true" -Token $token -Label 'dataverse-entitydefinitions'
$t = @($tables.Json.value)
@($t | Sort-Object LogicalName | Select-Object -First 20) | ForEach-Object { Write-Host ("    {0}" -f $_.LogicalName) }
if ($t.Count -gt 20) { Write-Host "    ... and $($t.Count - 20) more" }
Add-LabEvidenceNote "$($t.Count) custom table(s): $((@($t.LogicalName) | Sort-Object | Select-Object -First 20) -join ', ')"

Complete-LabRun -Verdict $(if ($tables.Ok) { 'PASS' } else { 'INCONCLUSIVE' }) `
    -Summary "Dataverse read path verified against $base. Nothing was created or modified." | Out-Null
