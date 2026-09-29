<#
Read-only analysis of the restore dependency graph in a Dataverse environment.

Answers the questions the spec leaves open before any data is created:
  - do the tables playing account / contact / order actually exist, and what are they called?
  - which lookups join them, and is each one obligatory (ApplicationRequired) or optional?
  - is there a genuine cycle, and if so can it be broken by nulling an optional lookup and
    patching it afterwards - or does every cycle contain an obligatory edge, in which case no
    creation order exists and the limitation is real rather than a timing artifact?
  - what creation order would a dependency-aware restore have to use?

With -Discover it also lists every custom table in the environment, which is how you find
artifacts that were built by hand outside this repo.

Creates nothing, changes nothing.

  PASS         = the graph was resolved and analysed (whether or not tables were missing).
  INCONCLUSIVE = auth or permissions prevented reading metadata.

  .\lab.ps1 INSPECT powerplatform/inspect-dependency-graph
  .\lab.ps1 INSPECT powerplatform/inspect-dependency-graph -ModelProfile oob
  .\lab.ps1 INSPECT powerplatform/inspect-dependency-graph -Discover
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$ModelProfile,     # model profile: custom (default) | oob
    [switch]$Discover          # also enumerate every custom table in the environment
)

$Recipe = @{
    Name        = 'powerplatform/inspect-dependency-graph'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read the account/contact/order lookup graph, classify each edge obligatory or optional, detect cycles and derive the required creation order.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'dv-inspect-dependency-graph' -Mode INSPECT -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request 'Determine the real lookup dependency graph between the account, contact and order tables, so restore-ordering hypotheses are tested against the actual schema rather than assumed field names.' `
    -Plan @(
    'Resolve the model profile against live entity metadata'
    'Read many-to-one relationships and lookup required levels for each role'
    'Classify every edge as obligatory or optional'
    'Enumerate cycles and report whether each is breakable by deferring an optional edge'
    'Derive the creation order a dependency-aware restore would need'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$Target with an environmentUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"

Write-LabStep 'WhoAmI'
$who = Get-DvWhoAmI -Dv $dv
if (-not $who.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "WhoAmI failed: HTTP $($who.Status) code=$($who.Error.Code)" -Evidence @(
        $who.Error.Message
        'Under delegated auth, 403 / 0x80072560 means the signed-in user is not a Dataverse user in this environment or has no security role.'
    ) | Out-Null
    return
}
Add-LabEvidenceNote "WhoAmI OK: UserId=$($who.Json.UserId) OrganizationId=$($who.Json.OrganizationId)"

# --- optional discovery ------------------------------------------------------
# Note: EntityDefinitions rejects $top with 0x80060888 "The query parameter is not supported".
# Filter and select are fine; paging is handled by Get-DvRecords.

if ($Discover) {
    Write-LabStep 'enumerating custom tables'
    $q = 'EntityDefinitions?$select=LogicalName,SchemaName,EntitySetName,PrimaryIdAttribute,PrimaryNameAttribute&$filter=IsCustomEntity eq true'
    $custom = Get-DvRecords -Dv $dv -Query $q -Label 'discover-custom-tables'
    if ($custom.Ok) {
        Add-LabEvidenceNote "$($custom.Records.Count) custom table(s) in $($dv.Base)"
        Write-Host ''
        Write-Host ('  {0,-42} {1}' -f 'LOGICAL NAME', 'ENTITY SET')
        Write-Host ('  ' + ('-' * 78))
        foreach ($c in @($custom.Records | Sort-Object LogicalName)) {
            Write-Host ('  {0,-42} {1}' -f $c.LogicalName, $c.EntitySetName)
        }
        Add-LabEvidenceNote "custom tables: $((@($custom.Records.LogicalName) | Sort-Object) -join ', ')"
    }
    else { Add-LabEvidenceNote "custom table discovery failed: HTTP $($custom.Status) $($custom.Error.Code)" }
}

# --- resolve the model -------------------------------------------------------

Write-LabStep 'resolving dependency model'
$prof = Get-DvModelProfile -Name $ModelProfile
Add-LabEvidenceNote "profile '$($prof._name)': $($prof.description)"
$resolved = Resolve-DvModel -Dv $dv -ModelProfile $prof

Write-Host ''
Write-Host '  ROLES' -ForegroundColor Cyan
Write-Host ('  {0,-9} {1,-24} {2,-8} {3,-24} {4}' -f 'ROLE', 'TABLE', 'EXISTS', 'ENTITY SET', 'NAME COLUMN')
Write-Host ('  ' + ('-' * 95))
foreach ($r in $resolved.Roles.Values) {
    Write-Host ('  {0,-9} {1,-24} {2,-8} {3,-24} {4}' -f $r.Role, $r.LogicalName, $(if ($r.Exists) { 'yes' } else { 'NO' }), $r.EntitySet, $r.NameAttribute)
    Add-LabEvidenceNote ("role {0}: {1} exists={2} entitySet={3} idAttr={4} nameAttr={5}" -f $r.Role, $r.LogicalName, $r.Exists, $r.EntitySet, $r.IdAttribute, $r.NameAttribute)
}

Write-Host ''
Write-Host '  EDGES  (obligatory = required lookup / black in the diagram)' -ForegroundColor Cyan
Write-Host ('  {0,-26} {1,-30} {2,-8} {3,-13} {4,-11} {5}' -f 'EDGE', 'LOOKUP', 'EXISTS', 'ACTUAL REQ', 'DELETE', 'BINDS VIA')
Write-Host ('  ' + ('-' * 118))
foreach ($e in $resolved.Edges) {
    $req = if (-not $e.Exists) { '-' } elseif ($e.IsRequired) { 'OBLIGATORY' } else { 'optional' }
    Write-Host ('  {0,-26} {1,-30} {2,-8} {3,-13} {4,-11} {5}' -f `
            $e.Name, "$($e.FromEntity).$($e.LookupAttribute)", $(if ($e.Exists) { 'yes' } else { 'NO' }), $req, $e.ActualDelete, $e.NavigationProperty)
    Add-LabEvidenceNote ("edge {0}: {1}.{2} -> {3} exists={4} intended={5} actualRequiredLevel={6} delete={7} navProperty={8}" -f `
            $e.Name, $e.FromEntity, $e.LookupAttribute, $e.ToEntity, $e.Exists, $e.IntendedLink, $e.ActualRequired, $e.ActualDelete, $e.NavigationProperty)
}

# Config drift is worth shouting about: an edge the config calls obligatory but that Dataverse
# reports as optional invalidates any conclusion drawn from the run.
$drift = @($resolved.Edges | Where-Object {
        $_.Exists -and (($_.IntendedLink -eq 'obligatory') -ne $_.IsRequired)
    })
foreach ($d in $drift) {
    Write-LabLog "DRIFT: edge '$($d.Name)' is configured as '$($d.IntendedLink)' but Dataverse reports RequiredLevel=$($d.ActualRequired)" -Level WARN
    Add-LabEvidenceNote "DRIFT: edge '$($d.Name)' configured '$($d.IntendedLink)' but actual RequiredLevel=$($d.ActualRequired)"
}

# --- cycles ------------------------------------------------------------------

Write-LabStep 'cycle analysis'
$cycles = @(Get-DvModelCycles -Resolved $resolved -ExistingOnly)
$unbreakable = @()

if (-not $cycles.Count) {
    Write-Host ''
    Write-Host '  No cycle among the existing edges.' -ForegroundColor Green
    Add-LabEvidenceNote 'cycles: none among existing edges'
}
else {
    Write-Host ''
    foreach ($c in $cycles) {
        $path = ($c.Nodes -join ' -> ')
        if ($c.Optional.Count) {
            Write-Host "  CYCLE  $path" -ForegroundColor Yellow
            Write-Host "         breakable - defer optional edge(s): $(@($c.Optional.Name) -join ', ')"
            Add-LabEvidenceNote "cycle [$path] BREAKABLE by deferring optional edge(s): $(@($c.Optional.Name) -join ', ')"
        }
        else {
            $unbreakable += $c
            Write-Host "  CYCLE  $path" -ForegroundColor Red
            Write-Host '         UNBREAKABLE - every edge in this loop is obligatory, so no creation order exists'
            Add-LabEvidenceNote "cycle [$path] UNBREAKABLE - all edges obligatory: $(@($c.Edges.Name) -join ', ')"
        }
    }
}

# --- creation order ----------------------------------------------------------

Write-LabStep 'creation order'
$order = Get-DvCreationOrder -Resolved $resolved
Write-Host ''
if ($order.Ok) {
    Write-Host "  Creation order (obligatory edges only):  $($order.Order -join '  ->  ')" -ForegroundColor Green
    Add-LabEvidenceNote "creation order honouring obligatory edges: $($order.Order -join ' -> ')"
    Add-LabEvidenceNote "deletion/purge order is the reverse: $((@($order.Order)[($order.Order.Count-1)..0]) -join ' -> ')"
}
else {
    Write-Host "  NO valid creation order - obligatory edges deadlock on: $($order.Stuck -join ', ')" -ForegroundColor Red
    Add-LabEvidenceNote "no creation order exists; obligatory-edge deadlock among: $($order.Stuck -join ', ')"
}

# --- verdict -----------------------------------------------------------------

$missingNote = if ($resolved.Missing.Count) { " $($resolved.Missing.Count) schema element(s) missing." } else { ' Schema is complete.' }
$summary = if ($unbreakable.Count) {
    "Graph resolved. $($unbreakable.Count) UNBREAKABLE cycle(s): every edge is obligatory, so no create order exists and a two-phase create cannot help either.$missingNote"
}
elseif ($cycles.Count) {
    "Graph resolved. $($cycles.Count) cycle(s), all breakable by deferring an optional lookup - so a cycle alone should not defeat a restore that creates with lookups nulled and patches afterwards.$missingNote"
}
else {
    "Graph resolved. No cycles among existing edges; dependencies form a chain, so ordering alone determines success.$missingNote"
}
if ($resolved.Missing.Count) {
    $resolved.Missing | ForEach-Object { Add-LabEvidenceNote "MISSING: $_" }
    Write-Host ''
    Write-Host '  Missing schema elements:' -ForegroundColor Yellow
    $resolved.Missing | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''
    Write-Host '  Create them with:  .\lab.ps1 BUILD powerplatform/build-dependency-model' -ForegroundColor Cyan
}

Complete-LabRun -Verdict PASS -Summary $summary | Out-Null
