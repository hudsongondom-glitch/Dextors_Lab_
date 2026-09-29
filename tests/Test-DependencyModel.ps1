<#
Offline self-test for the D365 restore dependency model. No network, no credentials, no tenant
access - the graph analysis is fabricated from in-memory models, and only the real config file
is read from disk.

Covers the reasoning the experiments rest on: whether a cycle exists, whether it can be broken
by deferring an optional lookup, and what creation order the obligatory edges force.

Run:  pwsh -File tests\Test-DependencyModel.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\core\Core.Context.ps1')

$pass = 0; $fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
        else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:fail++ }
    }
    catch { Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}

function New-TestEdge {
    param([string]$Name, [string]$From, [string]$To, [bool]$Required, [bool]$ClosesCycle = $false)
    [pscustomobject]@{
        Name = $Name; From = $From; To = $To; Exists = $true
        IsRequired = $Required; ClosesCycle = $ClosesCycle
        FromEntity = "e_$From"; ToEntity = "e_$To"; LookupAttribute = "l_$Name"
    }
}
function New-TestModel {
    param([object[]]$Edges)
    $roles = [ordered]@{}
    foreach ($n in 'account', 'contact', 'order') {
        $roles[$n] = [pscustomobject]@{ Role = $n; LogicalName = "e_$n"; Exists = $true; NameAttribute = 'name' }
    }
    [pscustomobject]@{ Roles = $roles; Edges = @($Edges); Missing = @() }
}

Write-Host "`nD365 dependency model self-test (offline)`n" -ForegroundColor Cyan

# The shape in the scenario diagram: obligatory order -> contact -> account, optional
# order -> account, optional account -> contact closing the loop.
$diagram = New-TestModel @(
    (New-TestEdge 'contact-to-account' 'contact' 'account' $true),
    (New-TestEdge 'order-to-contact' 'order' 'contact' $true),
    (New-TestEdge 'order-to-account' 'order' 'account' $false),
    (New-TestEdge 'account-to-primarycontact' 'account' 'contact' $false $true)
)
$diagramCycles = @(Get-DvModelCycles -Resolved $diagram -ExistingOnly)

Check 'diagram model has exactly one cycle' { $diagramCycles.Count -eq 1 }
Check 'the same loop is not reported once per entry point' { $diagramCycles.Count -eq 1 }
Check 'diagram cycle is breakable by deferring an optional edge' { $diagramCycles[0].Optional.Count -ge 1 }
Check 'diagram creation order exists' { (Get-DvCreationOrder -Resolved $diagram).Ok }
Check 'diagram creation order is account -> contact -> order' {
    ((Get-DvCreationOrder -Resolved $diagram).Order -join ',') -eq 'account,contact,order'
}

# If every edge in the loop were obligatory there would be no valid order at all, and a
# two-phase create could not rescue it either. This is the "A fails" row of the spec.
$hard = New-TestModel @(
    (New-TestEdge 'contact-to-account' 'contact' 'account' $true),
    (New-TestEdge 'account-to-contact' 'account' 'contact' $true $true)
)
$hardCycles = @(Get-DvModelCycles -Resolved $hard -ExistingOnly)
Check 'all-obligatory loop is detected' { $hardCycles.Count -eq 1 }
Check 'all-obligatory loop is reported unbreakable' { $hardCycles[0].Optional.Count -eq 0 }
Check 'all-obligatory loop yields no creation order' { -not (Get-DvCreationOrder -Resolved $hard).Ok }
Check 'deadlock names both deadlocked roles' {
    $s = (Get-DvCreationOrder -Resolved $hard).Stuck
    ($s -contains 'account') -and ($s -contains 'contact')
}

# B-control: identical chain, back-edge absent.
$control = New-TestModel @(
    (New-TestEdge 'contact-to-account' 'contact' 'account' $true),
    (New-TestEdge 'order-to-contact' 'order' 'contact' $true),
    (New-TestEdge 'order-to-account' 'order' 'account' $false)
)
Check 'control arm is acyclic' { @(Get-DvModelCycles -Resolved $control -ExistingOnly).Count -eq 0 }
Check 'control arm keeps the same creation order' {
    ((Get-DvCreationOrder -Resolved $control).Order -join ',') -eq 'account,contact,order'
}

# Edges that do not exist yet must not contribute to the analysis.
$partial = New-TestModel @(
    (New-TestEdge 'contact-to-account' 'contact' 'account' $true),
    (New-TestEdge 'account-to-contact' 'account' 'contact' $false $true)
)
$partial.Edges[1].Exists = $false
Check 'a not-yet-created edge is excluded from cycle detection' {
    @(Get-DvModelCycles -Resolved $partial -ExistingOnly).Count -eq 0
}

Write-Host ''
foreach ($name in 'custom', 'oob') {
    $p = Get-DvModelProfile -Name $name
    Check "profile '$name' defines all three roles" {
        (@($p.roles.PSObject.Properties.Name) | Sort-Object) -join ',' -eq 'account,contact,order'
    }
    Check "profile '$name' defines at least three edges" { @($p.edges).Count -ge 3 }
    Check "profile '$name' marks exactly one cycle-closing edge" {
        @($p.edges | Where-Object { $_.closesCycle }).Count -eq 1
    }
    Check "profile '$name' names every edge endpoint as a defined role" {
        $roleNames = @($p.roles.PSObject.Properties.Name)
        -not @($p.edges | Where-Object { $roleNames -notcontains $_.from -or $roleNames -notcontains $_.to }).Count
    }
}

Check 'custom profile marks contact->account and order->contact obligatory' {
    $p = Get-DvModelProfile -Name 'custom'
    (@($p.edges | Where-Object { $_.link -eq 'obligatory' } | ForEach-Object { $_.name }) | Sort-Object) -join ',' -eq 'contact-to-account,order-to-contact'
}
Check 'custom profile gives every managed edge a relationship schema name to create' {
    $p = Get-DvModelProfile -Name 'custom'
    -not @($p.edges | Where-Object { -not $_.relationshipSchemaName -or -not $_.lookupSchemaName }).Count
}
Check 'oob profile creates nothing' {
    $p = Get-DvModelProfile -Name 'oob'
    -not @($p.roles.PSObject.Properties.Value | Where-Object { $_.manage }).Count
}
Check 'unknown profile name fails loudly' {
    try { Get-DvModelProfile -Name 'no-such-profile'; $false } catch { $_.Exception.Message -like '*not defined*' }
}

Write-Host ''
$role = [pscustomobject]@{ NameAttribute = 'lastname' }
Check 'lab record filter targets the role name column' {
    (Get-DvLabRecordFilter -Role $role) -eq "startswith(lastname,'dextorslab')"
}
Check 'lab record filter scopes to a single run' {
    (Get-DvLabRecordFilter -Role $role -RunId '20260810-084500') -eq "startswith(lastname,'dextorslab-20260810-084500')"
}

Write-Host "`n$pass passed, $fail failed`n" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
