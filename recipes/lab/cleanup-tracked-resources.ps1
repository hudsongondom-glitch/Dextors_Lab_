<#
CLEANUP - removes resources recorded in the lab ledger (runs/_ledger.jsonl) and nothing else.
Untracked resources are never touched. Defaults to a dry run listing.

Each active ledger resource is classified as one of:
  deleted  - generic delete succeeded (ledger status -> deleted).
  failed   - a real delete attempt failed.
  skipped  - it SHOULD be generically deletable but was refused for safety/auth (name lacks the
             lab prefix and is not explicitName, or its api has no auth mapping).
  manual   - it has no generic delete path by design: no deleteUri, or a local artifact
             (api 'local'). Not a failure. Its purgeRecipe (if recorded) or local path is
             reported so you know how to finish it. It is left in the ledger untouched.

  DONE         = the ledger was already empty, this was a preview-only listing (no -Force /
                 dry run), or generic cleanup completed and nothing needing attention remains.
  FAIL         = at least one delete failed, or at least one deletable resource was skipped.
  INCONCLUSIVE = every deletable resource succeeded, but one or more manual resources remain
                 (still active in the ledger; see the evidence for how to clean each).
                 FAIL takes precedence over INCONCLUSIVE.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'CLEANUP',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$RunId,          # limit to one run
    [string]$Type            # limit to one resource type
)

$Recipe = @{
    Name        = 'lab/cleanup-tracked-resources'
    Product     = 'lab'
    Modes       = @('CLEANUP', 'INSPECT')
    Destructive = $true
    Description = 'Delete resources recorded in the lab ledger. -DryRun to preview; -Force to actually delete.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$run = Start-LabRun -Name 'cleanup' -Mode CLEANUP -Product lab -Target $Target -DryRun:$DryRun `
    -Request 'Remove lab-created resources listed in the resource ledger.' `
    -Plan @('Load ledger', 'Filter to active, lab-named resources', 'Delete each via its recorded deleteUri', 'Record outcome')

$resources = Get-LabResources -RunId $RunId -Type $Type
Add-LabEvidenceNote "$($resources.Count) active tracked resource(s) in ledger"

if (-not $resources.Count) {
    Complete-LabRun -Verdict DONE -Summary 'Nothing to clean up.' | Out-Null
    return
}

$resources | ForEach-Object { Write-Host ("  {0,-22} {1}  '{2}'  run={3}" -f $_.type, $_.id, $_.name, $_.runId) }

if ($Mode -eq 'INSPECT' -or (-not $Force -and -not (Get-LabPolicy).allowDestructive)) {
    Complete-LabRun -Verdict DONE -Summary "Listed $($resources.Count) tracked resource(s). Nothing deleted. Rerun with -Force (or set allowDestructive=true) to delete." | Out-Null
    return
}

$deleted = 0; $failed = 0; $skipped = 0; $manual = 0
$manualNotes = [System.Collections.Generic.List[string]]::new()
foreach ($res in $resources) {
    # No generic delete path by design (no deleteUri, or a local artifact): report, don't delete,
    # don't count as a failure, and leave the ledger entry as-is so it stays visible.
    if (-not $res.deleteUri -or $res.api -eq 'local') {
        $how = if ($res.purgeRecipe) { "clean up with recipe '$($res.purgeRecipe)' (run $($res.runId))" }
        elseif ($res.path) { "local artifact at '$($res.path)' - remove it manually" }
        else { 'no delete path recorded - clean up manually' }
        $note = "MANUAL $($res.type)/$($res.id): $how"
        $manualNotes.Add($note); Add-LabEvidenceNote $note
        $manual++
        continue
    }
    # Prefix check is a secondary guard; the ledger is authoritative. Resources deliberately given
    # a caller-chosen name are flagged explicitName so cleanup cannot orphan them.
    if ($res.name -and -not (Test-LabResourceName -Name $res.name) -and -not $res.explicitName) {
        Add-LabEvidenceNote "SKIPPED $($res.type)/$($res.id): name '$($res.name)' does not carry the lab prefix and is not flagged explicitName"
        $skipped++
        continue
    }
    $api = switch ($res.api) { 'fabric' { 'Fabric' } 'powerbi' { 'PowerBI' } 'graph' { 'Graph' } 'dataverse' { 'Dataverse' } 'sharepoint' { 'SharePoint' } default { $null } }
    if (-not $api) { Add-LabEvidenceNote "SKIPPED $($res.type)/$($res.id): no auth mapping for api '$($res.api)'"; $skipped++; continue }

    $tgt = try { Get-LabTarget -Name $res.target } catch { $null }
    $token = Get-LabAccessToken -Api $api -Target $tgt
    if (Remove-LabResource -Resource $res -Token $token -Force:$Force) { $deleted++ } else { $failed++ }
}

Add-LabEvidenceNote "deleted=$deleted failed=$failed skipped=$skipped manual=$manual"
$verdict = if ($failed -or $skipped) { 'FAIL' } elseif ($manual) { 'INCONCLUSIVE' } else { 'DONE' }
$summary = "Cleanup finished: $deleted deleted, $failed failed, $skipped skipped, $manual manual." +
$(if ($skipped) { ' Skipped resources are still active in the ledger and were not removed.' }) +
$(if ($manual) { " Manual/special-cleanup resources remain active in the ledger: $($manualNotes -join ' | ')" })
Complete-LabRun -Verdict $verdict -Summary $summary | Out-Null
