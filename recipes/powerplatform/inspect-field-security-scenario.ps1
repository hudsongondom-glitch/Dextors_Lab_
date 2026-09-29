<#
Read-only recon for the field-level-security restore investigation (Power Platform restores
failing with 0x80040265 on a table with secured columns). Before building a reproduction, we need the
real schema: the lab table's logical name, which columns can even be secured, whether any
already are, the test record's owner, and any field security profiles already in the
environment. Creates nothing, changes nothing.

  PASS         = table resolved and its schema/security state was read.
  INCONCLUSIVE = table (or the named record) could not be found - check -TableDisplayName /
                 -RecordName, or that "Lab Wind Turbine" was actually created in this environment.

  .\lab.ps1 INSPECT powerplatform/inspect-field-security-scenario
  .\lab.ps1 INSPECT powerplatform/inspect-field-security-scenario -TableDisplayName 'Lab Wind Turbine' -RecordName 'Test Turbine 01'
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$TableDisplayName = 'Lab Wind Turbine',
    [string]$RecordName = 'Test Turbine 01'
)

$Recipe = @{
    Name        = 'powerplatform/inspect-field-security-scenario'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only recon of a table''s columns, security state, a named record''s owner, and existing field security profiles - groundwork for reproducing a column-level-security restore failure.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dv-inspect-field-security' -Mode INSPECT -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Find the real schema for '$TableDisplayName' and the security state around '$RecordName', to ground a field-security reproduction in facts instead of assumptions." `
    -Plan @('Resolve the table by display name', 'List its columns and which can/are secured', 'Find the named record and its owner', 'List existing field security profiles in the environment')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix the above and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"

# --- resolve the table by display name ---------------------------------------
# EntityDefinitions can't be filtered server-side on a localized DisplayName label, so pull
# custom tables and match client-side - the same constraint inspect-dataverse works around.
Write-LabStep "resolving table '$TableDisplayName'"
$tables = Invoke-DvRequest -Dv $dv -Path "EntityDefinitions?`$select=LogicalName,EntitySetName,DisplayName,PrimaryIdAttribute,PrimaryNameAttribute&`$filter=IsCustomEntity eq true" `
    -Label 'dv-find-table' -Headers @{ 'Consistency' = 'Strong' }
if (-not $tables.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not enumerate tables: HTTP $($tables.Status) code=$($tables.Error.Code)" | Out-Null
    return
}
$table = @($tables.Json.value) | Where-Object { $_.DisplayName.UserLocalizedLabel.Label -eq $TableDisplayName } | Select-Object -First 1
if (-not $table) {
    $names = (@($tables.Json.value) | ForEach-Object { $_.DisplayName.UserLocalizedLabel.Label }) -join ', '
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "No custom table with display name '$TableDisplayName' found." -Evidence @("Custom tables present: $names") | Out-Null
    return
}
Add-LabEvidenceNote "table: logicalName=$($table.LogicalName) entitySet=$($table.EntitySetName) primaryId=$($table.PrimaryIdAttribute) primaryName=$($table.PrimaryNameAttribute)"

# --- columns: which can be secured, which already are ------------------------
Write-LabStep 'reading column security state'
$attrs = Invoke-DvRequest -Dv $dv -Path "EntityDefinitions(LogicalName='$($table.LogicalName)')/Attributes?`$select=LogicalName,DisplayName,AttributeType,IsCustomAttribute,IsSecured,CanBeSecuredForCreate,CanBeSecuredForRead,CanBeSecuredForUpdate" `
    -Label 'dv-table-attrs' -Headers @{ 'Consistency' = 'Strong' }
$custom = @()
if ($attrs.Ok) {
    $custom = @($attrs.Json.value | Where-Object { $_.IsCustomAttribute })
    foreach ($a in ($custom | Sort-Object LogicalName)) {
        $label = $a.DisplayName.UserLocalizedLabel.Label
        $securable = $a.CanBeSecuredForUpdate -or $a.CanBeSecuredForRead -or $a.CanBeSecuredForCreate
        Add-LabEvidenceNote ("column {0,-32} secured={1,-5} securable={2,-5} type={3}" -f $a.LogicalName, [bool]$a.IsSecured, [bool]$securable, $a.AttributeType)
    }
    Add-LabEvidenceNote "$($custom.Count) custom column(s); $((@($custom | Where-Object IsSecured)).Count) already secured; $((@($custom | Where-Object { $_.CanBeSecuredForUpdate } )).Count) eligible for update-security"
}
else {
    Add-LabEvidenceNote "column read failed: HTTP $($attrs.Status) code=$($attrs.Error.Code)"
}

# --- the named record and its owner -------------------------------------------
Write-LabStep "resolving record '$RecordName' and its owner"
$recordFound = $null
$ownerInfo = $null
$rec = Invoke-DvRequest -Dv $dv -Path "$($table.EntitySetName)?`$select=$($table.PrimaryIdAttribute),$($table.PrimaryNameAttribute),_ownerid_value,_createdby_value,_modifiedby_value&`$filter=$($table.PrimaryNameAttribute) eq '$RecordName'" `
    -Label 'dv-find-record'
if ($rec.Ok -and @($rec.Json.value).Count) {
    $recordFound = @($rec.Json.value)[0]
    $ownerId = $recordFound._ownerid_value
    Add-LabEvidenceNote "record found: id=$($recordFound.$($table.PrimaryIdAttribute)) ownerId=$ownerId createdBy=$($recordFound._createdby_value) modifiedBy=$($recordFound._modifiedby_value)"
    if ($ownerId) {
        $owner = Invoke-DvRequest -Dv $dv -Path "systemusers($ownerId)?`$select=systemuserid,fullname,domainname,isdisabled" -Label 'dv-owner-lookup'
        if ($owner.Ok) {
            $ownerInfo = $owner.Json
            Add-LabEvidenceNote "owner: $($owner.Json.fullname) ($($owner.Json.domainname)) disabled=$($owner.Json.isdisabled)"
        }
        else { Add-LabEvidenceNote "owner is not a systemuser (likely a team) or lookup failed: HTTP $($owner.Status)" }
    }
}
else {
    Add-LabEvidenceNote "record '$RecordName' not found in $($table.EntitySetName) (or the read failed: HTTP $($rec.Status))"
}

# --- existing field security profiles -----------------------------------------
Write-LabStep 'listing existing field security profiles'
$profiles = Get-DvRecords -Dv $dv -Query "fieldsecurityprofiles?`$select=fieldsecurityprofileid,name" -Label 'dv-fsp-list'
if ($profiles.Ok) {
    Add-LabEvidenceNote "$($profiles.Records.Count) field security profile(s): $((@($profiles.Records | ForEach-Object { $_.name })) -join ', ')"
}
$fieldPerms = Get-DvRecords -Dv $dv -Query "fieldpermissions?`$select=fieldpermissionid,attributelogicalname,canreadfieldsecuredfields,canupdatefieldsecuredfields&`$filter=entityname eq '$($table.LogicalName)'" -Label 'dv-fieldperms-list'
if ($fieldPerms.Ok -and $fieldPerms.Records.Count) {
    Add-LabEvidenceNote "$($fieldPerms.Records.Count) existing field permission record(s) already target $($table.LogicalName)"
}

Complete-LabRun -Verdict $(if ($table -and $attrs.Ok) { 'PASS' } else { 'INCONCLUSIVE' }) `
    -Summary "Resolved '$TableDisplayName' -> $($table.LogicalName). $($custom.Count) custom column(s), record '$RecordName' $(if ($recordFound) { 'found' } else { 'NOT found' }), $($profiles.Records.Count) field security profile(s) already in the environment." | Out-Null
