<#
Removes lab-owned records from the model's tables, in reverse dependency order.

This purge is required between every run of the dependency experiment. The reported case
logged 0x80040237 / HTTP 412 "a record with matching key values already exists", almost certainly
residue from an earlier restore into the same target - a second, unrelated failure mode that
would confound every conclusion.

Order matters here for the same reason it matters on restore, mirrored: obligatory lookups are
created with delete behaviour Restrict, so an account cannot be deleted while a contact still
points at it. Deletion runs orders -> contacts -> accounts, the reverse of the creation order
that inspect-dependency-graph derives.

Only records whose name carries the lab prefix are ever touched, and -RunId narrows that to a
single seeding run. Records outside that filter are invisible to this recipe.

Defaults to a preview. Deleting requires -Force (or allowDestructive=true in the policy).

  DONE = every matching record was deleted (or there were none).
  FAIL = some deletions failed; counts and the first error code are in the evidence.

  .\lab.ps1 CLEANUP powerplatform/purge-lab-records                      # preview
  .\lab.ps1 CLEANUP powerplatform/purge-lab-records -Force
  .\lab.ps1 CLEANUP powerplatform/purge-lab-records -RunId 20260810-084500 -Force
#>
[CmdletBinding()]
param(
    [string]$Mode = 'CLEANUP',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$ModelProfile,
    [string]$RunId,             # limit to one seeding run
    [int]$BatchSize = 100
)

$Recipe = @{
    Name        = 'powerplatform/purge-lab-records'
    Product     = 'powerplatform'
    Modes       = @('CLEANUP', 'INSPECT')
    Destructive = $true
    Description = 'Delete lab-owned records from the dependency model tables in reverse dependency order. Preview by default; -Force to delete.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dv-purge-lab-records' -Mode CLEANUP -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request 'Empty the target environment of lab-owned records so the next restore starts from a genuinely clean state.' `
    -Plan @(
    'Resolve the dependency model and derive the creation order'
    'Enumerate lab-named records per role, reversing that order'
    'Delete in batches, orders first and accounts last'
    'Report what remains'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$Target with an environmentUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
$prof = Get-DvModelProfile -Name $ModelProfile
$resolved = Resolve-DvModel -Dv $dv -ModelProfile $prof
Add-LabEvidenceNote "environment: $($dv.Base)  runId=$(if ($RunId) { $RunId } else { '<all lab records>' })"

$order = Get-DvCreationOrder -Resolved $resolved
$deleteOrder = if ($order.Ok -and $order.Order.Count) { @($order.Order)[($order.Order.Count - 1)..0] } else { @('order', 'contact', 'account') }
Add-LabEvidenceNote "deletion order: $($deleteOrder -join ' -> ')$(if (-not $order.Ok) { ' (fallback: obligatory edges deadlock, so no order could be derived)' })"

# --- enumerate ---------------------------------------------------------------

Write-LabStep 'enumerating lab records'
$found = [ordered]@{}
$total = 0
foreach ($roleName in $deleteOrder) {
    $r = $resolved.Roles[$roleName]
    if (-not $r -or -not $r.Exists) { continue }
    $filter = Get-DvLabRecordFilter -Role $r -RunId $RunId
    $res = Get-DvRecords -Dv $dv -Query "$($r.EntitySet)?`$select=$($r.IdAttribute),$($r.NameAttribute)&`$filter=$filter" -Label "purge-list-$roleName"
    if (-not $res.Ok) {
        Add-LabEvidenceNote "enumeration failed for $($r.LogicalName): HTTP $($res.Status) $($res.Error.Code)"
        continue
    }
    $found[$roleName] = [pscustomobject]@{ Role = $r; Records = @($res.Records) }
    $total += $res.Records.Count
    Add-LabEvidenceNote "$roleName ($($r.LogicalName)): $($res.Records.Count) lab record(s) matching $filter"
}

Write-Host ''
foreach ($k in $found.Keys) {
    Write-Host ('  {0,-9} {1,-26} {2} record(s)' -f $k, $found[$k].Role.LogicalName, $found[$k].Records.Count)
}

if ($total -eq 0) {
    Complete-LabRun -Verdict DONE -Summary 'Nothing to purge: no lab-owned records matched.' | Out-Null
    return
}

if ($Mode -eq 'INSPECT' -or (-not $Force -and -not (Get-LabPolicy).allowDestructive)) {
    Complete-LabRun -Verdict DONE -Summary "Preview only: $total lab record(s) would be deleted, in the order $($deleteOrder -join ' -> '). Nothing was deleted. Rerun with -Force." | Out-Null
    return
}

# One gate for the whole purge rather than one per record: the ledger cannot list thousands of
# padding rows individually, and the lab-prefix filter is what actually bounds the blast radius.
Assert-LabDestructive -Operation 'DELETE (bulk)' -Force:$Force -IsTracked `
    -ResourceDescription "$total lab-named record(s) in $($dv.Base) matching prefix filter$(if ($RunId) { " for run $RunId" })"

# --- delete ------------------------------------------------------------------

$deleted = 0; $failedCount = 0; $firstError = $null
foreach ($roleName in $deleteOrder) {
    if (-not $found[$roleName]) { continue }
    $r = $found[$roleName].Role
    $recs = $found[$roleName].Records
    if (-not $recs.Count) { continue }

    Write-LabStep "deleting $($recs.Count) $roleName record(s)"
    $reqs = foreach ($rec in $recs) { @{ Method = 'DELETE'; Path = "$($r.EntitySet)($($rec.$($r.IdAttribute)))" } }
    $b = Invoke-DvBatch -Dv $dv -Requests @($reqs) -Label "purge-$roleName" -ChangesetSize $BatchSize
    if ($b.DryRun) { Add-LabEvidenceNote "${roleName}: skipped by -DryRun"; continue }
    $deleted += $b.Succeeded
    $failedCount += $b.Failed
    if ($b.Failed -and -not $firstError) { $firstError = $b.FirstError }
    Add-LabEvidenceNote "${roleName}: deleted $($b.Succeeded)/$($recs.Count)$(if ($b.Failed) { " - $($b.Failed) failed ($($b.FirstError))" })"
}

# --- confirm -----------------------------------------------------------------

Write-LabStep 'confirming'
$remaining = 0
foreach ($roleName in $deleteOrder) {
    $r = $resolved.Roles[$roleName]
    if (-not $r -or -not $r.Exists) { continue }
    $res = Get-DvRecords -Dv $dv -Query "$($r.EntitySet)?`$select=$($r.IdAttribute)&`$filter=$(Get-DvLabRecordFilter -Role $r -RunId $RunId)" -Label "purge-confirm-$roleName" -NoEvidence
    if ($res.Ok) {
        $remaining += $res.Records.Count
        if ($res.Records.Count) { Add-LabEvidenceNote "$roleName still holds $($res.Records.Count) lab record(s)" }
    }
}

if ($remaining -eq 0) {
    Complete-LabRun -Verdict DONE -Summary "Purged $deleted record(s). The target holds no lab-owned records and is clean to restore into." | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary ("Purged $deleted record(s) but $remaining remain$(if ($firstError) { " (first error: $firstError)" }). " +
        'A Restrict delete rule blocks deleting a parent while a child still references it, so check the deletion order and any records outside the lab prefix that point at these rows.') | Out-Null
}
