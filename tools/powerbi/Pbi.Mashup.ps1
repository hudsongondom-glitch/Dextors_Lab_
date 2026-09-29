# Pbi.Mashup.ps1 - emitting Power Query (M) and base64 payloads.
#
# Shared by powerbi/build-pbip-project (M partitions inside TMDL) and
# powerbi/build-gen2-dataflow (M queries inside a mashup.pq section document).
#
# Inline #table literals are deliberate: a lab artifact that reaches out to an external data source
# would need credentials and a gateway, and would fail to refresh after a restore into a different
# tenant. Self-contained M refreshes anywhere.

function ConvertTo-LabB64 {
    param([string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertTo-LabMLiteral {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64]) { return [string]$Value }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return [System.Convert]::ToString($Value, [cultureinfo]::InvariantCulture)
    }
    $s = [string]$Value
    # ISO timestamps become real M date values rather than text.
    if ($s -match '^(\d{4})-(\d{2})-(\d{2})T') { return "#date($([int]$Matches[1]),$([int]$Matches[2]),$([int]$Matches[3]))" }
    return '"' + ($s -replace '"', '""') + '"'
}

# The lab's standard six-query dataflow mashup, shared by the Gen2 and Gen1 recipes so both
# generations hold identical logic and a backup can be compared across them.
#
# Returns:
#   Document    - an M section document ('section Section1; shared X = ...;')
#   Definitions - ordered query name -> M expression
#   Schema      - ordered query name -> ordered column name -> CDM data type
function New-LabSeedMashup {
    param(
        [int]$SalesRowCount = 1000,
        # A query that REFERENCES other queries is a "computed table", which Gen1 can only refresh
        # on Premium/Fabric capacity - a Pro workspace fails with "This dataflow contains tables
        # that require Premium to refresh". Default off: SalesByCategory carries its own inline
        # copy of the data and joins that, so it refreshes anywhere. Switch on for capacity
        # workspaces when a computed table is wanted as an artifact in its own right.
        [switch]$ComputedEntity
    )

    $data = New-LabSeedDataset -SalesRowCount $SalesRowCount

    # Generated rather than emitted as literals: keeps the mashup small and exercises real M.
    $calendarQuery = @'
let
    Dates = List.Dates(#date(2024, 1, 1), Duration.Days(#date(2026, 8, 7) - #date(2024, 1, 1)) + 1, #duration(1, 0, 0, 0)),
    AsTable = Table.FromList(Dates, Splitter.SplitByNothing(), {"Date"}),
    Typed = Table.TransformColumnTypes(AsTable, {{"Date", type date}}),
    WithKey = Table.AddColumn(Typed, "DateKey", each Date.Year([Date]) * 10000 + Date.Month([Date]) * 100 + Date.Day([Date]), Int64.Type),
    WithYear = Table.AddColumn(WithKey, "Year", each Date.Year([Date]), Int64.Type),
    WithQuarter = Table.AddColumn(WithYear, "Quarter", each "Q" & Text.From(Date.QuarterOfYear([Date])), type text),
    WithMonth = Table.AddColumn(WithQuarter, "Month", each Date.Month([Date]), Int64.Type),
    WithMonthName = Table.AddColumn(WithMonth, "MonthName", each Date.MonthName([Date]), type text),
    WithDayName = Table.AddColumn(WithMonthName, "DayOfWeek", each Date.DayOfWeekName([Date]), type text),
    WithWeekend = Table.AddColumn(WithDayName, "IsWeekend", each Date.DayOfWeek([Date], Day.Monday) >= 5, type logical)
in
    WithWeekend
'@

    # A join + group query, so the dataflow transforms rather than only echoing its inputs.
    $transformSteps = @'
    Joined = Table.NestedJoin(SalesSrc, {"ProductKey"}, ProductSrc, {"ProductKey"}, "ProductRow", JoinKind.LeftOuter),
    Expanded = Table.ExpandTableColumn(Joined, "ProductRow", {"Category", "Subcategory"}, {"Category", "Subcategory"}),
    Grouped = Table.Group(Expanded, {"Category", "Subcategory"}, {
        {"TotalAmount", each List.Sum([Amount]), type number},
        {"UnitsSold", each List.Sum([Quantity]), Int64.Type},
        {"OrderCount", each Table.RowCount(_), Int64.Type},
        {"AvgUnitPrice", each List.Average([UnitPrice]), type number}
    }),
    Sorted = Table.Sort(Grouped, {{"TotalAmount", Order.Descending}})
in
    Sorted
'@

    if ($ComputedEntity) {
        # References the sibling queries - richer lineage, but Premium/Fabric only.
        $derivedQuery = "let`n    SalesSrc = Sales,`n    ProductSrc = Product,`n$transformSteps"
    }
    else {
        $productBare = New-LabMTableExpression -Bare -Rows @($data.Products) `
            -ColumnOrder @('ProductKey', 'Product', 'Category', 'Subcategory') `
            -ColumnTypes @{ ProductKey = 'Int64.Type'; Product = 'Text.Type'; Category = 'Text.Type'; Subcategory = 'Text.Type' }
        $salesBare = New-LabMTableExpression -Bare -Rows @($data.Sales) `
            -ColumnOrder @('ProductKey', 'Quantity', 'UnitPrice', 'Amount') `
            -ColumnTypes @{ ProductKey = 'Int64.Type'; Quantity = 'Int64.Type'; UnitPrice = 'Number.Type'; Amount = 'Number.Type' }
        $derivedQuery = "let`n    ProductSrc = $productBare,`n    SalesSrc = $salesBare,`n$transformSteps"
    }

    $defs = [ordered]@{
        Product         = New-LabMTableExpression -Rows @($data.Products) `
            -ColumnOrder @('ProductKey', 'Product', 'Category', 'Subcategory', 'Brand', 'ListPrice') `
            -ColumnTypes @{ ProductKey = 'Int64.Type'; Product = 'Text.Type'; Category = 'Text.Type'; Subcategory = 'Text.Type'; Brand = 'Text.Type'; ListPrice = 'Number.Type' }
        Customer        = New-LabMTableExpression -Rows @($data.Customers) `
            -ColumnOrder @('CustomerKey', 'CustomerName', 'Segment', 'City', 'Country') `
            -ColumnTypes @{ CustomerKey = 'Int64.Type'; CustomerName = 'Text.Type'; Segment = 'Text.Type'; City = 'Text.Type'; Country = 'Text.Type' }
        Store           = New-LabMTableExpression -Rows @($data.Stores) `
            -ColumnOrder @('StoreKey', 'StoreName', 'Region', 'Country') `
            -ColumnTypes @{ StoreKey = 'Int64.Type'; StoreName = 'Text.Type'; Region = 'Text.Type'; Country = 'Text.Type' }
        Calendar        = $calendarQuery
        Sales           = New-LabMTableExpression -Rows @($data.Sales) `
            -ColumnOrder @('OrderId', 'OrderDate', 'DateKey', 'ProductKey', 'CustomerKey', 'StoreKey', 'Quantity', 'UnitPrice', 'Discount', 'Amount') `
            -ColumnTypes @{ OrderId = 'Int64.Type'; OrderDate = 'Date.Type'; DateKey = 'Int64.Type'; ProductKey = 'Int64.Type'; CustomerKey = 'Int64.Type'; StoreKey = 'Int64.Type'; Quantity = 'Int64.Type'; UnitPrice = 'Number.Type'; Discount = 'Number.Type'; Amount = 'Number.Type' }
        SalesByCategory = $derivedQuery
    }

    # CDM attribute types for the Gen1 model.json entity definitions.
    $schema = [ordered]@{
        Product         = [ordered]@{ ProductKey = 'int64'; Product = 'string'; Category = 'string'; Subcategory = 'string'; Brand = 'string'; ListPrice = 'double' }
        Customer        = [ordered]@{ CustomerKey = 'int64'; CustomerName = 'string'; Segment = 'string'; City = 'string'; Country = 'string' }
        Store           = [ordered]@{ StoreKey = 'int64'; StoreName = 'string'; Region = 'string'; Country = 'string' }
        Calendar        = [ordered]@{ Date = 'dateTime'; DateKey = 'int64'; Year = 'int64'; Quarter = 'string'; Month = 'int64'; MonthName = 'string'; DayOfWeek = 'string'; IsWeekend = 'boolean' }
        Sales           = [ordered]@{ OrderId = 'int64'; OrderDate = 'dateTime'; DateKey = 'int64'; ProductKey = 'int64'; CustomerKey = 'int64'; StoreKey = 'int64'; Quantity = 'int64'; UnitPrice = 'double'; Discount = 'double'; Amount = 'double' }
        SalesByCategory = [ordered]@{ Category = 'string'; Subcategory = 'string'; TotalAmount = 'double'; UnitsSold = 'int64'; OrderCount = 'int64'; AvgUnitPrice = 'double' }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('section Section1;')
    foreach ($q in $defs.Keys) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("shared $q = $($defs[$q].TrimEnd());")
    }

    return [pscustomobject]@{
        Document    = $sb.ToString()
        Definitions = $defs
        Schema      = $schema
        Data        = $data
    }
}

# Builds `let Source = #table(type table [...], {{...},{...}}) in Source`.
function New-LabMTableExpression {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][hashtable]$ColumnTypes,   # column name -> M type (Int64.Type, Text.Type, ...)
        [Parameter(Mandatory)][string[]]$ColumnOrder,
        [string]$Indent = '',
        [switch]$Bare                                    # emit only the #table(...) expression
    )
    $typeParts = $ColumnOrder | ForEach-Object { "$_ = $($ColumnTypes[$_])" }
    $sb = [System.Text.StringBuilder]::new()
    if (-not $Bare) {
        [void]$sb.AppendLine("${Indent}let")
        [void]$sb.Append("${Indent}    Source = ")
    }
    [void]$sb.AppendLine('#table(')
    [void]$sb.AppendLine("${Indent}        type table [$($typeParts -join ', ')],")
    [void]$sb.AppendLine("${Indent}        {")
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $vals = $ColumnOrder | ForEach-Object { ConvertTo-LabMLiteral $Rows[$i].$_ }
        $comma = if ($i -lt $Rows.Count - 1) { ',' } else { '' }
        [void]$sb.AppendLine("${Indent}            {$($vals -join ', ')}$comma")
    }
    [void]$sb.AppendLine("${Indent}        }")
    if ($Bare) { [void]$sb.Append("${Indent}    )"); return $sb.ToString() }
    [void]$sb.AppendLine("${Indent}    )")
    [void]$sb.AppendLine("${Indent}in")
    [void]$sb.Append("${Indent}    Source")
    return $sb.ToString()
}
