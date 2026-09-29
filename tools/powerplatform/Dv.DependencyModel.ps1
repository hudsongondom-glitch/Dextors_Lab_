# Dv.DependencyModel.ps1 - loads config/d365-dependency-model.json and resolves it against the
# live schema, so every dependency recipe agrees on what the graph actually is.
#
# The config file states intent (which table plays which role, which lookup, obligatory or
# optional). Everything else - entity set names, navigation property names, the real required
# level, the real delete rule - is read from Dataverse at run time. That is deliberate: a
# polymorphic lookup like contact.parentcustomerid binds through parentcustomerid_account, not
# through the attribute name, and a table someone already built by hand may not match what the
# config assumes. Resolving live means "reuse what exists" and "create what is missing" are the
# same code path.

function Get-DvModelPath { Join-Path $script:LabHome 'config\d365-dependency-model.json' }

function Get-DvModelProfile {
    param([string]$Name)
    $path = Get-DvModelPath
    if (-not (Test-Path $path)) { throw "Dependency model not found: $path" }
    $doc = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $Name) { $Name = $doc.defaultProfile }
    $p = $doc.profiles.$Name
    if (-not $p) { throw "Profile '$Name' is not defined in $path (defined: $(($doc.profiles.PSObject.Properties.Name) -join ', '))." }
    $p | Add-Member -NotePropertyName '_name' -NotePropertyValue $Name -Force
    foreach ($roleName in @('account', 'contact', 'order')) {
        if (-not $p.roles.$roleName) { throw "Profile '$Name' is missing role '$roleName'." }
        $p.roles.$roleName | Add-Member -NotePropertyName '_role' -NotePropertyValue $roleName -Force
    }
    return $p
}

# Resolves roles and edges against live metadata. Never throws on a missing table or lookup -
# absence is a normal state that BUILD is expected to fix, so it is reported, not fatal.
function Resolve-DvModel {
    param([Parameter(Mandatory)]$Dv, [Parameter(Mandatory)]$ModelProfile)

    $roles = [ordered]@{}
    foreach ($rp in $ModelProfile.roles.PSObject.Properties) {
        $r = $rp.Value
        $def = Get-DvEntityDefinition -Dv $Dv -LogicalName $r.logicalName -Quiet
        $roles[$rp.Name] = [pscustomobject]@{
            Role          = $rp.Name
            LogicalName   = $r.logicalName
            SchemaName    = $r.schemaName
            DisplayName   = $r.displayName
            PluralName    = $r.pluralName
            Manage        = [bool]$r.manage
            Exists        = [bool]$def
            EntitySet     = $def.EntitySetName
            IdAttribute   = $def.PrimaryIdAttribute
            NameAttribute = $(if ($r.nameAttribute) { $r.nameAttribute } else { $def.PrimaryNameAttribute })
            IsCustom      = $def.IsCustomEntity
        }
    }

    # One metadata read per entity, reused across every edge that references it.
    $rels = @{}; $lookups = @{}
    foreach ($r in $roles.Values) {
        if (-not $r.Exists) { continue }
        $rels[$r.LogicalName] = Get-DvManyToOneRelationships -Dv $Dv -LogicalName $r.LogicalName -Quiet
        $lookups[$r.LogicalName] = Get-DvLookupAttributes -Dv $Dv -LogicalName $r.LogicalName -Quiet
    }

    $edges = foreach ($e in $ModelProfile.edges) {
        $from = $roles[$e.from]; $to = $roles[$e.to]
        $attr = if ($e.lookupAttribute) { $e.lookupAttribute } else { ([string]$e.lookupSchemaName).ToLower() }

        $rel = $null; $lk = $null
        if ($from.Exists -and $to.Exists) {
            # Match on BOTH attribute and referenced entity: a polymorphic lookup produces one
            # relationship per target table, and only the right one yields a usable @odata.bind.
            $rel = @($rels[$from.LogicalName] | Where-Object {
                    $_.ReferencingAttribute -eq $attr -and $_.ReferencedEntity -eq $to.LogicalName
                }) | Select-Object -First 1
            $lk = @($lookups[$from.LogicalName] | Where-Object { $_.LogicalName -eq $attr }) | Select-Object -First 1
        }

        [pscustomobject]@{
            Name              = $e.name
            From              = $e.from
            To                = $e.to
            FromEntity        = $from.LogicalName
            ToEntity          = $to.LogicalName
            LookupAttribute   = $attr
            LookupSchemaName  = $e.lookupSchemaName
            DisplayName       = $e.displayName
            RelationshipName  = $e.relationshipSchemaName
            IntendedLink      = $e.link                       # obligatory | optional, from config
            IntendedDelete    = $(if ($e.deleteBehavior) { $e.deleteBehavior } else { 'RemoveLink' })
            ClosesCycle       = [bool]$e.closesCycle
            Exists            = [bool]$rel
            NavigationProperty = $rel.ReferencingEntityNavigationPropertyName
            ActualRequired    = $lk.RequiredLevel.Value       # None | Recommended | ApplicationRequired
            ActualDelete      = $rel.CascadeConfiguration.Delete
            IsRequired        = ($lk.RequiredLevel.Value -eq 'ApplicationRequired')
        }
    }

    [pscustomobject]@{
        Profile = $ModelProfile._name
        Roles   = $roles
        Edges   = @($edges)
        Missing = @(@($roles.Values | Where-Object { -not $_.Exists } | ForEach-Object { "table $($_.LogicalName) (role '$($_.Role)')" }) +
            @($edges | Where-Object { -not $_.Exists } | ForEach-Object { "lookup $($_.FromEntity).$($_.LookupAttribute) -> $($_.ToEntity)" }))
    }
}

# Depth-first cycle enumeration over the role graph. Small by construction (3 roles), so
# clarity beats cleverness here.
function Get-DvModelCycles {
    param([Parameter(Mandatory)]$Resolved, [switch]$ExistingOnly)
    $edges = @($Resolved.Edges | Where-Object { -not $ExistingOnly -or $_.Exists })
    $cycles = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    # $edges, $seen and $cycles resolve through the parent scope; .Add mutates the list object,
    # so no script-scoped accumulator is needed.
    function Invoke-Walk {
        param([string]$Node, [string[]]$Path, [object[]]$PathEdges)
        foreach ($e in @($edges | Where-Object { $_.From -eq $Node })) {
            $idx = [array]::IndexOf($Path, $e.To)
            if ($idx -ge 0) {
                # $PathEdges is empty on a self-loop from the start node; slicing it would wrap.
                $cycleEdges = @(if ($idx -lt $PathEdges.Count) { $PathEdges[$idx..($PathEdges.Count - 1)] }) + @($e)
                # Key on the edge set so the same loop entered from two different start nodes
                # is only reported once.
                $key = (@($cycleEdges.Name) | Sort-Object) -join '|'
                if ($seen.Add($key)) {
                    $cycles.Add([pscustomobject]@{
                            Nodes      = @($Path[$idx..($Path.Count - 1)]) + @($e.To)
                            Edges      = @($cycleEdges)
                            Obligatory = @($cycleEdges | Where-Object { $_.IsRequired })
                            Optional   = @($cycleEdges | Where-Object { -not $_.IsRequired })
                        })
                }
                continue
            }
            Invoke-Walk -Node $e.To -Path ($Path + @($e.To)) -PathEdges ($PathEdges + @($e))
        }
    }

    foreach ($start in @($Resolved.Roles.Keys)) { Invoke-Walk -Node $start -Path @($start) -PathEdges @() }
    return @($cycles)
}

# Creation order ignoring the deferrable (optional) edges - i.e. the order a restore would need
# if it created records with optional lookups nulled and patched them afterwards.
function Get-DvCreationOrder {
    param([Parameter(Mandatory)]$Resolved)
    $hard = @($Resolved.Edges | Where-Object { $_.Exists -and $_.IsRequired })
    $nodes = [System.Collections.Generic.List[string]]@($Resolved.Roles.Keys)
    $order = [System.Collections.Generic.List[string]]::new()
    $guard = 0
    while ($nodes.Count -and $guard -lt 50) {
        $guard++
        # A node is placeable once every table it obligatorily points at is already placed.
        $ready = @($nodes | Where-Object {
                $n = $_
                -not @($hard | Where-Object { $_.From -eq $n -and $nodes -contains $_.To }).Count
            })
        if (-not $ready.Count) { return [pscustomobject]@{ Ok = $false; Order = @($order); Stuck = @($nodes) } }
        foreach ($n in $ready) { $order.Add($n); [void]$nodes.Remove($n) }
    }
    [pscustomobject]@{ Ok = $true; Order = @($order); Stuck = @() }
}

# Records this lab created are identified by their name carrying the lab prefix. That keeps the
# marker inside data the connector already backs up, with no schema change to stock tables.
function Get-DvLabRecordFilter {
    param([Parameter(Mandatory)]$Role, [string]$RunId)
    $cfg = Get-LabConfig
    $prefix = if ($cfg.resourcePrefix) { $cfg.resourcePrefix } else { 'dextorslab' }
    $stem = if ($RunId) { "$prefix-$RunId" } else { $prefix }
    "startswith($($Role.NameAttribute),'$stem')"
}
