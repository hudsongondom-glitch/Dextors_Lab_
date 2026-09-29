<#
Creates a minimal Power Pages test dataset on an Enhanced Data Model (EDM) site, for validating
how a backup product ingests EDM sites. Every artifact uses the caller's unique -Prefix so it is
trivially identifiable in Dataverse and in a backup/restore, and nothing is deleted afterwards -
the whole point is to leave a stable, named dataset to back up.

EDM sites store each component as a row in ONE underlying system table, powerpagecomponent,
projected through per-type virtual tables (mspp_webpage, mspp_contentsnippet, mspp_sitesetting,
mspp_webfile, ...). See docs/... (Microsoft Learn "Site Component (powerpagecomponent)" and
"Power Pages enhanced data model") for the componenttype map. This recipe writes through those
virtual tables directly - each POST lands in powerpagecomponent, filtered by componenttype.

Creates, scoped to -SiteId:
  1. Web page          (mspp_webpages)         body text goes in mspp_copy
  2. Content snippet   (mspp_contentsnippets)   value goes in mspp_value
  3. Site setting      (mspp_sitesettings)      value goes in mspp_value
  4. Web file          (mspp_webfiles)          + an annotation carrying the file bytes

Requires an EDM site that already has at least one site language, one default-flagged (or first)
publishing state, and one default-flagged (or first) page template - run
INSPECT powerplatform/inspect-powerpages-site first; it reports exactly these and the -SiteId to
pass here. Site creation itself is not attempted here: provisioning a Power Pages site is a portal
wizard, not a plain Dataverse Web API call (see that recipe's FAIL path for the manual steps).

  PASS         = web page, content snippet and site setting all created. Web file body attach
                 is opportunistic (documented as "if straightforward" by design) - its own
                 failure does not fail the run, only the web-file row it applies to.
  INCONCLUSIVE = some but not all of the three required artifacts were created.
  FAIL         = none were created, or the site/prerequisite lookup failed.
  BLOCKED      = config/prereqs missing (see Stop-LabRunBlocked output).

  .\lab.ps1 BUILD powerplatform/build-powerpages-edm-testset -SiteId <powerpagesiteid guid>
  .\lab.ps1 BUILD powerplatform/build-powerpages-edm-testset -SiteId <guid> -NoWebFile
  .\lab.ps1 BUILD powerplatform/build-powerpages-edm-testset -SiteId <guid> -DryRun
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$SiteId,
    [string]$SiteName,
    [string]$Prefix = 'BACKUP_EDM_TEST_20260828',
    [switch]$NoWebFile
)

$Recipe = @{
    Name        = 'powerplatform/build-powerpages-edm-testset'
    Product     = 'powerplatform'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Create a minimal, uniquely-prefixed web page + content snippet + site setting (+ web file) on an existing Enhanced Data Model Power Pages site, for backup validation. Nothing is deleted.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'pp-build-edm-testset' -Mode BUILD -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request "Create a minimal '$Prefix'-prefixed test dataset (web page, content snippet, site setting, web file) on an Enhanced Data Model Power Pages site, for validating a backup of that data model." `
    -Plan @(
    'Resolve and re-confirm the target site against the powerpagesite system table (EDM proof)'
    'Read its site language / default publishing state / default page template'
    "Create mspp_webpages '$Prefix`_Page' with the required body text in mspp_copy"
    "Create mspp_contentsnippets '$Prefix`_Snippet'"
    "Create mspp_sitesettings '$Prefix`_Setting'"
    $(if (-not $NoWebFile) { "Create mspp_webfiles '$Prefix`_File.txt' and attempt to attach its bytes via an annotation" })
    'Register every created record with Add-LabResource (tracked, NOT deleted) and print a validation table'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Add targets.dataverse-main (or pass -Target) with an environmentUrl to config/lab.config.json.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"
Add-LabEvidenceNote "prefix: $Prefix"

$resolved = Resolve-PPSite -Dv $dv -SiteId $SiteId -SiteName $SiteName
if (-not $resolved.Ok) {
    Stop-LabRunBlocked -Problems @($resolved.Reason) -NextStep 'Run INSPECT powerplatform/inspect-powerpages-site to find or confirm a site, then pass -SiteId.'
    return
}
$site = $resolved.Site
Add-LabEvidenceNote "site: '$($site.name)' ($($site.powerpagesiteid)) - confirmed EDM by presence in the powerpagesite system table; datamodelversion=$($site.datamodelversion)"

$langs = @(Get-PPSiteLanguages -Dv $dv -SiteId $site.powerpagesiteid)
$states = @(Get-PPPublishingStates -Dv $dv -SiteId $site.powerpagesiteid)
$templates = @(Get-PPPageTemplates -Dv $dv -SiteId $site.powerpagesiteid)
$lang = if ($langs.Count) { $langs[0] } else { $null }
$state = Get-PPDefault -Records $states -DefaultField 'mspp_isdefault'
$template = Get-PPDefault -Records $templates -DefaultField 'mspp_isdefault'

$missing = @()
if (-not $lang) { $missing += 'a powerpagesitelanguage' }
if (-not $state) { $missing += 'an mspp_publishingstate' }
if (-not $template) { $missing += 'an mspp_pagetemplate' }
if ($missing.Count) {
    Stop-LabRunBlocked -Problems @("site '$($site.name)' has no $($missing -join ', no ')") -NextStep 'Open the site once in the Power Pages design studio (it provisions these on first load), then re-run INSPECT powerplatform/inspect-powerpages-site.'
    return
}
Add-LabEvidenceNote "language='$($lang.name)' ($($lang.powerpagesitelanguageid)); publishingstate='$($state.mspp_name)' ($($state.mspp_publishingstateid)); pagetemplate='$($template.mspp_name)' ($($template.mspp_pagetemplateid))"

$now = (Get-Date).ToUniversalTime()
$outcome = [ordered]@{}
function Set-Outcome { param([string]$Key, [string]$State, [string]$Detail)
    $script:outcome[$Key] = [pscustomobject]@{ Key = $Key; State = $State; Detail = $Detail }
    Add-LabEvidenceNote ("{0,-16} {1,-9} {2}" -f $Key, $State, $Detail)
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-ResultRow { param($Type, $Name, $Table, $Id, $CreatedUtc)
    $results.Add([pscustomobject]@{
        ArtifactType = $Type; DisplayName = $Name; Table = $Table; RecordGuid = $Id
        ParentSiteGuid = $site.powerpagesiteid; CreatedUtc = $CreatedUtc
    }) | Out-Null
}

# Re-running this recipe (e.g. after an earlier partial failure) must not create duplicate
# components with the same name - look each one up by name, scoped to the site, before creating.
function Find-PPExisting {
    param([string]$EntitySet, [string]$IdAttr, [string]$Name)
    $r = Get-DvRecords -Dv $dv -Query "$EntitySet`?`$select=$IdAttr,mspp_createdon&`$filter=mspp_name eq '$Name' and _mspp_websiteid_value eq $($site.powerpagesiteid)" -Label "pp-find-$EntitySet" -NoEvidence
    if ($r.Ok -and $r.Records.Count) { return $r.Records[0] }
    return $null
}

# Sections 1-4 below all follow the same shape: look up an existing component by name (never
# duplicate one), else create it and record the outcome. Factored out once here rather than
# repeated four times with only the entity set / body / labels differing.
function New-PPComponentIfMissing {
    param(
        [string]$EntitySet, [string]$IdAttr, [string]$Name, [string]$OutcomeKey,
        [string]$ArtifactType, [string]$TableLabel, [string]$ResourceRole,
        [hashtable]$Body, [string]$CreateLabel, [string]$CreatedDetail = ''
    )
    $existing = Find-PPExisting -EntitySet $EntitySet -IdAttr $IdAttr -Name $Name
    if ($existing) {
        $id = $existing.$IdAttr
        Set-Outcome $OutcomeKey 'EXISTS' "id=$id name='$Name' (already existed from an earlier run - not duplicated)"
        Add-ResultRow -Type $ArtifactType -Name $Name -Table $TableLabel -Id $id -CreatedUtc $existing.mspp_createdon
        return $id
    }
    $r = New-DvRecord -Dv $dv -EntitySet $EntitySet -Body $Body -Label $CreateLabel
    if ($r.Ok) {
        $id = Get-DvRecordId -Response $r -IdAttribute $IdAttr
        Set-Outcome $OutcomeKey 'CREATED' ("id=$id name='$Name'" + $(if ($CreatedDetail) { " $CreatedDetail" } else { '' }))
        Add-LabResource -Type 'dataverse-record' -Id $id -Name $Name -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/$EntitySet($id)" -Extra @{ role = $ResourceRole; siteId = $site.powerpagesiteid } | Out-Null
        Add-ResultRow -Type $ArtifactType -Name $Name -Table $TableLabel -Id $id -CreatedUtc $now.ToString('o')
        return $id
    }
    if ($r.DryRun) { Set-Outcome $OutcomeKey 'DRYRUN' 'skipped by -DryRun'; return $null }
    Set-Outcome $OutcomeKey 'FAILED' "HTTP $($r.Status) code=$($r.Error.Code) $($r.Error.Message)"
    return $null
}

# --- 1. Web page --------------------------------------------------------------
#
# Dataverse enforces that the FIRST webpage on a site becomes its home page and must sit at
# partial URL '/' - a brand-new blank site has no home page yet, so a create at any other
# partial URL is rejected (HTTP 400 0x80040265). If the site has no root page, provision one
# first (tracked like any other resource, never deleted) and hang the requested page off it.

Write-LabStep 'checking for an existing home (root) page'
$existingPages = @(Get-DvRecords -Dv $dv -Query "mspp_webpages?`$select=mspp_webpageid,mspp_isroot,mspp_partialurl&`$filter=_mspp_websiteid_value eq $($site.powerpagesiteid)" -Label 'pp-existing-webpages').Records
$rootPage = @($existingPages | Where-Object { $_.mspp_isroot -eq $true }) | Select-Object -First 1
$parentPageId = $null

if ($rootPage) {
    $parentPageId = $rootPage.mspp_webpageid
    Add-LabEvidenceNote "home page already exists ($parentPageId) - new page will be its child"
}
else {
    Write-LabStep 'no home page exists yet - provisioning one at partial URL / first'
    $homeName = "${Prefix}_Home"
    $homeBody = @{
        mspp_name                    = $homeName
        mspp_partialurl               = '/'
        mspp_isroot                   = $true
        mspp_sharedpageconfiguration  = $true
        mspp_hiddenfromsitemap        = $false
        'mspp_websiteid@odata.bind'         = "/mspp_websites($($site.powerpagesiteid))"
        'mspp_webpagelanguageid@odata.bind' = "/mspp_websitelanguages($($lang.powerpagesitelanguageid))"
        'mspp_publishingstateid@odata.bind' = "/mspp_publishingstates($($state.mspp_publishingstateid))"
        'mspp_pagetemplateid@odata.bind'    = "/mspp_pagetemplates($($template.mspp_pagetemplateid))"
    }
    $rh = New-DvRecord -Dv $dv -EntitySet 'mspp_webpages' -Body $homeBody -Label 'create-home-webpage'
    if ($rh.Ok) {
        $parentPageId = Get-DvRecordId -Response $rh -IdAttribute 'mspp_webpageid'
        Set-Outcome 'home-page' 'CREATED' "id=$parentPageId name='$homeName' (required prerequisite - the site had no home page)"
        Add-LabResource -Type 'dataverse-record' -Id $parentPageId -Name $homeName -Target $tgt._name -Api 'dataverse' `
            -DeleteUri "$($dv.Api)/mspp_webpages($parentPageId)" -Extra @{ role = 'powerpages-webpage-home'; siteId = $site.powerpagesiteid } | Out-Null
        Add-ResultRow -Type 'Web page (home, prerequisite)' -Name $homeName -Table 'powerpagecomponent (virtual: mspp_webpage)' -Id $parentPageId -CreatedUtc $now.ToString('o')
    }
    elseif ($rh.DryRun) { Set-Outcome 'home-page' 'DRYRUN' 'skipped by -DryRun' }
    else { Set-Outcome 'home-page' 'FAILED' "HTTP $($rh.Status) code=$($rh.Error.Code) $($rh.Error.Message)" }
}

Write-LabStep 'web page'
$pageName = "${Prefix}_Page"
$pageBody = @{
    mspp_name                     = $pageName
    mspp_partialurl                = 'backup-edm-test-20260828'
    mspp_copy                      = "<p>BACKUP_EDM_TEST_20260828_PAGE_CONTENT</p>"
    mspp_isroot                    = $false
    mspp_sharedpageconfiguration   = $true
    mspp_hiddenfromsitemap         = $false
    'mspp_websiteid@odata.bind'         = "/mspp_websites($($site.powerpagesiteid))"
    'mspp_webpagelanguageid@odata.bind' = "/mspp_websitelanguages($($lang.powerpagesitelanguageid))"
    'mspp_publishingstateid@odata.bind' = "/mspp_publishingstates($($state.mspp_publishingstateid))"
    'mspp_pagetemplateid@odata.bind'    = "/mspp_pagetemplates($($template.mspp_pagetemplateid))"
}
if ($parentPageId) { $pageBody['mspp_parentpageid@odata.bind'] = "/mspp_webpages($parentPageId)" }
$pageId = New-PPComponentIfMissing -EntitySet 'mspp_webpages' -IdAttr 'mspp_webpageid' -Name $pageName `
    -OutcomeKey 'webpage' -ArtifactType 'Web page' -TableLabel 'powerpagecomponent (virtual: mspp_webpage)' `
    -ResourceRole 'powerpages-webpage' -Body $pageBody -CreateLabel 'create-webpage' -CreatedDetail 'partialurl=backup-edm-test-20260828'

# --- 2. Content snippet --------------------------------------------------------

Write-LabStep 'content snippet'
$snippetName = "${Prefix}_Snippet"
$snippetId = New-PPComponentIfMissing -EntitySet 'mspp_contentsnippets' -IdAttr 'mspp_contentsnippetid' -Name $snippetName `
    -OutcomeKey 'snippet' -ArtifactType 'Content snippet' -TableLabel 'powerpagecomponent (virtual: mspp_contentsnippet)' `
    -ResourceRole 'powerpages-contentsnippet' -CreateLabel 'create-contentsnippet' -Body @{
        mspp_name    = $snippetName
        mspp_value   = 'BACKUP_EDM_TEST_20260828_SNIPPET_CONTENT'
        mspp_type    = 756150000   # Text
        'mspp_websiteid@odata.bind' = "/mspp_websites($($site.powerpagesiteid))"
    }

# --- 3. Site setting ------------------------------------------------------------

Write-LabStep 'site setting'
$settingName = "${Prefix}_Setting"
$settingId = New-PPComponentIfMissing -EntitySet 'mspp_sitesettings' -IdAttr 'mspp_sitesettingid' -Name $settingName `
    -OutcomeKey 'setting' -ArtifactType 'Site setting' -TableLabel 'powerpagecomponent (virtual: mspp_sitesetting)' `
    -ResourceRole 'powerpages-sitesetting' -CreateLabel 'create-sitesetting' -Body @{
        mspp_name    = $settingName
        mspp_value   = 'BACKUP_EDM_TEST_20260828_SETTING_VALUE'
        mspp_source  = 0   # Table
        'mspp_websiteid@odata.bind' = "/mspp_websites($($site.powerpagesiteid))"
    }

# --- 4. Web file (opportunistic body attach) ------------------------------------
#
# mspp_webfile carries only metadata (name, partial url, ...); unlike powerpagessourcefile it has
# no writable 'filecontent' column of its own in the Web API metadata, so the byte payload is
# attempted as a Dataverse annotation (note) pointed at the new webfile row via the standard
# polymorphic objectid_<table>@odata.bind pattern. This is the "if straightforward" part of the
# request: if the annotation attach fails, the webfile row itself still stands and the run is
# not failed for it - only that one step is marked INCONCLUSIVE in the evidence.

if (-not $NoWebFile) {
    Write-LabStep 'web file'
    $fileName = "${Prefix}_File.txt"
    $fileId = New-PPComponentIfMissing -EntitySet 'mspp_webfiles' -IdAttr 'mspp_webfileid' -Name $fileName `
        -OutcomeKey 'webfile' -ArtifactType 'Web file' -TableLabel 'powerpagecomponent (virtual: mspp_webfile)' `
        -ResourceRole 'powerpages-webfile' -CreateLabel 'create-webfile' -CreatedDetail '(metadata only - see webfile-content below)' -Body @{
            mspp_name       = $fileName
            mspp_partialurl = 'backup-edm-test-20260828-file.txt'
            'mspp_websiteid@odata.bind'        = "/mspp_websites($($site.powerpagesiteid))"
            'mspp_publishingstateid@odata.bind' = "/mspp_publishingstates($($state.mspp_publishingstateid))"
        }

    # mspp_webfile is a virtual projection over powerpagecomponent and does not expose a
    # 'HasNotes' relationship the way standard tables do, so annotations cannot attach to it -
    # the OData service reports the bind property as undeclared rather than a payload mistake.
    # Confirmed against this live environment; left in as a documented, non-fatal attempt so a
    # platform change (or a different site) can succeed without code changes.
    if ($fileId) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('BACKUP_EDM_TEST_20260828_FILE_CONTENT')
        $noteBody = @{
            subject      = $fileName
            filename     = $fileName
            mimetype     = 'text/plain'
            documentbody = [Convert]::ToBase64String($bytes)
            'objectid_mspp_webfile@odata.bind' = "/mspp_webfiles($fileId)"
        }
        $rn = New-DvRecord -Dv $dv -EntitySet 'annotations' -Body $noteBody -Label 'attach-webfile-content'
        if ($rn.Ok) {
            $noteId = Get-DvRecordId -Response $rn -IdAttribute 'annotationid'
            Set-Outcome 'webfile-content' 'ATTACHED' "annotation id=$noteId carries the file bytes"
            Add-LabResource -Type 'dataverse-record' -Id $noteId -Name "$fileName-annotation" -Target $tgt._name -Api 'dataverse' `
                -DeleteUri "$($dv.Api)/annotations($noteId)" -Extra @{ role = 'powerpages-webfile-annotation'; webfileId = $fileId } | Out-Null
        }
        elseif ($rn.DryRun) { Set-Outcome 'webfile-content' 'DRYRUN' 'skipped by -DryRun' }
        else { Set-Outcome 'webfile-content' 'NOT-SUPPORTED' "mspp_webfile does not accept an attached annotation in this environment: HTTP $($rn.Status) code=$($rn.Error.Code) - not fatal to the run; the web file row itself exists with metadata only" }
    }
}

# --- validation table + summary -------------------------------------------------

Save-LabEvidence -Kind response -Name 'validation-table' -Content $results | Out-Null

Write-Host ''
Write-Host ('  {0,-16} {1,-32} {2,-42} {3,-38} {4}' -f 'TYPE', 'NAME', 'TABLE', 'RECORD GUID', 'CREATED (UTC)')
Write-Host ('  ' + ('-' * 160))
foreach ($row in $results) {
    Write-Host ('  {0,-16} {1,-32} {2,-42} {3,-38} {4}' -f $row.ArtifactType, $row.DisplayName, $row.Table, $row.RecordGuid, $row.CreatedUtc)
}
if ($results.Count) { Write-Host ''; Write-Host "  Parent Power Pages site GUID (all rows): $($site.powerpagesiteid)" }

$required = @('webpage', 'snippet', 'setting')
$requiredOk = @($required | Where-Object { $outcome[$_] -and $outcome[$_].State -in 'CREATED', 'EXISTS' })
$failed = @($outcome.Values | Where-Object { $_.State -eq 'FAILED' })
$ev = @($outcome.Values | ForEach-Object { "$($_.Key): $($_.State) - $($_.Detail)" })

if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary "Dry run: nothing was created. Would create a web page, content snippet and site setting$(if (-not $NoWebFile) { ', plus a web file' }) prefixed '$Prefix' on site '$($site.name)'." -Evidence $ev | Out-Null
}
elseif ($requiredOk.Count -eq $required.Count) {
    Complete-LabRun -Verdict PASS -Summary "Created the '$Prefix' test dataset on site '$($site.name)' ($($site.powerpagesiteid)). Nothing was deleted - back this environment up now." -Evidence $ev | Out-Null
}
elseif ($requiredOk.Count -gt 0) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Only $($requiredOk.Count)/$($required.Count) required artifacts were created on site '$($site.name)'. See evidence for the Microsoft error on the failed one(s)." -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary "Nothing could be created on site '$($site.name)'." -Evidence $ev | Out-Null
}
