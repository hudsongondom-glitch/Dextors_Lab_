# Dv.Api.ps1 - Dataverse Web API surface for the lab: data, metadata and $batch.
#
# Thin by design. Every call goes through Invoke-LabRequest so host allow-listing, dry-run and
# evidence capture cannot be bypassed. Nothing here knows about a specific experiment - schema
# shapes and seeding logic belong in recipes/powerplatform/.
#
# Dataverse behaviours this file exists to absorb:
#   - the token audience is the environment URL itself, not a fixed Microsoft resource
#   - a create returns the new id only in the OData-EntityId header unless you ask for
#     "Prefer: return=representation"
#   - a metadata read straight after a metadata write is stale without "Consistency: Strong"
#   - collections page at 5000 rows and hand back an @odata.nextLink, never a total
#   - the navigation property used by @odata.bind is NOT reliably the lookup's schema name;
#     it must be read from the many-to-one relationship metadata

$script:DvApiVersion = 'v9.2'

# Bundles environment, base URIs and a Dataverse-audience token so recipes stay short.
function Get-DvContext {
    param([Parameter(Mandatory)]$Target, [string]$Identity)
    if (-not $Target.environmentUrl) { throw "Target '$($Target._name)' has no environmentUrl in config/lab.config.json." }
    $base = $Target.environmentUrl.TrimEnd('/')
    [pscustomobject]@{
        Target = $Target
        Name   = $Target._name
        Base   = $base
        Api    = "$base/api/data/$script:DvApiVersion"
        Token  = (Get-LabAccessToken -Api Dataverse -Target $Target -Identity $Identity)
    }
}

function Invoke-DvRequest {
    param(
        [Parameter(Mandatory)]$Dv,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,       # relative to /api/data/v9.2, or absolute
        $Body,
        [hashtable]$Headers = @{},
        [string]$Label,
        [string]$ContentType = 'application/json',
        [switch]$NoEvidence,
        [switch]$AllowInDryRun
    )
    $uri = if ($Path -like 'http*') { $Path } else { "$($Dv.Api)/$($Path.TrimStart('/'))" }
    # Hashtable + hashtable throws on duplicate keys, so merge explicitly and let callers win.
    $h = @{ 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; 'Accept' = 'application/json' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    Invoke-LabRequest -Uri $uri -Method $Method -Token $Dv.Token -Body $Body -Headers $h -Label $Label `
        -ContentType $ContentType -NoEvidence:$NoEvidence -AllowInDryRun:$AllowInDryRun
}

function Get-DvWhoAmI {
    param($Dv)
    Invoke-DvRequest -Dv $Dv -Path 'WhoAmI' -Label 'dv-whoami' -AllowInDryRun
}

# --- data ---------------------------------------------------------------------

function New-DvRecord {
    param($Dv, [Parameter(Mandatory)][string]$EntitySet, [Parameter(Mandatory)][hashtable]$Body, [string]$Label, [switch]$NoEvidence)
    Invoke-DvRequest -Dv $Dv -Method POST -Path $EntitySet -Body $Body -Label $Label -NoEvidence:$NoEvidence `
        -Headers @{ 'Prefer' = 'return=representation' }
}

function Set-DvRecord {
    param($Dv, [Parameter(Mandatory)][string]$EntitySet, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Body, [string]$Label)
    # If-Match:* makes this an update-only PATCH. Without it Dataverse upserts, which would
    # silently create a record with a caller-supplied id instead of failing loudly.
    Invoke-DvRequest -Dv $Dv -Method PATCH -Path "$EntitySet($Id)" -Body $Body -Label $Label -Headers @{ 'If-Match' = '*' }
}

function Remove-DvRecord {
    param($Dv, [Parameter(Mandatory)][string]$EntitySet, [Parameter(Mandatory)][string]$Id, [string]$Label)
    Invoke-DvRequest -Dv $Dv -Method DELETE -Path "$EntitySet($Id)" -Label $Label
}

# A create returns its id in the body only when return=representation was honoured; fall back
# to the OData-EntityId header so callers never have to care which happened.
function Get-DvRecordId {
    param($Response, [string]$IdAttribute)
    if ($IdAttribute -and $Response.Json -and $Response.Json.$IdAttribute) { return [string]$Response.Json.$IdAttribute }
    $loc = @($Response.Headers['OData-EntityId']) | Select-Object -First 1
    if ($loc -and $loc -match '\(([0-9a-fA-F-]{36})\)') { return $Matches[1] }
    return $null
}

# Follows @odata.nextLink so callers get the whole set, not the first page.
function Get-DvRecords {
    param($Dv, [Parameter(Mandatory)][string]$Query, [string]$Label, [int]$MaxPages = 50, [switch]$NoEvidence)
    $out = [System.Collections.Generic.List[object]]::new()
    $next = $Query
    for ($p = 0; $p -lt $MaxPages -and $next; $p++) {
        $lbl = if ($p) { "$Label-page$p" } else { $Label }
        $r = Invoke-DvRequest -Dv $Dv -Path $next -Label $lbl -NoEvidence:$NoEvidence -AllowInDryRun `
            -Headers @{ 'Prefer' = 'odata.maxpagesize=5000' }
        if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Records = @(); Status = $r.Status; Error = $r.Error } }
        $out.AddRange(@($r.Json.value))
        $next = $r.Json.'@odata.nextLink'
    }
    [pscustomobject]@{ Ok = $true; Records = @($out); Status = 200; Error = $null }
}

# --- $batch -------------------------------------------------------------------

# Requests: @( @{ Method='POST'; Path='dxl_labcontacts'; Body=@{...} }, ... )
# Dataverse changesets are atomic, so a chunk either lands whole or not at all - the result
# reports per-chunk, not per-record, and says so rather than pretending otherwise.
function Invoke-DvBatch {
    param(
        $Dv,
        [Parameter(Mandatory)][object[]]$Requests,
        [string]$Label = 'dv-batch',
        [int]$ChangesetSize = 100
    )
    $nl = "`r`n"
    $succeeded = 0; $failed = 0; $firstError = $null; $chunks = 0
    $batchUri = "$($Dv.Api)/" + '$batch'

    for ($start = 0; $start -lt $Requests.Count; $start += $ChangesetSize) {
        $chunk = @($Requests[$start..([math]::Min($start + $ChangesetSize - 1, $Requests.Count - 1))])
        $chunks++
        $batchId = "batch_$([guid]::NewGuid().ToString('N'))"
        $csId = "changeset_$([guid]::NewGuid().ToString('N'))"

        $sb = [Text.StringBuilder]::new()
        [void]$sb.Append("--$batchId$nl")
        [void]$sb.Append("Content-Type: multipart/mixed;boundary=$csId$nl$nl")
        $contentId = 0
        foreach ($req in $chunk) {
            $contentId++
            $uri = if ($req.Path -like 'http*') { $req.Path } else { "$($Dv.Api)/$(([string]$req.Path).TrimStart('/'))" }
            [void]$sb.Append("--$csId$nl")
            [void]$sb.Append("Content-Type: application/http$nl")
            [void]$sb.Append("Content-Transfer-Encoding:binary$nl")
            [void]$sb.Append("Content-ID: $contentId$nl$nl")
            [void]$sb.Append("$($req.Method) $uri HTTP/1.1$nl")
            [void]$sb.Append("Content-Type: application/json;type=entry$nl$nl")
            [void]$sb.Append((($req.Body | ConvertTo-Json -Depth 10 -Compress) + $nl))
        }
        [void]$sb.Append("--$csId--$nl")
        [void]$sb.Append("--$batchId--$nl")

        # Bulk bodies are megabytes of near-identical rows; only failures are worth keeping.
        $r = Invoke-DvRequest -Dv $Dv -Method POST -Path $batchUri -Body $sb.ToString() `
            -ContentType "multipart/mixed;boundary=$batchId" -Label "$Label-$chunks" -NoEvidence

        if ($r.DryRun) { return [pscustomobject]@{ Ok = $false; DryRun = $true; Succeeded = 0; Failed = 0; Chunks = $chunks; FirstError = $null } }

        # The outer POST is 200 even when an inner request failed; the real verdict is in the
        # embedded status lines.
        $inner = [regex]::Matches([string]$r.Raw, '(?m)^HTTP/1\.1 (\d{3})') | ForEach-Object { [int]$_.Groups[1].Value }
        $bad = @($inner | Where-Object { $_ -lt 200 -or $_ -ge 300 })
        if ($r.Ok -and $inner.Count -and -not $bad.Count) {
            $succeeded += $chunk.Count
        }
        else {
            $failed += $chunk.Count
            if (-not $firstError) {
                $firstError = if ($bad.Count) { "inner HTTP $($bad[0])" } else { "outer HTTP $($r.Status) $($r.Error.Code)" }
                Save-LabEvidence -Kind response -Name "$Label-failed-chunk-$chunks" -Content ([string]$r.Raw) -Extension 'txt' | Out-Null
            }
            Write-LabLog "batch chunk $chunks failed ($firstError) - changesets are atomic, so all $($chunk.Count) records in it were rolled back" -Level ERROR
        }
    }
    [pscustomobject]@{ Ok = ($failed -eq 0); DryRun = $false; Succeeded = $succeeded; Failed = $failed; Chunks = $chunks; FirstError = $firstError }
}

# --- global discovery -----------------------------------------------------

# Neither an admin-center "Environment ID" nor "Organization ID" is a hostname - the Web API URL
# for a given environment can only be resolved by asking the Global Discovery Service, which
# enumerates every environment (Teams-type included) the signed-in identity can see tenant-wide.
# $Dv must come from a context built against https://globaldisco.crm.dynamics.com, not a real org.
function Get-DvGlobalDiscoveryInstances {
    param($Dv)
    $r = Invoke-DvRequest -Dv $Dv -Path 'https://globaldisco.crm.dynamics.com/api/discovery/v2.0/Instances' `
        -Label 'dv-globaldisco-instances' -AllowInDryRun
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Instances = @(); Status = $r.Status; Error = $r.Error } }
    [pscustomobject]@{ Ok = $true; Instances = @($r.Json.value); Status = 200; Error = $null }
}

# --- metadata (read) ----------------------------------------------------------

function Get-DvEntityDefinition {
    param($Dv, [Parameter(Mandatory)][string]$LogicalName, [switch]$Quiet)
    $sel = 'MetadataId,LogicalName,SchemaName,EntitySetName,PrimaryIdAttribute,PrimaryNameAttribute,IsCustomEntity'
    $r = Invoke-DvRequest -Dv $Dv -Path "EntityDefinitions(LogicalName='$LogicalName')?`$select=$sel" `
        -Label "dv-entitydef-$LogicalName" -Headers @{ 'Consistency' = 'Strong' } -NoEvidence:$Quiet -AllowInDryRun
    if ($r.Ok) { return $r.Json }
    return $null
}

# The authoritative source for both the dependency graph and for building @odata.bind payloads:
# it carries the navigation property name, the required level of the lookup and the delete rule.
function Get-DvManyToOneRelationships {
    param($Dv, [Parameter(Mandatory)][string]$LogicalName, [switch]$Quiet)
    $sel = 'SchemaName,ReferencingAttribute,ReferencingEntityNavigationPropertyName,ReferencedEntity,ReferencedAttribute,CascadeConfiguration,IsCustomRelationship'
    $r = Invoke-DvRequest -Dv $Dv -Path "EntityDefinitions(LogicalName='$LogicalName')/ManyToOneRelationships?`$select=$sel" `
        -Label "dv-m2o-$LogicalName" -Headers @{ 'Consistency' = 'Strong' } -NoEvidence:$Quiet -AllowInDryRun
    if ($r.Ok) { return @($r.Json.value) }
    return @()
}

# Logical names of every attribute on a table. Used to decide whether optional lab marker
# columns are present before writing to them - a stock table will not have them.
function Get-DvAttributeNames {
    param($Dv, [Parameter(Mandatory)][string]$LogicalName)
    $r = Invoke-DvRequest -Dv $Dv -Path "EntityDefinitions(LogicalName='$LogicalName')/Attributes?`$select=LogicalName" `
        -Label "dv-attrs-$LogicalName" -Headers @{ 'Consistency' = 'Strong' } -NoEvidence -AllowInDryRun
    if ($r.Ok) { return @($r.Json.value.LogicalName) }
    return @()
}

function Get-DvLookupAttributes {
    param($Dv, [Parameter(Mandatory)][string]$LogicalName, [switch]$Quiet)
    $sel = 'MetadataId,LogicalName,SchemaName,RequiredLevel,Targets,AttributeOf,IsValidForCreate,IsValidForUpdate'
    $path = "EntityDefinitions(LogicalName='$LogicalName')/Attributes/Microsoft.Dynamics.CRM.LookupAttributeMetadata?`$select=$sel"
    $r = Invoke-DvRequest -Dv $Dv -Path $path -Label "dv-lookups-$LogicalName" -Headers @{ 'Consistency' = 'Strong' } -NoEvidence:$Quiet -AllowInDryRun
    if (-not $r.Ok) { return @() }
    # AttributeOf is set on the shadow attributes Dataverse generates behind a lookup; they are
    # not independently writable and would double-count every edge in the graph.
    @($r.Json.value | Where-Object { -not $_.AttributeOf })
}

# --- metadata (write) ---------------------------------------------------------

function New-DvLabel {
    param([Parameter(Mandatory)][string]$Text, [int]$Lcid = 1033)
    @{
        '@odata.type'   = 'Microsoft.Dynamics.CRM.Label'
        LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $Text; LanguageCode = $Lcid })
    }
}

function New-DvRequiredLevel {
    param([ValidateSet('None', 'Recommended', 'ApplicationRequired')][string]$Value = 'None')
    @{ Value = $Value; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' }
}

function New-DvStringAttribute {
    param([string]$SchemaName, [string]$DisplayName, [int]$MaxLength = 100, [switch]$IsPrimaryName, [string]$RequiredLevel = 'None')
    $a = @{
        '@odata.type'  = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
        SchemaName     = $SchemaName
        DisplayName    = (New-DvLabel $DisplayName)
        MaxLength      = $MaxLength
        FormatName     = @{ Value = 'Text' }
        RequiredLevel  = (New-DvRequiredLevel $RequiredLevel)
    }
    if ($IsPrimaryName) { $a.IsPrimaryName = $true }
    $a
}

function New-DvIntegerAttribute {
    param([string]$SchemaName, [string]$DisplayName, [int]$MinValue = -2147483648, [int]$MaxValue = 2147483647)
    @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'
        SchemaName    = $SchemaName
        DisplayName   = (New-DvLabel $DisplayName)
        Format        = 'None'
        MinValue      = $MinValue
        MaxValue      = $MaxValue
        RequiredLevel = (New-DvRequiredLevel 'None')
    }
}

function New-DvEntity {
    param(
        $Dv,
        [Parameter(Mandatory)][string]$SchemaName,          # e.g. dxl_LabAccount
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$PluralName,
        [string]$Description = '',
        [Parameter(Mandatory)][hashtable]$PrimaryAttribute, # from New-DvStringAttribute -IsPrimaryName
        [hashtable[]]$ExtraAttributes = @(),
        [string]$Solution
    )
    $body = @{
        '@odata.type'         = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName            = $SchemaName
        DisplayName           = (New-DvLabel $DisplayName)
        DisplayCollectionName = (New-DvLabel $PluralName)
        Description           = (New-DvLabel $Description)
        OwnershipType         = 'UserOwned'
        IsActivity            = $false
        HasActivities         = $false
        HasNotes              = $false
        Attributes            = @($PrimaryAttribute) + @($ExtraAttributes)
    }
    $h = @{}
    if ($Solution) { $h['MSCRM.SolutionUniqueName'] = $Solution }
    Invoke-DvRequest -Dv $Dv -Method POST -Path 'EntityDefinitions' -Body $body -Label "dv-create-entity-$SchemaName" -Headers $h
}

# Creates a lookup by creating the one-to-many relationship that owns it. RequiredLevel here is
# the whole point of the dependency experiments: ApplicationRequired is the "obligatory" edge.
function New-DvLookup {
    param(
        $Dv,
        [Parameter(Mandatory)][string]$RelationshipSchemaName,
        [Parameter(Mandatory)][string]$ReferencedEntity,     # the "one" side, logical name
        [Parameter(Mandatory)][string]$ReferencingEntity,    # the "many" side, logical name
        [Parameter(Mandatory)][string]$LookupSchemaName,     # e.g. dxl_AccountId
        [Parameter(Mandatory)][string]$LookupDisplayName,
        [ValidateSet('None', 'Recommended', 'ApplicationRequired')][string]$RequiredLevel = 'None',
        [ValidateSet('NoCascade', 'RemoveLink', 'Restrict', 'Cascade')][string]$DeleteBehavior = 'RemoveLink',
        [string]$Solution
    )
    $body = @{
        '@odata.type'               = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName                  = $RelationshipSchemaName
        ReferencedEntity            = $ReferencedEntity
        ReferencingEntity           = $ReferencingEntity
        CascadeConfiguration        = @{
            Assign = 'NoCascade'; Delete = $DeleteBehavior; Merge = 'NoCascade'
            Reparent = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'
        }
        AssociatedMenuConfiguration = @{
            Behavior = 'UseCollectionName'; Group = 'Details'; Label = (New-DvLabel $LookupDisplayName); Order = 10000
        }
        Lookup                      = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            SchemaName    = $LookupSchemaName
            DisplayName   = (New-DvLabel $LookupDisplayName)
            RequiredLevel = (New-DvRequiredLevel $RequiredLevel)
        }
    }
    $h = @{}
    if ($Solution) { $h['MSCRM.SolutionUniqueName'] = $Solution }
    Invoke-DvRequest -Dv $Dv -Method POST -Path 'RelationshipDefinitions' -Body $body -Label "dv-create-rel-$RelationshipSchemaName" -Headers $h
}

function Get-DvRelationshipBySchemaName {
    param($Dv, [Parameter(Mandatory)][string]$SchemaName)
    $r = Invoke-DvRequest -Dv $Dv -Path "RelationshipDefinitions?`$filter=SchemaName eq '$SchemaName'&`$select=SchemaName,MetadataId" `
        -Label 'dv-find-relationship' -Headers @{ 'Consistency' = 'Strong' } -NoEvidence -AllowInDryRun
    if ($r.Ok) { return @($r.Json.value) | Select-Object -First 1 }
    return $null
}

# --- publisher / solution -----------------------------------------------------
#
# A dedicated publisher and unmanaged solution keep every lab table in one place in the maker
# portal and give the customisation prefix a real owner. Both are reused if they already exist.

function Get-DvOrCreatePublisher {
    param($Dv, [string]$UniqueName, [string]$FriendlyName, [string]$Prefix, [int]$OptionValuePrefix = 42100)
    $found = Get-DvRecords -Dv $Dv -Query "publishers?`$select=publisherid,uniquename,customizationprefix&`$filter=uniquename eq '$UniqueName'" -Label 'dv-find-publisher' -NoEvidence
    if ($found.Ok -and $found.Records.Count) { return [pscustomobject]@{ Id = $found.Records[0].publisherid; Created = $false } }
    $r = New-DvRecord -Dv $Dv -EntitySet 'publishers' -Label 'dv-create-publisher' -Body @{
        uniquename                     = $UniqueName
        friendlyname                   = $FriendlyName
        customizationprefix            = $Prefix
        customizationoptionvalueprefix = $OptionValuePrefix
    }
    if (-not $r.Ok) { return [pscustomobject]@{ Id = $null; Created = $false; Error = "HTTP $($r.Status) $($r.Error.Code) $($r.Error.Message)" } }
    [pscustomobject]@{ Id = (Get-DvRecordId -Response $r -IdAttribute 'publisherid'); Created = $true }
}

function Get-DvOrCreateSolution {
    param($Dv, [string]$UniqueName, [string]$FriendlyName, [string]$PublisherId, [string]$Version = '1.0.0.0')
    $found = Get-DvRecords -Dv $Dv -Query "solutions?`$select=solutionid,uniquename&`$filter=uniquename eq '$UniqueName'" -Label 'dv-find-solution' -NoEvidence
    if ($found.Ok -and $found.Records.Count) { return [pscustomobject]@{ Id = $found.Records[0].solutionid; Created = $false } }
    $r = New-DvRecord -Dv $Dv -EntitySet 'solutions' -Label 'dv-create-solution' -Body @{
        uniquename            = $UniqueName
        friendlyname          = $FriendlyName
        version               = $Version
        'publisherid@odata.bind' = "/publishers($PublisherId)"
    }
    if (-not $r.Ok) { return [pscustomobject]@{ Id = $null; Created = $false; Error = "HTTP $($r.Status) $($r.Error.Code) $($r.Error.Message)" } }
    [pscustomobject]@{ Id = (Get-DvRecordId -Response $r -IdAttribute 'solutionid'); Created = $true }
}
