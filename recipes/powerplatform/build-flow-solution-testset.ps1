<#
Builds the Dataverse side of a "how solution-aware is a backup connector" experiment: one Cloud
Flow added to TWO solutions (same workflowid, two solutioncomponent rows),
plus a CLONE of that flow (new workflowid, same clientdata) added to a THIRD solution.

  Solution A  -> original flow (componentid X)
  Solution B  -> original flow (componentid X, same id - proves multi-solution membership)
  Solution C  -> cloned flow   (componentid Y, different id, same definition)

This recipe only touches Dataverse. It creates nothing in a backup product - back this
environment up afterwards with your backup product of choice (this lab's own Keepit automation
has been removed and will be redesigned separately), then
inspect the snapshot to see whether it preserves X-in-{A,B} vs Y-in-C.

Source flow resolution, in order:
  -SourceFlowId <guid>      use this EXISTING real flow - the recommended path. A real flow's
                             clientdata is already valid; there is no known-good way in this lab
                             to hand-author one that Dataverse's Flow-specific plugins will accept.
  "<Prefix>_SourceFlow"     reused if a prior run of this recipe already created one.
  -CreateFlowIfMissing      opt-in, EXPERIMENTAL: attempts to POST a minimal category=5 workflow
                             record from scratch. This is UNVERIFIED - real Cloud Flows are
                             normally provisioned through the Flow service, not a raw Dataverse
                             Create, and this may be rejected by a plugin. If it fails, or you
                             don't pass this switch, the recipe lists existing flows so you can
                             rerun with a real -SourceFlowId instead of guessing further.

  PASS         = source flow resolved, clone created, and all 3 solutioncomponent memberships
                 verified by reading them back from solutioncomponents.
  INCONCLUSIVE = source flow could not be resolved - nothing else was attempted.
  FAIL         = source flow resolved but one or more solution/clone/membership steps failed.

  .\lab.ps1 BUILD powerplatform/build-flow-solution-testset -SourceFlowId <guid>
  .\lab.ps1 BUILD powerplatform/build-flow-solution-testset -CreateFlowIfMissing
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$SourceFlowId,
    [string]$Prefix = 'BACKUP_FLOW_TEST_20260908',
    [switch]$CreateFlowIfMissing
)

$Recipe = @{
    Name        = 'powerplatform/build-flow-solution-testset'
    Product     = 'powerplatform'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create/reuse a Cloud Flow in two solutions plus a cloned copy in a third, for a backup-connector solution-awareness experiment.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'pp-build-flow-solution-testset' -Mode BUILD -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Put one Cloud Flow into two solutions (same workflowid) and a cloned copy of it into a third solution (different workflowid), as fixed ground truth for testing a backup connector's solution-awareness." `
    -Plan @(
    'Publisher + 3 solutions (find-or-create)',
    'Resolve the source flow: -SourceFlowId, or an existing "<Prefix>_SourceFlow", or (opt-in) create one',
    'Add the source flow to Solution A and Solution B',
    'Clone the source flow (new workflowid, same clientdata) and add the clone to Solution C',
    'Verify all 3 memberships by reading solutioncomponents back'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Add targets.dataverse-main (or pass -Target) with an environmentUrl to config/lab.config.json.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"
Add-LabEvidenceNote "prefix: $Prefix"

# ---------------------------------------------------------------- publisher + solutions

Write-LabStep 'publisher and 3 solutions'
$pub = Get-DvOrCreatePublisher -Dv $dv -UniqueName 'dextorslab' -FriendlyName 'Dextors Lab' -Prefix 'dxl'
if (-not $pub.Id) { Complete-LabRun -Verdict FAIL -Summary "Publisher resolution failed: $($pub.Error)" | Out-Null; return }
if ($pub.Created) { Add-LabResource -Type 'dataverse-record' -Id $pub.Id -Name 'dextorslab' -Target $tgt._name -Api 'dataverse' -DeleteUri "$($dv.Api)/publishers($($pub.Id))" | Out-Null }

$solutionSpecs = @(
    @{ Key = 'A'; UniqueName = "$($Prefix)_SolutionA"; FriendlyName = "$Prefix Solution A (original flow)" }
    @{ Key = 'B'; UniqueName = "$($Prefix)_SolutionB"; FriendlyName = "$Prefix Solution B (original flow, 2nd membership)" }
    @{ Key = 'C'; UniqueName = "$($Prefix)_SolutionC"; FriendlyName = "$Prefix Solution C (cloned flow)" }
)
$solutions = @{}
foreach ($spec in $solutionSpecs) {
    $sol = Get-DvOrCreateSolution -Dv $dv -UniqueName $spec.UniqueName -FriendlyName $spec.FriendlyName -PublisherId $pub.Id
    if (-not $sol.Id) {
        Complete-LabRun -Verdict FAIL -Summary "Solution '$($spec.UniqueName)' could not be resolved: $($sol.Error)" | Out-Null
        return
    }
    if ($sol.Created) { Add-LabResource -Type 'dataverse-record' -Id $sol.Id -Name $spec.UniqueName -Target $tgt._name -Api 'dataverse' -DeleteUri "$($dv.Api)/solutions($($sol.Id))" | Out-Null }
    $solutions[$spec.Key] = [pscustomobject]@{ Id = $sol.Id; UniqueName = $spec.UniqueName; Created = $sol.Created }
    Add-LabEvidenceNote "solution $($spec.Key): $($spec.UniqueName) ($($sol.Id)) - $(if ($sol.Created) { 'created' } else { 'existing' })"
}

# ---------------------------------------------------------------- resolve source flow

Write-LabStep 'resolving source flow'
$src = $null
if ($SourceFlowId) {
    $r = Get-DvFlowById -Dv $dv -WorkflowId $SourceFlowId
    if ($r.Ok) { $src = $r.Json; Add-LabEvidenceNote "source flow: -SourceFlowId $SourceFlowId ('$($src.name)')" }
    else { Add-LabEvidenceNote "source flow: -SourceFlowId $SourceFlowId failed - HTTP $($r.Status) $($r.Error.Code)" }
}
else {
    $existing = Find-DvFlowByName -Dv $dv -Name "$($Prefix)_SourceFlow"
    if ($existing) {
        $r = Get-DvFlowById -Dv $dv -WorkflowId $existing.workflowid
        if ($r.Ok) { $src = $r.Json; Add-LabEvidenceNote "source flow: reused existing '$($Prefix)_SourceFlow' ($($src.workflowid))" }
    }
}

if (-not $src -and $CreateFlowIfMissing) {
    Write-LabStep 'creating source flow (experimental - raw workflow create)'
    $minimalDefinition = @{
        properties = @{
            connectionReferences = @{}
            definition           = @{
                '$schema'      = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
                contentVersion = '1.0.0.0'
                parameters     = @{}
                triggers       = @{ manual = @{ type = 'Request'; kind = 'Button'; inputs = @{ schema = @{} } } }
                actions        = @{}
                outputs        = @{}
            }
        }
        schemaVersion = '1.0.0.0'
    } | ConvertTo-Json -Depth 10 -Compress
    $rc = New-DvRecord -Dv $dv -EntitySet 'workflows' -Label 'dv-create-source-flow' -Body @{
        name       = "$($Prefix)_SourceFlow"
        category   = $script:DvWorkflowCategoryModernFlow
        type       = 1
        clientdata = $minimalDefinition
    }
    if ($rc.Ok) {
        $newId = Get-DvRecordId -Response $rc -IdAttribute 'workflowid'
        $r = Get-DvFlowById -Dv $dv -WorkflowId $newId
        if ($r.Ok) {
            $src = $r.Json
            Add-LabResource -Type 'dataverse-record' -Id $newId -Name "$($Prefix)_SourceFlow" -Target $tgt._name -Api 'dataverse' -DeleteUri "$($dv.Api)/workflows($newId)" | Out-Null
            Add-LabEvidenceNote "source flow: CREATED (experimental raw create succeeded) $newId"
        }
    }
    else {
        Add-LabEvidenceNote "source flow: raw create FAILED - HTTP $($rc.Status) code=$($rc.Error.Code) $($rc.Error.Message). This is the known-risky path; use -SourceFlowId with a real flow instead."
    }
}

if (-not $src) {
    Write-LabStep 'no source flow resolved - listing existing modern flows for you to pick a -SourceFlowId'
    $candidates = Get-DvModernFlows -Dv $dv -Top 15
    $list = if ($candidates.Ok) { @($candidates.Records | ForEach-Object { "$($_.name)  ($($_.workflowid))  managed=$($_.ismanaged)" }) } else { @() }
    if ($list.Count) { $list | ForEach-Object { Write-Host "    $_" } }
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'No source flow could be resolved - nothing else was attempted.' -Evidence @(
        if ($list.Count) { "Existing modern flows in this environment: $($list -join ' | ')" } else { 'No existing modern (category=5) flows were found in this environment either.' }
        'Re-run with -SourceFlowId <one of the guids above>, or with -CreateFlowIfMissing to attempt the experimental raw-create path.'
    ) | Out-Null
    return
}

# ---------------------------------------------------------------- add original to A and B

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($key in 'A', 'B') {
    Write-LabStep "adding source flow to Solution $key"
    $add = Add-DvSolutionComponent -Dv $dv -ComponentId $src.workflowid -ComponentType $script:DvComponentTypeWorkflow `
        -SolutionUniqueName $solutions[$key].UniqueName -Label "dv-add-flow-to-$key"
    if ($add.Ok) { Add-LabEvidenceNote "solution ${key}: added componentid=$($src.workflowid)" }
    else { $failures.Add("add source flow to Solution $key failed: HTTP $($add.Status) code=$($add.Error.Code) $($add.Error.Message)") }
}

# ---------------------------------------------------------------- clone + add to C

Write-LabStep 'cloning source flow'
$cloneName = "$($Prefix)_ClonedFlow"
$existingClone = Find-DvFlowByName -Dv $dv -Name $cloneName
$clone = $null
if ($existingClone) {
    $r = Get-DvFlowById -Dv $dv -WorkflowId $existingClone.workflowid
    if ($r.Ok) { $clone = $r.Json; Add-LabEvidenceNote "clone: reused existing '$cloneName' ($($clone.workflowid))" }
}
else {
    $rcl = New-DvFlowClone -Dv $dv -Source $src -NewName $cloneName -Label 'dv-clone-source-flow'
    if ($rcl.Ok) {
        $cloneId = Get-DvRecordId -Response $rcl -IdAttribute 'workflowid'
        Add-LabResource -Type 'dataverse-record' -Id $cloneId -Name $cloneName -Target $tgt._name -Api 'dataverse' -DeleteUri "$($dv.Api)/workflows($cloneId)" | Out-Null
        $r = Get-DvFlowById -Dv $dv -WorkflowId $cloneId
        if ($r.Ok) { $clone = $r.Json; Add-LabEvidenceNote "clone: CREATED $cloneId (from source $($src.workflowid))" }
    }
    else { $failures.Add("clone creation failed: HTTP $($rcl.Status) code=$($rcl.Error.Code) $($rcl.Error.Message)") }
}

if ($clone) {
    Write-LabStep 'adding cloned flow to Solution C'
    $addC = Add-DvSolutionComponent -Dv $dv -ComponentId $clone.workflowid -ComponentType $script:DvComponentTypeWorkflow `
        -SolutionUniqueName $solutions['C'].UniqueName -Label 'dv-add-clone-to-C'
    if ($addC.Ok) { Add-LabEvidenceNote "solution C: added componentid=$($clone.workflowid)" }
    else { $failures.Add("add cloned flow to Solution C failed: HTTP $($addC.Status) code=$($addC.Error.Code) $($addC.Error.Message)") }
}

# ---------------------------------------------------------------- verify memberships

Write-LabStep 'verifying solution memberships'
$expected = @{
    A = $src.workflowid
    B = $src.workflowid
    C = if ($clone) { $clone.workflowid } else { $null }
}
$verified = @{}
foreach ($key in 'A', 'B', 'C') {
    if (-not $expected[$key]) { $verified[$key] = $false; continue }
    $comp = Get-DvSolutionComponents -Dv $dv -SolutionId $solutions[$key].Id -ComponentType $script:DvComponentTypeWorkflow
    $has = $comp.Ok -and (@($comp.Records | Where-Object { $_.objectid -eq $expected[$key] })).Count -gt 0
    $verified[$key] = $has
    Add-LabEvidenceNote "solution $key membership verified: $has (expected componentid=$($expected[$key]))"
}

Write-Host ''
Write-Host ('  {0,-10} {1,-28} {2,-10} {3,-38} {4}' -f 'SOLUTION', 'UNIQUE NAME', 'ROLE', 'WORKFLOWID', 'VERIFIED')
Write-Host ('  ' + ('-' * 110))
Write-Host ('  {0,-10} {1,-28} {2,-10} {3,-38} {4}' -f 'A', $solutions['A'].UniqueName, 'original', $src.workflowid, $verified['A'])
Write-Host ('  {0,-10} {1,-28} {2,-10} {3,-38} {4}' -f 'B', $solutions['B'].UniqueName, 'original', $src.workflowid, $verified['B'])
Write-Host ('  {0,-10} {1,-28} {2,-10} {3,-38} {4}' -f 'C', $solutions['C'].UniqueName, 'clone', $(if ($clone) { $clone.workflowid } else { '(none)' }), $verified['C'])

$ev = @(
    "source flow: $($src.name) ($($src.workflowid))"
    "clone: $(if ($clone) { "$($clone.name) ($($clone.workflowid))" } else { 'NOT CREATED' })"
    "solution A ($($solutions['A'].UniqueName)): contains $($src.workflowid) - verified=$($verified['A'])"
    "solution B ($($solutions['B'].UniqueName)): contains $($src.workflowid) - verified=$($verified['B'])"
    "solution C ($($solutions['C'].UniqueName)): contains $(if ($clone) { $clone.workflowid } else { '(none)' }) - verified=$($verified['C'])"
    'Next: back up the Power Platform / Dynamics 365 Backup connector with your backup product, then inspect the snapshot for these workflowids and solution names.'
)

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary 'Dry run: no calls made.' -Evidence $ev | Out-Null
}
elseif ($failures.Count) {
    Complete-LabRun -Verdict FAIL -Summary "$($failures.Count) step(s) failed." -Evidence (@($ev) + @($failures)) | Out-Null
}
elseif (-not ($verified['A'] -and $verified['B'] -and $verified['C'])) {
    Complete-LabRun -Verdict FAIL -Summary 'One or more solution memberships did not verify after being added.' -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict PASS -Summary "Ground truth ready: $($src.workflowid) in solutions A+B, clone $($clone.workflowid) in solution C. All 3 memberships verified." -Evidence $ev | Out-Null
}
