<#
Creates the tables and lookups that the dependency scenarios need, exactly as described in
config/d365-dependency-model.json.

Idempotent and additive: anything that already exists is reused untouched, so pointing a role
at a table you built by hand is supported - set "manage": false on that role and the recipe
verifies it instead of creating it. Nothing existing is ever modified or deleted.

The 'custom' profile builds the scenario diagram:

    Lab Contact --(obligatory)--> Lab Account          contact cannot exist without its account
    Lab Order   --(obligatory)--> Lab Contact          order cannot exist without its contact
    Lab Order   --(optional)----> Lab Account          blue link
    Lab Account --(optional)----> Lab Contact          closes the cycle (mirrors primarycontactid)

Obligatory edges are created with RequiredLevel=ApplicationRequired and delete behaviour
Restrict; optional edges with RequiredLevel=None and RemoveLink. Whether Dataverse actually
enforces ApplicationRequired on a Web API create is measured at seed time, not assumed here.

  PASS         = every table and lookup in the profile now exists.
  INCONCLUSIVE = some created, some failed; per-element error codes are in the evidence.
  FAIL         = nothing could be created (auth, privileges or policy).

  .\lab.ps1 BUILD powerplatform/build-dependency-model -DryRun
  .\lab.ps1 BUILD powerplatform/build-dependency-model
  .\lab.ps1 BUILD powerplatform/build-dependency-model -Publish

Metadata is registered in the ledger, so tables can be removed with:
  .\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Type dataverse-table -Force
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$ModelProfile,     # custom (default) | oob
    [switch]$Publish           # run PublishAllXml afterwards (only needed for the maker UI)
)

$Recipe = @{
    Name        = 'powerplatform/build-dependency-model'
    Product     = 'powerplatform'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create the account/contact/order tables and their obligatory + optional lookups for the restore dependency scenarios. Reuses anything that already exists.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dv-build-dependency-model' -Mode BUILD -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request 'Create controlled test tables whose lookup dependencies reproduce the reported restore failure: an obligatory chain order -> contact -> account, plus an optional back-reference that closes a cycle.' `
    -Plan @(
    'Resolve the model profile against live metadata to see what is already there'
    'Create the publisher and solution if absent'
    'Create each missing table with its primary name, run marker and sequence columns'
    'Create each missing lookup at the configured required level and delete behaviour'
    'Re-resolve and report the resulting graph'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$Target with an environmentUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"

$prof = Get-DvModelProfile -Name $ModelProfile
Add-LabEvidenceNote "profile '$($prof._name)'"

$outcome = [ordered]@{}
function Set-Outcome {
    param([string]$Key, [string]$State, [string]$Detail)
    $script:outcome[$Key] = [pscustomobject]@{ Key = $Key; State = $State; Detail = $Detail }
    Add-LabEvidenceNote ("{0,-38} {1,-9} {2}" -f $Key, $State, $Detail)
}

Write-LabStep 'resolving current state'
$before = Resolve-DvModel -Dv $dv -ModelProfile $prof
if (-not $before.Missing.Count) {
    foreach ($r in $before.Roles.Values) { Set-Outcome "table $($r.LogicalName)" 'PRESENT' "entitySet=$($r.EntitySet)" }
    foreach ($e in $before.Edges) { Set-Outcome "lookup $($e.Name)" 'PRESENT' "$($e.FromEntity).$($e.LookupAttribute) required=$($e.ActualRequired)" }
    Complete-LabRun -Verdict PASS -Summary 'Every table and lookup in the profile already exists. Nothing was created.' `
        -Evidence @($outcome.Values | ForEach-Object { "$($_.Key): $($_.State) - $($_.Detail)" }) | Out-Null
    return
}
Add-LabEvidenceNote "missing before build: $($before.Missing -join '; ')"

# Roles flagged manage=false are someone else's - report and never touch them.
$unmanaged = @($before.Roles.Values | Where-Object { -not $_.Manage -and -not $_.Exists })
foreach ($u in $unmanaged) {
    Set-Outcome "table $($u.LogicalName)" 'BLOCKED' "role '$($u.Role)' is manage=false but the table does not exist - create it yourself or set manage=true in config/d365-dependency-model.json"
}

# --- publisher and solution --------------------------------------------------

$solutionName = $null
if ($prof.solution -and @($before.Roles.Values | Where-Object { $_.Manage -and -not $_.Exists }).Count) {
    Write-LabStep 'publisher and solution'
    $pub = Get-DvOrCreatePublisher -Dv $dv -UniqueName $prof.solution.publisherUniqueName -FriendlyName $prof.solution.publisherFriendlyName `
        -Prefix $prof.solution.prefix -OptionValuePrefix $prof.solution.optionValuePrefix
    if ($pub.Id) {
        Set-Outcome 'publisher' $(if ($pub.Created) { 'CREATED' } else { 'PRESENT' }) "$($prof.solution.publisherUniqueName) prefix=$($prof.solution.prefix) id=$($pub.Id)"
        if ($pub.Created) {
            Add-LabResource -Type 'dataverse-publisher' -Id $pub.Id -Name $prof.solution.publisherUniqueName -Target $tgt._name -Api 'dataverse' `
                -DeleteUri "$($dv.Api)/publishers($($pub.Id))" -Extra @{ explicitName = $true } | Out-Null
        }
        $sol = Get-DvOrCreateSolution -Dv $dv -UniqueName $prof.solution.uniqueName -FriendlyName $prof.solution.friendlyName `
            -PublisherId $pub.Id -Version $prof.solution.version
        if ($sol.Id) {
            $solutionName = $prof.solution.uniqueName
            Set-Outcome 'solution' $(if ($sol.Created) { 'CREATED' } else { 'PRESENT' }) "$solutionName id=$($sol.Id)"
            if ($sol.Created) {
                Add-LabResource -Type 'dataverse-solution' -Id $sol.Id -Name $solutionName -Target $tgt._name -Api 'dataverse' `
                    -DeleteUri "$($dv.Api)/solutions($($sol.Id))" -Extra @{ explicitName = $true } | Out-Null
            }
        }
        else { Set-Outcome 'solution' 'FAILED' "$($sol.Error) - tables will be created in the default solution instead" }
    }
    elseif ($DryRun) { Set-Outcome 'publisher' 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome 'publisher' 'FAILED' "$($pub.Error) - tables will be created in the default solution instead" }
}

# --- tables ------------------------------------------------------------------

$prefix = if ($prof.solution.prefix) { $prof.solution.prefix } else { 'dxl' }

foreach ($r in $before.Roles.Values) {
    if ($r.Exists) { Set-Outcome "table $($r.LogicalName)" 'PRESENT' "entitySet=$($r.EntitySet)"; continue }
    if (-not $r.Manage) { continue }   # already reported as BLOCKED above

    Write-LabStep "table $($r.LogicalName)"
    $primary = New-DvStringAttribute -SchemaName "$($prefix)_Name" -DisplayName 'Name' -MaxLength 200 -IsPrimaryName
    # Two lab-owned columns on every table: RunId scopes a purge or a verification to a single
    # seeding run, Seq records where a record sat in the seeding order, which is what Scenario B
    # manipulates when it pushes the cycle contact late in the set.
    $extra = @(
        (New-DvStringAttribute -SchemaName "$($prefix)_RunId" -DisplayName 'Lab Run Id' -MaxLength 64),
        (New-DvIntegerAttribute -SchemaName "$($prefix)_Seq" -DisplayName 'Seed Sequence')
    )
    $res = New-DvEntity -Dv $dv -SchemaName $r.SchemaName -DisplayName $r.DisplayName -PluralName $r.PluralName `
        -Description "Dextors Lab - restore dependency scenario ($($r.Role))" -PrimaryAttribute $primary -ExtraAttributes $extra -Solution $solutionName

    if ($res.Ok) {
        $mid = Get-DvRecordId -Response $res
        Set-Outcome "table $($r.LogicalName)" 'CREATED' "schemaName=$($r.SchemaName) metadataId=$mid"
        Add-LabResource -Type 'dataverse-table' -Id $(if ($mid) { $mid } else { $r.LogicalName }) -Name $r.LogicalName -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/EntityDefinitions(LogicalName='$($r.LogicalName)')" -Extra @{ explicitName = $true; role = $r.Role } | Out-Null
    }
    elseif ($res.DryRun) { Set-Outcome "table $($r.LogicalName)" 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome "table $($r.LogicalName)" 'FAILED' "HTTP $($res.Status) code=$($res.Error.Code) $($res.Error.Message)" }
}

# --- lookups -----------------------------------------------------------------
# Created after every table exists, because a relationship needs both ends present.

foreach ($e in $before.Edges) {
    if ($e.Exists) { Set-Outcome "lookup $($e.Name)" 'PRESENT' "$($e.FromEntity).$($e.LookupAttribute) required=$($e.ActualRequired) delete=$($e.ActualDelete)"; continue }
    if (-not $e.RelationshipName) {
        Set-Outcome "lookup $($e.Name)" 'BLOCKED' "profile gives no relationshipSchemaName, so this lookup cannot be created - it is expected to exist already on $($e.FromEntity)"
        continue
    }
    # An already-created relationship from a previous partial run is a reuse, not a failure.
    $existing = Get-DvRelationshipBySchemaName -Dv $dv -SchemaName $e.RelationshipName
    if ($existing) { Set-Outcome "lookup $($e.Name)" 'PRESENT' "relationship $($e.RelationshipName) already exists"; continue }

    Write-LabStep "lookup $($e.Name)  ($($e.IntendedLink))"
    $required = if ($e.IntendedLink -eq 'obligatory') { 'ApplicationRequired' } else { 'None' }
    $res = New-DvLookup -Dv $dv -RelationshipSchemaName $e.RelationshipName -ReferencedEntity $e.ToEntity -ReferencingEntity $e.FromEntity `
        -LookupSchemaName $e.LookupSchemaName -LookupDisplayName $e.DisplayName -RequiredLevel $required -DeleteBehavior $e.IntendedDelete -Solution $solutionName

    if ($res.Ok) {
        $mid = Get-DvRecordId -Response $res
        Set-Outcome "lookup $($e.Name)" 'CREATED' "$($e.FromEntity).$($e.LookupAttribute) -> $($e.ToEntity) required=$required delete=$($e.IntendedDelete)"
        Add-LabResource -Type 'dataverse-relationship' -Id $(if ($mid) { $mid } else { $e.RelationshipName }) -Name $e.RelationshipName -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/RelationshipDefinitions(SchemaName='$($e.RelationshipName)')" -Extra @{ explicitName = $true; edge = $e.Name } | Out-Null
    }
    elseif ($res.DryRun) { Set-Outcome "lookup $($e.Name)" 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome "lookup $($e.Name)" 'FAILED' "HTTP $($res.Status) code=$($res.Error.Code) $($res.Error.Message)" }
}

# --- publish (optional) ------------------------------------------------------
# Data operations work against unpublished metadata; publishing only matters for the maker and
# model-driven UI. It can take minutes, so it is opt-in and never fatal.

if ($Publish -and -not $script:LabRun.DryRun) {
    Write-LabStep 'PublishAllXml'
    $p = Invoke-DvRequest -Dv $dv -Method POST -Path 'PublishAllXml' -Body @{} -Label 'dv-publish-all'
    Set-Outcome 'publish' $(if ($p.Ok) { 'DONE' } else { 'FAILED' }) "HTTP $($p.Status) $($p.Error.Code)"
}

# --- verify ------------------------------------------------------------------

Write-LabStep 'verifying resulting graph'
$after = Resolve-DvModel -Dv $dv -ModelProfile $prof
foreach ($e in @($after.Edges | Where-Object { $_.Exists })) {
    Add-LabEvidenceNote ("verified edge {0}: {1}.{2} -> {3} requiredLevel={4} delete={5} navProperty={6}" -f `
            $e.Name, $e.FromEntity, $e.LookupAttribute, $e.ToEntity, $e.ActualRequired, $e.ActualDelete, $e.NavigationProperty)
}

Write-Host ''
Write-Host ('  {0,-38} {1,-9} {2}' -f 'ELEMENT', 'STATE', 'DETAIL')
Write-Host ('  ' + ('-' * 118))
foreach ($o in $outcome.Values) { Write-Host ('  {0,-38} {1,-9} {2}' -f $o.Key, $o.State, $o.Detail) }

$created = @($outcome.Values | Where-Object { $_.State -eq 'CREATED' })
$failed = @($outcome.Values | Where-Object { $_.State -in 'FAILED', 'BLOCKED' })
$ev = @($outcome.Values | ForEach-Object { "$($_.Key): $($_.State) - $($_.Detail)" })

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary "Dry run: nothing was created. $($before.Missing.Count) element(s) would be created." -Evidence $ev | Out-Null
}
elseif ($after.Missing.Count -eq 0) {
    Complete-LabRun -Verdict PASS -Summary "Schema complete: $($created.Count) element(s) created, the rest already existed." -Evidence $ev | Out-Null
    Write-Host ''
    Write-Host '  Next:  .\lab.ps1 BUILD powerplatform/seed-cycle-dataset -Scenario A' -ForegroundColor Cyan
}
elseif ($created.Count) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Partially built: $($created.Count) created, $($after.Missing.Count) still missing. Microsoft error codes per element are in the evidence." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary "Nothing could be created ($($failed.Count) element(s) failed or blocked). Check that the signed-in user has the System Customizer or System Administrator role." -Evidence $ev | Out-Null
}
