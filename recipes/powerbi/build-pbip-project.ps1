<#
Generates a complete Power BI Project (PBIP) on disk - TMDL semantic model plus PBIR report - so
it can be opened in Power BI Desktop and published.

Why this exists: artifacts created through the REST/Fabric APIs (push datasets, PBIR-only reports)
cannot be downloaded as .pbix. Only content that was PUBLISHED FROM DESKTOP can. This recipe
produces the Desktop-side source so the lab can have genuinely PBIX-backed artifacts to back up
and restore, without anyone hand-building a model through the UI.

The data is identical to what powerbi/build-seed-artifacts pushes over REST (both call
New-LabSeedDataset), so a Desktop-published model and an API-created push dataset can be compared
field-for-field after a restore.

Beyond the REST version, this adds modelling that only exists in a real Desktop model:
hierarchies, a calculation group, RLS roles, a marked date table, display folders and
formatted measures.

Verdict meaning (explicit):
  PASS         = the project was written and every expected file is present.
  FAIL         = the project could not be written.
  INCONCLUSIVE = written, but a file is missing or empty.

  .\lab.ps1 BUILD powerbi/build-pbip-project
  .\lab.ps1 BUILD powerbi/build-pbip-project -SalesRows 8000 -ProjectName ContosoSales

This recipe makes no API calls and needs no credentials. Validate the output before opening it in
Desktop by pointing the Power BI Modeling MCP at <project>.SemanticModel with ConnectFolder.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$ProjectName = 'DextorsLabSales',
    [string]$OutputPath,
    [int]$SalesRows = 3000
)

$Recipe = @{
    Name        = 'powerbi/build-pbip-project'
    Product     = 'powerbi'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Generate a PBIP (TMDL model + PBIR report) on disk for Power BI Desktop to open and publish, so artifacts are PBIX-backed.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

if (-not $OutputPath) { $OutputPath = Join-Path (Get-LabHome) 'artifacts\pbip' }
$projRoot = Join-Path $OutputPath $ProjectName
$modelDir = Join-Path $projRoot "$ProjectName.SemanticModel"
$reportDir = Join-Path $projRoot "$ProjectName.Report"
$defDir = Join-Path $modelDir 'definition'
$tablesDir = Join-Path $defDir 'tables'
$rolesDir = Join-Path $defDir 'roles'

$problems = @()
if ($ProjectName -notmatch '^[A-Za-z][A-Za-z0-9_-]{2,60}$') {
    $problems += "-ProjectName '$ProjectName' must start with a letter and contain only letters, digits, hyphen or underscore."
}
if ($SalesRows -lt 1 -or $SalesRows -gt 100000) { $problems += '-SalesRows must be between 1 and 100000.' }

$run = Start-LabRun -Name 'pbi-build-pbip-project' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Generate a Power BI Project (TMDL semantic model + PBIR report) on disk so Power BI Desktop can open and publish it, producing PBIX-backed artifacts that the REST APIs cannot create.' `
    -Plan @(
    'Generate the deterministic star-schema dataset'
    'Emit each table as a TMDL file with an inline M #table partition'
    'Add hierarchies, display folders and formatted DAX measures'
    'Add a calculation group, RLS roles and a marked date table'
    'Emit relationships.tmdl and model.tmdl'
    'Emit the PBIR report with three pages of visuals'
    'Emit the .pbip project file and verify every expected file exists'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix the arguments and rerun.'; return }

# --- TMDL emission -----------------------------------------------------------
# ConvertTo-LabB64, ConvertTo-LabMLiteral and New-LabMTableExpression come from
# tools/powerbi/Pbi.Mashup.ps1 - shared with powerbi/build-gen2-dataflow.

$TAB = ([char]9).ToString()

# TMDL indents the M script two levels below `source =`.
function Format-TmdlMSource {
    param([string]$M)
    $pad = $TAB * 4
    (($M -split "`r?`n") | ForEach-Object { if ($_.Length) { $pad + $_ } else { '' } }) -join "`n"
}

function Write-LabTextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # TMDL and PBIR readers expect UTF-8 without a BOM.
    [IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

# --- generate data -----------------------------------------------------------

Write-LabStep "generating seed data ($SalesRows sales rows)"
$data = New-LabSeedDataset -SalesRowCount $SalesRows
Add-LabEvidenceNote ("generated: {0} products, {1} customers, {2} stores, {3} dates, {4} sales rows" -f `
        $data.Products.Count, $data.Customers.Count, $data.Stores.Count, $data.Dates.Count, $data.Sales.Count)

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary "Dry run: would write the project to $projRoot." | Out-Null
    return
}

if (Test-Path $projRoot) {
    Write-LabLog "output folder exists, replacing: $projRoot" -Level WARN
    Remove-Item $projRoot -Recurse -Force
}

# --- table TMDL --------------------------------------------------------------

Write-LabStep 'writing table definitions'

$tableSpecs = @(
    @{
        Name        = 'Product'
        Rows        = $data.Products
        Order       = @('ProductKey', 'Product', 'Category', 'Subcategory', 'Brand', 'ListPrice')
        Types       = @{ ProductKey = 'Int64.Type'; Product = 'Text.Type'; Category = 'Text.Type'; Subcategory = 'Text.Type'; Brand = 'Text.Type'; ListPrice = 'Number.Type' }
        Columns     = @(
            @{ Name = 'ProductKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'Product'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Category'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Subcategory'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Brand'; DataType = 'string'; SummarizeBy = 'none' }
            # A per-unit price must not default to Sum; summing prices is meaningless and it also
            # makes the column unusable in visuals that require an aggregation.
            @{ Name = 'ListPrice'; DataType = 'double'; SummarizeBy = 'average'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00' }
        )
        Hierarchies = @(
            @{ Name = 'Product Hierarchy'; Levels = @('Category', 'Subcategory', 'Product') }
        )
    }
    @{
        Name        = 'Customer'
        Rows        = $data.Customers
        Order       = @('CustomerKey', 'CustomerName', 'Segment', 'City', 'Country')
        Types       = @{ CustomerKey = 'Int64.Type'; CustomerName = 'Text.Type'; Segment = 'Text.Type'; City = 'Text.Type'; Country = 'Text.Type' }
        Columns     = @(
            @{ Name = 'CustomerKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'CustomerName'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Segment'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'City'; DataType = 'string'; SummarizeBy = 'none'; DataCategory = 'City' }
            @{ Name = 'Country'; DataType = 'string'; SummarizeBy = 'none'; DataCategory = 'Country' }
        )
        Hierarchies = @(
            @{ Name = 'Geography'; Levels = @('Country', 'City', 'CustomerName') }
        )
    }
    @{
        Name        = 'Store'
        Rows        = $data.Stores
        Order       = @('StoreKey', 'StoreName', 'Region', 'Country')
        Types       = @{ StoreKey = 'Int64.Type'; StoreName = 'Text.Type'; Region = 'Text.Type'; Country = 'Text.Type' }
        Columns     = @(
            @{ Name = 'StoreKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'StoreName'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Region'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Country'; DataType = 'string'; SummarizeBy = 'none'; DataCategory = 'Country' }
        )
        Hierarchies = @(
            @{ Name = 'Store Locations'; Levels = @('Region', 'Country', 'StoreName') }
        )
    }
    @{
        Name         = 'Calendar'
        Rows         = $data.Dates
        Order        = @('DateKey', 'Date', 'Year', 'Quarter', 'Month', 'MonthName', 'DayOfWeek', 'IsWeekend')
        Types        = @{ DateKey = 'Int64.Type'; Date = 'Date.Type'; Year = 'Int64.Type'; Quarter = 'Text.Type'; Month = 'Int64.Type'; MonthName = 'Text.Type'; DayOfWeek = 'Text.Type'; IsWeekend = 'Logical.Type' }
        DataCategory = 'Time'
        Columns      = @(
            @{ Name = 'DateKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'Date'; DataType = 'dateTime'; SummarizeBy = 'none'; FormatString = 'Long Date' }
            @{ Name = 'Year'; DataType = 'int64'; SummarizeBy = 'none' }
            @{ Name = 'Quarter'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'Month'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'MonthName'; DataType = 'string'; SummarizeBy = 'none'; SortByColumn = 'Month' }
            @{ Name = 'DayOfWeek'; DataType = 'string'; SummarizeBy = 'none' }
            @{ Name = 'IsWeekend'; DataType = 'boolean'; SummarizeBy = 'none' }
        )
        Hierarchies  = @(
            @{ Name = 'Calendar Hierarchy'; Levels = @('Year', 'Quarter', 'MonthName') }
        )
    }
    @{
        Name     = 'Sales'
        Rows     = $data.Sales
        Order    = @('OrderId', 'OrderDate', 'DateKey', 'ProductKey', 'CustomerKey', 'StoreKey', 'Quantity', 'UnitPrice', 'Discount', 'Amount')
        Types    = @{ OrderId = 'Int64.Type'; OrderDate = 'Date.Type'; DateKey = 'Int64.Type'; ProductKey = 'Int64.Type'; CustomerKey = 'Int64.Type'; StoreKey = 'Int64.Type'; Quantity = 'Int64.Type'; UnitPrice = 'Number.Type'; Discount = 'Number.Type'; Amount = 'Number.Type' }
        Columns  = @(
            @{ Name = 'OrderId'; DataType = 'int64'; SummarizeBy = 'none' }
            @{ Name = 'OrderDate'; DataType = 'dateTime'; SummarizeBy = 'none'; FormatString = 'Long Date' }
            @{ Name = 'DateKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'ProductKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'CustomerKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'StoreKey'; DataType = 'int64'; SummarizeBy = 'none'; Hidden = $true }
            @{ Name = 'Quantity'; DataType = 'int64'; SummarizeBy = 'sum' }
            @{ Name = 'UnitPrice'; DataType = 'double'; SummarizeBy = 'average'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00' }
            @{ Name = 'Discount'; DataType = 'double'; SummarizeBy = 'average'; FormatString = '0.00%;-0.00%;0.00%' }
            @{ Name = 'Amount'; DataType = 'double'; SummarizeBy = 'sum'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00' }
        )
        Measures = @(
            @{ Name = 'Total Sales'; Expression = 'SUM(Sales[Amount])'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'KPIs' }
            @{ Name = 'Order Count'; Expression = 'DISTINCTCOUNT(Sales[OrderId])'; FormatString = '#,0'; DisplayFolder = 'KPIs' }
            @{ Name = 'Units Sold'; Expression = 'SUM(Sales[Quantity])'; FormatString = '#,0'; DisplayFolder = 'KPIs' }
            @{ Name = 'Average Order Value'; Expression = 'DIVIDE([Total Sales], [Order Count])'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'KPIs' }
            @{ Name = 'Discount Impact'; Expression = 'SUMX(Sales, Sales[UnitPrice] * Sales[Quantity] * Sales[Discount])'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'Margin' }
            # Explicit measure rather than an implicit column aggregation: report visuals bind to
            # measures only, which keeps the generated PBIR free of Aggregation projections.
            @{ Name = 'Avg Unit Price'; Expression = 'AVERAGE(Sales[UnitPrice])'; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'KPIs' }
            @{ Name = 'Sales YTD'; Expression = "TOTALYTD([Total Sales], 'Calendar'[Date])"; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'Time Intelligence' }
            @{ Name = 'Sales PY'; Expression = "CALCULATE([Total Sales], SAMEPERIODLASTYEAR('Calendar'[Date]))"; FormatString = '\$#,0.00;(\$#,0.00);\$#,0.00'; DisplayFolder = 'Time Intelligence' }
            @{ Name = 'Sales YoY %'; Expression = 'DIVIDE([Total Sales] - [Sales PY], [Sales PY])'; FormatString = '0.00%;-0.00%;0.00%'; DisplayFolder = 'Time Intelligence' }
        )
    }
)

foreach ($t in $tableSpecs) {
    $m = New-LabMTableExpression -Rows @($t.Rows) -ColumnTypes $t.Types -ColumnOrder $t.Order

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("table $($t.Name)")
    if ($t.DataCategory) { [void]$sb.AppendLine("${TAB}dataCategory: $($t.DataCategory)") }
    [void]$sb.AppendLine()

    foreach ($c in $t.Columns) {
        [void]$sb.AppendLine("${TAB}column $($c.Name)")
        [void]$sb.AppendLine("${TAB}${TAB}dataType: $($c.DataType)")
        if ($c.FormatString) { [void]$sb.AppendLine("${TAB}${TAB}formatString: $($c.FormatString)") }
        [void]$sb.AppendLine("${TAB}${TAB}summarizeBy: $($c.SummarizeBy)")
        [void]$sb.AppendLine("${TAB}${TAB}sourceColumn: $($c.Name)")
        if ($c.SortByColumn) { [void]$sb.AppendLine("${TAB}${TAB}sortByColumn: $($c.SortByColumn)") }
        if ($c.DataCategory) { [void]$sb.AppendLine("${TAB}${TAB}dataCategory: $($c.DataCategory)") }
        if ($c.Hidden) { [void]$sb.AppendLine("${TAB}${TAB}isHidden") }
        [void]$sb.AppendLine()
    }

    foreach ($mm in @($t.Measures)) {
        if (-not $mm) { continue }
        [void]$sb.AppendLine("${TAB}measure '$($mm.Name)' = $($mm.Expression)")
        if ($mm.FormatString) { [void]$sb.AppendLine("${TAB}${TAB}formatString: $($mm.FormatString)") }
        if ($mm.DisplayFolder) { [void]$sb.AppendLine("${TAB}${TAB}displayFolder: $($mm.DisplayFolder)") }
        [void]$sb.AppendLine()
    }

    foreach ($h in @($t.Hierarchies)) {
        if (-not $h) { continue }
        [void]$sb.AppendLine("${TAB}hierarchy '$($h.Name)'")
        foreach ($lvl in $h.Levels) {
            [void]$sb.AppendLine("${TAB}${TAB}level $lvl")
            [void]$sb.AppendLine("${TAB}${TAB}${TAB}column: $lvl")
            [void]$sb.AppendLine()
        }
    }

    [void]$sb.AppendLine("${TAB}partition $($t.Name) = m")
    [void]$sb.AppendLine("${TAB}${TAB}mode: import")
    [void]$sb.AppendLine("${TAB}${TAB}source =")
    [void]$sb.AppendLine((Format-TmdlMSource $m))

    Write-LabTextFile -Path (Join-Path $tablesDir "$($t.Name).tmdl") -Content $sb.ToString()
    Write-LabLog "table $($t.Name): $(@($t.Rows).Count) rows, $(@($t.Columns).Count) columns, $(@($t.Measures).Count) measures" -Level OK
}

# --- calculation group -------------------------------------------------------

Write-LabStep 'writing calculation group'
$calcGroup = @"
table 'Time Intelligence'

${TAB}calculationGroup

${TAB}${TAB}calculationItem Current = SELECTEDMEASURE()

${TAB}${TAB}calculationItem YTD = TOTALYTD(SELECTEDMEASURE(), 'Calendar'[Date])

${TAB}${TAB}calculationItem 'Prior Year' = CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR('Calendar'[Date]))

${TAB}${TAB}calculationItem 'YoY %' =
${TAB}${TAB}${TAB}${TAB}VAR _curr = SELECTEDMEASURE()
${TAB}${TAB}${TAB}${TAB}VAR _prev = CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR('Calendar'[Date]))
${TAB}${TAB}${TAB}${TAB}RETURN DIVIDE(_curr - _prev, _prev)

${TAB}column 'Time Calculation'
${TAB}${TAB}dataType: string
${TAB}${TAB}summarizeBy: none
${TAB}${TAB}sourceColumn: Name
${TAB}${TAB}sortByColumn: Ordinal

${TAB}column Ordinal
${TAB}${TAB}dataType: int64
${TAB}${TAB}summarizeBy: none
${TAB}${TAB}sourceColumn: Ordinal
${TAB}${TAB}isHidden

${TAB}partition 'Time Intelligence' = calculationGroup
${TAB}${TAB}mode: import
"@
Write-LabTextFile -Path (Join-Path $tablesDir 'Time Intelligence.tmdl') -Content $calcGroup

# --- relationships -----------------------------------------------------------

Write-LabStep 'writing relationships'
$rels = @(
    @{ Name = 'Sales_Product'; From = 'Sales.ProductKey'; To = 'Product.ProductKey' }
    @{ Name = 'Sales_Customer'; From = 'Sales.CustomerKey'; To = 'Customer.CustomerKey' }
    @{ Name = 'Sales_Store'; From = 'Sales.StoreKey'; To = 'Store.StoreKey' }
    @{ Name = 'Sales_Calendar'; From = 'Sales.DateKey'; To = 'Calendar.DateKey' }
)
$relSb = [System.Text.StringBuilder]::new()
foreach ($r in $rels) {
    [void]$relSb.AppendLine("relationship $($r.Name)")
    [void]$relSb.AppendLine("${TAB}fromColumn: $($r.From)")
    [void]$relSb.AppendLine("${TAB}toColumn: $($r.To)")
    [void]$relSb.AppendLine()
}
Write-LabTextFile -Path (Join-Path $defDir 'relationships.tmdl') -Content $relSb.ToString()

# --- RLS roles ---------------------------------------------------------------

Write-LabStep 'writing RLS roles'
$roles = @(
    @{ Name = 'Nordics Only'; Table = 'Store'; Filter = "'Store'[Region] = ""Nordics""" }
    @{ Name = 'DACH Only'; Table = 'Store'; Filter = "'Store'[Region] = ""DACH""" }
)
foreach ($r in $roles) {
    $roleTmdl = @"
role '$($r.Name)'
${TAB}modelPermission: read

${TAB}tablePermission $($r.Table) = $($r.Filter)
"@
    Write-LabTextFile -Path (Join-Path $rolesDir "$($r.Name).tmdl") -Content $roleTmdl
}

# --- model.tmdl / database.tmdl ---------------------------------------------

Write-LabStep 'writing model definition'
# __PBI_TimeIntelligenceEnabled = 0 turns off auto date/time. Left on, Desktop silently adds a
# hidden LocalDateTable per date column, which bloats the model and pollutes a restore comparison.
# TMDL rejects '//' comment lines inside the model block, so this note stays here.
$allTables = @($tableSpecs | ForEach-Object { $_.Name }) + @('Time Intelligence')
$refLines = $allTables | ForEach-Object { if ($_ -match '\s') { "ref table '$_'" } else { "ref table $_" } }
$roleLines = $roles | ForEach-Object { "ref role '$($_.Name)'" }

$modelTmdl = @"
model Model
${TAB}culture: en-US
${TAB}defaultPowerBIDataSourceVersion: powerBI_V3
${TAB}discourageImplicitMeasures
${TAB}sourceQueryCulture: en-US

${TAB}annotation PBI_ProTooling = ["DextorsLab"]

${TAB}annotation __PBI_TimeIntelligenceEnabled = 0

$($refLines -join "`n")

$($roleLines -join "`n")
"@
Write-LabTextFile -Path (Join-Path $defDir 'model.tmdl') -Content $modelTmdl
Write-LabTextFile -Path (Join-Path $defDir 'database.tmdl') -Content "database`n${TAB}compatibilityLevel: 1567`n"

# --- semantic model wrapper files -------------------------------------------

Write-LabTextFile -Path (Join-Path $modelDir 'definition.pbism') -Content (@{
        version  = '4.2'
        settings = @{}
    } | ConvertTo-Json -Depth 5)

Write-LabTextFile -Path (Join-Path $modelDir '.platform') -Content (@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata  = @{ type = 'SemanticModel'; displayName = $ProjectName }
        config    = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
    } | ConvertTo-Json -Depth 5)

# --- PBIR report -------------------------------------------------------------

Write-LabStep 'writing PBIR report'

# Builds a fully bound visual container.
#
# A visualType alone is NOT enough: without `projections` and a matching `prototypeQuery`,
# Power BI Desktop assigns dropped fields to arbitrary data roles. That is what put Product on a
# scatter chart's X axis and left a map with no Location. Roles must be declared explicitly.
#
# Fields are given as 'Table|Field|measure' or 'Table|Field|column'. Visuals bind to measures for
# anything aggregated, which avoids Aggregation projections entirely.
function New-SeedVisual {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Type,
        [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Z,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Roles
    )
    $aliases = [ordered]@{}     # entity -> query alias
    $selects = [System.Collections.Generic.List[object]]::new()
    $projections = [ordered]@{}
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $firstItem = $true

    foreach ($role in $Roles.Keys) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($spec in @($Roles[$role])) {
            $parts = $spec -split '\|'
            $tbl = $parts[0]; $fld = $parts[1]; $kind = $parts[2]

            if (-not $aliases.Contains($tbl)) {
                $base = $tbl.Substring(0, 1).ToLower()
                $alias = $base; $n = 1
                while (@($aliases.Values) -contains $alias) { $n++; $alias = "$base$n" }
                $aliases[$tbl] = $alias
            }
            $queryRef = "$tbl.$fld"

            if ($seen.Add($queryRef)) {
                $expr = @{ Expression = @{ SourceRef = @{ Source = $aliases[$tbl] } }; Property = $fld }
                $sel = [ordered]@{}
                if ($kind -eq 'measure') { $sel['Measure'] = $expr } else { $sel['Column'] = $expr }
                $sel['Name'] = $queryRef
                $sel['NativeReferenceName'] = $fld
                $selects.Add([pscustomobject]$sel)
            }

            # Desktop marks the first categorical projection active; mirror that.
            if ($firstItem) { $items.Add([ordered]@{ queryRef = $queryRef; active = $true }); $firstItem = $false }
            else { $items.Add([ordered]@{ queryRef = $queryRef }) }
        }
        $projections[$role] = @($items)
    }

    $from = @($aliases.Keys | ForEach-Object { [ordered]@{ Name = $aliases[$_]; Entity = $_; Type = 0 } })

    $config = [ordered]@{
        name         = $Id
        layouts      = @(@{ id = 0; position = [ordered]@{ x = $X; y = $Y; z = $Z; width = $W; height = $H } })
        singleVisual = [ordered]@{
            visualType              = $Type
            projections             = $projections
            prototypeQuery          = [ordered]@{ Version = 2; From = $from; Select = @($selects) }
            drillFilterOtherVisuals = $true
            objects                 = @{}
        }
    }
    @{
        x = $X; y = $Y; width = $W; height = $H; z = $Z
        config = ($config | ConvertTo-Json -Depth 25 -Compress)
    }
}

$sections = @(
    @{
        name = 'ReportSection1'; displayName = 'Executive Summary'; width = 1280; height = 720; config = '{}'
        visualContainers = @(
            (New-SeedVisual -Id 'kpiTotalSales' -Type 'card' -X 20 -Y 20 -W 300 -H 160 -Z 0 -Roles ([ordered]@{
                        Values = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'kpiOrders' -Type 'card' -X 340 -Y 20 -W 300 -H 160 -Z 1 -Roles ([ordered]@{
                        Values = @('Sales|Order Count|measure') }))
            (New-SeedVisual -Id 'kpiAov' -Type 'card' -X 660 -Y 20 -W 300 -H 160 -Z 2 -Roles ([ordered]@{
                        Values = @('Sales|Average Order Value|measure') }))
            (New-SeedVisual -Id 'trendByMonth' -Type 'lineChart' -X 20 -Y 200 -W 620 -H 380 -Z 3 -Roles ([ordered]@{
                        Category = @('Calendar|Date|column'); Y = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'salesByCategory' -Type 'donutChart' -X 660 -Y 200 -W 300 -H 380 -Z 4 -Roles ([ordered]@{
                        Category = @('Product|Category|column'); Y = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'sliceYear' -Type 'slicer' -X 980 -Y 20 -W 260 -H 560 -Z 5 -Roles ([ordered]@{
                        Values = @('Calendar|Year|column') }))
        )
    }
    @{
        name = 'ReportSection2'; displayName = 'Product Performance'; width = 1280; height = 720; config = '{}'
        visualContainers = @(
            (New-SeedVisual -Id 'barBySubcategory' -Type 'barChart' -X 20 -Y 20 -W 600 -H 400 -Z 0 -Roles ([ordered]@{
                        Category = @('Product|Subcategory|column'); Y = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'tableProducts' -Type 'tableEx' -X 640 -Y 20 -W 620 -H 400 -Z 1 -Roles ([ordered]@{
                        Values = @('Product|Product|column', 'Product|Category|column', 'Sales|Total Sales|measure', 'Sales|Units Sold|measure') }))
            # Category is the grouping role; X and Y must be aggregated, hence measures.
            (New-SeedVisual -Id 'scatterPriceQty' -Type 'scatterChart' -X 20 -Y 440 -W 1240 -H 250 -Z 2 -Roles ([ordered]@{
                        Category = @('Product|Product|column'); X = @('Sales|Avg Unit Price|measure'); Y = @('Sales|Units Sold|measure') }))
        )
    }
    @{
        name = 'ReportSection3'; displayName = 'Geography'; width = 1280; height = 720; config = '{}'
        visualContainers = @(
            # For a map, Category IS the Location role - omitting it leaves the visual unplottable.
            (New-SeedVisual -Id 'mapByCountry' -Type 'map' -X 20 -Y 20 -W 780 -H 480 -Z 0 -Roles ([ordered]@{
                        Category = @('Store|Country|column'); Size = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'colByRegion' -Type 'columnChart' -X 820 -Y 20 -W 440 -H 230 -Z 1 -Roles ([ordered]@{
                        Category = @('Store|Region|column'); Y = @('Sales|Total Sales|measure') }))
            (New-SeedVisual -Id 'matrixSegment' -Type 'pivotTable' -X 820 -Y 270 -W 440 -H 230 -Z 2 -Roles ([ordered]@{
                        Rows = @('Customer|Segment|column'); Columns = @('Calendar|Year|column'); Values = @('Sales|Total Sales|measure') }))
        )
    }
)

Write-LabTextFile -Path (Join-Path $reportDir 'report.json') -Content (@{
        '$schema'          = 'http://powerbi.com/product/schema#report'
        themeCollection    = @{}
        layoutOptimization = 0
        resourcePackages   = @()
        sections           = $sections
        config             = (@{ version = '5.43'; themeCollection = @{}; activeSectionIndex = 0 } | ConvertTo-Json -Depth 10 -Compress)
    } | ConvertTo-Json -Depth 40)

Write-LabTextFile -Path (Join-Path $reportDir 'definition.pbir') -Content (@{
        version          = '4.0'
        datasetReference = @{ byPath = @{ path = "../$ProjectName.SemanticModel" } }
    } | ConvertTo-Json -Depth 10)

Write-LabTextFile -Path (Join-Path $reportDir '.platform') -Content (@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata  = @{ type = 'Report'; displayName = $ProjectName }
        config    = @{ version = '2.0'; logicalId = [guid]::NewGuid().ToString() }
    } | ConvertTo-Json -Depth 5)

# --- .pbip -------------------------------------------------------------------

Write-LabTextFile -Path (Join-Path $projRoot "$ProjectName.pbip") -Content (@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json'
        version   = '1.0'
        artifacts = @(@{ report = @{ path = "$ProjectName.Report" } })
        settings  = @{ enableAutoRecovery = $true }
    } | ConvertTo-Json -Depth 10)

# --- verify ------------------------------------------------------------------

Write-LabStep 'verifying output'
$expected = @(
    "$ProjectName.pbip"
    "$ProjectName.SemanticModel\.platform"
    "$ProjectName.SemanticModel\definition.pbism"
    "$ProjectName.SemanticModel\definition\database.tmdl"
    "$ProjectName.SemanticModel\definition\model.tmdl"
    "$ProjectName.SemanticModel\definition\relationships.tmdl"
    "$ProjectName.Report\.platform"
    "$ProjectName.Report\definition.pbir"
    "$ProjectName.Report\report.json"
) + @($allTables | ForEach-Object { "$ProjectName.SemanticModel\definition\tables\$_.tmdl" }
) + @($roles | ForEach-Object { "$ProjectName.SemanticModel\definition\roles\$($_.Name).tmdl" })

$missing = @(); $totalBytes = 0
foreach ($rel in $expected) {
    $p = Join-Path $projRoot $rel
    if (-not (Test-Path $p)) { $missing += $rel; continue }
    $len = (Get-Item $p).Length
    $totalBytes += $len
    if ($len -eq 0) { $missing += "$rel (empty)" }
}

$ev = @(
    "project root: $projRoot"
    "files written: $($expected.Count - $missing.Count)/$($expected.Count) ($([math]::Round($totalBytes / 1KB)) KB)"
    "tables: $($allTables -join ', ')"
    "measures: $(@($tableSpecs | ForEach-Object { $_.Measures } | Where-Object { $_ }).Count)"
    "roles: $($roles.Name -join ', ')"
    "report pages: $($sections.Count)"
)
Add-LabResource -Type 'local-pbip' -Id $ProjectName -Name $ProjectName -Target $Target -Api 'local' `
    -Extra @{ path = $projRoot } | Out-Null

Write-Host ''
foreach ($e in $ev) { Write-Host "  $e" }

if ($missing.Count) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Project written but $($missing.Count) file(s) missing or empty." -Evidence ($ev + ($missing | ForEach-Object { "MISSING: $_" })) | Out-Null
}
else {
    Complete-LabRun -Verdict PASS -Summary "PBIP project written to $projRoot ($($expected.Count) files)." -Evidence $ev | Out-Null
}

Write-Host ''
Write-Host "Open in Power BI Desktop:  $(Join-Path $projRoot "$ProjectName.pbip")" -ForegroundColor Cyan
