# Dv.PowerPages.ps1 - Enhanced Data Model (EDM) site discovery for Power Pages.
#
# EDM stores each site as one 'powerpagesite' system-table row (this is itself the presence
# test for EDM - a standard-model site has no powerpagesite row, only 'adx_website'). Page/
# content-snippet/site-setting/web-file components are virtual tables (mspp_*) backed by the
# 'powerpagecomponent' system table; site, site language and source files are virtual/system
# tables in their own right. See docs/... (Microsoft Learn "Power Pages enhanced data model")
# for the full system/virtual table map - this file only wraps the handful of read paths two
# recipes (inspect-powerpages-site, build-powerpages-edm-testset) both need.

function Get-PPSites {
    param($Dv)
    $r = Get-DvRecords -Dv $Dv -Query "powerpagesites?`$select=powerpagesiteid,name,datamodelversion,powerpagesitetype,primarydomainname,statecode" -Label 'pp-sites'
    if (-not $r.Ok) { return @() }
    @($r.Records)
}

# Standard-model sites, for contrast only - never written to. Some environments never install
# the legacy adx_website table at all, so a failed lookup here just means "none / not present".
function Get-PPStandardSites {
    param($Dv)
    $r = Get-DvRecords -Dv $Dv -Query "adx_websites?`$select=adx_websiteid,adx_name" -Label 'pp-standard-sites' -NoEvidence
    if (-not $r.Ok) { return @() }
    @($r.Records)
}

# Resolves exactly one EDM site to act against. Never guesses across multiple candidates -
# ambiguity is returned for the caller to surface, not silently picked for.
function Resolve-PPSite {
    param($Dv, [string]$SiteId, [string]$SiteName)
    $sites = @(Get-PPSites -Dv $Dv)
    if ($SiteId) {
        $m = @($sites | Where-Object { $_.powerpagesiteid -eq $SiteId })
        if ($m.Count -eq 1) { return [pscustomobject]@{ Ok = $true; Site = $m[0]; Candidates = $sites; Reason = $null } }
        return [pscustomobject]@{ Ok = $false; Site = $null; Candidates = $sites; Reason = "no EDM site with powerpagesiteid '$SiteId'" }
    }
    if ($SiteName) {
        $m = @($sites | Where-Object { $_.name -like "*$SiteName*" -or $_.primarydomainname -like "*$SiteName*" })
        if ($m.Count -eq 1) { return [pscustomobject]@{ Ok = $true; Site = $m[0]; Candidates = $sites; Reason = $null } }
        if ($m.Count -gt 1) { return [pscustomobject]@{ Ok = $false; Site = $null; Candidates = $m; Reason = "'$SiteName' matches $($m.Count) EDM sites - pass -SiteId to disambiguate" } }
        return [pscustomobject]@{ Ok = $false; Site = $null; Candidates = $sites; Reason = "no EDM site matches '$SiteName'" }
    }
    if ($sites.Count -eq 1) { return [pscustomobject]@{ Ok = $true; Site = $sites[0]; Candidates = $sites; Reason = $null } }
    if ($sites.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Site = $null; Candidates = @(); Reason = 'no Power Pages sites on the Enhanced Data Model exist in this environment' } }
    return [pscustomobject]@{ Ok = $false; Site = $null; Candidates = $sites; Reason = "$($sites.Count) EDM sites exist - pass -SiteId or -SiteName to pick one" }
}

function Get-PPSiteLanguages {
    param($Dv, [Parameter(Mandatory)][string]$SiteId)
    $r = Get-DvRecords -Dv $Dv -Query "powerpagesitelanguages?`$select=powerpagesitelanguageid,name,languagecode,lcid&`$filter=_powerpagesiteid_value eq $SiteId" -Label 'pp-site-languages'
    if (-not $r.Ok) { return @() }
    @($r.Records)
}

function Get-PPPublishingStates {
    param($Dv, [Parameter(Mandatory)][string]$SiteId)
    $r = Get-DvRecords -Dv $Dv -Query "mspp_publishingstates?`$select=mspp_publishingstateid,mspp_name,mspp_isdefault,mspp_isvisible&`$filter=_mspp_websiteid_value eq $SiteId" -Label 'pp-publishingstates'
    if (-not $r.Ok) { return @() }
    @($r.Records)
}

function Get-PPPageTemplates {
    param($Dv, [Parameter(Mandatory)][string]$SiteId)
    $r = Get-DvRecords -Dv $Dv -Query "mspp_pagetemplates?`$select=mspp_pagetemplateid,mspp_name,mspp_isdefault,mspp_type&`$filter=_mspp_websiteid_value eq $SiteId" -Label 'pp-pagetemplates'
    if (-not $r.Ok) { return @() }
    @($r.Records)
}

# Picks the record flagged as default; falls back to the first one so callers still get a
# usable id when a site (unusually) has no default flagged.
function Get-PPDefault {
    param([object[]]$Records, [string]$DefaultField)
    if (-not $Records -or $Records.Count -eq 0) { return $null }
    $d = @($Records | Where-Object { $_.$DefaultField -eq $true }) | Select-Object -First 1
    if ($d) { return $d }
    $Records[0]
}
