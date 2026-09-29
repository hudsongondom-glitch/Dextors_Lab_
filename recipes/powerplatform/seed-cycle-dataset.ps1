<#
Seeds the source environment with the dataset for one scenario arm, then writes a manifest that
verify-dataset-state checks the restored environment against.

Scenario arms:

  A          minimal cycle, no padding. Isolates the cycle with timing removed. ~4 records.
  B-test     same cycle plus bulk padding, with the cycle contact created LAST so it restores
             late. Isolates timing with the cycle held constant.
  B-control  identical volume and padding but ACYCLIC - the account's optional back-reference to
             the contact is left null, so the graph is a pure chain. If the test arm fails and
             this passes, the cycle is necessary rather than incidental.
  C          identical to B-test; run 3-5 times, purging between each, to test whether entity
             processing order is deterministic.

Seeding itself demonstrates the two-phase create the spec proposes as the fix: the account is
created with its optional lookup null, the contact is created against it, and only then is the
account patched to close the cycle. If a restore did the same, a cycle of optional edges could
never deadlock - which is precisely what Scenario A is designed to prove or disprove.

  PASS         = the full arm was seeded and the cycle is in the intended state.
  INCONCLUSIVE = seeded partially; per-step error codes are in the evidence.
  FAIL         = nothing could be seeded.

  .\lab.ps1 BUILD powerplatform/seed-cycle-dataset -Scenario A
  .\lab.ps1 BUILD powerplatform/seed-cycle-dataset -Scenario B-test -PaddingContacts 4000
  .\lab.ps1 BUILD powerplatform/seed-cycle-dataset -Scenario B-control -PaddingContacts 4000
  .\lab.ps1 BUILD powerplatform/seed-cycle-dataset -Scenario A -ProbeRequiredLevel

-ProbeRequiredLevel additionally creates one throwaway record with its obligatory lookup omitted,
to measure whether Dataverse enforces ApplicationRequired on a Web API create at all, and deletes
it again. That answer decides whether a two-phase restore is even possible, so it is worth one
record - but because it deletes, it is opt-in rather than default.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$ModelProfile,                                    # custom (default) | oob
    [ValidateSet('A', 'B-test', 'B-control', 'C')][string]$Scenario = 'A',
    [int]$PaddingContacts = -1,                               # -1 = scenario default
    [int]$Orders = 2,                                         # cascade victims, mirrors the 2 customeraddress rows
    [ValidateSet('last', 'first')][string]$CyclePosition = 'last',
    [int]$BatchSize = 100,
    [switch]$ProbeRequiredLevel
)

$Recipe = @{
    Name        = 'powerplatform/seed-cycle-dataset'
    Product     = 'powerplatform'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Seed one scenario arm (A / B-test / B-control / C) of the restore dependency experiment and write a manifest for later verification.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

# Padding defaults follow the spec: Scenario A must finish well inside the retry window, the
# B arms must push the cycle contact past it. Both are starting points to iterate on.
if ($PaddingContacts -lt 0) { $PaddingContacts = if ($Scenario -eq 'A') { 0 } else { 3000 } }

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
if ($Orders -lt 0 -or $Orders -gt 50) { $problems = @($problems) + '-Orders must be between 0 and 50.' }
if ($PaddingContacts -gt 100000) { $problems = @($problems) + '-PaddingContacts must be 100000 or fewer.' }

$isControl = ($Scenario -eq 'B-control')
$run = Start-LabRun -Name "dv-seed-$($Scenario.ToLower())" -Mode BUILD -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Seed scenario arm '$Scenario' into the source environment so a backup can capture it and a restore can be measured against it." `
    -Plan @(
    'Resolve the dependency model against live metadata'
    'Create the padding account and bulk padding contacts (B arms) so the cycle contact lands late'
    'Create the cycle account with its optional back-reference left null'
    'Create the cycle contact against that account (obligatory edge)'
    $(if ($isControl) { 'Leave the back-reference null - this arm is deliberately acyclic' } else { 'Patch the account to close the cycle (phase two)' })
    'Create the order records that depend on the contact'
    'Write a seed manifest for verify-dataset-state'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix the above and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
$prof = Get-DvModelProfile -Name $ModelProfile
$resolved = Resolve-DvModel -Dv $dv -ModelProfile $prof

Add-LabEvidenceNote "environment: $($dv.Base)"
Add-LabEvidenceNote "scenario=$Scenario profile=$($prof._name) padding=$PaddingContacts orders=$Orders cyclePosition=$CyclePosition"

if ($resolved.Missing.Count) {
    Stop-LabRunBlocked -Problems @($resolved.Missing | ForEach-Object { "missing schema element: $_" }) `
        -NextStep 'Run:  .\lab.ps1 BUILD powerplatform/build-dependency-model'
    return
}

$acct = $resolved.Roles['account']; $cont = $resolved.Roles['contact']; $ordr = $resolved.Roles['order']

# Edge lookups, resolved by role pair so the profile can rename anything without touching code.
function Find-Edge { param([string]$From, [string]$To, [switch]$Cycle)
    @($resolved.Edges | Where-Object { $_.From -eq $From -and $_.To -eq $To -and $_.Exists -and ($_.ClosesCycle -eq [bool]$Cycle) }) | Select-Object -First 1
}
$eContactAccount = Find-Edge -From 'contact' -To 'account'
$eOrderContact = Find-Edge -From 'order' -To 'contact'
$eOrderAccount = Find-Edge -From 'order' -To 'account'
$eCycle = Find-Edge -From 'account' -To 'contact' -Cycle

foreach ($pair in @(@{ N = 'contact->account'; E = $eContactAccount }, @{ N = 'order->contact'; E = $eOrderContact }, @{ N = 'account->contact (cycle)'; E = $eCycle })) {
    if (-not $pair.E) { Stop-LabRunBlocked -Problems @("edge '$($pair.N)' could not be resolved against live metadata") -NextStep 'Run INSPECT powerplatform/inspect-dependency-graph to see the real graph.'; return }
}
Add-LabEvidenceNote "contact->account binds via '$($eContactAccount.NavigationProperty)' (requiredLevel=$($eContactAccount.ActualRequired))"
Add-LabEvidenceNote "order->contact binds via '$($eOrderContact.NavigationProperty)' (requiredLevel=$($eOrderContact.ActualRequired))"
Add-LabEvidenceNote "cycle edge account->contact binds via '$($eCycle.NavigationProperty)' (requiredLevel=$($eCycle.ActualRequired))"

# Marker columns exist only on tables this lab built; a stock table has neither.
$mp = $prof.solution.prefix
$markers = @{}
foreach ($r in @($acct, $cont, $ordr)) {
    $names = if ($mp) { Get-DvAttributeNames -Dv $dv -LogicalName $r.LogicalName } else { @() }
    $markers[$r.Role] = [pscustomobject]@{
        RunId = $(if ($mp -and $names -contains "${mp}_runid") { "${mp}_runid" } else { $null })
        Seq   = $(if ($mp -and $names -contains "${mp}_seq") { "${mp}_seq" } else { $null })
    }
}
Add-LabEvidenceNote "marker columns present: $((@($markers.Keys | ForEach-Object { "$_=$(if ($markers[$_].RunId) { 'yes' } else { 'no' })" })) -join ' ')"

$runId = $script:LabRun.RunId
$outcome = [ordered]@{}
function Set-Outcome { param([string]$Key, [string]$State, [string]$Detail)
    $script:outcome[$Key] = [pscustomobject]@{ Key = $Key; State = $State; Detail = $Detail }
    Add-LabEvidenceNote ("{0,-22} {1,-9} {2}" -f $Key, $State, $Detail)
}

# Builds a record body with the lab name and whichever marker columns exist.
function New-Body { param($Role, [string]$Name, [int]$Seq, [hashtable]$Extra = @{})
    $b = @{ $Role.NameAttribute = $Name }
    $m = $markers[$Role.Role]
    if ($m.RunId) { $b[$m.RunId] = $runId }
    if ($m.Seq) { $b[$m.Seq] = $Seq }
    foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] }
    $b
}
function New-Bind { param($Edge, $ToRole, [string]$Id) @{ "$($Edge.NavigationProperty)@odata.bind" = "/$($ToRole.EntitySet)($Id)" } }

$manifest = [ordered]@{
    runId = $runId; scenario = $Scenario; profile = $prof._name; environment = $dv.Base
    seededUtc = (Get-Date).ToUniversalTime().ToString('o')
    acyclic = $isControl; paddingContacts = $PaddingContacts; orders = $Orders; cyclePosition = $CyclePosition
    roles = [ordered]@{}; records = [ordered]@{}
}
foreach ($r in @($acct, $cont, $ordr)) {
    $manifest.roles[$r.Role] = [ordered]@{ logicalName = $r.LogicalName; entitySet = $r.EntitySet; idAttribute = $r.IdAttribute; nameAttribute = $r.NameAttribute }
}

# --- required-level probe ----------------------------------------------------
# Metadata says the lookup is ApplicationRequired; that is not the same as the platform
# rejecting a create that omits it. Only an actual create settles it.

if ($ProbeRequiredLevel -and $eContactAccount.IsRequired -and -not $script:LabRun.DryRun) {
    Write-LabStep 'probing whether ApplicationRequired is enforced on create'
    $probeName = New-LabResourceName -Suffix 'probe-noref'
    $p = New-DvRecord -Dv $dv -EntitySet $cont.EntitySet -Body (New-Body -Role $cont -Name $probeName -Seq 0) -Label 'probe-required-level'
    if ($p.Ok) {
        $probeId = Get-DvRecordId -Response $p -IdAttribute $cont.IdAttribute
        Set-Outcome 'required-probe' 'NOT-ENFORCED' "create succeeded WITHOUT the obligatory lookup - a restore CAN create with lookups nulled and patch afterwards"
        $res = Add-LabResource -Type 'dataverse-record' -Id $probeId -Name $probeName -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/$($cont.EntitySet)($probeId)" -Extra @{ role = 'probe' }
        # -ProbeRequiredLevel is an explicit opt-in to creating and removing this one record.
        if (Remove-LabResource -Resource $res -Token $dv.Token -Force) { Add-LabEvidenceNote 'probe record deleted' }
        else { Add-LabEvidenceNote 'probe record could NOT be deleted - remove it with powerplatform/purge-lab-records' }
    }
    else {
        Set-Outcome 'required-probe' 'ENFORCED' "create rejected: HTTP $($p.Status) code=$($p.Error.Code) - $($p.Error.Message)"
    }
}

# --- padding (B arms) --------------------------------------------------------

$padAccountId = $null
function Add-Padding {
    if ($PaddingContacts -le 0) { return }
    Write-LabStep "padding: $PaddingContacts contacts"
    $padName = New-LabResourceName -Suffix 'acct-padding'
    $pa = New-DvRecord -Dv $dv -EntitySet $acct.EntitySet -Body (New-Body -Role $acct -Name $padName -Seq 0) -Label 'create-padding-account'
    if (-not $pa.Ok) {
        Set-Outcome 'padding' 'FAILED' "padding account create failed: HTTP $($pa.Status) code=$($pa.Error.Code) $($pa.Error.Message)"
        return
    }
    $script:padAccountId = Get-DvRecordId -Response $pa -IdAttribute $acct.IdAttribute
    Add-LabResource -Type 'dataverse-record' -Id $script:padAccountId -Name $padName -Target $tgt._name -Api 'dataverse' `
        -DeleteUri "$($dv.Api)/$($acct.EntitySet)($($script:padAccountId))" -Extra @{ role = 'account'; kind = 'padding' } | Out-Null

    $reqs = for ($i = 1; $i -le $PaddingContacts; $i++) {
        @{
            Method = 'POST'; Path = $cont.EntitySet
            Body   = (New-Body -Role $cont -Name (New-LabResourceName -Suffix ('c{0:d6}' -f $i)) -Seq $i `
                    -Extra (New-Bind -Edge $eContactAccount -ToRole $acct -Id $script:padAccountId))
        }
    }
    $b = Invoke-DvBatch -Dv $dv -Requests @($reqs) -Label 'seed-padding-contacts' -ChangesetSize $BatchSize
    if ($b.DryRun) { Set-Outcome 'padding' 'DRYRUN' 'skipped by -DryRun'; return }
    Set-Outcome 'padding' $(if ($b.Ok) { 'CREATED' } else { 'PARTIAL' }) "$($b.Succeeded)/$PaddingContacts padding contacts in $($b.Chunks) changeset(s)$(if ($b.Failed) { "; $($b.Failed) rolled back - $($b.FirstError)" })"

    # One ledger entry stands for the whole set: registering thousands of rows individually would
    # blow the per-run policy cap and make the ledger unusable. Generic cleanup will report this
    # as manual-cleanup-required; powerplatform/purge-lab-records is the deletion path.
    Add-LabResource -Type 'dataverse-recordset' -Id "$($cont.LogicalName):$runId" -Name (New-LabResourceName -Suffix 'padding-contacts') `
        -Target $tgt._name -Api 'dataverse' -Extra @{
        role = 'contact'; kind = 'padding'; count = $b.Succeeded; entitySet = $cont.EntitySet
        purgeFilter = (Get-DvLabRecordFilter -Role $cont -RunId $runId); purgeRecipe = 'powerplatform/purge-lab-records'
    } | Out-Null
    $manifest.records['paddingContacts'] = $b.Succeeded
}

if ($CyclePosition -eq 'last') { Add-Padding }

# --- phase one: account with the cycle edge left null ------------------------

Write-LabStep 'cycle account (back-reference left null)'
$acctName = New-LabResourceName -Suffix 'acct-cycle'
$ra = New-DvRecord -Dv $dv -EntitySet $acct.EntitySet -Body (New-Body -Role $acct -Name $acctName -Seq 1) -Label 'create-cycle-account'
$acctId = $null
if ($ra.Ok) {
    $acctId = Get-DvRecordId -Response $ra -IdAttribute $acct.IdAttribute
    Set-Outcome 'cycle-account' 'CREATED' "id=$acctId name='$acctName'"
    Add-LabResource -Type 'dataverse-record' -Id $acctId -Name $acctName -Target $tgt._name -Api 'dataverse' `
        -DeleteUri "$($dv.Api)/$($acct.EntitySet)($acctId)" -Extra @{ role = 'account'; kind = 'cycle' } | Out-Null
    $manifest.records['account'] = @{ id = $acctId; name = $acctName }
}
elseif ($ra.DryRun) { Set-Outcome 'cycle-account' 'DRYRUN' 'skipped by -DryRun' }
else { Set-Outcome 'cycle-account' 'FAILED' "HTTP $($ra.Status) code=$($ra.Error.Code) $($ra.Error.Message)" }

# --- the contact that depends on it (obligatory edge) ------------------------

$contId = $null
if ($acctId) {
    Write-LabStep 'cycle contact (obligatory lookup to the account)'
    $contName = New-LabResourceName -Suffix 'contact-cycle'
    $rc = New-DvRecord -Dv $dv -EntitySet $cont.EntitySet -Label 'create-cycle-contact' `
        -Body (New-Body -Role $cont -Name $contName -Seq ($PaddingContacts + 1) -Extra (New-Bind -Edge $eContactAccount -ToRole $acct -Id $acctId))
    if ($rc.Ok) {
        $contId = Get-DvRecordId -Response $rc -IdAttribute $cont.IdAttribute
        Set-Outcome 'cycle-contact' 'CREATED' "id=$contId name='$contName' seq=$($PaddingContacts + 1)"
        Add-LabResource -Type 'dataverse-record' -Id $contId -Name $contName -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/$($cont.EntitySet)($contId)" -Extra @{ role = 'contact'; kind = 'cycle' } | Out-Null
        $manifest.records['contact'] = @{ id = $contId; name = $contName }
    }
    elseif ($rc.DryRun) { Set-Outcome 'cycle-contact' 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome 'cycle-contact' 'FAILED' "HTTP $($rc.Status) code=$($rc.Error.Code) $($rc.Error.Message)" }
}

# --- phase two: close the cycle (or deliberately leave it open) --------------

if ($acctId -and $contId) {
    if ($isControl) {
        Set-Outcome 'cycle-closure' 'SKIPPED' 'B-control is acyclic by design: the back-reference stays null'
        $manifest.records['cycleClosed'] = $false
    }
    else {
        Write-LabStep 'closing the cycle (phase two patch)'
        $rp = Set-DvRecord -Dv $dv -EntitySet $acct.EntitySet -Id $acctId -Label 'patch-close-cycle' `
            -Body (New-Bind -Edge $eCycle -ToRole $cont -Id $contId)
        if ($rp.Ok) {
            Set-Outcome 'cycle-closure' 'CLOSED' "$($acct.LogicalName).$($eCycle.LookupAttribute) -> contact $contId"
            $manifest.records['cycleClosed'] = $true
        }
        elseif ($rp.DryRun) { Set-Outcome 'cycle-closure' 'DRYRUN' 'skipped by -DryRun' }
        else {
            Set-Outcome 'cycle-closure' 'FAILED' "HTTP $($rp.Status) code=$($rp.Error.Code) $($rp.Error.Message)"
            $manifest.records['cycleClosed'] = $false
        }
    }
}

# --- the cascade victims -----------------------------------------------------

$orderIds = @()
if ($contId -and $Orders -gt 0) {
    Write-LabStep "$Orders order record(s) depending on the contact"
    for ($i = 1; $i -le $Orders; $i++) {
        $oName = New-LabResourceName -Suffix ('order{0:d2}' -f $i)
        $extra = New-Bind -Edge $eOrderContact -ToRole $cont -Id $contId
        # The optional blue edge, populated so a restore has the chance to drop it.
        if ($eOrderAccount -and $acctId) { $extra["$($eOrderAccount.NavigationProperty)@odata.bind"] = "/$($acct.EntitySet)($acctId)" }
        $ro = New-DvRecord -Dv $dv -EntitySet $ordr.EntitySet -Body (New-Body -Role $ordr -Name $oName -Seq $i -Extra $extra) -Label "create-order-$i"
        if ($ro.Ok) {
            $oid = Get-DvRecordId -Response $ro -IdAttribute $ordr.IdAttribute
            $orderIds += $oid
            Add-LabResource -Type 'dataverse-record' -Id $oid -Name $oName -Target $tgt._name -Api 'dataverse' `
                -DeleteUri "$($dv.Api)/$($ordr.EntitySet)($oid)" -Extra @{ role = 'order'; kind = 'cycle' } | Out-Null
        }
        elseif ($ro.DryRun) { }
        else { Write-LabLog "order $i failed: HTTP $($ro.Status) code=$($ro.Error.Code) $($ro.Error.Message)" -Level ERROR }
    }
    Set-Outcome 'orders' $(if ($orderIds.Count -eq $Orders) { 'CREATED' } elseif ($orderIds.Count) { 'PARTIAL' } else { 'FAILED' }) "$($orderIds.Count)/$Orders created"
    $manifest.records['orders'] = @($orderIds)
}

if ($CyclePosition -eq 'first') { Add-Padding }

# --- manifest ----------------------------------------------------------------
# Kept outside runs/ as well, because runs/ is git-ignored and a verification may happen days
# later against a different working copy.

Save-LabEvidence -Kind log -Name 'seed-manifest' -Content $manifest | Out-Null
if (-not $script:LabRun.DryRun) {
    $mdir = Join-Path (Get-LabHome) 'artifacts\d365-dependency'
    New-Item -ItemType Directory -Path $mdir -Force | Out-Null
    $mpath = Join-Path $mdir "$runId-$($Scenario.ToLower()).json"
    $manifest | ConvertTo-Json -Depth 10 | Set-Content $mpath -Encoding utf8
    Add-LabEvidenceNote "manifest: $mpath"
}

# --- summary -----------------------------------------------------------------

Write-Host ''
Write-Host ('  {0,-22} {1,-9} {2}' -f 'STEP', 'STATE', 'DETAIL')
Write-Host ('  ' + ('-' * 112))
foreach ($o in $outcome.Values) { Write-Host ('  {0,-22} {1,-9} {2}' -f $o.Key, $o.State, $o.Detail) }

$ev = @($outcome.Values | ForEach-Object { "$($_.Key): $($_.State) - $($_.Detail)" })
$failed = @($outcome.Values | Where-Object { $_.State -in 'FAILED', 'PARTIAL' })
$cycleOk = $isControl -or ($manifest.records['cycleClosed'] -eq $true)

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary "Dry run: nothing was seeded. Arm '$Scenario' would create 1 account, 1 contact, $Orders order(s) and $PaddingContacts padding contact(s)." -Evidence $ev | Out-Null
}
elseif ($acctId -and $contId -and $orderIds.Count -eq $Orders -and $cycleOk -and -not $failed.Count) {
    $shape = if ($isControl) { 'acyclic chain' } else { 'closed cycle' }
    Complete-LabRun -Verdict PASS -Summary "Arm '$Scenario' seeded: $shape, $Orders order(s), $PaddingContacts padding contact(s). Back this environment up before restoring." -Evidence $ev | Out-Null
    Write-Host ''
    Write-Host '  Next:' -ForegroundColor Cyan
    Write-Host '    1. Back the environment up with your backup product'
    Write-Host "    2. .\lab.ps1 CLEANUP powerplatform/purge-lab-records -Force        # empty the target"
    Write-Host "    3. Restore it, then:"
    Write-Host "       .\lab.ps1 INSPECT powerplatform/verify-dataset-state -RunId $runId -Expect Complete"
}
elseif ($acctId -or $contId) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Arm '$Scenario' seeded only partially. Microsoft error codes per step are in the evidence; do not back this up until it is clean." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary "Nothing could be seeded for arm '$Scenario'." -Evidence $ev | Out-Null
}
