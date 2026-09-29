# Core.Resources.ps1 - ledger of everything the lab creates, so CLEANUP can only ever
# touch resources this lab is responsible for.
#
# Per-run:  runs/<run>/resources.json
# Global :  runs/_ledger.jsonl   (append-only, survives across runs)

function Get-LabLedgerPath {
    if ($env:LAB_LEDGER) { return $env:LAB_LEDGER }   # override, used by the offline self-test
    Join-Path $script:LabHome 'runs\_ledger.jsonl'
}

function Add-LabResource {
    param(
        [Parameter(Mandatory)][string]$Type,        # e.g. fabric-dataflow, spo-list, dataverse-record
        [Parameter(Mandatory)][string]$Id,
        [string]$Name,
        [string]$Target,
        [string]$Api,                               # fabric | powerbi | graph | dataverse | local
        [string]$DeleteUri,                         # absolute URI for DELETE, when applicable
        [hashtable]$Extra = @{}
    )
    $pol = Get-LabPolicy
    $entry = [ordered]@{
        runId      = $(if ($script:LabRun) { $script:LabRun.RunId } else { 'adhoc' })
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        type       = $Type; id = $Id; name = $Name; target = $Target; api = $Api
        deleteUri  = $DeleteUri; status = 'active'
    }
    foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] }

    if ($script:LabRun) {
        $file = Join-Path $script:LabRun.Dir 'resources.json'
        $existing = @(if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json })
        if ($existing.Count -ge $pol.maxResourcesPerRun) { throw "SAFETY: run already tracks $($existing.Count) resources (policy max $($pol.maxResourcesPerRun))." }
        , ($existing + [pscustomobject]$entry) | ConvertTo-Json -Depth 10 -AsArray | Set-Content $file -Encoding utf8
    }
    ([pscustomobject]$entry | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path (Get-LabLedgerPath) -Encoding utf8
    Write-LabLog "tracked resource $Type/$Id '$Name'" -Level OK
    return [pscustomobject]$entry
}

function Get-LabResources {
    param([string]$RunId, [string]$Type, [switch]$IncludeDeleted)
    $p = Get-LabLedgerPath
    if (-not (Test-Path $p)) { return @() }
    # Collapse the append-only log to the latest state per (runId,type,id).
    $all = Get-Content $p | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    $latest = @{}
    foreach ($e in $all) { $latest["$($e.runId)|$($e.type)|$($e.id)"] = $e }
    $out = $latest.Values
    if ($RunId) { $out = $out | Where-Object { $_.runId -eq $RunId } }
    if ($Type) { $out = $out | Where-Object { $_.type -eq $Type } }
    if (-not $IncludeDeleted) { $out = $out | Where-Object { $_.status -ne 'deleted' } }
    @($out | Sort-Object createdUtc)
}

function Set-LabResourceStatus {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$Status, [string]$Note)
    # Start from every field the resource already carries (including Extra metadata from
    # Add-LabResource) so a status transition doesn't drop it from the collapsed ledger view.
    $e = [ordered]@{}
    foreach ($p in $Resource.PSObject.Properties) { $e[$p.Name] = $p.Value }
    $e['status'] = $Status
    $e['statusUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $e['note'] = $Note
    ([pscustomobject]$e | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path (Get-LabLedgerPath) -Encoding utf8
}

# The only sanctioned delete path.
function Remove-LabResource {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$Token, [switch]$Force)
    if (-not $Resource.deleteUri) {
        Write-LabLog "no deleteUri for $($Resource.type)/$($Resource.id) - manual cleanup required" -Level WARN
        Set-LabResourceStatus -Resource $Resource -Status 'manual-cleanup-required'
        return $false
    }
    Assert-LabDestructive -Operation 'DELETE' -ResourceDescription "$($Resource.type)/$($Resource.id) '$($Resource.name)'" -Force:$Force -IsTracked
    $r = Invoke-LabRequest -Method DELETE -Uri $Resource.deleteUri -Token $Token -Label "delete-$($Resource.type)-$($Resource.id)"
    if ($r.DryRun) { return $false }
    if ($r.Ok -or $r.Status -eq 404) {
        Set-LabResourceStatus -Resource $Resource -Status 'deleted' -Note "HTTP $($r.Status)"
        Write-LabLog "deleted $($Resource.type)/$($Resource.id)" -Level OK
        return $true
    }
    Set-LabResourceStatus -Resource $Resource -Status 'delete-failed' -Note "HTTP $($r.Status) $($r.Error.Code)"
    Write-LabLog "delete failed $($Resource.type)/$($Resource.id): HTTP $($r.Status) $($r.Error.Code)" -Level ERROR
    return $false
}
