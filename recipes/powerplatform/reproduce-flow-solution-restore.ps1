<#
Step 1 of the "restore" half of a backup-connector solution-awareness experiment (build was
BUILD powerplatform/build-flow-solution-testset).

Deletes the CLONED flow "<Prefix>_ClonedFlow", which has exactly ONE solution membership
(Solution "<Prefix>_SolutionC") - the simplest, least ambiguous case to restore and check. The
original flow (in Solutions A+B) is deliberately left alone as a harder follow-up test once this
simple case is confirmed.

Nothing is hardcoded. The flow and solution are resolved from -Prefix (same default as the build
recipe) or supplied explicitly with -WorkflowId / -SolutionId. Before anything is deleted the
flow MUST be present in the Dextor resource ledger (runs/_ledger.jsonl) for this target, i.e.
created by a lab run - otherwise the recipe stops with BLOCKED and deletes nothing.

Records a baseline of the flow's solution membership BEFORE deleting, so a later re-run of this
recipe (or a companion check) can compare post-restore membership against it. Deleting a
solution-aware component also removes its solutioncomponent row(s) as a side effect - this
recipe confirms and records that too, since "did membership disappear on delete" is the baseline
"did it come back on restore" is measured against.

This recipe does NOT restore anything - restore is performed manually in your backup product.
Once the flow is restored there, check Solution C's solutioncomponent row in Dataverse directly
to see whether it came back.

  PASS         = the flow was deleted and its Solution C membership is confirmed gone.
  INCONCLUSIVE = the flow was resolved and ledger-confirmed but could not be read before deleting.
  FAIL         = the delete call failed, or the flow / its membership is still present after it.
  BLOCKED      = config missing, or the flow/solution could not be resolved, or the flow is not
                 in the resource ledger for this target. Nothing was deleted.

  .\lab.ps1 TEST powerplatform/reproduce-flow-solution-restore -Force
#>
[CmdletBinding()]
param(
    [string]$Mode = 'TEST',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$Prefix = 'BACKUP_FLOW_TEST_20260908',   # must match the build recipe's -Prefix
    [string]$WorkflowId,                              # optional: override the flow resolved from -Prefix
    [string]$SolutionId                               # optional: override the solution resolved from -Prefix
)

$Recipe = @{
    Name        = 'powerplatform/reproduce-flow-solution-restore'
    Product     = 'powerplatform'
    Modes       = @('TEST')
    Destructive = $true
    Description = 'Deletes the cloned test flow (Solution C membership) as the setup step for a backup-restore-and-check test; records the pre-delete solution membership baseline.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'pp-reproduce-flow-solution-restore' -Mode TEST -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Delete the lab-created cloned test flow '$($Prefix)_ClonedFlow' (Solution C membership only) so its restore can be checked for solution-awareness." `
    -Plan @(
    'Resolve the flow and Solution C, and confirm the flow is in the Dextor resource ledger (else stop, delete nothing)',
    'Read the flow and confirm its Solution C membership (baseline)',
    'Delete the flow',
    'Confirm the flow is gone and its solutioncomponent row for Solution C is gone too'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Add targets.dataverse-main (or pass -Target) with an environmentUrl to config/lab.config.json.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"

# ---------------------------------------------------------------- resolve + confirm ledger tracking

$blocked = [System.Collections.Generic.List[string]]::new()
if (-not $WorkflowId) {
    $found = Find-DvFlowByName -Dv $dv -Name "$($Prefix)_ClonedFlow"
    if ($found) { $WorkflowId = $found.workflowid }
    else { $blocked.Add("No flow named '$($Prefix)_ClonedFlow' was found. Run BUILD powerplatform/build-flow-solution-testset first, or pass -Prefix / -WorkflowId.") }
}
if (-not $SolutionId) {
    $sr = Get-DvRecords -Dv $dv -Query "solutions?`$select=solutionid,uniquename&`$filter=uniquename eq '$($Prefix)_SolutionC'" -Label 'dv-find-solution-c' -NoEvidence
    if ($sr.Ok -and $sr.Records.Count) { $SolutionId = $sr.Records[0].solutionid }
    else { $blocked.Add("No solution with unique name '$($Prefix)_SolutionC' was found. Run BUILD powerplatform/build-flow-solution-testset first, or pass -Prefix / -SolutionId.") }
}
if ($WorkflowId) {
    # -IsTracked below is only honest if the ledger says this lab created this exact workflow in this target.
    $tracked = @(Get-LabResources -Type 'dataverse-record' | Where-Object { $_.id -ieq $WorkflowId -and $_.target -eq $tgt._name })
    if (-not $tracked.Count) {
        $blocked.Add("Workflow $WorkflowId is not in the Dextor resource ledger for target '$($tgt._name)', so it will not be deleted. Only flows created by a lab run (e.g. BUILD powerplatform/build-flow-solution-testset) can be removed by this recipe.")
    }
}
if ($blocked.Count) {
    Stop-LabRunBlocked -Problems $blocked -NextStep 'Fix the above and re-run. Nothing was deleted.'
    return
}
Add-LabEvidenceNote "workflowId=$WorkflowId solutionId=$SolutionId (ledger-tracked: yes)"

# ---------------------------------------------------------------- baseline

Write-LabStep 'reading baseline: flow + Solution C membership'
$before = Get-DvFlowById -Dv $dv -WorkflowId $WorkflowId
if (-not $before.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Flow $WorkflowId could not be read (HTTP $($before.Status)) - nothing to delete." | Out-Null
    return
}
Add-LabEvidenceNote "baseline flow: name='$($before.Json.name)' statecode=$($before.Json.statecode) solutionid(own-attribute)=$($before.Json.solutionid)"

$compBefore = Get-DvSolutionComponents -Dv $dv -SolutionId $SolutionId -ComponentType $script:DvComponentTypeWorkflow
$hadMembership = $compBefore.Ok -and (@($compBefore.Records | Where-Object { $_.objectid -eq $WorkflowId })).Count -gt 0
Add-LabEvidenceNote "baseline Solution C membership present: $hadMembership"
Write-Host "    flow: $($before.Json.name)  Solution C membership: $hadMembership"

# ---------------------------------------------------------------- delete

Write-LabStep 'deleting the flow'
Assert-LabDestructive -Operation "DELETE workflow $WorkflowId" -ResourceDescription "cloned test flow '$($before.Json.name)' ($WorkflowId)" -Force:$Force -IsTracked:($tracked.Count -gt 0)
$del = Remove-DvRecord -Dv $dv -EntitySet 'workflows' -Id $WorkflowId -Label 'dv-delete-cloned-flow'
if (-not $del.Ok -and -not $del.DryRun) {
    Set-LabResourceStatus -Resource $tracked[0] -Status 'delete-failed' -Note "HTTP $($del.Status) $($del.Error.Code)"
    Complete-LabRun -Verdict FAIL -Summary "Delete failed: HTTP $($del.Status) code=$($del.Error.Code) $($del.Error.Message)" | Out-Null
    return
}
if (-not $del.DryRun) { Set-LabResourceStatus -Resource $tracked[0] -Status 'deleted' -Note "HTTP $($del.Status)" }
Add-LabEvidenceNote "delete: $(if ($del.DryRun) { 'DRYRUN' } else { 'OK' })"

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary 'Dry run: nothing deleted.' | Out-Null
    return
}

# ---------------------------------------------------------------- confirm gone

Write-LabStep 'confirming the flow and its Solution C membership are gone'
$after = Get-DvFlowById -Dv $dv -WorkflowId $WorkflowId
$flowGone = -not $after.Ok
Add-LabEvidenceNote "post-delete flow lookup: $(if ($flowGone) { 'GONE (expected)' } else { "STILL PRESENT - HTTP $($after.Status)" })"

$compAfter = Get-DvSolutionComponents -Dv $dv -SolutionId $SolutionId -ComponentType $script:DvComponentTypeWorkflow
$membershipGone = -not ($compAfter.Ok -and (@($compAfter.Records | Where-Object { $_.objectid -eq $WorkflowId })).Count -gt 0)
Add-LabEvidenceNote "post-delete Solution C membership: $(if ($membershipGone) { 'GONE (expected)' } else { 'STILL PRESENT - unexpected' })"

Write-Host "    flow gone: $flowGone   Solution C membership gone: $membershipGone"

$ev = @(
    "flow: $($before.Json.name) ($WorkflowId)"
    "pre-delete Solution C membership: $hadMembership"
    "post-delete flow gone: $flowGone"
    "post-delete Solution C membership gone: $membershipGone"
    'NEXT STEP (manual): restore this flow via your backup product''s portal, then check whether Solution C''s solutioncomponent row for this workflowid reappears in Dataverse.'
)

if ($flowGone -and $membershipGone) {
    Complete-LabRun -Verdict PASS -Summary "Flow $WorkflowId deleted; its Solution C membership is confirmed gone. Ready for the restore step." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary 'Delete did not fully clear the flow and/or its Solution C membership - see evidence.' -Evidence $ev | Out-Null
}
