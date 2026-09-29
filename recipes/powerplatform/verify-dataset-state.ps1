<#
Checks what is actually present in an environment, and classifies the result against the failure
signatures the spec is trying to tell apart.

Two uses, one recipe:

  -Expect Empty      the purge precondition. The spec is blunt that leftover records from an
                     earlier restore produce a second, unrelated failure mode (0x80040237,
                     HTTP 412 "a record with matching key values already exists") and muddy the
                     results. Run this before every restore.

  -Expect Complete   the post-restore check. Reports which records arrived, which are missing,
                     and - the part that matters - which references came back null. A record
                     that restored with its lookup dropped is a different finding from a record
                     that never restored at all.

Failure signatures reported:

  cascade-from-account   account missing -> contact missing -> orders missing. The diagram's case.
  cascade-from-contact   account present, contact missing, orders missing.
  refs-dropped           every record present but one or more lookups came back null. The
                         restore fell back to creating without references and never patched.
  cycle-edge-dropped     only the cycle back-reference is null. Two-phase create worked, the
                         second phase did not.
  partial-orders         some orders restored, some did not - suggests non-deterministic ordering.

  PASS  = the environment matches -Expect.
  FAIL  = it does not; the summary names the signature.

  .\lab.ps1 INSPECT powerplatform/verify-dataset-state -Expect Empty
  .\lab.ps1 INSPECT powerplatform/verify-dataset-state -RunId 20260810-084500 -Expect Complete
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$ModelProfile,
    [string]$RunId,                                       # scope to one seeding run; blank = all lab records
    [ValidateSet('Complete', 'Empty')][string]$Expect = 'Complete'
)

$Recipe = @{
    Name        = 'powerplatform/verify-dataset-state'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Check whether an environment is empty of lab records (pre-restore) or holds the complete seeded set with intact references (post-restore), and name the failure signature.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dv-verify-dataset-state' -Mode INSPECT -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Verify the environment is in the expected state ('$Expect') for the restore dependency experiment." `
    -Plan @(
    'Resolve the dependency model against live metadata'
    'Load the seed manifest for the run being verified, if one exists'
    'Count lab-owned records per role'
    'Read every reference on the cycle records and record which are null'
    'Classify the result against the known failure signatures'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$Target with an environmentUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
$prof = Get-DvModelProfile -Name $ModelProfile
$resolved = Resolve-DvModel -Dv $dv -ModelProfile $prof
Add-LabEvidenceNote "environment: $($dv.Base)  expect=$Expect  runId=$(if ($RunId) { $RunId } else { '<all lab records>' })"

$present = @($resolved.Roles.Values | Where-Object { $_.Exists })
if (-not $present.Count) {
    Complete-LabRun -Verdict $(if ($Expect -eq 'Empty') { 'PASS' } else { 'FAIL' }) `
        -Summary "None of the model's tables exist in $($dv.Base). $(if ($Expect -eq 'Empty') { 'Trivially empty.' } else { 'Nothing could have been restored into tables that are absent - build the model first.' })" | Out-Null
    return
}

# --- manifest ----------------------------------------------------------------

$manifest = $null
if ($RunId) {
    $mpath = Join-Path (Get-LabHome) "artifacts\d365-dependency\$RunId-*.json"
    $mfile = @(Get-ChildItem -Path $mpath -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($mfile) {
        $manifest = Get-Content $mfile.FullName -Raw | ConvertFrom-Json
        Add-LabEvidenceNote "manifest: $($mfile.Name) scenario=$($manifest.scenario) acyclic=$($manifest.acyclic) padding=$($manifest.paddingContacts) orders=$($manifest.orders)"
    }
    else { Add-LabEvidenceNote "no seed manifest found for run $RunId - falling back to counting lab-named records" }
}

# --- counts ------------------------------------------------------------------

Write-LabStep 'counting lab records'
$counts = [ordered]@{}
$rows = [ordered]@{}
foreach ($r in $present) {
    # Select the name plus every lookup this role owns, so reference integrity is visible in
    # the same read. Lookup values come back as _<attribute>_value.
    $lookupCols = @($resolved.Edges | Where-Object { $_.From -eq $r.Role -and $_.Exists } | ForEach-Object { "_$($_.LookupAttribute)_value" })
    $sel = (@($r.IdAttribute, $r.NameAttribute) + $lookupCols) -join ','
    $filter = Get-DvLabRecordFilter -Role $r -RunId $RunId
    $q = "$($r.EntitySet)?`$select=$sel&`$filter=$filter"
    $res = Get-DvRecords -Dv $dv -Query $q -Label "verify-$($r.Role)"
    if (-not $res.Ok) {
        Add-LabEvidenceNote "read failed for $($r.LogicalName): HTTP $($res.Status) $($res.Error.Code) $($res.Error.Message)"
        $counts[$r.Role] = -1; $rows[$r.Role] = @()
        continue
    }
    $counts[$r.Role] = $res.Records.Count
    $rows[$r.Role] = @($res.Records)
    Add-LabEvidenceNote "$($r.Role) ($($r.LogicalName)): $($res.Records.Count) lab record(s)"
}

Write-Host ''
Write-Host ('  {0,-9} {1,-26} {2}' -f 'ROLE', 'TABLE', 'LAB RECORDS')
Write-Host ('  ' + ('-' * 58))
foreach ($r in $present) {
    Write-Host ('  {0,-9} {1,-26} {2}' -f $r.Role, $r.LogicalName, $(if ($counts[$r.Role] -lt 0) { 'read failed' } else { $counts[$r.Role] }))
}

$total = (@($counts.Values | Where-Object { $_ -gt 0 }) | Measure-Object -Sum).Sum
if (-not $total) { $total = 0 }

# --- Expect Empty ------------------------------------------------------------

if ($Expect -eq 'Empty') {
    if ($total -eq 0) {
        Complete-LabRun -Verdict PASS -Summary "Target is clean: no lab-owned records in any of the model's tables. Safe to restore into." | Out-Null
    }
    else {
        Complete-LabRun -Verdict FAIL -Summary ("Target still holds $total lab record(s): " +
            (@($counts.Keys | Where-Object { $counts[$_] -gt 0 } | ForEach-Object { "$_=$($counts[$_])" }) -join ' ') +
            ". Restoring now risks 0x80040237 / HTTP 412 duplicate-key failures that would confound the result. Purge with:  .\lab.ps1 CLEANUP powerplatform/purge-lab-records -Force") | Out-Null
    }
    return
}

# --- Expect Complete ---------------------------------------------------------

Write-LabStep 'checking reference integrity'
$dangling = [System.Collections.Generic.List[string]]::new()
$cycleEdgeNull = $false
$requiredEdgeNull = $false

foreach ($r in $present) {
    foreach ($e in @($resolved.Edges | Where-Object { $_.From -eq $r.Role -and $_.Exists })) {
        $col = "_$($e.LookupAttribute)_value"
        $nulls = @($rows[$r.Role] | Where-Object { -not $_.$col })
        if (-not $nulls.Count) { continue }
        $kind = if ($e.IsRequired) { 'OBLIGATORY' } else { 'optional' }
        $dangling.Add("$($nulls.Count) $($r.Role) record(s) have a null $kind reference '$($e.Name)' ($($e.FromEntity).$($e.LookupAttribute) -> $($e.ToEntity))")
        if ($e.ClosesCycle) { $cycleEdgeNull = $true }
        if ($e.IsRequired) { $requiredEdgeNull = $true }
        Add-LabEvidenceNote "null reference: $($nulls.Count)/$($rows[$r.Role].Count) $($r.Role) record(s) missing $kind edge '$($e.Name)'"
    }
}

# Expected counts come from the manifest when there is one; otherwise only presence is checked.
$expAcct = if ($manifest) { 1 + $(if ($manifest.paddingContacts -gt 0) { 1 } else { 0 }) } else { $null }
$expCont = if ($manifest) { 1 + [int]$manifest.paddingContacts } else { $null }
$expOrd = if ($manifest) { [int]$manifest.orders } else { $null }
if ($manifest) { Add-LabEvidenceNote "expected from manifest: account=$expAcct contact=$expCont order=$expOrd" }

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($pair in @(@{ R = 'account'; E = $expAcct }, @{ R = 'contact'; E = $expCont }, @{ R = 'order'; E = $expOrd })) {
    if ($null -eq $pair.E) { continue }
    $got = [int]$counts[$pair.R]
    if ($got -lt $pair.E) { $missing.Add("$($pair.R): $got of $($pair.E) present") }
}

# --- signature ---------------------------------------------------------------

$acctN = [int]$counts['account']; $contN = [int]$counts['contact']; $ordN = [int]$counts['order']

# Classify on shortfall against what was seeded, not on absolute zero: padding records mean a
# role's count can be non-zero while the record that matters is missing.
function Test-Short { param($Got, $Expected) ($null -ne $Expected) -and ([int]$Got -lt [int]$Expected) }
$shortAcct = Test-Short $acctN $expAcct
$shortCont = Test-Short $contN $expCont
$shortOrd = Test-Short $ordN $expOrd

# The cycle edge is only "dropped" if it was closed at seed time; the B-control arm leaves it
# null deliberately, and reporting that as a failure would invert the control.
$cycleWasClosed = (-not $manifest) -or [bool]$manifest.cycleClosed

$signature = if ($total -eq 0) { 'nothing-restored' }
elseif ($shortAcct -and $shortCont -and $shortOrd) { 'cascade-from-account' }
elseif (-not $shortAcct -and $shortCont -and $shortOrd) { 'cascade-from-contact' }
elseif ($shortOrd -and -not $shortAcct -and -not $shortCont) { 'partial-orders' }
elseif ($missing.Count) { 'records-missing' }
elseif ($requiredEdgeNull) { 'refs-dropped' }
elseif ($cycleEdgeNull -and $cycleWasClosed) { 'cycle-edge-dropped' }
else { $null }

if ($dangling.Count) {
    Write-Host ''
    Write-Host '  Null references:' -ForegroundColor Yellow
    $dangling | ForEach-Object { Write-Host "    - $_" }
}
if ($missing.Count) {
    Write-Host ''
    Write-Host '  Missing records:' -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "    - $_" }
}
if ($signature) { Add-LabEvidenceNote "signature: $signature" }

$ev = @($dangling) + @($missing | ForEach-Object { "missing - $_" })

if (-not $missing.Count -and -not $dangling.Count) {
    Complete-LabRun -Verdict PASS -Summary "Complete: every seeded record is present with all references intact$(if ($manifest) { " (scenario $($manifest.scenario))" }). No dependency failure." -Evidence $ev | Out-Null
}
else {
    $explain = switch ($signature) {
        'cascade-from-account' { 'The account is absent, so the contact could not be created, so the orders could not be created either - the cascade in the scenario diagram.' }
        'cascade-from-contact' { 'The account restored but the contact did not, taking its dependent orders with it.' }
        'refs-dropped' { 'Every record is present but an OBLIGATORY reference came back null. The restore created records without their lookups and never patched them - note that this should not even be possible if the platform enforces the required level.' }
        'cycle-edge-dropped' { 'Every record is present and only the cycle back-reference is null. The two-phase create worked; the second phase did not run. This is the cheapest failure mode to fix.' }
        'partial-orders' { 'Some orders restored and some did not, on identical data - consistent with non-deterministic processing order (Scenario C).' }
        'nothing-restored' { 'No lab records at all. Either the restore did not run, or it targeted a different environment.' }
        default { 'Records or references are missing; see the lists above.' }
    }
    Complete-LabRun -Verdict FAIL -Summary "Incomplete - signature '$signature'. $explain" -Evidence $ev | Out-Null
}
