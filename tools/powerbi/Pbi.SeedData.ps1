# Pbi.SeedData.ps1 - deterministic sample star-schema data shared by the Power BI seed recipes.
#
# Two callers need the SAME rows: powerbi/build-seed-artifacts (pushes them over REST into a push
# semantic model) and powerbi/build-pbip-project (emits them as M literals inside a PBIP). Keeping
# one generator means a Desktop-published PBIX and an API-created push dataset hold identical data,
# so a restore can be compared field-for-field across the two artifact kinds.
#
# Deterministic by design: a fixed RNG seed, so reruns reproduce the same rows.

function New-LabSeedDataset {
    param(
        [int]$SalesRowCount = 3000,
        [int]$Seed = 20260807,
        [datetime]$StartDate = ([datetime]'2024-01-01'),
        [datetime]$EndDate = ([datetime]'2026-08-07')
    )
    $rand = [Random]::new($Seed)
    $pick = { param($a) $a[$rand.Next(0, $a.Count)] }

    $taxonomy = [ordered]@{
        'Bikes'       = @('Road Bikes', 'Mountain Bikes', 'Touring Bikes')
        'Components'  = @('Brakes', 'Chains', 'Cranksets', 'Wheels')
        'Clothing'    = @('Jerseys', 'Gloves', 'Shorts', 'Helmets')
        'Accessories' = @('Bottles', 'Pumps', 'Lights', 'Locks')
    }
    $brands = @('Contoso', 'Fabrikam', 'Northwind', 'Adventure Works')

    $products = [System.Collections.Generic.List[object]]::new()
    $pk = 1
    foreach ($cat in $taxonomy.Keys) {
        foreach ($sub in $taxonomy[$cat]) {
            foreach ($n in 1..2) {
                $basePrice = switch ($cat) {
                    'Bikes' { 800 + $rand.Next(0, 2600) }
                    'Components' { 40 + $rand.Next(0, 420) }
                    'Clothing' { 20 + $rand.Next(0, 140) }
                    default { 8 + $rand.Next(0, 70) }
                }
                $products.Add([pscustomobject]@{
                        ProductKey  = $pk
                        Product     = "$(& $pick $brands) $($sub -replace 's$','') $((100 * $n) + $rand.Next(1, 99))"
                        Category    = $cat
                        Subcategory = $sub
                        Brand       = & $pick $brands
                        ListPrice   = [math]::Round($basePrice + $rand.NextDouble(), 2)
                    })
                $pk++
            }
        }
    }

    $first = @('Ava', 'Liam', 'Noor', 'Mateo', 'Sofia', 'Jonas', 'Priya', 'Elena', 'Tomas', 'Aisha', 'Hugo', 'Mei', 'Anders', 'Ines', 'Kofi')
    $last = @('Hansen', 'Okafor', 'Rossi', 'Novak', 'Silva', 'Lindqvist', 'Patel', 'Dubois', 'Kowalski', 'Nakamura', 'Bauer', 'Costa')
    $segments = @('Consumer', 'Corporate', 'Small Business')
    $geo = @(
        @{ City = 'Copenhagen'; Country = 'Denmark'; Region = 'Nordics' }
        @{ City = 'Aarhus'; Country = 'Denmark'; Region = 'Nordics' }
        @{ City = 'Stockholm'; Country = 'Sweden'; Region = 'Nordics' }
        @{ City = 'Oslo'; Country = 'Norway'; Region = 'Nordics' }
        @{ City = 'Hamburg'; Country = 'Germany'; Region = 'DACH' }
        @{ City = 'Munich'; Country = 'Germany'; Region = 'DACH' }
        @{ City = 'Zurich'; Country = 'Switzerland'; Region = 'DACH' }
        @{ City = 'Amsterdam'; Country = 'Netherlands'; Region = 'Benelux' }
        @{ City = 'Brussels'; Country = 'Belgium'; Region = 'Benelux' }
        @{ City = 'Lisbon'; Country = 'Portugal'; Region = 'Iberia' }
        @{ City = 'Madrid'; Country = 'Spain'; Region = 'Iberia' }
        @{ City = 'Dublin'; Country = 'Ireland'; Region = 'UK & Ireland' }
    )

    $customers = [System.Collections.Generic.List[object]]::new()
    foreach ($i in 1..150) {
        $g = & $pick $geo
        $customers.Add([pscustomobject]@{
                CustomerKey  = $i
                CustomerName = "$(& $pick $first) $(& $pick $last)"
                Segment      = & $pick $segments
                City         = $g.City
                Country      = $g.Country
            })
    }

    $stores = [System.Collections.Generic.List[object]]::new()
    $sk = 1
    foreach ($g in $geo | Select-Object -First 10) {
        $stores.Add([pscustomobject]@{
                StoreKey  = $sk
                StoreName = "$($g.City) Store"
                Region    = $g.Region
                Country   = $g.Country
            })
        $sk++
    }

    $dates = [System.Collections.Generic.List[object]]::new()
    for ($d = $StartDate; $d -le $EndDate; $d = $d.AddDays(1)) {
        $dates.Add([pscustomobject]@{
                DateKey   = [int]$d.ToString('yyyyMMdd')
                Date      = $d.ToString('yyyy-MM-ddT00:00:00Z')
                Year      = $d.Year
                Quarter   = "Q$([math]::Ceiling($d.Month / 3))"
                Month     = $d.Month
                MonthName = $d.ToString('MMMM')
                DayOfWeek = $d.DayOfWeek.ToString()
                IsWeekend = ($d.DayOfWeek -in 'Saturday', 'Sunday')
            })
    }

    $spanDays = ($EndDate - $StartDate).Days
    $sales = [System.Collections.Generic.List[object]]::new()
    foreach ($i in 1..$SalesRowCount) {
        $p = $products[$rand.Next(0, $products.Count)]
        $od = $StartDate.AddDays($rand.Next(0, $spanDays + 1))
        $qty = $rand.Next(1, 9)
        # Seasonal lift towards Q4 makes trend visuals look like real data rather than noise.
        $seasonal = if ($od.Month -ge 10) { 1.0 + ($rand.NextDouble() * 0.45) } else { 0.85 + ($rand.NextDouble() * 0.30) }
        $unit = [math]::Round($p.ListPrice * $seasonal, 2)
        $disc = @(0.0, 0.0, 0.0, 0.05, 0.10, 0.15)[$rand.Next(0, 6)]
        $sales.Add([pscustomobject]@{
                OrderId     = 100000 + $i
                OrderDate   = $od.ToString('yyyy-MM-ddT00:00:00Z')
                DateKey     = [int]$od.ToString('yyyyMMdd')
                ProductKey  = $p.ProductKey
                CustomerKey = $rand.Next(1, 151)
                StoreKey    = $rand.Next(1, 11)
                Quantity    = $qty
                UnitPrice   = $unit
                Discount    = $disc
                Amount      = [math]::Round($unit * $qty * (1 - $disc), 2)
            })
    }

    return [pscustomobject]@{
        Products = $products; Customers = $customers; Stores = $stores; Dates = $dates; Sales = $sales
    }
}
