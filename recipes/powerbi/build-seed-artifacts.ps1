<#
Seeds a Power BI workspace with one artifact of each type, carrying realistic simulated data, so
backup and restore behaviour can be exercised against a genuine spread of objects rather than a
single empty report.

The push semantic model is a real star schema - a Sales fact joined to Product, Customer, Store
and Date dimensions, with relationships and DAX measures - populated with generated rows. Data is
deterministic (fixed RNG seed), so two runs produce comparable content.

Every artifact type is attempted independently: a failure in one does not stop the rest, and the
exact Microsoft error code for each failure is recorded. That matters more than a clean run -
"Gen2 dataflows need capacity" is itself a finding worth keeping.

Artifact types attempted:
  pushmodel   star-schema push semantic model + rows   Power BI REST   shared capacity OK
  report      multi-page report from PBIR              Fabric Items    shared capacity OK
  dashboard   dashboard                                Power BI REST   needs Dashboard.ReadWrite.All
  tile        dashboard tile (cloned)                  Power BI REST   needs an existing source tile
  model       semantic model from TMDL                 Fabric Items    needs SemanticModel.ReadWrite.All
  dataflow    Dataflow Gen2                            Fabric REST     needs Fabric capacity
  paginated   paginated report from RDL                Power BI REST   needs Fabric/Premium capacity
  lakehouse   Lakehouse                                Fabric REST     needs Fabric capacity
  notebook    Notebook                                 Fabric REST     needs Fabric capacity

Verdict meaning (explicit):
  PASS         = every attempted artifact type was created.
  INCONCLUSIVE = some types created, some failed; per-type error codes are in the evidence.
  FAIL         = nothing could be created (auth, workspace access or policy problem).

  .\lab.ps1 BUILD powerbi/build-seed-artifacts -Target powerbi-main
  .\lab.ps1 BUILD powerbi/build-seed-artifacts -Target powerbi-fabric -SalesRows 8000
  .\lab.ps1 BUILD powerbi/build-seed-artifacts -Only dashboard,model
  .\lab.ps1 BUILD powerbi/build-seed-artifacts -DryRun

Everything created is registered in the ledger with a DeleteUri, so:
  .\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'powerbi-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string[]]$Only,                 # subset of artifact keys; default = all
    [int]$SalesRows = 3000           # fact table row count
)

$Recipe = @{
    Name        = 'powerbi/build-seed-artifacts'
    Product     = 'powerbi'
    Modes       = @('BUILD', 'TEST')
    Destructive = $false
    Description = 'Seed a workspace with one of each Power BI/Fabric artifact type, including a star-schema push model with generated data.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$AllKeys = @('pushmodel', 'report', 'dashboard', 'tile', 'model', 'dataflow', 'paginated', 'lakehouse', 'notebook')
# lab.ps1 forwards recipe args as a flat string, so "-Only a,b c" arrives as one element rather
# than an array. Split on commas and whitespace so every documented invocation form works.
$Only = @($Only | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Only -or $Only.Count -eq 0) { $Only = $AllKeys }
$bad = @($Only | Where-Object { $_ -notin $AllKeys })

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('workspaceId')
if ($bad.Count) { $problems = @($problems) + "Unknown -Only value(s): $($bad -join ', '). Known: $($AllKeys -join ', ')." }
if ($SalesRows -lt 1 -or $SalesRows -gt 100000) { $problems = @($problems) + "-SalesRows must be between 1 and 100000." }

$run = Start-LabRun -Name 'pbi-build-seed-artifacts' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Create one artifact of each Power BI/Fabric type in the lab workspace, populated with realistic simulated data, so backup and restore behaviour can be exercised across object types.' `
    -Plan @(
    'Probe workspace capacity (several types require Fabric capacity)'
    'Generate a deterministic star-schema dataset (Sales + Product/Customer/Store/Date)'
    'Create a push semantic model with relationships and measures, then push rows in batches'
    'Create a multi-page report bound to that model'
    'Create a dashboard and clone a tile onto it'
    'Create a semantic model from a TMDL definition'
    'Create a Dataflow Gen2, Lakehouse and Notebook'
    'Import a paginated report from generated RDL'
    'Register every created artifact in the ledger with a DeleteUri'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix the above and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId
Add-LabEvidenceNote "workspace: $ws ($($tgt.workspaceName))"
Add-LabEvidenceNote "artifact types attempted: $($Only -join ', ')"

# --- helpers -----------------------------------------------------------------

# ConvertTo-LabB64 comes from tools/powerbi/Pbi.Mashup.ps1 (loaded by every recipe) - no need to
# redefine it here.

# Fabric item creation is asynchronous: 201 returns the item, 202 returns an operation to poll.
function Wait-LabFabricItem {
    param($Response, [Parameter(Mandatory)][string]$Token, [int]$MaxTries = 40)
    if ($Response.Status -eq 201 -or ($Response.Ok -and $Response.Json.id)) { return $Response.Json }
    if ($Response.Status -ne 202) { return $null }

    $op = $Response.Headers['x-ms-operation-id'] | Select-Object -First 1
    if (-not $op) { return $null }
    Write-LabLog "long-running operation $op - polling" -Level INFO
    for ($i = 0; $i -lt $MaxTries; $i++) {
        Start-Sleep -Seconds 3
        $st = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op" -Token $Token -Label 'fabric-operation-status' -NoEvidence
        switch ($st.Json.status) {
            'Succeeded' {
                $r = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op/result" -Token $Token -Label 'fabric-operation-result'
                return $r.Json
            }
            'Failed' {
                # Surface the workload's own error - the outer call only ever reported "HTTP 202",
                # which hid the actual cause.
                $script:LastFabricOpError = "$($st.Json.error.errorCode): $($st.Json.error.message)"
                Write-LabLog "operation failed: $($st.Raw)" -Level ERROR
                return $null
            }
        }
    }
    Write-LabLog "operation $op did not finish within $($MaxTries * 3)s" -Level WARN
    return $null
}

$outcome = [ordered]@{}
function Set-Outcome {
    param([string]$Key, [string]$State, [string]$Detail)
    $script:outcome[$Key] = [pscustomobject]@{ Key = $Key; State = $State; Detail = $Detail }
    Add-LabEvidenceNote ("{0,-10} {1,-8} {2}" -f $Key, $State, $Detail)
}
function Test-Wanted { param([string]$Key) return ($Key -in $Only) }

# --- capacity probe ----------------------------------------------------------

Write-LabStep 'workspace capacity probe'
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity
$fabToken = Get-LabAccessToken -Api Fabric -Target $tgt -Identity $Identity

$wsInfo = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups?`$filter=id eq '$ws'" -Token $pbiToken -Label 'workspace-info' -AllowInDryRun
$wsRow = $wsInfo.Json.value | Select-Object -First 1
if (-not $wsInfo.Ok -or -not $wsRow) {
    Complete-LabRun -Verdict FAIL -Summary "Workspace $ws is not reachable (HTTP $($wsInfo.Status) code=$($wsInfo.Error.Code)). Nothing was created." | Out-Null
    return
}
$onCapacity = [bool]$wsRow.isOnDedicatedCapacity
Add-LabEvidenceNote "capacity: isOnDedicatedCapacity=$onCapacity capacityId=$(if ($wsRow.capacityId) { $wsRow.capacityId } else { '<none>' })"
if (-not $onCapacity) {
    Write-LabLog 'workspace is on shared capacity - dataflow/paginated/lakehouse/notebook are expected to fail; their exact error codes will be captured' -Level WARN
}

# --- 1. push semantic model + rows ------------------------------------------

$pushDatasetId = $null
if (Test-Wanted 'pushmodel') {
    Write-LabStep "generating seed data ($SalesRows sales rows)"
    $data = New-LabSeedDataset -SalesRowCount $SalesRows
    Add-LabEvidenceNote ("generated: {0} products, {1} customers, {2} stores, {3} dates, {4} sales rows" -f `
            $data.Products.Count, $data.Customers.Count, $data.Stores.Count, $data.Dates.Count, $data.Sales.Count)

    Write-LabStep 'push semantic model (star schema)'
    $name = New-LabResourceName -Suffix 'pushmodel'
    $schema = @{
        name          = $name
        defaultMode   = 'Push'
        tables        = @(
            @{
                name     = 'Sales'
                columns  = @(
                    @{ name = 'OrderId'; dataType = 'Int64' }
                    @{ name = 'OrderDate'; dataType = 'DateTime' }
                    @{ name = 'DateKey'; dataType = 'Int64' }
                    @{ name = 'ProductKey'; dataType = 'Int64' }
                    @{ name = 'CustomerKey'; dataType = 'Int64' }
                    @{ name = 'StoreKey'; dataType = 'Int64' }
                    @{ name = 'Quantity'; dataType = 'Int64' }
                    @{ name = 'UnitPrice'; dataType = 'Double' }
                    @{ name = 'Discount'; dataType = 'Double' }
                    @{ name = 'Amount'; dataType = 'Double' }
                )
                measures = @(
                    @{ name = 'Total Sales'; expression = 'SUM(Sales[Amount])'; formatString = '#,0.00' }
                    @{ name = 'Order Count'; expression = 'DISTINCTCOUNT(Sales[OrderId])'; formatString = '#,0' }
                    @{ name = 'Units Sold'; expression = 'SUM(Sales[Quantity])'; formatString = '#,0' }
                    @{ name = 'Average Order Value'; expression = 'DIVIDE([Total Sales], [Order Count])'; formatString = '#,0.00' }
                    @{ name = 'Discount Impact'; expression = 'SUMX(Sales, Sales[UnitPrice] * Sales[Quantity] * Sales[Discount])'; formatString = '#,0.00' }
                )
            }
            @{
                name    = 'Product'
                columns = @(
                    @{ name = 'ProductKey'; dataType = 'Int64' }
                    @{ name = 'Product'; dataType = 'String' }
                    @{ name = 'Category'; dataType = 'String' }
                    @{ name = 'Subcategory'; dataType = 'String' }
                    @{ name = 'Brand'; dataType = 'String' }
                    @{ name = 'ListPrice'; dataType = 'Double' }
                )
            }
            @{
                name    = 'Customer'
                columns = @(
                    @{ name = 'CustomerKey'; dataType = 'Int64' }
                    @{ name = 'CustomerName'; dataType = 'String' }
                    @{ name = 'Segment'; dataType = 'String' }
                    @{ name = 'City'; dataType = 'String' }
                    @{ name = 'Country'; dataType = 'String' }
                )
            }
            @{
                name    = 'Store'
                columns = @(
                    @{ name = 'StoreKey'; dataType = 'Int64' }
                    @{ name = 'StoreName'; dataType = 'String' }
                    @{ name = 'Region'; dataType = 'String' }
                    @{ name = 'Country'; dataType = 'String' }
                )
            }
            @{
                # NOT 'Date': the push-rows endpoint 404s on a table with that name even though
                # GET /tables lists it. 'Calendar' also avoids colliding with the DAX DATE function.
                name    = 'Calendar'
                columns = @(
                    @{ name = 'DateKey'; dataType = 'Int64' }
                    @{ name = 'Date'; dataType = 'DateTime' }
                    @{ name = 'Year'; dataType = 'Int64' }
                    @{ name = 'Quarter'; dataType = 'String' }
                    @{ name = 'Month'; dataType = 'Int64' }
                    @{ name = 'MonthName'; dataType = 'String' }
                    @{ name = 'DayOfWeek'; dataType = 'String' }
                    @{ name = 'IsWeekend'; dataType = 'Boolean' }
                )
            }
        )
        relationships = @(
            @{ name = 'Sales_Product'; fromTable = 'Sales'; fromColumn = 'ProductKey'; toTable = 'Product'; toColumn = 'ProductKey'; crossFilteringBehavior = 'OneDirection' }
            @{ name = 'Sales_Customer'; fromTable = 'Sales'; fromColumn = 'CustomerKey'; toTable = 'Customer'; toColumn = 'CustomerKey'; crossFilteringBehavior = 'OneDirection' }
            @{ name = 'Sales_Store'; fromTable = 'Sales'; fromColumn = 'StoreKey'; toTable = 'Store'; toColumn = 'StoreKey'; crossFilteringBehavior = 'OneDirection' }
            @{ name = 'Sales_Calendar'; fromTable = 'Sales'; fromColumn = 'DateKey'; toTable = 'Calendar'; toColumn = 'DateKey'; crossFilteringBehavior = 'OneDirection' }
        )
    }
    $ds = Invoke-LabRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/datasets?defaultRetentionPolicy=basicFIFO" `
        -Token $pbiToken -Body $schema -Label 'create-push-dataset'

    if ($ds.Ok -and $ds.Json.id) {
        $pushDatasetId = $ds.Json.id
        Add-LabResource -Type 'powerbi-dataset' -Id $pushDatasetId -Name $name -Target $tgt._name -Api 'powerbi' `
            -DeleteUri "https://api.powerbi.com/v1.0/myorg/groups/$ws/datasets/$pushDatasetId" | Out-Null

        # The push rows API caps at 10k rows per request; batch well under that.
        $pushed = [ordered]@{}
        $failedTables = @()
        foreach ($t in @(
                @{ Name = 'Product'; Rows = $data.Products }
                @{ Name = 'Customer'; Rows = $data.Customers }
                @{ Name = 'Store'; Rows = $data.Stores }
                @{ Name = 'Calendar'; Rows = $data.Dates }
                @{ Name = 'Sales'; Rows = $data.Sales }
            )) {
            $all = @($t.Rows); $sent = 0; $batch = 1000
            for ($i = 0; $i -lt $all.Count; $i += $batch) {
                $chunk = $all[$i..([math]::Min($i + $batch - 1, $all.Count - 1))]
                $r = Invoke-LabRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/datasets/$pushDatasetId/tables/$($t.Name)/rows" `
                    -Token $pbiToken -Body @{ rows = $chunk } -Label "push-rows-$($t.Name)-$([int]($i / $batch))" -NoEvidence
                if ($r.Ok) { $sent += $chunk.Count }
                else {
                    Write-LabLog "push $($t.Name) batch failed: HTTP $($r.Status) code=$($r.Error.Code) $($r.Error.Message)" -Level ERROR
                    $failedTables += "$($t.Name) (HTTP $($r.Status) $($r.Error.Code))"
                    break
                }
            }
            $pushed[$t.Name] = $sent
            Write-LabLog "pushed $sent/$($all.Count) rows into $($t.Name)" -Level $(if ($sent -eq $all.Count) { 'OK' } else { 'WARN' })
        }
        $rowNote = (($pushed.Keys | ForEach-Object { "$_=$($pushed[$_])" }) -join ' ')
        if ($failedTables.Count) { $rowNote += " | FAILED: $($failedTables -join ', ')" }
        Set-Outcome 'pushmodel' 'CREATED' "id=$pushDatasetId name='$name' rows: $rowNote"
    }
    elseif ($ds.DryRun) { Set-Outcome 'pushmodel' 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome 'pushmodel' 'FAILED' "HTTP $($ds.Status) code=$($ds.Error.Code) $($ds.Error.Message)" }
}

# --- 2. multi-page report from PBIR -----------------------------------------

if (Test-Wanted 'report') {
    Write-LabStep 'multi-page report from PBIR'
    if (-not $pushDatasetId) {
        Set-Outcome 'report' 'SKIPPED' 'no semantic model available to bind to'
    }
    else {
        $name = New-LabResourceName -Suffix 'report'
        $pbir = @{
            '$schema'        = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/1.0.0/schema.json'
            version          = '4.0'
            datasetReference = @{
                byConnection = @{
                    connectionString          = $null
                    pbiServiceModelId         = $null
                    pbiModelVirtualServerName = 'sobe_wowvirtualserver'
                    pbiModelDatabaseName      = $pushDatasetId
                    name                      = 'EntityDataSource'
                    connectionType            = 'pbiServiceXmlaStyleLive'
                }
            }
        } | ConvertTo-Json -Depth 10

        function New-SeedVisual {
            param([string]$Id, [string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Z)
            @{
                x = $X; y = $Y; width = $W; height = $H; z = $Z
                config = (@{
                        name         = $Id
                        layouts      = @(@{ id = 0; position = @{ x = $X; y = $Y; z = $Z; width = $W; height = $H } })
                        singleVisual = @{ visualType = $Type; drillFilterOtherVisuals = $true; objects = @{} }
                    } | ConvertTo-Json -Depth 20 -Compress)
            }
        }

        $sections = @(
            @{
                name = 'ReportSection1'; displayName = 'Executive Summary'; width = 1280; height = 720; config = '{}'
                visualContainers = @(
                    (New-SeedVisual -Id 'kpiTotalSales' -Type 'card' -X 20 -Y 20 -W 300 -H 160 -Z 0)
                    (New-SeedVisual -Id 'kpiOrders' -Type 'card' -X 340 -Y 20 -W 300 -H 160 -Z 1)
                    (New-SeedVisual -Id 'kpiAov' -Type 'card' -X 660 -Y 20 -W 300 -H 160 -Z 2)
                    (New-SeedVisual -Id 'trendByMonth' -Type 'lineChart' -X 20 -Y 200 -W 620 -H 380 -Z 3)
                    (New-SeedVisual -Id 'salesByCategory' -Type 'donutChart' -X 660 -Y 200 -W 300 -H 380 -Z 4)
                    (New-SeedVisual -Id 'sliceYear' -Type 'slicer' -X 980 -Y 20 -W 260 -H 560 -Z 5)
                )
            }
            @{
                name = 'ReportSection2'; displayName = 'Product Performance'; width = 1280; height = 720; config = '{}'
                visualContainers = @(
                    (New-SeedVisual -Id 'barBySubcategory' -Type 'barChart' -X 20 -Y 20 -W 600 -H 400 -Z 0)
                    (New-SeedVisual -Id 'tableProducts' -Type 'tableEx' -X 640 -Y 20 -W 620 -H 400 -Z 1)
                    (New-SeedVisual -Id 'scatterPriceQty' -Type 'scatterChart' -X 20 -Y 440 -W 1240 -H 250 -Z 2)
                )
            }
            @{
                name = 'ReportSection3'; displayName = 'Geography'; width = 1280; height = 720; config = '{}'
                visualContainers = @(
                    (New-SeedVisual -Id 'mapByCountry' -Type 'map' -X 20 -Y 20 -W 780 -H 480 -Z 0)
                    (New-SeedVisual -Id 'colByRegion' -Type 'columnChart' -X 820 -Y 20 -W 440 -H 230 -Z 1)
                    (New-SeedVisual -Id 'matrixSegment' -Type 'pivotTable' -X 820 -Y 270 -W 440 -H 230 -Z 2)
                )
            }
        )

        $reportJson = @{
            '$schema'          = 'http://powerbi.com/product/schema#report'
            themeCollection    = @{}
            layoutOptimization = 0
            resourcePackages   = @()
            sections           = $sections
            config             = (@{ version = '5.43'; themeCollection = @{}; activeSectionIndex = 0 } | ConvertTo-Json -Depth 10 -Compress)
        } | ConvertTo-Json -Depth 40

        $platformReport = @{
            '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
            metadata  = @{ type = 'Report'; displayName = $name }
            config    = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
        } | ConvertTo-Json -Depth 10

        $body = @{
            displayName = $name
            type        = 'Report'
            definition  = @{
                parts = @(
                    @{ path = 'definition.pbir'; payload = (ConvertTo-LabB64 $pbir); payloadType = 'InlineBase64' }
                    @{ path = 'report.json'; payload = (ConvertTo-LabB64 $reportJson); payloadType = 'InlineBase64' }
                    @{ path = '.platform'; payload = (ConvertTo-LabB64 $platformReport); payloadType = 'InlineBase64' }
                )
            }
        }
        $create = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items" -Token $fabToken -Body $body -Label 'create-report'
        $item = Wait-LabFabricItem -Response $create -Token $fabToken

        if ($item.id) {
            Add-LabResource -Type 'fabric-report' -Id $item.id -Name $name -Target $tgt._name -Api 'fabric' `
                -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items/$($item.id)" | Out-Null
            Set-Outcome 'report' 'CREATED' "id=$($item.id) name='$name' pages=$($sections.Count) boundTo=$pushDatasetId"
        }
        elseif ($create.DryRun) { Set-Outcome 'report' 'DRYRUN' 'skipped by -DryRun' }
        else { Set-Outcome 'report' 'FAILED' "HTTP $($create.Status) code=$($create.Error.Code) $($create.Error.Message)" }
    }
}

# --- 3. dashboard ------------------------------------------------------------

$dashboardId = $null
if (Test-Wanted 'dashboard') {
    Write-LabStep 'dashboard'
    $name = New-LabResourceName -Suffix 'dashboard'
    $dash = Invoke-LabRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dashboards" `
        -Token $pbiToken -Body @{ name = $name } -Label 'create-dashboard'

    if ($dash.Ok -and $dash.Json.id) {
        $dashboardId = $dash.Json.id
        # Power BI REST has no public DELETE for dashboards; the Fabric Items API can remove them.
        Add-LabResource -Type 'powerbi-dashboard' -Id $dashboardId -Name $name -Target $tgt._name -Api 'fabric' `
            -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items/$dashboardId" | Out-Null
        Set-Outcome 'dashboard' 'CREATED' "id=$dashboardId name='$name'"
    }
    elseif ($dash.DryRun) { Set-Outcome 'dashboard' 'DRYRUN' 'skipped by -DryRun' }
    elseif ($dash.Status -eq 401) {
        Set-Outcome 'dashboard' 'FAILED' 'HTTP 401 (empty body) - the token has no Dashboard.ReadWrite.All scope. Add it in Entra, delete config/.tokencache.local.json, re-consent.'
    }
    else { Set-Outcome 'dashboard' 'FAILED' "HTTP $($dash.Status) code=$($dash.Error.Code) $($dash.Error.Message)" }
}

# --- 4. dashboard tile (clone) ----------------------------------------------
# REST cannot pin a fresh visual to a dashboard - Clone Tile is the only public path, so this
# needs a tile that already exists somewhere in the workspace.

if (Test-Wanted 'tile') {
    Write-LabStep 'dashboard tile (clone)'
    if (-not $dashboardId) {
        Set-Outcome 'tile' 'SKIPPED' 'no target dashboard was created in this run'
    }
    else {
        $srcTile = $null; $srcDashId = $null
        $dashList = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dashboards" -Token $pbiToken -Label 'list-dashboards' -AllowInDryRun
        foreach ($d in @($dashList.Json.value | Where-Object { $_.id -ne $dashboardId })) {
            $tiles = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dashboards/$($d.id)/tiles" -Token $pbiToken -Label 'list-tiles' -NoEvidence -AllowInDryRun
            $t = @($tiles.Json.value) | Select-Object -First 1
            if ($t) { $srcTile = $t; $srcDashId = $d.id; break }
        }

        if (-not $srcTile) {
            Set-Outcome 'tile' 'MANUAL' 'no existing tile to clone. Pin one visual to a dashboard in the portal, then rerun -Only tile.'
        }
        else {
            $clone = Invoke-LabRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dashboards/$srcDashId/tiles/$($srcTile.id)/Clone" `
                -Token $pbiToken -Body @{ targetDashboardId = $dashboardId; targetWorkspaceId = $ws } -Label 'clone-tile'
            if ($clone.Ok) { Set-Outcome 'tile' 'CREATED' "cloned tile $($srcTile.id) onto dashboard $dashboardId" }
            elseif ($clone.DryRun) { Set-Outcome 'tile' 'DRYRUN' 'skipped by -DryRun' }
            else { Set-Outcome 'tile' 'FAILED' "HTTP $($clone.Status) code=$($clone.Error.Code) $($clone.Error.Message)" }
        }
    }
}

# --- 5. semantic model from TMDL --------------------------------------------
# TMDL is tab-indented and whitespace-significant: `t below is a real tab, not decoration.

if (Test-Wanted 'model') {
    Write-LabStep 'semantic model from TMDL'
    $name = New-LabResourceName -Suffix 'model'

    $tmdlDatabase = "database`n`tcompatibilityLevel: 1567`n"
    $tmdlModel = @"
model Model
`tculture: en-US
`tdefaultPowerBIDataSourceVersion: powerBI_V3
`tsourceQueryCulture: en-US

ref table Sales
ref table Product
"@
    $tmdlProduct = @"
table Product

`tcolumn ProductKey
`t`tdataType: int64
`t`tsourceColumn: ProductKey
`t`tsummarizeBy: none

`tcolumn Product
`t`tdataType: string
`t`tsourceColumn: Product
`t`tsummarizeBy: none

`tcolumn Category
`t`tdataType: string
`t`tsourceColumn: Category
`t`tsummarizeBy: none

`tpartition Product = m
`t`tmode: import
`t`tsource =
`t`t`t`tlet
`t`t`t`t    Source = #table(
`t`t`t`t        {"ProductKey","Product","Category"},
`t`t`t`t        {
`t`t`t`t            {1,"Contoso Road Bike 101","Bikes"},
`t`t`t`t            {2,"Fabrikam Mountain Bike 202","Bikes"},
`t`t`t`t            {3,"Northwind Brake 303","Components"},
`t`t`t`t            {4,"Adventure Works Jersey 404","Clothing"},
`t`t`t`t            {5,"Contoso Bottle 505","Accessories"}
`t`t`t`t        }
`t`t`t`t    ),
`t`t`t`t    Typed = Table.TransformColumnTypes(Source,{{"ProductKey", Int64.Type},{"Product", type text},{"Category", type text}})
`t`t`t`tin
`t`t`t`t    Typed
"@
    $tmdlSales = @"
table Sales

`tcolumn OrderId
`t`tdataType: int64
`t`tsourceColumn: OrderId
`t`tsummarizeBy: none

`tcolumn ProductKey
`t`tdataType: int64
`t`tsourceColumn: ProductKey
`t`tsummarizeBy: none

`tcolumn Region
`t`tdataType: string
`t`tsourceColumn: Region
`t`tsummarizeBy: none

`tcolumn Amount
`t`tdataType: double
`t`tsourceColumn: Amount
`t`tsummarizeBy: sum

`tmeasure 'Total Amount' = SUM(Sales[Amount])
`t`tformatString: #,0.00

`tmeasure 'Order Count' = DISTINCTCOUNT(Sales[OrderId])
`t`tformatString: #,0

`tpartition Sales = m
`t`tmode: import
`t`tsource =
`t`t`t`tlet
`t`t`t`t    Source = #table(
`t`t`t`t        {"OrderId","ProductKey","Region","Amount"},
`t`t`t`t        {
`t`t`t`t            {1001,1,"Nordics",1250.00},
`t`t`t`t            {1002,2,"DACH",880.50},
`t`t`t`t            {1003,1,"Benelux",2310.75},
`t`t`t`t            {1004,3,"Iberia",495.20},
`t`t`t`t            {1005,4,"Nordics",1675.00},
`t`t`t`t            {1006,5,"DACH",320.10},
`t`t`t`t            {1007,2,"UK & Ireland",1490.00}
`t`t`t`t        }
`t`t`t`t    ),
`t`t`t`t    Typed = Table.TransformColumnTypes(Source,{{"OrderId", Int64.Type},{"ProductKey", Int64.Type},{"Region", type text},{"Amount", type number}})
`t`t`t`tin
`t`t`t`t    Typed
"@
    $tmdlRelationships = @"
relationship Sales_Product
`tfromColumn: Sales.ProductKey
`ttoColumn: Product.ProductKey
"@
    $platformModel = @{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata  = @{ type = 'SemanticModel'; displayName = $name }
        config    = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
    } | ConvertTo-Json -Depth 10

    # definition.pbism is mandatory: without it the create is accepted (202) and then fails
    # asynchronously with Workload_FailedToParseFile "Required artifact is missing".
    $pbism = @{ version = '4.2'; settings = @{} } | ConvertTo-Json -Depth 5

    $body = @{
        displayName = $name
        type        = 'SemanticModel'
        definition  = @{
            parts = @(
                @{ path = 'definition.pbism'; payload = (ConvertTo-LabB64 $pbism); payloadType = 'InlineBase64' }
                @{ path = 'definition/database.tmdl'; payload = (ConvertTo-LabB64 $tmdlDatabase); payloadType = 'InlineBase64' }
                @{ path = 'definition/model.tmdl'; payload = (ConvertTo-LabB64 $tmdlModel); payloadType = 'InlineBase64' }
                @{ path = 'definition/tables/Sales.tmdl'; payload = (ConvertTo-LabB64 $tmdlSales); payloadType = 'InlineBase64' }
                @{ path = 'definition/tables/Product.tmdl'; payload = (ConvertTo-LabB64 $tmdlProduct); payloadType = 'InlineBase64' }
                @{ path = 'definition/relationships.tmdl'; payload = (ConvertTo-LabB64 $tmdlRelationships); payloadType = 'InlineBase64' }
                @{ path = '.platform'; payload = (ConvertTo-LabB64 $platformModel); payloadType = 'InlineBase64' }
            )
        }
    }
    $create = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items" -Token $fabToken -Body $body -Label 'create-semantic-model'
    $item = Wait-LabFabricItem -Response $create -Token $fabToken

    if ($item.id) {
        Add-LabResource -Type 'fabric-semanticmodel' -Id $item.id -Name $name -Target $tgt._name -Api 'fabric' `
            -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/items/$($item.id)" | Out-Null
        Set-Outcome 'model' 'CREATED' "id=$($item.id) name='$name'"
    }
    elseif ($create.DryRun) { Set-Outcome 'model' 'DRYRUN' 'skipped by -DryRun' }
    elseif ($create.Error.Code -eq 'InsufficientScopes') {
        Set-Outcome 'model' 'FAILED' 'HTTP 403 InsufficientScopes - the token has no SemanticModel.ReadWrite.All scope. Add it in Entra, delete config/.tokencache.local.json, re-consent.'
    }
    elseif ($script:LastFabricOpError) {
        Set-Outcome 'model' 'FAILED' "accepted (202) then failed asynchronously - $($script:LastFabricOpError)"
    }
    else { Set-Outcome 'model' 'FAILED' "HTTP $($create.Status) code=$($create.Error.Code) $($create.Error.Message)" }
}

# --- 6. Fabric items: dataflow / lakehouse / notebook ------------------------

foreach ($spec in @(
        @{ Key = 'dataflow'; Path = 'dataflows'; Type = 'fabric-dataflow'; Suffix = 'dfgen2'; Label = 'Dataflow Gen2' }
        # Lakehouse names become SQL identifiers, so hyphens are rejected with a bare InvalidInput.
        @{ Key = 'lakehouse'; Path = 'lakehouses'; Type = 'fabric-lakehouse'; Suffix = 'lakehouse'; Label = 'Lakehouse'; UnderscoreName = $true }
        @{ Key = 'notebook'; Path = 'notebooks'; Type = 'fabric-notebook'; Suffix = 'notebook'; Label = 'Notebook' }
    )) {
    if (-not (Test-Wanted $spec.Key)) { continue }
    Write-LabStep $spec.Label
    $name = New-LabResourceName -Suffix $spec.Suffix
    if ($spec.UnderscoreName) { $name = $name -replace '-', '_' }
    $create = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/$($spec.Path)" -Token $fabToken `
        -Body @{ displayName = $name; description = 'Dextors Lab seed artifact' } -Label "create-$($spec.Key)"
    $item = Wait-LabFabricItem -Response $create -Token $fabToken

    if ($item.id) {
        Add-LabResource -Type $spec.Type -Id $item.id -Name $name -Target $tgt._name -Api 'fabric' `
            -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/$($spec.Path)/$($item.id)" | Out-Null
        Set-Outcome $spec.Key 'CREATED' "id=$($item.id) name='$name'"
    }
    elseif ($create.DryRun) { Set-Outcome $spec.Key 'DRYRUN' 'skipped by -DryRun' }
    elseif ($create.Error.Code -eq 'FeatureNotAvailable') {
        Set-Outcome $spec.Key 'FAILED' "HTTP $($create.Status) FeatureNotAvailable - requires Fabric capacity on this workspace."
    }
    else { Set-Outcome $spec.Key 'FAILED' "HTTP $($create.Status) code=$($create.Error.Code) $($create.Error.Message)" }
}

# --- 7. paginated report from RDL -------------------------------------------

if (Test-Wanted 'paginated') {
    Write-LabStep 'paginated report (RDL import)'
    $name = New-LabResourceName -Suffix 'paginated'
    $rdl = @"
<?xml version="1.0" encoding="utf-8"?>
<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition" xmlns:rd="http://schemas.microsoft.com/SQLServer/reporting/reportdesigner">
  <AutoRefresh>0</AutoRefresh>
  <ReportSections>
    <ReportSection>
      <Body>
        <ReportItems>
          <Textbox Name="Title">
            <CanGrow>true</CanGrow>
            <KeepTogether>true</KeepTogether>
            <Paragraphs>
              <Paragraph>
                <TextRuns>
                  <TextRun>
                    <Value>Dextors Lab seed paginated report</Value>
                    <Style><FontSize>16pt</FontSize><FontWeight>Bold</FontWeight></Style>
                  </TextRun>
                </TextRuns>
                <Style />
              </Paragraph>
            </Paragraphs>
            <rd:DefaultName>Title</rd:DefaultName>
            <Top>0.25in</Top>
            <Left>0.25in</Left>
            <Height>0.4in</Height>
            <Width>5in</Width>
            <Style><Border><Style>None</Style></Border></Style>
          </Textbox>
        </ReportItems>
        <Height>1in</Height>
        <Style />
      </Body>
      <Width>6.5in</Width>
      <Page>
        <PageHeight>11in</PageHeight>
        <PageWidth>8.5in</PageWidth>
        <LeftMargin>1in</LeftMargin>
        <RightMargin>1in</RightMargin>
        <TopMargin>1in</TopMargin>
        <BottomMargin>1in</BottomMargin>
        <Style />
      </Page>
    </ReportSection>
  </ReportSections>
</Report>
"@
    Save-LabEvidence -Kind request -Name 'seed-paginated-rdl' -Content $rdl -Extension 'rdl' | Out-Null

    $boundary = "----LabBoundary$([guid]::NewGuid().ToString('N'))"
    $nl = "`r`n"
    $head = "--$boundary$nl" +
    "Content-Disposition: form-data; name=`"file`"; filename=`"$name.rdl`"$nl" +
    "Content-Type: application/octet-stream$nl$nl"
    $tail = "$nl--$boundary--$nl"
    $bytes = [byte[]]@(
        [Text.Encoding]::UTF8.GetBytes($head) +
        [Text.Encoding]::UTF8.GetBytes($rdl) +
        [Text.Encoding]::UTF8.GetBytes($tail)
    )

    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$ws/imports?datasetDisplayName=$name.rdl&nameConflict=Abort"
    $imp = Invoke-LabRequest -Method POST -Uri $uri -Token $pbiToken -Body $bytes `
        -ContentType "multipart/form-data; boundary=$boundary" -Label 'import-paginated-report'

    $reportId = $null
    if ($imp.Ok) {
        # Import is asynchronous; poll until the import reports Succeeded and yields a report id.
        $importId = $imp.Json.id
        for ($i = 0; $i -lt 20 -and -not $reportId; $i++) {
            Start-Sleep -Seconds 3
            $st = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/imports/$importId" -Token $pbiToken -Label 'import-status' -NoEvidence
            if ($st.Json.importState -eq 'Succeeded') { $reportId = @($st.Json.reports)[0].id }
            elseif ($st.Json.importState -eq 'Failed') { Write-LabLog "import failed: $($st.Raw)" -Level ERROR; break }
        }
    }

    if ($reportId) {
        Add-LabResource -Type 'powerbi-paginated-report' -Id $reportId -Name $name -Target $tgt._name -Api 'powerbi' `
            -DeleteUri "https://api.powerbi.com/v1.0/myorg/groups/$ws/reports/$reportId" | Out-Null
        Set-Outcome 'paginated' 'CREATED' "id=$reportId name='$name'"
    }
    elseif ($imp.DryRun) { Set-Outcome 'paginated' 'DRYRUN' 'skipped by -DryRun' }
    elseif ($imp.Ok) { Set-Outcome 'paginated' 'FAILED' 'import accepted but never reached Succeeded with a report id' }
    else { Set-Outcome 'paginated' 'FAILED' "HTTP $($imp.Status) code=$($imp.Error.Code) $($imp.Error.Message)" }
}

# --- summary -----------------------------------------------------------------

Write-LabStep 'summary'
Write-Host ''
Write-Host ('  {0,-11} {1,-9} {2}' -f 'TYPE', 'STATE', 'DETAIL')
Write-Host ('  ' + ('-' * 110))
foreach ($o in $outcome.Values) { Write-Host ('  {0,-11} {1,-9} {2}' -f $o.Key, $o.State, $o.Detail) }

$created = @($outcome.Values | Where-Object { $_.State -eq 'CREATED' })
$failed = @($outcome.Values | Where-Object { $_.State -eq 'FAILED' })
$attempted = @($outcome.Values | Where-Object { $_.State -in 'CREATED', 'FAILED' })

$ev = @("capacity: isOnDedicatedCapacity=$onCapacity") + @($outcome.Values | ForEach-Object { "$($_.Key): $($_.State) - $($_.Detail)" })

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary 'Dry run: no artifacts were created.' -Evidence $ev | Out-Null
}
elseif ($created.Count -eq 0) {
    Complete-LabRun -Verdict FAIL -Summary "No artifacts could be created ($($failed.Count) type(s) failed). See per-type error codes." -Evidence $ev | Out-Null
}
elseif ($failed.Count -eq 0 -and $attempted.Count -gt 0) {
    Complete-LabRun -Verdict PASS -Summary "Created $($created.Count) artifact type(s); none failed." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Created $($created.Count) artifact type(s); $($failed.Count) failed. Per-type Microsoft error codes are recorded in the evidence and raw responses." -Evidence $ev | Out-Null
}

Write-Host ''
Write-Host "Remove everything this run created:  .\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force" -ForegroundColor Cyan
