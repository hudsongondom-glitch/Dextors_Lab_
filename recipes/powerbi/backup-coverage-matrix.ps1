<#
Sweeps one workspace and answers, per item: which API surface can see it, and can its
definition actually be retrieved? Produces a coverage matrix - the artifact you hand a
developer instead of a job log.

Written for the support case "missing reports and Dataflow Gen2 (CI/CD) in a Power BI backup".
It separates three things a job log conflates:

  1. items the Power BI REST API can SEE and EXPORT            -> backed up
  2. items it can SEE but Microsoft REFUSES to export          -> logged failure, exact code captured
  3. items it CANNOT SEE at all (Fabric-native item types)     -> silently absent, no error anywhere

Class 3 is what produces "missing data with no error in the log", so the matrix lists every
Fabric item type in the workspace next to what the Power BI surfaces return.

Verdict meaning (explicit):
  PASS         = a coverage gap was demonstrated: at least one item is invisible to the Power BI
                 surface, or is visible but its definition cannot be retrieved.
  FAIL         = no gap: every item is visible on the Power BI surface and every report exported.
  INCONCLUSIVE = enumeration itself failed (auth, workspace access), so nothing can be concluded.

  .\lab.ps1 INSPECT powerbi/backup-coverage-matrix -Target powerbi-fabric
  .\lab.ps1 INSPECT powerbi/backup-coverage-matrix -Target powerbi-largesem -IncludeScan
  .\lab.ps1 INSPECT powerbi/backup-coverage-matrix -Target powerbi-main -NoExport

-IncludeScan additionally runs the admin metadata scanner (getInfo/scanStatus/scanResult), which
is the discovery path a backup connector uses. It needs Fabric admin rights; without them the
recipe carries on and says so.

Background and citations: docs/powerbi-backup-coverage.md
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [switch]$NoExport,          # inventory only, skip the export attempts
    [switch]$IncludeScan,       # also run the admin metadata scanner
    [switch]$KeepPbix,          # keep successfully exported PBIX files in the run directory
    [int]$MaxExports = 25
)

$Recipe = @{
    Name        = 'powerbi/backup-coverage-matrix'
    Product     = 'powerbi'
    Modes       = @('INSPECT', 'TEST', 'REPRODUCE')
    Destructive = $false
    Description = 'Per-item coverage matrix: which API surface sees each item, and whether its definition can be retrieved.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $(if ($Target) { $Target } else { (Get-LabConfig).defaults.target }) -RequiredTargetFields @('workspaceId')
$run = Start-LabRun -Name 'pbi-backup-coverage-matrix' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Determine, per item in the workspace, which API surface exposes it and whether its definition can be retrieved, so that "missing from backup" can be attributed to a documented refusal, an invisible item type, or neither.' `
    -Plan @('Acquire Power BI + Fabric tokens', 'Inventory via Power BI REST', 'Inventory via Fabric Items API',
    'Optionally run the admin metadata scanner', 'Attempt PBIX export per report', 'Emit the coverage matrix')

if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fill in config and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId
Add-LabEvidenceNote "workspace: $ws ($($tgt.workspaceName))"

# Documented Microsoft refusals. Mapping the exact API error code to its cause is what makes a
# job log self-explaining. Sources are cited in docs/powerbi-backup-coverage.md.
$KnownRefusals = @{
    'ModelWithIncrementalRefreshIsNotDownloadable'  = 'Semantic model has incremental refresh - PBIX with data is not downloadable (UI offers live-connect only).'
    'ExportData_DisabledForModelWithDirectLakeMode' = 'Semantic model is Direct Lake - PBIX with data is not downloadable (UI offers live-connect only).'
    'OperationIsNotSupportedForPremiumFilesModel'   = 'Semantic model uses large semantic model storage format (PremiumFiles) - documented as not downloadable via REST, while UI download still works.'
    'ModelExportActionDenied'                       = 'Export denied for this model - template app or usage metrics content, or export blocked by a tenant setting.'
    'ExportPBIX_ModelessWorkbookNotFound'           = 'No PBIX behind this report - it was authored in the service or created through the Fabric items API, so there is no workbook to export. Reports like this are absent from a PBIX-based backup.'
    'PowerBINotAuthorizedException'                 = 'Caller lacks rights on the report or on its semantic model.'
}

# Microsoft returns codes with a namespace prefix in some cases - the log-visible short code
# ServerError_PremiumFilesErrors_OperationIsNotSupportedForPremiumFilesModel is one string, so
# match on containment rather than equality.
function Resolve-RefusalCause {
    param([string]$Code)
    if (-not $Code) { return $null }
    foreach ($k in $KnownRefusals.Keys) { if ($Code -like "*$k*") { return $KnownRefusals[$k] } }
    return $null
}

# --- 1. Tokens ---------------------------------------------------------------
Write-LabStep 'tokens'
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity
$fabToken = Get-LabAccessToken -Api Fabric -Target $tgt -Identity $Identity

# --- 2. Power BI REST inventory ---------------------------------------------
Write-LabStep 'Power BI REST inventory'
$pbiBase = "https://api.powerbi.com/v1.0/myorg/groups/$ws"
$rReports = Invoke-LabRequest -Uri "$pbiBase/reports" -Token $pbiToken -Label 'powerbi-reports' -AllowInDryRun
$rDatasets = Invoke-LabRequest -Uri "$pbiBase/datasets" -Token $pbiToken -Label 'powerbi-datasets' -AllowInDryRun
$rDataflows = Invoke-LabRequest -Uri "$pbiBase/dataflows" -Token $pbiToken -Label 'powerbi-dataflows' -AllowInDryRun
$rDashboards = Invoke-LabRequest -Uri "$pbiBase/dashboards" -Token $pbiToken -Label 'powerbi-dashboards' -AllowInDryRun

if (-not $rReports.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not list reports: HTTP $($rReports.Status) code=$($rReports.Error.Code)." `
        -Evidence @('Without an inventory nothing can be concluded about coverage.', "Raw: $($rReports.Raw)") | Out-Null
    return
}

$reports = @($rReports.Json.value)
$datasets = @($rDatasets.Json.value)
$pbiDataflows = @($rDataflows.Json.value)
$dashboards = @($rDashboards.Json.value)
$dsById = @{}; $datasets | ForEach-Object { $dsById[$_.id] = $_ }

Add-LabEvidenceNote ("Power BI REST: {0} report(s), {1} semantic model(s), {2} dataflow(s), {3} dashboard(s)" -f `
        $reports.Count, $datasets.Count, $pbiDataflows.Count, $dashboards.Count)

# --- 3. Fabric Items inventory ----------------------------------------------
Write-LabStep 'Fabric Items inventory'
$rItems = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items" -Token $fabToken -Label 'fabric-items' -AllowInDryRun
$fabItems = @($rItems.Json.value)
if ($rItems.Ok) {
    $byType = $fabItems | Group-Object type | Sort-Object Name
    Add-LabEvidenceNote ("Fabric Items API: {0} item(s) - {1}" -f $fabItems.Count, (($byType | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))
}
else {
    Add-LabEvidenceNote "Fabric Items API unavailable: HTTP $($rItems.Status) code=$($rItems.Error.Code) - Fabric-only item types cannot be listed."
}

# --- 4. Admin metadata scanner (a backup connector's discovery path) ---------
if ($IncludeScan) {
    Write-LabStep 'admin metadata scanner'
    $scan = Invoke-LabRequest -Method POST -Token $pbiToken -Label 'scanner-getinfo' -AllowInDryRun `
        -Uri 'https://api.powerbi.com/v1.0/myorg/admin/workspaces/getInfo?lineage=True&datasourceDetails=True&datasetSchema=False&datasetExpressions=False' `
        -Body @{ workspaces = @($ws) }
    if ($scan.Ok -and $scan.Json.id) {
        $scanId = $scan.Json.id
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            $st = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanStatus/$scanId" -Token $pbiToken -Label 'scanner-status' -NoEvidence -AllowInDryRun
            if ($st.Json.status -eq 'Succeeded') { break }
        }
        $res = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanResult/$scanId" -Token $pbiToken -Label 'scanner-result' -AllowInDryRun
        if ($res.Ok) {
            $sw = @($res.Json.workspaces)[0]
            $counts = @(
                "reports=$(@($sw.reports).Count)"
                "datasets=$(@($sw.datasets).Count)"
                "dataflows=$(@($sw.dataflows).Count)"
                "dashboards=$(@($sw.dashboards).Count)"
                "datamarts=$(@($sw.datamarts).Count)"
            ) -join ', '
            Add-LabEvidenceNote "Scanner result collections: $counts"
            Add-LabEvidenceNote 'The scanner response schema carries collections only for reports/dashboards/datasets/dataflows/datamarts - there is no collection for generic Fabric item types, so those cannot be discovered through it.'
        }
    }
    else {
        Add-LabEvidenceNote "Scanner unavailable: HTTP $($scan.Status) code=$($scan.Error.Code) - needs Fabric admin rights. The inventory below is still valid."
    }
}

# --- 5. Export attempt per report -------------------------------------------
Write-LabStep 'export attempts'
$rows = [System.Collections.Generic.List[object]]::new()
$exported = 0

foreach ($rep in $reports) {
    $ds = if ($rep.datasetId) { $dsById[$rep.datasetId] } else { $null }
    $row = [ordered]@{
        Kind       = 'Report'
        Name       = $rep.name
        Id         = $rep.id
        ItemType   = if ($rep.reportType) { $rep.reportType } else { 'PowerBIReport' }
        Storage    = if ($ds) { $ds.targetStorageMode } else { 'n/a' }
        PbiRest    = 'yes'
        FabricApi  = if ($fabItems | Where-Object { $_.id -eq $rep.id }) { 'yes' } else { 'no' }
        Export     = 'not attempted'
        Code       = ''
        Cause      = ''
    }

    if ($NoExport) { $rows.Add([pscustomobject]$row); continue }

    # The Export endpoint produces PBIX for Power BI reports only. A paginated report is RDL and
    # is not retrievable through it at all - which is why it never shows up as an export failure.
    if ($row.ItemType -eq 'PaginatedReport') {
        $row.Export = 'n/a'
        $row.Cause = 'Paginated (RDL) report - the PBIX Export endpoint does not apply. Needs a separate retrieval path.'
        $rows.Add([pscustomobject]$row); continue
    }
    if ($exported -ge $MaxExports) {
        $row.Export = 'skipped'; $row.Cause = "MaxExports=$MaxExports reached"
        $rows.Add([pscustomobject]$row); continue
    }

    $exported++
    $out = Join-Path $run.ResponsesDir ("export-" + $rep.id + ".bin")
    $exp = Invoke-LabRequest -Uri "$pbiBase/reports/$($rep.id)/Export" -Token $pbiToken -OutFile $out -Label "export-$($rep.id)" -AllowInDryRun

    if ($exp.Ok) {
        $size = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        $row.Export = "ok ($size bytes)"
        if ($KeepPbix) { Move-Item $out ([IO.Path]::ChangeExtension($out, '.pbix')) -Force }
        else { Remove-Item $out -ErrorAction SilentlyContinue }
    }
    else {
        Remove-Item $out -ErrorAction SilentlyContinue
        $code = $exp.Error.Code
        if (-not $code -and $exp.Raw -match '"code"\s*:\s*"([^"]+)"') { $code = $Matches[1] }
        $row.Export = "FAILED (HTTP $($exp.Status))"
        $row.Code = if ($code) { $code } else { '<none parsed>' }
        $cause = Resolve-RefusalCause -Code $code
        $row.Cause = if ($cause) { $cause } else { 'Not a known documented refusal - keep the raw body and take it to Microsoft.' }
        Save-LabEvidence -Kind response -Name "export-error-$($rep.id)" -Content $exp.Raw -Extension 'json' | Out-Null
    }
    $rows.Add([pscustomobject]$row)
}

# --- 6. Dataflows across both surfaces --------------------------------------
Write-LabStep 'dataflow surfaces'
$pbiDfIds = @($pbiDataflows | ForEach-Object { $_.objectId })
foreach ($item in ($fabItems | Where-Object { $_.type -eq 'Dataflow' })) {
    $seenInPbi = $item.id -in $pbiDfIds
    $rows.Add([pscustomobject][ordered]@{
            Kind      = 'Dataflow'
            Name      = $item.displayName
            Id        = $item.id
            ItemType  = 'Dataflow (Fabric item)'
            Storage   = ''
            PbiRest   = $(if ($seenInPbi) { 'yes' } else { 'no' })
            FabricApi = 'yes'
            Export    = $(if ($seenInPbi) { 'via Power BI dataflow API' } else { 'Fabric getDefinition only' })
            Code      = ''
            Cause     = $(if ($seenInPbi) { 'Gen1-shaped dataflow: visible to the legacy Power BI dataflow API.' }
                else { 'Dataflow Gen2 (CI/CD): absent from the Power BI dataflow API. Its definition is mashup.pq via Fabric POST items/{id}/getDefinition, not model.json.' })
        })
}
# Gen1 dataflows the Fabric Items call did not return (or could not list)
foreach ($df in $pbiDataflows) {
    if ($fabItems | Where-Object { $_.id -eq $df.objectId }) { continue }
    $rows.Add([pscustomobject][ordered]@{
            Kind      = 'Dataflow'
            Name      = $df.name
            Id        = $df.objectId
            ItemType  = 'Dataflow (Power BI)'
            Storage   = ''
            PbiRest   = 'yes'
            FabricApi = 'no'
            Export    = 'via Power BI dataflow API'
            Code      = ''
            Cause     = 'Gen1 dataflow: model.json retrievable through the legacy Power BI dataflow API.'
        })
}

# Fabric-native item types with no Power BI REST representation at all.
$pbiVisibleIds = @($reports | ForEach-Object { $_.id }) + @($datasets | ForEach-Object { $_.id }) + $pbiDfIds + @($dashboards | ForEach-Object { $_.id })
foreach ($item in ($fabItems | Where-Object { $_.type -notin 'Dataflow', 'Report', 'SemanticModel', 'Dashboard' })) {
    if ($item.id -in $pbiVisibleIds) { continue }
    $rows.Add([pscustomobject][ordered]@{
            Kind      = 'Fabric item'
            Name      = $item.displayName
            Id        = $item.id
            ItemType  = $item.type
            Storage   = ''
            PbiRest   = 'no'
            FabricApi = 'yes'
            Export    = 'Fabric API only'
            Code      = ''
            Cause     = "Fabric-native item type '$($item.type)': no representation in the Power BI REST or scanner surfaces."
        })
}

# --- 7. Matrix ---------------------------------------------------------------
Write-LabStep 'coverage matrix'
Write-Host ($rows | Format-Table Kind, Name, ItemType, Storage, PbiRest, FabricApi, Export, Code -AutoSize | Out-String -Width 400)

$md = @(
    '| Kind | Name | Type | Storage | Power BI REST | Fabric API | Export | Code | Cause |'
    '|---|---|---|---|---|---|---|---|---|'
)
$md += $rows | ForEach-Object { "| $($_.Kind) | $($_.Name) | $($_.ItemType) | $($_.Storage) | $($_.PbiRest) | $($_.FabricApi) | $($_.Export) | $($_.Code) | $($_.Cause) |" }
Save-LabEvidence -Kind response -Name 'coverage-matrix' -Content ($md -join "`n") -Extension 'md' | Out-Null

$invisible = @($rows | Where-Object { $_.PbiRest -eq 'no' })
$refused = @($rows | Where-Object { $_.Export -like 'FAILED*' })
$inapplicable = @($rows | Where-Object { $_.Export -eq 'n/a' })
$ok = @($rows | Where-Object { $_.Export -like 'ok*' })

$ev = @(
    "Items in matrix: $($rows.Count)"
    "Exported successfully: $($ok.Count)"
    "Export refused by Microsoft: $($refused.Count)"
    "Export endpoint not applicable (paginated/RDL): $($inapplicable.Count)"
    "Invisible to the Power BI REST surface: $($invisible.Count)"
)
if ($refused.Count) { $ev += 'Refusal codes: ' + (($refused | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ') }
if ($invisible.Count) { $ev += 'Invisible items: ' + (($invisible | ForEach-Object { "$($_.ItemType) '$($_.Name)'" }) -join ', ') }
$ev += 'Full matrix: responses/coverage-matrix.md'

if ($invisible.Count -or $refused.Count -or $inapplicable.Count) {
    Complete-LabRun -Verdict PASS -Summary "Coverage gap demonstrated: $($refused.Count) item(s) refused by Microsoft, $($inapplicable.Count) outside the Export endpoint, $($invisible.Count) invisible to the Power BI REST surface." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary 'No coverage gap: every item is visible to the Power BI REST surface and every report exported.' -Evidence $ev | Out-Null
}
