<#
Gives a Fabric Dataflow Gen2 real Power Query content: dimension tables, a generated calendar, a
fact table, and a derived query that actually transforms (join + group), rather than the empty
`section Section1;` stub that a bare create leaves behind.

Why it matters here: a dataflow created with only a displayName is indistinguishable from an empty
item. To judge whether a backup captures a dataflow's *definition* - the mashup, not just the name -
the dataflow has to contain something worth losing.

Data comes from New-LabSeedDataset, the same generator behind the push semantic model and the PBIP,
so the same rows appear as a dataflow, a push dataset and a Desktop model.

Verdict meaning (explicit):
  PASS         = every targeted dataflow now holds the generated mashup.
  INCONCLUSIVE = some updated, some failed; per-dataflow error codes are in the evidence.
  FAIL         = nothing could be created or updated.
  BLOCKED      = config/credentials missing.

  .\lab.ps1 BUILD powerbi/build-gen2-dataflow -Target powerbi-fabric
  .\lab.ps1 BUILD powerbi/build-gen2-dataflow -Target powerbi-largesem -SalesRows 500
  .\lab.ps1 BUILD powerbi/build-gen2-dataflow -Target powerbi-fabric -DataflowId <guid>
  .\lab.ps1 BUILD powerbi/build-gen2-dataflow -Target powerbi-fabric -CreateNew

Default behaviour: update every lab-owned dataflow in the target workspace. If there are none,
create one. Gen2 requires Fabric capacity - on a Pro workspace this stops cleanly.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'powerbi-fabric',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$DataflowId,          # update one specific dataflow
    [switch]$CreateNew,           # always create a new one instead of updating
    [int]$SalesRows = 1000
)

$Recipe = @{
    Name        = 'powerbi/build-gen2-dataflow'
    Product     = 'powerbi'
    Modes       = @('BUILD', 'TEST')
    Destructive = $false
    Description = 'Give a Dataflow Gen2 a real Power Query mashup (dimensions, calendar, fact, and a join+group query) instead of an empty stub.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('workspaceId')
if ($SalesRows -lt 1 -or $SalesRows -gt 20000) { $problems = @($problems) + '-SalesRows must be between 1 and 20000.' }

$run = Start-LabRun -Name 'pbi-build-gen2-dataflow' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Populate Fabric Dataflow Gen2 items with a real Power Query mashup so a backup has actual dataflow logic to capture, not an empty stub.' `
    -Plan @(
    'Confirm the workspace is on Fabric capacity'
    'Generate the deterministic seed dataset'
    'Build a mashup.pq section document: Product, Customer, Store, Calendar, Sales, SalesByCategory'
    'Resolve which dataflows to target (specific id, lab-owned existing, or create new)'
    'POST updateDefinition with mashup.pq + queryMetadata.json + .platform'
    'Re-read each definition and confirm the mashup landed'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix config and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId
Add-LabEvidenceNote "workspace: $ws ($($tgt.workspaceName))"

$fabToken = Get-LabAccessToken -Api Fabric -Target $tgt -Identity $Identity
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity

# --- capacity gate -----------------------------------------------------------

Write-LabStep 'capacity check'
$wsInfo = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups?`$filter=id eq '$ws'" -Token $pbiToken -Label 'workspace-info' -AllowInDryRun
$wsRow = $wsInfo.Json.value | Select-Object -First 1
if (-not $wsRow) {
    Complete-LabRun -Verdict FAIL -Summary "Workspace $ws is not reachable (HTTP $($wsInfo.Status))." | Out-Null
    return
}
if (-not $wsRow.isOnDedicatedCapacity) {
    Stop-LabRunBlocked -Problems @("Workspace '$($tgt.workspaceName)' is on shared capacity; Dataflow Gen2 requires Fabric capacity.") `
        -NextStep 'Assign the workspace to a Fabric capacity, or target powerbi-fabric / powerbi-largesem. For a Pro workspace use a Gen1 dataflow instead.'
    return
}
Add-LabEvidenceNote "capacity: $($wsRow.capacityId)"

# --- build the mashup --------------------------------------------------------

Write-LabStep "building mashup.pq ($SalesRows sales rows)"
# The six-query mashup is shared with powerbi/build-gen1-dataflow so both dataflow generations
# carry identical logic - see tools/powerbi/Pbi.Mashup.ps1.
# Gen2 only ever runs on Fabric capacity, so the referencing (computed table) form is safe here
# and gives richer lineage. Gen1 uses the self-contained form so it refreshes on Pro too.
$seed = New-LabSeedMashup -SalesRowCount $SalesRows -ComputedEntity
$queryDefs = $seed.Definitions
$mashup = $seed.Document
Add-LabEvidenceNote ("generated: {0} products, {1} customers, {2} stores, {3} sales rows" -f `
        $seed.Data.Products.Count, $seed.Data.Customers.Count, $seed.Data.Stores.Count, $seed.Data.Sales.Count)

$queriesMetadata = [ordered]@{}
foreach ($qName in $queryDefs.Keys) {
    $queriesMetadata[$qName] = [ordered]@{
        queryId     = [guid]::NewGuid().ToString()
        queryName   = $qName
        loadEnabled = $true
    }
}
$queryMetadataJson = [ordered]@{
    formatVersion        = '202502'
    computeEngineSettings = @{ allowFastCopy = $false }
    name                 = 'Section1'
    queryGroups          = @()
    documentLocale       = 'en-US'
    queriesMetadata      = $queriesMetadata
    allowNativeQueries   = $false
} | ConvertTo-Json -Depth 10

Add-LabEvidenceNote "mashup: $($queryDefs.Count) queries ($($queryDefs.Keys -join ', ')), $([math]::Round($mashup.Length / 1KB)) KB"
Save-LabEvidence -Kind request -Name 'mashup' -Content $mashup -Extension 'pq' | Out-Null

# --- resolve targets ---------------------------------------------------------

Write-LabStep 'resolving target dataflows'
$targets = @()

if ($DataflowId) {
    $targets = @([pscustomobject]@{ id = $DataflowId; displayName = "<specified $DataflowId>" })
}
elseif (-not $CreateNew) {
    $list = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows" -Token $fabToken -Label 'list-dataflows' -AllowInDryRun
    # Only ever touch dataflows this lab created - never anything hand-made in the workspace.
    $targets = @($list.Json.value | Where-Object { Test-LabResourceName -Name $_.displayName })
    $skipped = @($list.Json.value | Where-Object { -not (Test-LabResourceName -Name $_.displayName) })
    if ($skipped.Count) { Add-LabEvidenceNote "left untouched (not lab-owned): $(($skipped.displayName) -join ', ')" }
}

$platformFor = {
    param([string]$Name)
    @{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata  = @{ type = 'Dataflow'; displayName = $Name; description = 'Dextors Lab seed dataflow' }
        config    = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
    } | ConvertTo-Json -Depth 10
}

function New-DefinitionParts {
    param([string]$Name)
    @(
        @{ path = 'queryMetadata.json'; payload = (ConvertTo-LabB64 $queryMetadataJson); payloadType = 'InlineBase64' }
        @{ path = 'mashup.pq'; payload = (ConvertTo-LabB64 $mashup); payloadType = 'InlineBase64' }
        @{ path = '.platform'; payload = (ConvertTo-LabB64 (& $platformFor $Name)); payloadType = 'InlineBase64' }
    )
}

function Wait-LabFabricOperation {
    param($Response, [int]$MaxTries = 40)
    if ($Response.Status -ne 202) { return $Response.Ok }
    $op = $Response.Headers['x-ms-operation-id'] | Select-Object -First 1
    if (-not $op) { return $false }
    Write-LabLog "long-running operation $op - polling" -Level INFO
    for ($i = 0; $i -lt $MaxTries; $i++) {
        Start-Sleep -Seconds 3
        $st = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op" -Token $fabToken -Label 'fabric-operation-status' -NoEvidence
        if ($st.Json.status -eq 'Succeeded') { return $true }
        if ($st.Json.status -eq 'Failed') { Write-LabLog "operation failed: $($st.Raw)" -Level ERROR; return $false }
    }
    Write-LabLog "operation $op did not finish within $($MaxTries * 3)s" -Level WARN
    return $false
}

# --- create if nothing to update ---------------------------------------------

if (-not $targets -or $targets.Count -eq 0) {
    Write-LabStep 'no lab-owned dataflow found - creating one'
    $name = New-LabResourceName -Suffix 'dfgen2'
    $create = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows" -Token $fabToken `
        -Body @{ displayName = $name; description = 'Dextors Lab seed dataflow'; definition = @{ parts = (New-DefinitionParts $name) } } `
        -Label 'create-dataflow-with-definition'

    $newId = $null
    if ($create.Status -eq 201 -or ($create.Ok -and $create.Json.id)) { $newId = $create.Json.id }
    elseif ($create.Status -eq 202) {
        $op = $create.Headers['x-ms-operation-id'] | Select-Object -First 1
        if (Wait-LabFabricOperation -Response $create) {
            $r = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op/result" -Token $fabToken -Label 'create-result'
            $newId = $r.Json.id
        }
    }

    if (-not $newId) {
        Complete-LabRun -Verdict FAIL -Summary "Could not create a dataflow: HTTP $($create.Status) code=$($create.Error.Code) $($create.Error.Message)" | Out-Null
        return
    }
    Add-LabResource -Type 'fabric-dataflow' -Id $newId -Name $name -Target $tgt._name -Api 'fabric' `
        -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows/$newId" | Out-Null
    $targets = @([pscustomobject]@{ id = $newId; displayName = $name })
    Add-LabEvidenceNote "created dataflow $newId '$name' with definition"
}
else {
    # --- update each -----------------------------------------------------------
    Write-LabStep "updating $($targets.Count) dataflow(s)"
    foreach ($df in $targets) {
        $name = if ($df.displayName -like '<specified*') { (New-LabResourceName -Suffix 'dfgen2') } else { $df.displayName }
        $upd = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows/$($df.id)/updateDefinition?updateMetadata=true" `
            -Token $fabToken -Body @{ definition = @{ parts = (New-DefinitionParts $name) } } -Label "update-$($df.id)"
        $ok = Wait-LabFabricOperation -Response $upd
        if ($ok) { Write-LabLog "updated $($df.id) '$name'" -Level OK }
        else { Write-LabLog "update FAILED $($df.id): HTTP $($upd.Status) code=$($upd.Error.Code) $($upd.Error.Message)" -Level ERROR }
    }
}

# --- verify ------------------------------------------------------------------

Write-LabStep 'verifying definitions'
$results = @()
foreach ($df in $targets) {
    $def = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows/$($df.id)/getDefinition" `
        -Token $fabToken -Label "verify-$($df.id)"
    $part = @($def.Json.definition.parts) | Where-Object { $_.path -eq 'mashup.pq' } | Select-Object -First 1
    $text = if ($part) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) } else { '' }
    $shared = @([regex]::Matches($text, '(?m)^shared\s+([A-Za-z0-9_]+)\s*=')) | ForEach-Object { $_.Groups[1].Value }

    $results += [pscustomobject]@{
        Id      = $df.id
        Name    = $df.displayName
        Ok      = ($shared.Count -eq $queryDefs.Count)
        Queries = $shared
        Bytes   = $text.Length
    }
}

Write-Host ''
Write-Host ('  {0,-38} {1,-8} {2}' -f 'DATAFLOW', 'STATE', 'QUERIES')
Write-Host ('  ' + ('-' * 100))
foreach ($r in $results) {
    Write-Host ('  {0,-38} {1,-8} {2}' -f $r.Id, $(if ($r.Ok) { 'OK' } else { 'PARTIAL' }), ($r.Queries -join ', '))
}

$ev = @($results | ForEach-Object { "$($_.Id) '$($_.Name)': $(if ($_.Ok) { 'OK' } else { 'PARTIAL' }) - $($_.Queries.Count)/$($queryDefs.Count) queries, mashup $($_.Bytes) bytes" })
$good = @($results | Where-Object { $_.Ok })

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary 'Dry run: no dataflow was created or updated.' -Evidence $ev | Out-Null
}
elseif ($good.Count -eq $results.Count -and $results.Count -gt 0) {
    Complete-LabRun -Verdict PASS -Summary "$($good.Count) dataflow(s) now hold a $($queryDefs.Count)-query mashup including a join+group transformation." -Evidence $ev | Out-Null
}
elseif ($good.Count -gt 0) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "$($good.Count)/$($results.Count) dataflow(s) updated; the rest did not take the full mashup." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary 'No dataflow ended up with the mashup.' -Evidence $ev | Out-Null
}

Write-Host ''
Write-Host 'Note: Gen2 dataflows do not appear in the legacy Power BI REST dataflow API.' -ForegroundColor Yellow
Write-Host 'Check whether your backup captured them:  .\lab.ps1 REPRODUCE powerbi/dataflow-gen2-visibility -Target ' -NoNewline -ForegroundColor Yellow
Write-Host $Target -ForegroundColor Yellow
