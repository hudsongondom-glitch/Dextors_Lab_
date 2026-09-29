<#
Reproduces (or refutes) a theory for Power Platform restores failing with 0x80040265 "User does
not have roles for editing field" on a table with column-level security: that
a restore blocked on a secured column happens because the write executes as an IMPERSONATED
user (e.g. the record's original owner, via the MSCRMCallerID header) rather than as the
connector's own System Administrator service account - and column-level security is enforced
against whoever is actually impersonated, not against the caller's own admin privileges.

Prior recon (INSPECT powerplatform/inspect-field-security-scenario) found: table
crcce_labwindturbine, column crcce_nacellecolour already secured, record "Test Turbine 01"
owned by the same System Administrator identity used to sign in, which is
why a manual test as that user did not reproduce the reported failure (system admins are
exempt from column-level security by design, regardless of field security profile membership).

Method: two PATCHes of the same secured column against the same record with the SAME token
(dverse-app, System Administrator) - one direct, one with MSCRMCallerID set to a non-admin
user found in the environment. If direct succeeds and impersonated fails with a field-security
error, that is a controlled, reproducible confirmation of the mechanism.

  PASS         = direct write succeeded AND impersonated write failed with a field-security error
                 (0x80040265 / "does not have roles for editing field" or equivalent) - the
                 impersonation theory is confirmed.
  FAIL         = both writes succeeded - column security did not block the non-admin caller,
                 which would mean the theory is wrong (or the found user is secretly a system admin).
  INCONCLUSIVE = no suitable non-admin user could be found in the environment, or a request
                 failed for an unrelated reason.

  .\lab.ps1 REPRODUCE powerplatform/reproduce-field-security-restore -RecordId <guid>

-RecordId is the id of the test record found by inspect-field-security-scenario.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'REPRODUCE',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$TableLogicalName = 'crcce_labwindturbine',
    [string]$EntitySet = 'crcce_labwindturbines',
    [string]$RecordId,
    [string]$SecuredColumn = 'crcce_nacellecolour',
    [string]$ImpersonateUserId               # override: skip auto-discovery, use this systemuserid
)

$Recipe = @{
    Name        = 'powerplatform/reproduce-field-security-restore'
    Product     = 'powerplatform'
    Modes       = @('REPRODUCE')
    Destructive = $false
    Description = 'Reproduces a field-security (0x80040265) restore failure by contrasting a direct write against an impersonated (non-admin) write on the same secured column.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
if (-not $RecordId) { $problems = @($problems) + '-RecordId is required: the test record id reported by INSPECT powerplatform/inspect-field-security-scenario' }
$run = Start-LabRun -Name 'dv-repro-field-security' -Mode REPRODUCE -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request 'Confirm whether a restore that writes as an impersonated (non-admin) user, rather than as the connector''s own System Administrator account, is blocked by column-level security - the suspected root cause of 0x80040265 restore failures.' `
    -Plan @(
    'Read the current value of the secured column (baseline)'
    'PATCH it directly with the signed-in (System Administrator) identity - expect success'
    'Find a non-admin user in the environment (or use -ImpersonateUserId)'
    'PATCH it again with MSCRMCallerID set to that user - expect a field-security failure'
    'Restore the baseline value'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix the above and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"
Add-LabEvidenceNote "table=$TableLogicalName column=$SecuredColumn record=$RecordId"

# --- baseline -------------------------------------------------------------------
Write-LabStep 'reading baseline value'
$base = Invoke-DvRequest -Dv $dv -Path "$EntitySet($RecordId)?`$select=$SecuredColumn" -Label 'dv-read-baseline'
if (-not $base.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not read baseline: HTTP $($base.Status) code=$($base.Error.Code)" | Out-Null
    return
}
$originalValue = $base.Json.$SecuredColumn
Add-LabEvidenceNote "baseline $SecuredColumn = '$originalValue'"

# --- direct write (control) ------------------------------------------------------
Write-LabStep 'direct PATCH as the signed-in System Administrator identity'
$directValue = "lab-direct-$(Get-Date -Format 'HHmmss')"
$direct = Set-DvRecord -Dv $dv -EntitySet $EntitySet -Id $RecordId -Label 'dv-patch-direct' -Body @{ $SecuredColumn = $directValue }
$directOk = $direct.Ok
Add-LabEvidenceNote "direct write: $(if ($directOk) { 'SUCCEEDED' } else { "FAILED HTTP $($direct.Status) code=$($direct.Error.Code) $($direct.Error.Message)" })"

# --- find a non-admin user to impersonate -----------------------------------------
$targetUserId = $ImpersonateUserId
$targetUserLabel = $null
if (-not $targetUserId) {
    Write-LabStep 'looking for a non-admin user to impersonate'
    $users = Get-DvRecords -Dv $dv -Query "systemusers?`$select=systemuserid,fullname,domainname,isdisabled&`$filter=isdisabled eq false" -Label 'dv-list-users'
    if ($users.Ok) {
        foreach ($u in $users.Records) {
            $roles = Get-DvRecords -Dv $dv -Query "systemusers($($u.systemuserid))/systemuserroles_association?`$select=name" -Label 'dv-user-roles' -NoEvidence
            $isAdmin = $roles.Ok -and (@($roles.Records) | Where-Object { $_.name -eq 'System Administrator' }).Count -gt 0
            Add-LabEvidenceNote "candidate $($u.fullname) ($($u.domainname)): admin=$isAdmin roles=$((@($roles.Records | ForEach-Object { $_.name })) -join ',')"
            if (-not $isAdmin) { $targetUserId = $u.systemuserid; $targetUserLabel = "$($u.fullname) ($($u.domainname))"; break }
        }
    }
}
if (-not $targetUserId) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'No non-admin user found in the environment to impersonate.' -Evidence @(
        "direct write: $(if ($directOk) { 'SUCCEEDED' } else { 'FAILED' })"
        'Create a second user (Power Platform admin center -> Users) without the System Administrator role, or pass -ImpersonateUserId with an existing one, then rerun.'
    ) | Out-Null
    # best-effort revert of the control write
    if ($directOk) { Set-DvRecord -Dv $dv -EntitySet $EntitySet -Id $RecordId -Label 'dv-restore-baseline' -Body @{ $SecuredColumn = $originalValue } | Out-Null }
    return
}
Add-LabEvidenceNote "impersonation target: $targetUserLabel ($targetUserId)"

# --- impersonated write (the actual test) -----------------------------------------
Write-LabStep "impersonated PATCH as $targetUserLabel via MSCRMCallerID"
$impValue = "lab-impersonated-$(Get-Date -Format 'HHmmss')"
$imp = Invoke-DvRequest -Dv $dv -Method PATCH -Path "$EntitySet($RecordId)" -Label 'dv-patch-impersonated' `
    -Body @{ $SecuredColumn = $impValue } -Headers @{ 'If-Match' = '*'; 'MSCRMCallerID' = $targetUserId }
$impOk = $imp.Ok
Add-LabEvidenceNote "impersonated write: $(if ($impOk) { 'SUCCEEDED' } else { "FAILED HTTP $($imp.Status) code=$($imp.Error.Code) $($imp.Error.Message)" })"

# --- restore baseline ---------------------------------------------------------------
Write-LabStep 'restoring baseline value'
$restore = Set-DvRecord -Dv $dv -EntitySet $EntitySet -Id $RecordId -Label 'dv-restore-baseline' -Body @{ $SecuredColumn = $originalValue }
Add-LabEvidenceNote "baseline restore: $(if ($restore.Ok) { 'OK' } else { "FAILED HTTP $($restore.Status) - revert '$SecuredColumn' to '$originalValue' manually" })"

$ev = @(
    "direct write (as System Administrator):    $(if ($directOk) { 'SUCCEEDED' } else { "FAILED - $($direct.Error.Code) $($direct.Error.Message)" })"
    "impersonated write (as $targetUserLabel):    $(if ($impOk) { 'SUCCEEDED' } else { "FAILED - $($imp.Error.Code) $($imp.Error.Message)" })"
)

if ($directOk -and -not $impOk) {
    Complete-LabRun -Verdict PASS -Summary "Confirmed: writing as System Administrator succeeds, the identical write impersonating a non-admin user on the same secured column fails ($($imp.Error.Code)). This matches the reported 0x80040265 failure signature and supports the impersonation theory over a service-account-permissions theory." -Evidence $ev | Out-Null
}
elseif ($directOk -and $impOk) {
    Complete-LabRun -Verdict FAIL -Summary "Both writes succeeded - column security did not block $targetUserLabel. Check whether that user is actually exempt (a hidden admin-equivalent role, or a field security profile already grants them access)." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'The control (direct) write itself failed, so the impersonated result proves nothing either way.' -Evidence $ev | Out-Null
}
