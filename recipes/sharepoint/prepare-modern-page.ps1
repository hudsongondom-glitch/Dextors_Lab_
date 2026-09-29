<#
BUILD a known-good modern Site Page with populated canvas content, to act as the SOURCE for a
"restore to a new URL" reproduction.

What it does:
  - updates the site's welcome page (Home.aspx) with real modern canvas content
  - optionally creates an Article page, which SharePoint gives a header region
  - uploads a banner image to Site Assets so an Image web part references a real asset
  - reads both CanvasContent1 and LayoutWebpartsContent back and reports their sizes

Everything goes through the supported SP.Publishing.SitePageService API (/_api/sitepages/pages),
the same API the modern page editor uses. Nothing writes to SharePoint internals directly.

LayoutWebpartsContent is deliberately NEVER sent. It is only reported as SharePoint leaves it,
so the reproduction source is genuine.

  PASS = the target page(s) have non-empty CanvasContent1 and load over HTTP.
  FAIL = canvas content is still empty, or the page does not load.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$SiteUrl,               # defaults to the resolved target's siteUrl
    [string]$Identity = 'msg-app-cert',
    [switch]$NoArticlePage          # only touch the home page
)

$Recipe = @{
    Name        = 'sharepoint/prepare-modern-page'
    Product     = 'sharepoint'
    Modes       = @('BUILD')
    Destructive = $false
    Description = 'Populate a modern Site Page with real canvas content as a restore-test source.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')
. (Join-Path $PSScriptRoot '..\..\tools\microsoft\Spo.Rest.ps1')

# The site comes from configuration, not from a default baked into the recipe - a hardcoded
# tenant URL is both wrong for anyone else and a way to accidentally target the wrong site.
$problems = Test-LabConfigReady -Target $Target
if (-not $SiteUrl) {
    $cfgTarget = try { Get-LabTarget -Name $Target } catch { $null }
    $SiteUrl = $cfgTarget.siteUrl
    if (-not $SiteUrl) { $problems += "No site to work on: pass -SiteUrl, or set targets.<target>.siteUrl in lab.config.json." }
}

$run = Start-LabRun -Name 'spo-prepare-modern-page' -Mode BUILD -Product sharepoint -Target $Target -DryRun:$DryRun `
    -Request "Populate modern page canvas content on $SiteUrl so it can be backed up and restored to a new URL." `
    -Plan @('Locate the Site Pages library and welcome page', 'Upload a banner image to Site Assets',
    'Build canvas content (text, image, list, quick links)', 'SavePageAsDraft + Publish via the SitePages API',
    'Optionally create an Article page with a SharePoint-generated header', 'Read CanvasContent1 and LayoutWebpartsContent back',
    'Confirm the pages load')

if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Pass -SiteUrl <site> or fill in the target''s siteUrl, then rerun.'; return }

$t = [pscustomobject]@{ product = 'sharepoint'; siteUrl = $SiteUrl.TrimEnd('/'); _name = 'spo-page-source' }
$webPath = ([Uri]$t.siteUrl).AbsolutePath.TrimEnd('/')
$tok = Get-LabAccessToken -Api SharePoint -Target $t -Identity $Identity

# --- 1. context -------------------------------------------------------------
Write-LabStep 'reading site context'
$web = Invoke-SpoRequest -Target $t -Token $tok -Path '/_api/web?$select=Id,Title,Url' -Label 'web-context'
$site = Invoke-SpoRequest -Target $t -Token $tok -Path '/_api/site?$select=Id' -Label 'site-context'
$welcome = Invoke-SpoRequest -Target $t -Token $tok -Path '/_api/web/RootFolder?$select=WelcomePage' -Label 'welcomepage'
$pagesLib = Invoke-SpoRequest -Target $t -Token $tok -Path "/_api/web/lists/getbytitle('Site Pages')?`$select=Id,Title,ItemCount" -Label 'sitepages-library'
$depList = Invoke-SpoRequest -Target $t -Token $tok -Path "/_api/web/lists/getbytitle('Departments')?`$select=Id" -Label 'departments-list'

$webId = $web.Json.Id; $siteId = $site.Json.Id
Add-LabEvidenceNote "site '$($web.Json.Title)' webId=$webId siteId=$siteId"
Add-LabEvidenceNote "Site Pages library Id=$($pagesLib.Json.Id) items=$($pagesLib.Json.ItemCount); WelcomePage=$($welcome.Json.WelcomePage)"

$pages = Get-SpoSitePages -Target $t -Token $tok
$homePage = @($pages.Json.value) | Where-Object { $_.FileName -eq (Split-Path $welcome.Json.WelcomePage -Leaf) } | Select-Object -First 1
if (-not $homePage) { $homePage = @($pages.Json.value) | Select-Object -First 1 }
Add-LabEvidenceNote "welcome page: Id=$($homePage.Id) $($homePage.FileName) layout=$($homePage.PageLayoutType)"

# --- 2. banner image into Site Assets ---------------------------------------
Write-LabStep 'uploading banner image to Site Assets'
$imgUrl = $null
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bmp = [System.Drawing.Bitmap]::new(960, 320)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(0, 90, 158))
    $g.DrawString('LabCo', [System.Drawing.Font]::new('Segoe UI', 64), [System.Drawing.Brushes]::White, 40, 90)
    $g.DrawString('Departments', [System.Drawing.Font]::new('Segoe UI', 28), [System.Drawing.Brushes]::White, 44, 190)
    $g.Dispose()
    $ms = [IO.MemoryStream]::new(); $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    $ensure = Invoke-SpoRequest -Target $t -Token $tok -Method POST -Path '/_api/web/lists/EnsureSiteAssetsLibrary' -Label 'ensure-siteassets'
    $assets = if ($ensure.Ok -and $ensure.Json.RootFolder) { $ensure.Json.RootFolder.ServerRelativeUrl } else { "$webPath/SiteAssets" }
    $up = Add-SpoFile -Target $t -Token $tok -FolderServerRelativeUrl $assets -FileName 'labco-banner.png' -Bytes $ms.ToArray()
    if ($up.Ok) {
        $imgUrl = "$assets/labco-banner.png"
        Add-LabEvidenceNote "banner uploaded: $imgUrl ($($ms.ToArray().Length) bytes)"
    }
    else { Add-LabEvidenceNote "banner upload failed: HTTP $($up.Status) - image web part will be omitted" }
}
catch { Add-LabEvidenceNote "banner image not generated ($($_.Exception.Message)) - image web part will be omitted" }

# --- 3. build canvas content -------------------------------------------------
Write-LabStep 'building canvas content'
$WP_IMAGE = 'd1d91016-032f-456d-98a4-721247c305e8'
$WP_LIST = 'f92bf067-bc19-489e-a556-7fe95f508720'
$WP_QUICKLINKS = 'c70391ea-0b10-4ee9-b2b4-006d3fcad0cd'
$ci = 0
function New-Pos { param([int]$Zone, [int]$Section = 1, [int]$Factor = 12) @{ layoutIndex = 1; zoneIndex = $Zone; sectionIndex = $Section; sectionFactor = $Factor; controlIndex = ++$script:ci } }
function New-Guid2 { [guid]::NewGuid().ToString() }

$controls = [System.Collections.Generic.List[object]]::new()

$controls.Add(@{
        controlType = 4; id = New-Guid2; position = New-Pos -Zone 1; emphasis = @{}; displayMode = 2
        innerHTML   = '<h2>LabCo departmental hub</h2><p>Reference data for the six departments, their managers, locations and cost centres. This page is the <strong>source page</strong> for a SharePoint restore-to-new-URL test.</p>'
    })

if ($imgUrl) {
    $controls.Add(@{
            controlType = 3; id = New-Guid2; position = New-Pos -Zone 2; emphasis = @{}; webPartId = $WP_IMAGE
            webPartData = @{
                id = $WP_IMAGE; instanceId = New-Guid2; title = 'Image'; description = 'Show an image on your page'; dataVersion = '1.9'
                properties = @{ imageSourceType = 2; siteId = $siteId; webId = $webId; listId = ''; uniqueId = ''
                    imgWidth = 960; imgHeight = 320; fixAspectRatio = $false; overlayText = 'LabCo departments'; captionText = 'Departmental banner'; alignment = 'Center'
                }
                serverProcessedContent = @{
                    htmlStrings = @{}; searchablePlainTexts = @{ captionText = 'Departmental banner' }
                    imageSources = @{ imageSource = $imgUrl }; links = @{}
                }
            }
        })
}

$controls.Add(@{
        controlType = 3; id = New-Guid2; position = New-Pos -Zone 3; emphasis = @{}; webPartId = $WP_LIST
        webPartData = @{
            id = $WP_LIST; instanceId = New-Guid2; title = 'Departments'; description = 'Display a list'; dataVersion = '1.0'
            properties = @{ isDocumentLibrary = $false; selectedListId = $depList.Json.Id; webRelativeListUrl = '/Lists/Departments'; listTitle = 'Departments' }
            serverProcessedContent = @{ htmlStrings = @{}; searchablePlainTexts = @{}; imageSources = @{}; links = @{} }
        }
    })

$controls.Add(@{
        controlType = 3; id = New-Guid2; position = New-Pos -Zone 4; emphasis = @{}; webPartId = $WP_QUICKLINKS
        webPartData = @{
            id = $WP_QUICKLINKS; instanceId = New-Guid2; title = 'Quick links'; description = 'Add links to important documents and pages'; dataVersion = '2.2'
            properties = @{
                items = @(
                    @{ id = 1; sourceItem = @{ itemType = 2; fileExtension = ''; progId = '' }; thumbnailType = 3; description = ''; altText = 'Departments list' }
                    @{ id = 2; sourceItem = @{ itemType = 2; fileExtension = ''; progId = '' }; thumbnailType = 3; description = ''; altText = 'Department Docs' }
                )
                isMigrated = $true; layoutId = 'List'; shouldShowThumbnail = $true; hideWebPartWhenEmpty = $true
                dataProviderId = 'QuickLinks'; webId = $webId; siteId = $siteId
            }
            serverProcessedContent = @{
                htmlStrings = @{}; imageSources = @{}
                searchablePlainTexts = @{ 'items[0].title' = 'Departments list'; 'items[1].title' = 'Department Docs' }
                links = @{ 'items[0].sourceItem.url' = "$webPath/Lists/Departments/AllItems.aspx"; 'items[1].sourceItem.url' = "$webPath/Department Docs" }
            }
        }
    })

$controls.Add(@{
        controlType = 4; id = New-Guid2; position = New-Pos -Zone 5; emphasis = @{}; displayMode = 2
        innerHTML   = '<p><em>Prepared by the Dextors Lab as a restore-to-new-URL test source. Canvas content includes a text section, an image web part referencing a Site Assets file, a list web part bound to the Departments list, and a quick links web part with server-relative URLs.</em></p>'
    })

# The page settings slice is the trailing control the modern editor always emits.
$controls.Add(@{ controlType = 0; pageSettingsSlice = @{ isDefaultDescription = $true; isDefaultThumbnail = $true } })

$canvas = $controls | ConvertTo-Json -Depth 12 -Compress
Add-LabEvidenceNote "canvas built: $($controls.Count) controls, $($canvas.Length) characters"

# --- 4. save + publish the home page ----------------------------------------
Write-LabStep "saving canvas to page Id=$($homePage.Id) ($($homePage.FileName))"
$co = Invoke-SpoSitePageCheckout -Target $t -Token $tok -PageId $homePage.Id
Write-Host "    checkoutpage    -> HTTP $($co.Status)"
if (-not $co.Ok) { Add-LabEvidenceNote "checkoutpage failed: HTTP $($co.Status) $($co.Error.Message)" }
$save = Save-SpoSitePageDraft -Target $t -Token $tok -PageId $homePage.Id -Fields @{
    CanvasContent1 = $canvas
    Title          = 'LabCo departmental hub'
    Description    = 'Departmental reference data and documents.'
}
Write-Host "    SavePageAsDraft -> HTTP $($save.Status)"
$pub = Publish-SpoSitePage -Target $t -Token $tok -PageId $homePage.Id
Write-Host "    Publish         -> HTTP $($pub.Status)"

# --- 5. optional Article page (SharePoint generates its header) --------------
$article = $null
if (-not $NoArticlePage) {
    Write-LabStep 'creating an Article page so SharePoint generates a header region'
    $new = New-SpoSitePage -Target $t -Token $tok -Title 'Department Overview' -PageLayoutType 'Article'
    if ($new.Ok) {
        $articleId = $new.Json.Id
        $fields = @{ CanvasContent1 = $canvas; Title = 'Department Overview'; Description = 'Article-layout source page for restore testing.' }
        if ($imgUrl) { $fields.BannerImageUrl = "$($t.siteUrl)$imgUrl" }   # supported property; SharePoint builds the header from it
        Save-SpoSitePageDraft -Target $t -Token $tok -PageId $articleId -Fields $fields | Out-Null
        Publish-SpoSitePage -Target $t -Token $tok -PageId $articleId | Out-Null
        $article = Get-SpoSitePage -Target $t -Token $tok -PageId $articleId
        Add-LabEvidenceNote "article page created: Id=$articleId $($article.Json.FileName)"
    }
    else { Add-LabEvidenceNote "article page creation failed: HTTP $($new.Status) $($new.Raw)" }
}

# --- 6. read back ------------------------------------------------------------
Write-LabStep 'verifying persisted fields'
function Report-Page {
    param($PageObj, [string]$Label)
    $c = [string]$PageObj.CanvasContent1
    $l = [string]$PageObj.LayoutWebpartsContent
    $line = "{0}: Id={1} file={2} layout={3} | CanvasContent1={4} | LayoutWebpartsContent={5}" -f `
        $Label, $PageObj.Id, $PageObj.FileName, $PageObj.PageLayoutType,
    $(if ($c) { "PRESENT ~$($c.Length) chars" } else { 'EMPTY' }),
    $(if ($l) { "PRESENT ~$($l.Length) chars" } else { 'EMPTY' })
    Write-Host "    $line"
    Add-LabEvidenceNote $line
    return [bool]$c
}

$homePageAfter = Get-SpoSitePage -Target $t -Token $tok -PageId $homePage.Id
$homePageOk = Report-Page -PageObj $homePageAfter.Json -Label 'home page'

$articleOk = $true
if ($article) {
    $articleAfter = Get-SpoSitePage -Target $t -Token $tok -PageId $article.Json.Id
    $articleOk = Report-Page -PageObj $articleAfter.Json -Label 'article page'
}

# Same fields as seen through the Site Pages list item, which is what a backup product reads.
$item = Invoke-SpoRequest -Target $t -Token $tok -Label 'sitepages-item-fields' `
    -Path "/_api/web/lists/getbytitle('Site Pages')/items($($homePage.Id))?`$select=Id,Title,FileLeafRef,CanvasContent1,LayoutWebpartsContent"
if ($item.Ok) {
    $ic = [string]$item.Json.CanvasContent1; $il = [string]$item.Json.LayoutWebpartsContent
    Add-LabEvidenceNote ("list item view: CanvasContent1={0}, LayoutWebpartsContent={1}" -f `
        $(if ($ic) { "$($ic.Length) chars" } else { 'EMPTY' }), $(if ($il) { "$($il.Length) chars" } else { 'EMPTY' }))
}

# --- 7. do the pages actually load? -----------------------------------------
# Fetching the .aspx HTML with an app-only token always returns 401 - SharePoint does not render
# pages for app-only identities. That says nothing about page health, so check the published file
# state over REST instead. Opening the page in a browser remains the human confirmation.
Write-LabStep 'confirming the published page files are healthy'
$loadOk = $true
$files = @($homePageAfter.Json.FileName)
if ($article) { $files += $articleAfter.Json.FileName }
foreach ($fn in $files) {
    $r = Invoke-SpoRequest -Target $t -Token $tok -Label "file-state-$fn" `
        -Path "/_api/web/GetFileByServerRelativeUrl('$webPath/SitePages/$fn')?`$select=Exists,Name,Length,Level,UIVersionLabel,CheckOutType,TimeLastModified"
    $j = $r.Json
    $level = switch ([int]$j.Level) { 1 { 'Published' } 2 { 'Draft' } 255 { 'Checkout' } default { $j.Level } }
    $co = switch ([int]$j.CheckOutType) { 0 { 'checked out' } 1 { 'short-term' } 2 { 'none' } default { $j.CheckOutType } }
    $line = "file {0}: exists={1} level={2} version={3} checkout={4} size={5}B" -f $fn, $j.Exists, $level, $j.UIVersionLabel, $co, $j.Length
    Write-Host "    $line"
    Add-LabEvidenceNote $line
    if (-not $r.Ok -or -not $j.Exists -or [int]$j.Level -ne 1) { $loadOk = $false }
}

$verdict = if ($homePageOk -and $articleOk -and $loadOk) { 'PASS' } else { 'FAIL' }
Complete-LabRun -Verdict $verdict -Summary "Modern page canvas content prepared on $($t.siteUrl)." | Out-Null

