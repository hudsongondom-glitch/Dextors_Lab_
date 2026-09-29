<#
Read-only discovery for a Power Pages test site on the Enhanced Data Model (EDM).

EDM sites live in the 'powerpagesite' system table; a standard-model site never appears there
(it lives in 'adx_website' instead), so the presence of a powerpagesite row IS the EDM proof -
see docs/... (Microsoft Learn "Power Pages enhanced data model", the system/virtual table map).
This recipe resolves one target site, confirms it against that table, and enumerates the
per-site prerequisite records (site language, publishing state, page template) that
build-powerpages-edm-testset needs to create a web page. It creates and changes nothing.

  PASS         = an EDM site was resolved and it has all three prerequisite record types.
  INCONCLUSIVE = an EDM site was resolved but is missing a prerequisite, or -SiteId/-SiteName
                 matched none/multiple and needs disambiguation.
  FAIL         = no Power Pages site on the Enhanced Data Model exists in this environment at
                 all - creating one is a manual Power Pages home page action (see summary).

  .\lab.ps1 INSPECT powerplatform/inspect-powerpages-site
  .\lab.ps1 INSPECT powerplatform/inspect-powerpages-site -SiteName Test
  .\lab.ps1 INSPECT powerplatform/inspect-powerpages-site -SiteId <powerpagesiteid guid>
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target = 'dataverse-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [string]$SiteId,
    [string]$SiteName
)

$Recipe = @{
    Name        = 'powerplatform/inspect-powerpages-site'
    Product     = 'powerplatform'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Resolve a Power Pages EDM site, confirm it against the powerpagesite system table, and enumerate its site language / publishing state / page template prerequisites.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('environmentUrl')
$run = Start-LabRun -Name 'pp-inspect-site' -Mode INSPECT -Product powerplatform -Target $Target -DryRun:$DryRun `
    -Request 'Find a Power Pages test site, confirm it is on the Enhanced Data Model, and read the records a new web page must bind to.' `
    -Plan @(
    'Query powerpagesites (EDM system table) and adx_websites (standard model, contrast only)'
    'Resolve exactly one target site (by -SiteId, -SiteName, or the sole EDM site found)'
    'Enumerate powerpagesitelanguages / mspp_publishingstates / mspp_pagetemplates scoped to that site'
    'Report the default of each, ready for build-powerpages-edm-testset'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Add targets.dataverse-main (or pass -Target) with an environmentUrl to config/lab.config.json.'; return }

$tgt = Get-LabTarget -Name $Target
$dv = Get-DvContext -Target $tgt -Identity $Identity
Add-LabEvidenceNote "environment: $($dv.Base)"

Write-LabStep 'enumerating EDM and standard-model sites'
$edmSites = @(Get-PPSites -Dv $dv)
$stdSites = @(Get-PPStandardSites -Dv $dv)
Add-LabEvidenceNote "$($edmSites.Count) EDM site(s) [powerpagesite], $($stdSites.Count) standard-model site(s) [adx_website]"
foreach ($s in $edmSites) { Write-Host ("    EDM      {0,-38} datamodelversion={1} type={2} domain={3}" -f $s.name, $s.datamodelversion, $s.powerpagesitetype, $s.primarydomainname) }
foreach ($s in $stdSites) { Write-Host ("    standard {0}" -f $s.adx_name) }

$resolved = Resolve-PPSite -Dv $dv -SiteId $SiteId -SiteName $SiteName
if (-not $resolved.Ok) {
    if ($edmSites.Count -eq 0) {
        Complete-LabRun -Verdict FAIL -Summary 'No Power Pages site on the Enhanced Data Model exists in this environment.' -Evidence @(
            $resolved.Reason
            'Site creation is not a plain Dataverse Web API call - it goes through Power Pages provisioning.'
            'Manual step: open https://make.powerpages.microsoft.com , select this environment, "Create a site", pick a template that supports EDM (e.g. "Blank page" - see docs/... "Supported templates"), finish the wizard.'
            'Then re-run this recipe (optionally with -SiteName) to pick it up.'
        ) | Out-Null
    }
    else {
        Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not resolve a single target site: $($resolved.Reason)" -Evidence (@($resolved.Candidates | ForEach-Object { "candidate: $($_.name) ($($_.powerpagesiteid))" })) | Out-Null
    }
    return
}

$site = $resolved.Site
Add-LabEvidenceNote "resolved site: '$($site.name)' ($($site.powerpagesiteid)) datamodelversion=$($site.datamodelversion) type=$($site.powerpagesitetype)"
Write-Host ''
Write-Host "  Site: $($site.name)" -ForegroundColor Cyan
Write-Host "  powerpagesiteid: $($site.powerpagesiteid)"
Write-Host "  Data model: Enhanced (confirmed by presence of this row in the powerpagesite system table)"
Write-Host "  datamodelversion attribute: $($site.datamodelversion)"

Write-LabStep 'enumerating site languages / publishing states / page templates'
$langs = @(Get-PPSiteLanguages -Dv $dv -SiteId $site.powerpagesiteid)
$states = @(Get-PPPublishingStates -Dv $dv -SiteId $site.powerpagesiteid)
$templates = @(Get-PPPageTemplates -Dv $dv -SiteId $site.powerpagesiteid)

Write-Host ''
Write-Host '  Site languages (powerpagesitelanguage):'
foreach ($l in $langs) { Write-Host ("    {0}  {1}  languagecode={2} lcid={3}" -f $l.powerpagesitelanguageid, $l.name, $l.languagecode, $l.lcid) }
Write-Host '  Publishing states (mspp_publishingstate):'
foreach ($p in $states) { Write-Host ("    {0}  {1}  isdefault={2}" -f $p.mspp_publishingstateid, $p.mspp_name, $p.mspp_isdefault) }
Write-Host '  Page templates (mspp_pagetemplate):'
foreach ($t in $templates) { Write-Host ("    {0}  {1}  isdefault={2} type={3}" -f $t.mspp_pagetemplateid, $t.mspp_name, $t.mspp_isdefault, $t.mspp_type) }

# Site language has no isdefault flag; the first (usually the only) one is the working choice.
$defLang = if ($langs.Count) { $langs[0] } else { $null }
$defState = Get-PPDefault -Records $states -DefaultField 'mspp_isdefault'
$defTemplate = Get-PPDefault -Records $templates -DefaultField 'mspp_isdefault'

Add-LabEvidenceNote "$($langs.Count) site language(s), default candidate: $(if ($defLang) { "$($defLang.name) ($($defLang.powerpagesitelanguageid))" } else { 'NONE' })"
Add-LabEvidenceNote "$($states.Count) publishing state(s), default candidate: $(if ($defState) { "$($defState.mspp_name) ($($defState.mspp_publishingstateid))" } else { 'NONE' })"
Add-LabEvidenceNote "$($templates.Count) page template(s), default candidate: $(if ($defTemplate) { "$($defTemplate.mspp_name) ($($defTemplate.mspp_pagetemplateid))" } else { 'NONE' })"

$ready = $defLang -and $defState -and $defTemplate
if ($ready) {
    Complete-LabRun -Verdict PASS -Summary "Site '$($site.name)' is on the Enhanced Data Model and has everything build-powerpages-edm-testset needs. Run: .\lab.ps1 BUILD powerplatform/build-powerpages-edm-testset -SiteId $($site.powerpagesiteid)" | Out-Null
}
else {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Site '$($site.name)' is on the Enhanced Data Model but is missing a prerequisite record (see evidence) - build-powerpages-edm-testset cannot create a web page without a language, publishing state and page template already present." | Out-Null
}
