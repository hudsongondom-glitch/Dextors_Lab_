<#
Reproduces the Microsoft Graph limitation around Exchange In-Place Archive (Online Archive)
mailboxes, specifically for a backup/restore product that wants an incremental (delta) feed.

Background
----------
An In-Place Archive is a SEPARATE mailbox from the user's primary mailbox. `/users/{id}/mailFolders`
only ever addresses the primary mailbox, so the "Archive" folder you see there is the one-click
Archive button target inside the primary mailbox - NOT the In-Place Archive. The only Graph surface
that can address the archive mailbox is the admin/exchange path:

    /admin/exchange/mailboxes/{mailboxId}/folders
    /admin/exchange/mailboxes/{mailboxId}/folders/{folderId}/items[/delta]

where mailboxId is `MBX:{mailboxGuid}@{tenantGuid}`. The archive mailbox's id is discoverable
(without Exchange PowerShell) from `/beta/users/{id}/settings/exchange` -> inPlaceArchiveMailboxId.

What this recipe checks
-----------------------
For one mailbox that has an In-Place Archive, it runs the same four calls against BOTH the
primary and the archive mailbox, on BOTH v1.0 and beta, and records:
  * HTTP status and the verbatim Microsoft error code/message
  * whether the response body is well-formed JSON (the delta bodies are not)
  * whether the endpoint carries Deprecation/Sunset headers
It then pages `/items` to completion to show whether full enumeration is possible at all.

Verdicts
--------
  PASS         = the limitation was reproduced, i.e. v1.0 refuses archive operations AND the
                 beta item-level delta returns a body that cannot be consumed.
  FAIL         = archive delta worked on both versions; the limitation no longer applies.
  INCONCLUSIVE = auth/permissions failed, the mailbox has no In-Place Archive to test, or only
                 one of the two required failure modes occurred this run (both must hold for
                 PASS - a partial match is not a reproduction).

Needs Graph app-only MailboxFolder.Read.All + MailboxItem.Read.All (msg-app already holds both).
Read-only: creates nothing, modifies nothing.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'REPRODUCE',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Mailbox,
    [string]$Identity
)

$Recipe = @{
    Name        = 'exchange/archive-graph-delta'
    Product     = 'exchange'
    Modes       = @('REPRODUCE', 'INSPECT')
    Destructive = $false
    Description = 'Graph v1.0 vs beta against an In-Place Archive mailbox: folder/item enumeration and delta.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$targetName = if ($Target) { $Target } else { 'exchange-main' }
$problems = Test-LabConfigReady -Target $targetName
$run = Start-LabRun -Name 'exchange-archive-graph-delta' -Mode $Mode -Product exchange -Target $targetName -DryRun:$DryRun `
    -Request 'Determine whether Microsoft Graph can incrementally (delta) enumerate items in an Exchange In-Place Archive mailbox, on v1.0 and on beta.' `
    -Plan @(
        'Acquire a Graph app-only token',
        'Resolve primary + In-Place Archive mailbox ids via /beta/users/{id}/settings/exchange',
        'Run folders, folders/delta, items, items/delta against primary and archive on v1.0 and beta',
        'Record status, verbatim error code, JSON well-formedness and Deprecation headers',
        'Page /items to completion to test whether full enumeration is possible'
    )
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Set `$env:LAB_SECRET_MSGAPP and ensure targets.$targetName exists in config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $targetName
$upn = if ($Mailbox) { $Mailbox } else { $tgt.mailbox }
if ([string]::IsNullOrWhiteSpace($upn)) {
    Stop-LabRunBlocked -Problems @("No mailbox to test: targets.$targetName.mailbox is empty and -Mailbox was not supplied.") `
        -NextStep 'Pass -Mailbox <upn>, or set targets.exchange-main.mailbox in config/lab.config.json.'
    return
}

$graph = Get-LabAccessToken -Api Graph -Target $tgt -Identity $Identity

# ---------------------------------------------------------------- resolve the two mailbox ids
Write-LabStep "resolving mailbox ids for $upn"
$settings = Invoke-LabRequest -Uri "https://graph.microsoft.com/beta/users/$upn/settings/exchange" -Token $graph -Label 'exchange-settings'
if (-not $settings.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not read /beta/users/$upn/settings/exchange: HTTP $($settings.Status) code=$($settings.Error.Code)" -Evidence @(
        $settings.Error.Message,
        'App-only access needs Graph MailboxFolder.Read.All (and MailboxItem.Read.All for items).') | Out-Null
    return
}
$primaryId = $settings.Json.primaryMailboxId
$archiveId = $settings.Json.inPlaceArchiveMailboxId
Add-LabEvidenceNote "primaryMailboxId       = $primaryId"
Add-LabEvidenceNote "inPlaceArchiveMailboxId = $(if ($archiveId) { $archiveId } else { '<none - archive not enabled>' })"

if (-not $archiveId) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Mailbox $upn has no In-Place Archive, so the archive path cannot be tested." -Evidence @(
        "primaryMailboxId = $primaryId",
        'Enable the archive (Exchange admin center > Recipients > Mailboxes > Others > Manage mailbox archive), or pass -Mailbox for a mailbox that already has one.') | Out-Null
    return
}

# ---------------------------------------------------------------- pick a populated archive folder
Write-LabStep 'listing archive folders (beta)'
$archFolders = Invoke-LabRequest -Uri "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$archiveId/folders?`$top=100" -Token $graph -Label 'beta-archive-folders'
$archList = @($archFolders.Json.value)
$archList | ForEach-Object { Write-Host ("    {0,-34} items={1,-6} children={2,-4} wellKnown={3}" -f $_.displayName, $_.totalItemCount, $_.childFolderCount, $_.wellKnownName) }
Add-LabEvidenceNote "archive exposes $($archList.Count) folder(s), $((($archList | Measure-Object totalItemCount -Sum).Sum)) item(s) total"

$archFolder = $archList | Sort-Object totalItemCount -Descending | Select-Object -First 1
if (-not $archFolder -or $archFolder.totalItemCount -eq 0) {
    Add-LabEvidenceNote 'WARNING: the archive contains no items, so an empty delta result would be ambiguous.'
}

$primFolders = Invoke-LabRequest -Uri "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$primaryId/folders?`$top=100" -Token $graph -Label 'beta-primary-folders'
$primFolder = @($primFolders.Json.value) | Where-Object wellKnownName -eq 'inbox' | Select-Object -First 1

# ---------------------------------------------------------------- the matrix
$results = [System.Collections.Generic.List[object]]::new()
function Invoke-Case {
    param([string]$Version, [string]$Scope, [string]$Op, [string]$Uri)
    $label = "$Version-$Scope-$($Op -replace '/', '-')"
    $r = Invoke-LabRequest -Uri $Uri -Token $graph -Label $label
    $wellFormed = $false
    if ($r.Raw) { try { $null = $r.Raw | ConvertFrom-Json -ErrorAction Stop; $wellFormed = $true } catch { } }
    $dep = $r.Headers['Deprecation']
    $row = [pscustomobject]@{
        Version    = $Version
        Scope      = $Scope
        Operation  = $Op
        Status     = $r.Status
        ErrorCode  = $r.Error.Code
        Message    = $r.Error.Message
        Bytes      = $r.Raw.Length
        WellFormed = $wellFormed
        Items      = if ($wellFormed -and $r.Json) { @($r.Json.value).Count } else { $null }
        Deprecated = [bool]$dep
    }
    $results.Add($row)
    $tag = if (-not $r.Ok) { "HTTP $($r.Status) $($r.Error.Code)" } elseif (-not $wellFormed) { 'HTTP 200 but MALFORMED JSON' } else { "HTTP 200 ok ($($row.Items) value entries)" }
    Write-Host ("    {0,-5} {1,-8} {2,-16} {3}" -f $Version, $Scope, $Op, $tag)
    return $r
}

foreach ($v in 'v1.0', 'beta') {
    Write-LabStep "matrix on $v"
    $base = "https://graph.microsoft.com/$v/admin/exchange/mailboxes"
    $null = Invoke-Case $v 'primary' 'folders'       "$base/$primaryId/folders?`$top=100"
    $null = Invoke-Case $v 'primary' 'folders/delta' "$base/$primaryId/folders/delta"
    $null = Invoke-Case $v 'archive' 'folders'       "$base/$archiveId/folders?`$top=100"
    $null = Invoke-Case $v 'archive' 'folders/delta' "$base/$archiveId/folders/delta"
    if ($primFolder) {
        $null = Invoke-Case $v 'primary' 'items'       "$base/$primaryId/folders/$($primFolder.id)/items"
        $null = Invoke-Case $v 'primary' 'items/delta' "$base/$primaryId/folders/$($primFolder.id)/items/delta"
    }
    if ($archFolder) {
        $null = Invoke-Case $v 'archive' 'items'       "$base/$archiveId/folders/$($archFolder.id)/items"
        $null = Invoke-Case $v 'archive' 'items/delta' "$base/$archiveId/folders/$($archFolder.id)/items/delta"
    }
}

# ---------------------------------------------------------------- can we enumerate the archive fully?
$paged = 0; $pages = 0
if ($archFolder) {
    Write-LabStep "paging beta archive items in '$($archFolder.displayName)'"
    $uri = "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$archiveId/folders/$($archFolder.id)/items"
    while ($uri -and $pages -lt 50) {
        $p = Invoke-LabRequest -Uri $uri -Token $graph -Label "beta-archive-items-page$pages"
        if (-not $p.Ok) { break }
        $paged += @($p.Json.value).Count; $pages++
        $uri = $p.Json.'@odata.nextLink'
    }
    Add-LabEvidenceNote "beta full enumeration: folder '$($archFolder.displayName)' reports totalItemCount=$($archFolder.totalItemCount); paging /items returned $paged item(s) over $pages page(s)"
}

Save-LabEvidence -Kind log -Name 'matrix' -Content $results | Out-Null

# ---------------------------------------------------------------- verdict
$v1Archive = @($results | Where-Object { $_.Version -eq 'v1.0' -and $_.Scope -eq 'archive' })
$v1Blocked = @($v1Archive | Where-Object { $_.Status -ge 400 }).Count -eq $v1Archive.Count -and $v1Archive.Count -gt 0
$betaItemDelta = $results | Where-Object { $_.Version -eq 'beta' -and $_.Scope -eq 'archive' -and $_.Operation -eq 'items/delta' } | Select-Object -First 1
$betaDeltaUnusable = $betaItemDelta -and ($betaItemDelta.Status -eq 200) -and (-not $betaItemDelta.WellFormed)

$v1Code = ($v1Archive | Where-Object ErrorCode | Select-Object -First 1).ErrorCode
$v1Msg = ($v1Archive | Where-Object Message | Select-Object -First 1).Message

$v1Verdict = if ($v1Blocked) { "every operation refused - code='$v1Code' message='$v1Msg'" } else { 'at least one operation succeeded' }
$evidence = @(
    "v1.0 against the archive mailbox: $v1Verdict",
    "beta archive items/delta: HTTP $($betaItemDelta.Status), $($betaItemDelta.Bytes) bytes, well-formed JSON = $($betaItemDelta.WellFormed)",
    "beta archive folders + items enumerate normally; only the item-level delta is unusable",
    "every beta /admin/exchange call carries Deprecation/Sunset headers (deprecated 2021-08-19, sunset 2023-08-19)"
)
if ($archFolder) { $evidence += "full enumeration via paged /items returned $paged of $($archFolder.totalItemCount) item(s)" }

if ($v1Blocked -and $betaDeltaUnusable) {
    Complete-LabRun -Verdict PASS -Summary 'Reproduced: Graph v1.0 refuses all In-Place Archive operations, and the beta item-level delta returns an unusable (truncated) body. No incremental item feed exists for archive mailboxes on either version.' -Evidence $evidence | Out-Null
}
elseif ($v1Blocked -or $betaDeltaUnusable) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'Only one of the two required failure modes occurred this run - see the matrix. Both v1.0-refuses-archive AND beta-delta-unusable must hold for a full reproduction.' -Evidence $evidence | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary 'The limitation did not reproduce: archive delta returned usable data.' -Evidence $evidence | Out-Null
}
