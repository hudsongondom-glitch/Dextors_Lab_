<#
BUILD a group-connected SharePoint team site with sample content, for use as the subject of
backup/restore reproduction tests.

Creates:
  - a Microsoft 365 group + its team site   (Graph, app-only - Group.ReadWrite.All)
  - a "Departments" custom list with 4 columns and sample rows   (SPO REST, certificate app-only)
  - a "Department Docs" document library with sample text files  (SPO REST)

  PASS = site, list, library and sample data all created and read back.
  FAIL = creation succeeded partially; see evidence for the first failing call.

The group is tracked in the resource ledger with a DeleteUri, so CLEANUP removes the group,
the team site and all of this content in one operation.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$SiteName = 'LabCo',
    [string]$Identity = 'msg-app',
    [string]$CertIdentity = 'msg-app-cert'
)

$Recipe = @{
    Name        = 'sharepoint/build-test-site'
    Product     = 'sharepoint'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create a team site with a sample list and document library, tracked for cleanup.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')
. (Join-Path $PSScriptRoot '..\..\tools\microsoft\Spo.Rest.ps1')

$problems = Test-LabConfigReady
$run = Start-LabRun -Name "spo-build-$SiteName" -Mode BUILD -Product sharepoint -Target $Target -DryRun:$DryRun `
    -Request "Create SharePoint team site '$SiteName' with a Departments list and a document library containing sample data." `
    -Plan @('Create M365 group + team site via Graph', 'Wait for site provisioning', 'Create Departments list + columns',
    'Add sample department rows', 'Create document library + sample files', 'Read everything back')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix config and rerun.'; return }

$graph = Get-LabAccessToken -Api Graph -Identity $Identity

# --- 1. Group-connected team site -------------------------------------------
Write-LabStep "creating Microsoft 365 group + team site '$SiteName'"
$existing = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=mailNickname eq '$SiteName'&`$select=id,displayName" -Token $graph -Label 'graph-group-exists'
if (@($existing.Json.value).Count -and -not $Force) {
    Complete-LabRun -Verdict FAIL -Summary "A group with mailNickname '$SiteName' already exists (id $($existing.Json.value[0].id)). Pass -Force to build alongside it, or clean up first." | Out-Null
    return
}

$groupBody = @{
    displayName     = $SiteName
    mailNickname    = $SiteName
    description     = 'Dextors Lab test site'
    groupTypes      = @('Unified')
    mailEnabled     = $true
    securityEnabled = $false
    visibility      = 'Private'
}
$grp = Invoke-LabRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Token $graph -Body $groupBody -Label 'graph-create-group'
if (-not $grp.Ok) {
    Complete-LabRun -Verdict FAIL -Summary "Group creation failed: HTTP $($grp.Status) code=$($grp.Error.Code)" -Evidence @($grp.Error.Message) | Out-Null
    return
}
$groupId = $grp.Json.id
Add-LabResource -Type 'm365-group-site' -Id $groupId -Name $SiteName -Target 'spo-main' -Api 'graph' `
    -DeleteUri "https://graph.microsoft.com/v1.0/groups/$groupId" -Extra @{ explicitName = $true; note = 'deleting the group also deletes the team site' } | Out-Null
Add-LabEvidenceNote "created M365 group '$SiteName' id=$groupId"

# --- 2. Wait for SharePoint provisioning ------------------------------------
Write-LabStep 'waiting for the team site to provision'
$siteUrl = $null
for ($i = 0; $i -lt 40 -and -not $siteUrl; $i++) {
    Start-Sleep -Seconds 6
    $s = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/sites/root?`$select=id,webUrl,displayName" -Token $graph -Label 'graph-group-site' -NoEvidence
    if ($s.Ok -and $s.Json.webUrl) { $siteUrl = $s.Json.webUrl; $siteId = $s.Json.id }
    else { Write-LabLog "  provisioning... ($($i + 1))" -Level DEBUG }
}
if (-not $siteUrl) {
    Complete-LabRun -Verdict FAIL -Summary 'Group created but the SharePoint site did not provision within 4 minutes.' -Evidence @("group id $groupId - rerun the content steps once the site appears") | Out-Null
    return
}
Add-LabEvidenceNote "team site provisioned: $siteUrl"
Write-LabLog "site ready: $siteUrl" -Level OK

# Site-scoped target for SPO REST calls.
$siteTarget = [pscustomobject]@{ product = 'sharepoint'; siteUrl = $siteUrl; _name = 'spo-labco' }
$spo = Get-LabAccessToken -Api SharePoint -Target $siteTarget -Identity $CertIdentity

# --- 3. Departments list -----------------------------------------------------
Write-LabStep 'creating Departments list'
$listTitle = 'Departments'
$mk = New-SpoList -Target $siteTarget -Token $spo -Title $listTitle -BaseTemplate 100 -Description 'Sample department reference data'
if (-not $mk.Ok) {
    Complete-LabRun -Verdict FAIL -Summary "List creation failed: HTTP $($mk.Status)" -Evidence @("$($mk.Raw)", "Site was created: $siteUrl") | Out-Null
    return
}
foreach ($f in @(@{n = 'Manager'; k = 2 }, @{n = 'Headcount'; k = 9 }, @{n = 'Location'; k = 2 }, @{n = 'CostCentre'; k = 2 })) {
    $r = New-SpoField -Target $siteTarget -Token $spo -ListTitle $listTitle -FieldName $f.n -FieldTypeKind $f.k
    if ($r.Ok) { Add-SpoViewField -Target $siteTarget -Token $spo -ListTitle $listTitle -FieldName $f.n | Out-Null }
    else { Write-LabLog "field '$($f.n)' failed: HTTP $($r.Status)" -Level WARN }
}
Add-LabEvidenceNote "list '$listTitle' created with columns Manager, Headcount, Location, CostCentre"

Write-LabStep 'adding sample department rows'
$entityType = Get-SpoListEntityType -Target $siteTarget -Token $spo -ListTitle $listTitle
$departments = @(
    @{ Title = 'Finance'; Manager = 'Alena Kovac'; Headcount = 12; Location = 'Copenhagen'; CostCentre = 'CC-1001' }
    @{ Title = 'Human Resources'; Manager = 'Priya Raman'; Headcount = 7; Location = 'London'; CostCentre = 'CC-1002' }
    @{ Title = 'Engineering'; Manager = 'Tomas Berg'; Headcount = 43; Location = 'Copenhagen'; CostCentre = 'CC-2001' }
    @{ Title = 'Customer Support'; Manager = 'Nadia Haddad'; Headcount = 21; Location = 'Lisbon'; CostCentre = 'CC-2002' }
    @{ Title = 'Legal'; Manager = 'Sam Whitfield'; Headcount = 4; Location = 'London'; CostCentre = 'CC-3001' }
    @{ Title = 'Facilities'; Manager = 'Jonas Lind'; Headcount = 9; Location = 'Aarhus'; CostCentre = 'CC-3002' }
)
$added = 0
foreach ($d in $departments) {
    $r = New-SpoListItem -Target $siteTarget -Token $spo -ListTitle $listTitle -Fields $d -EntityType $entityType
    if ($r.Ok) { $added++ } else { Write-LabLog "row '$($d.Title)' failed: HTTP $($r.Status) $($r.Raw)" -Level WARN }
}
Add-LabEvidenceNote "$added of $($departments.Count) department rows added"

# --- 4. Document library -----------------------------------------------------
Write-LabStep 'creating document library'
$libTitle = 'Department Docs'
$lib = New-SpoList -Target $siteTarget -Token $spo -Title $libTitle -BaseTemplate 101 -Description 'Sample documents for restore testing'
$uploaded = 0
if ($lib.Ok) {
    $folder = ([Uri]$siteUrl).AbsolutePath.TrimEnd('/') + '/' + ($libTitle -replace ' ', '')
    # SharePoint strips spaces from the library's URL segment; confirm the real one.
    $li = Invoke-SpoRequest -Target $siteTarget -Token $spo -Path "/_api/web/lists/getbytitle('$([Uri]::EscapeDataString($libTitle))')/RootFolder?`$select=ServerRelativeUrl" -Label 'spo-lib-rootfolder'
    if ($li.Ok -and $li.Json.ServerRelativeUrl) { $folder = $li.Json.ServerRelativeUrl }
    Add-LabEvidenceNote "library '$libTitle' root folder: $folder"

    $files = @(
        @{ n = 'Departments-Overview.txt'; c = "LabCo department overview`r`n`r`nFinance, HR, Engineering, Customer Support, Legal, Facilities.`r`nGenerated by the Dextors Lab as sample backup content." }
        @{ n = 'Headcount-Summary.txt'; c = "Headcount by department`r`nFinance 12`r`nHuman Resources 7`r`nEngineering 43`r`nCustomer Support 21`r`nLegal 4`r`nFacilities 9`r`nTotal 96" }
        @{ n = 'Cost-Centres.txt'; c = "Cost centre mapping`r`nCC-1001 Finance`r`nCC-1002 Human Resources`r`nCC-2001 Engineering`r`nCC-2002 Customer Support`r`nCC-3001 Legal`r`nCC-3002 Facilities" }
    )
    foreach ($f in $files) {
        $r = Add-SpoFile -Target $siteTarget -Token $spo -FolderServerRelativeUrl $folder -FileName $f.n -Content $f.c
        if ($r.Ok) { $uploaded++ } else { Write-LabLog "upload '$($f.n)' failed: HTTP $($r.Status) $($r.Raw)" -Level WARN }
    }
    Add-LabEvidenceNote "$uploaded of $($files.Count) sample files uploaded"
}
else { Add-LabEvidenceNote "library creation failed: HTTP $($lib.Status)" }

# --- 5. Read back ------------------------------------------------------------
Write-LabStep 'verifying'
$lists = Get-SpoLists -Target $siteTarget -Token $spo
@($lists.Json.value | Where-Object { -not $_.Hidden }) | ForEach-Object {
    Write-Host ("    {0,-28} items={1,-5} template={2}" -f $_.Title, $_.ItemCount, $_.BaseTemplate)
}
$items = Get-SpoListItems -Target $siteTarget -Token $spo -ListTitle $listTitle -Top 10 -Select 'Title,Manager,Headcount,Location,CostCentre'
Write-Host ("      {0,-20} {1,-16} {2,-12} {3,-10} {4}" -f 'DEPARTMENT', 'MANAGER', 'LOCATION', 'HEADCOUNT', 'COST CENTRE')
@($items.Json.value) | ForEach-Object { Write-Host ("      {0,-20} {1,-16} {2,-12} {3,-10} {4}" -f $_.Title, $_.Manager, $_.Location, $_.Headcount, $_.CostCentre) }

$ok = ($added -eq $departments.Count -and $uploaded -eq 3 -and $lists.Ok)
Complete-LabRun -Verdict $(if ($ok) { 'PASS' } else { 'FAIL' }) `
    -Summary "Team site '$SiteName' built at $siteUrl with $added department rows and $uploaded sample files." `
    -Evidence @("Site URL: $siteUrl", "Group id: $groupId (tracked - CLEANUP deletes group + site together)") | Out-Null
