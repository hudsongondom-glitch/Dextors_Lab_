# Spo.Rest.ps1 - SharePoint Online REST (_api) wrapper.
#
# SPO REST is the primary SharePoint API for this lab. Note the auth constraint:
# app-only REST requires a CERTIFICATE credential (authMode=certificate). A client secret
# yields "Unsupported app only token". Delegated (devicecode) also works.
#
# Graph and SPO REST are different APIs with different permissions:
#   Graph    -> Microsoft Graph "Sites.*"                 -> graph.microsoft.com/v1.0/sites
#   SPO REST -> Office 365 SharePoint Online "Sites.*"    -> <tenant>.sharepoint.com/_api

function Get-SpoSiteUri {
    param($Target)
    if ($Target.siteUrl) { return $Target.siteUrl.TrimEnd('/') }
    $cfg = Get-LabConfig
    $prefix = $cfg.tenant.domain -replace '\.onmicrosoft\.com$', ''
    "https://$prefix.sharepoint.com"
}

function Invoke-SpoRequest {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,     # e.g. '/_api/web/lists'
        [string]$Method = 'GET',
        $Body,
        [string]$ContentType = 'application/json;odata=verbose',
        [string]$Accept = 'application/json;odata=nometadata',
        [string]$Label
    )
    $uri = (Get-SpoSiteUri -Target $Target) + $Path
    Invoke-LabRequest -Uri $uri -Method $Method -Token $Token -Body $Body -ContentType $ContentType `
        -Headers @{ Accept = $Accept } `
        -Label $(if ($Label) { $Label } else { "spo-$($Path -replace '[^A-Za-z0-9]','-')" })
}

# --- creation helpers --------------------------------------------------------
# SharePoint list/field creation needs the verbose OData form with a __metadata type.

function New-SpoList {
    param(
        $Target, [string]$Token,
        [Parameter(Mandatory)][string]$Title,
        [int]$BaseTemplate = 100,           # 100 = custom list, 101 = document library
        [string]$Description = ''
    )
    $body = @{ '__metadata' = @{ type = 'SP.List' }; BaseTemplate = $BaseTemplate; Title = $Title; Description = $Description }
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Path '/_api/web/lists' -Body $body -Label "spo-newlist-$Title"
}

function New-SpoField {
    param(
        $Target, [string]$Token,
        [Parameter(Mandatory)][string]$ListTitle,
        [Parameter(Mandatory)][string]$FieldName,
        [int]$FieldTypeKind = 2             # 2 = Text, 9 = Number, 4 = DateTime, 6 = Choice
    )
    $t = [Uri]::EscapeDataString($ListTitle)
    $body = @{ '__metadata' = @{ type = 'SP.Field' }; Title = $FieldName; FieldTypeKind = $FieldTypeKind }
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Body $body `
        -Path "/_api/web/lists/getbytitle('$t')/fields" -Label "spo-newfield-$ListTitle-$FieldName"
}

function Add-SpoViewField {
    param($Target, [string]$Token, [string]$ListTitle, [string]$FieldName, [string]$ViewTitle = 'All Items')
    $t = [Uri]::EscapeDataString($ListTitle); $v = [Uri]::EscapeDataString($ViewTitle)
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST `
        -Path "/_api/web/lists/getbytitle('$t')/views/getbytitle('$v')/viewfields/addviewfield('$FieldName')" `
        -Label "spo-viewfield-$ListTitle-$FieldName"
}

function New-SpoListItem {
    param($Target, [string]$Token, [Parameter(Mandatory)][string]$ListTitle, [Parameter(Mandatory)][hashtable]$Fields, [string]$EntityType)
    $t = [Uri]::EscapeDataString($ListTitle)
    if (-not $EntityType) { $EntityType = 'SP.Data.' + (($ListTitle -replace '[^A-Za-z0-9]', '')) + 'ListItem' }
    $body = @{ '__metadata' = @{ type = $EntityType } } + $Fields
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Body $body `
        -Path "/_api/web/lists/getbytitle('$t')/items" -Label "spo-newitem-$ListTitle"
}

# Returns the ListItemEntityTypeFullName SharePoint expects when creating items.
function Get-SpoListEntityType {
    param($Target, [string]$Token, [string]$ListTitle)
    $t = [Uri]::EscapeDataString($ListTitle)
    $r = Invoke-SpoRequest -Target $Target -Token $Token -Path "/_api/web/lists/getbytitle('$t')?`$select=ListItemEntityTypeFullName" -Label "spo-entitytype-$ListTitle"
    $r.Json.ListItemEntityTypeFullName
}

function Add-SpoFile {
    param(
        $Target, [string]$Token,
        [Parameter(Mandatory)][string]$FolderServerRelativeUrl,
        [Parameter(Mandatory)][string]$FileName,
        [string]$Content,
        [byte[]]$Bytes                       # binary alternative to -Content
    )
    $f = [Uri]::EscapeDataString($FolderServerRelativeUrl)
    $n = [Uri]::EscapeDataString($FileName)
    $body = if ($PSBoundParameters.ContainsKey('Bytes')) { $Bytes } else { $Content }
    $ct = if ($PSBoundParameters.ContainsKey('Bytes')) { 'application/octet-stream' } else { 'text/plain; charset=utf-8' }
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Body $body -ContentType $ct `
        -Path "/_api/web/GetFolderByServerRelativeUrl('$f')/Files/add(url='$n',overwrite=true)" -Label "spo-upload-$FileName"
}

# --- modern page (SitePages) API --------------------------------------------
# SP.Publishing.SitePageService - the same API the modern page editor uses.

function Get-SpoSitePages {
    param($Target, [string]$Token)
    Invoke-SpoRequest -Target $Target -Token $Token -Path '/_api/sitepages/pages' -Label 'sitepages-list'
}

function Get-SpoSitePage {
    param($Target, [string]$Token, [Parameter(Mandatory)][int]$PageId)
    Invoke-SpoRequest -Target $Target -Token $Token -Path "/_api/sitepages/pages($PageId)" -Label "sitepage-$PageId"
}

function New-SpoSitePage {
    param($Target, [string]$Token, [Parameter(Mandatory)][string]$Title, [string]$PageLayoutType = 'Article')
    $body = @{ '__metadata' = @{ type = 'SP.Publishing.SitePage' }; Title = $Title; PageLayoutType = $PageLayoutType }
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Path '/_api/sitepages/pages' -Body $body -Label "sitepage-new-$Title"
}

# Saves page content as a draft. Only the fields supplied are sent - notably this never sends
# LayoutWebpartsContent unless the caller explicitly asks, so the header stays SharePoint-generated.
function Save-SpoSitePageDraft {
    param($Target, [string]$Token, [Parameter(Mandatory)][int]$PageId, [hashtable]$Fields)
    $body = @{ '__metadata' = @{ type = 'SP.Publishing.SitePage' } } + $Fields
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Path "/_api/sitepages/pages($PageId)/SavePageAsDraft" -Body $body -Label "sitepage-savedraft-$PageId"
}

# An existing page must be checked out before SavePageAsDraft, otherwise SharePoint returns
# HTTP 409 "a site member has ended your editing session". Newly created pages are already
# checked out to their creator.
function Invoke-SpoSitePageCheckout {
    param($Target, [string]$Token, [Parameter(Mandatory)][int]$PageId)
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Path "/_api/sitepages/pages($PageId)/checkoutpage" -Label "sitepage-checkout-$PageId"
}

function Publish-SpoSitePage {
    param($Target, [string]$Token, [Parameter(Mandatory)][int]$PageId)
    Invoke-SpoRequest -Target $Target -Token $Token -Method POST -Path "/_api/sitepages/pages($PageId)/Publish" -Label "sitepage-publish-$PageId"
}


function Get-SpoWeb {
    param($Target, [string]$Token)
    Invoke-SpoRequest -Target $Target -Token $Token -Path '/_api/web?$select=Title,Url,Created,WebTemplate' -Label 'spo-web'
}

function Get-SpoLists {
    param($Target, [string]$Token)
    Invoke-SpoRequest -Target $Target -Token $Token -Path '/_api/web/lists?$select=Title,ItemCount,BaseTemplate,Hidden,Id' -Label 'spo-lists'
}

function Get-SpoListItems {
    param(
        $Target, [string]$Token,
        [Parameter(Mandatory)][string]$ListTitle,
        [int]$Top = 20,
        [string]$Select        # always prefer an explicit $select: the default projection returns
        # both "Id" and "ID", which breaks case-insensitive JSON parsers
    )
    $t = [Uri]::EscapeDataString($ListTitle)
    $q = "`$top=$Top"
    if ($Select) { $q += "&`$select=$([Uri]::EscapeDataString($Select))" }
    Invoke-SpoRequest -Target $Target -Token $Token -Path "/_api/web/lists/getbytitle('$t')/items?$q" -Label "spo-items-$ListTitle"
}
