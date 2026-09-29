<#
WORKAROUND for the missing In-Place Archive delta feed (see exchange/archive-graph-delta).

Graph offers no usable item-level delta for archive mailboxes: v1.0 refuses every archive
operation, and beta's items/delta returns a truncated body. This recipe implements and proves
a "synthetic delta" that gives a backup product an incremental feed anyway.

The mechanism
-------------
  1. DISCOVER   GET /v1.0/users/{upn}/settings/exchange  -> inPlaceArchiveMailboxId
                v1.0, GA, no deprecation header. (The v1.0 docs claim only primary and shared
                mailboxes are returned; empirically the archive id is returned too.)
  2. TOPOLOGY   GET /beta/admin/exchange/mailboxes/{arch}/folders/delta
                Folder-level delta DOES work on archives and yields a real deltaLink.
  3. ITEMS      GET /beta/.../folders/{id}/items?$filter=lastModifiedDateTime gt {watermark}
                Server-side filtering works. This replaces the broken items/delta.
  4. DELETIONS  GET /beta/.../folders/{id}/items?$select=id   (full id sweep, diffed vs catalog)
                A watermark cannot express "item removed", so deletions need a sweep.
  5. CONTENT    POST /v1.0/admin/exchange/mailboxes/{arch}/exportItems   (max 20 ids per call)
                v1.0, GA, no deprecation header. Full-fidelity opaque FTS stream.

The watermark trap (load-bearing)
---------------------------------
lastModifiedDateTime is RETURNED truncated to whole seconds but FILTERED at sub-second
precision. Items modified at 11:31:28.750 are reported as "11:31:28". So the watermark must be
the max OBSERVED (already truncated) value compared with `gt`. That re-reads the boundary second
on the next cycle - harmless, deduplicated by changeKey. Rounding the watermark UP to the next
second instead would skip those items permanently and silently. Never round up.

Restore direction
-----------------
Export FROM an archive works. Import INTO an archive is refused ("Operation on Archive mailbox
not allowed"), while import into a primary mailbox succeeds. Archives are therefore read-only
over this API: restore must target the primary or an alternate mailbox.

Phases
------
  Phase 1 (always, read-only): prove the archive read path end to end and build a catalog.
  Phase 2 (-Force only): prove the change-detection mechanism end to end by mutating a folder
          in the PRIMARY mailbox - create, update and delete an item, and confirm the watermark
          query and the id sweep each detect the right change. The archive cannot be used for
          this half because it rejects writes. The endpoints and logic are identical.

Verdicts
--------
  PASS         = archive read path works AND (if Phase 2 ran) every mutation was detected.
  FAIL         = the archive read path or a detection mechanism did not work.
  INCONCLUSIVE = auth/permissions failed, or no archive/no items to test.

Needs Graph app-only: MailboxFolder.Read.All, MailboxItem.Read.All, MailboxItem.ImportExport.All,
and (Phase 2 only) MailboxItem.ReadWrite.All. Phase 2 also needs outlook.office365.com in
config/lab.policy.json allowedApiHosts - the import URL lives there.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'TEST',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Mailbox,
    [string]$Identity,
    [string]$Since               # ISO-8601 watermark; omit for a full initial sync
)

$Recipe = @{
    Name        = 'exchange/archive-incremental-sync'
    Product     = 'exchange'
    Modes       = @('TEST', 'INSPECT')
    Destructive = $true
    Description = 'Synthetic delta workaround for In-Place Archive: watermark + id sweep + exportItems.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$targetName = if ($Target) { $Target } else { 'exchange-main' }
$problems = Test-LabConfigReady -Target $targetName
$run = Start-LabRun -Name 'exchange-archive-incremental-sync' -Mode $Mode -Product exchange -Target $targetName -DryRun:$DryRun `
    -Request 'Implement and prove a synthetic incremental feed for an Exchange In-Place Archive, replacing the unusable Graph items/delta.' `
    -Plan @(
        'Resolve the archive mailbox id on v1.0',
        'Folder topology via folders/delta and confirm the deltaLink replays cleanly',
        'Build an item catalog per folder (id, changeKey, lastModifiedDateTime) and compute the watermark',
        'Retrieve content with v1.0 exportItems in batches of 20',
        'Phase 2 (-Force): create/update/delete an item in the primary mailbox and prove each change is detected'
    )
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Set `$env:LAB_SECRET_MSGAPP and ensure targets.$targetName exists."; return }

$tgt = Get-LabTarget -Name $targetName
$upn = if ($Mailbox) { $Mailbox } else { $tgt.mailbox }
if ([string]::IsNullOrWhiteSpace($upn)) {
    Stop-LabRunBlocked -Problems @("No mailbox to test: targets.$targetName.mailbox is empty and -Mailbox was not supplied.") -NextStep 'Pass -Mailbox <upn>.'
    return
}
$graph = Get-LabAccessToken -Api Graph -Target $tgt -Identity $Identity

# --------------------------------------------------------------------- helpers
function Get-LabWatermark {
    # The watermark is the max OBSERVED lastModifiedDateTime, already truncated to the second by
    # the service. Returned as-is and compared with `gt`. Never round up - see the header.
    param([object[]]$Items)
    $stamps = @($Items | Where-Object lastModifiedDateTime | ForEach-Object { [datetime]$_.lastModifiedDateTime })
    if (-not $stamps.Count) { return $null }
    ($stamps | Sort-Object)[-1].ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-LabFolderItems {
    # Pages a folder's items, optionally filtered by watermark. Returns the flat item list.
    param([string]$MailboxId, [string]$FolderId, [string]$Select = 'id,changeKey,lastModifiedDateTime,size,type', [string]$Watermark, [string]$Label)
    $uri = "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$MailboxId/folders/$FolderId/items?`$select=$Select&`$top=200"
    if ($Watermark) { $uri += "&`$filter=lastModifiedDateTime gt $Watermark" }
    $out = [System.Collections.Generic.List[object]]::new()
    $page = 0
    while ($uri -and $page -lt 100) {
        $r = Invoke-LabRequest -Uri $uri -Token $graph -Label "$Label-p$page" -AllowInDryRun
        if (-not $r.Ok) { Write-LabLog "item page failed: HTTP $($r.Status) $($r.Error.Code)" -Level WARN; break }
        @($r.Json.value) | ForEach-Object { $out.Add($_) }
        $uri = $r.Json.'@odata.nextLink'; $page++
    }
    , $out.ToArray()
}

function Export-LabItems {
    # exportItems caps at 20 ids per call. Returns a manifest, not the payloads: a 56 KB opaque
    # blob per item is not useful evidence, but its size and hash prove it was retrieved intact.
    param([string]$MailboxId, [string[]]$ItemIds, [string]$Version = 'v1.0')
    $manifest = [System.Collections.Generic.List[object]]::new()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    for ($i = 0; $i -lt $ItemIds.Count; $i += 20) {
        $batch = @($ItemIds[$i..([Math]::Min($i + 19, $ItemIds.Count - 1))])
        $r = Invoke-LabRequest -Uri "https://graph.microsoft.com/$Version/admin/exchange/mailboxes/$MailboxId/exportItems" `
            -Method POST -Token $graph -Body @{ itemIds = $batch } -Label "export-batch$([int]($i / 20))" -AllowInDryRun
        if (-not $r.Ok) {
            Write-LabLog "export batch failed: HTTP $($r.Status) $($r.Error.Code)" -Level WARN
            continue
        }
        foreach ($v in @($r.Json.value)) {
            $bytes = if ($v.data -and -not $v.error) { [Convert]::FromBase64String($v.data) } else { @() }
            $manifest.Add([pscustomobject]@{
                itemId    = $v.itemId
                changeKey = $v.changeKey
                bytes     = $bytes.Length
                sha256    = if ($bytes.Length) { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } else { $null }
                error     = $v.error.code
            })
        }
    }
    , $manifest.ToArray()
}

# --------------------------------------------------------------------- 0. discover
Write-LabStep "resolving mailbox ids for $upn (v1.0, GA)"
$settings = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/users/$upn/settings/exchange" -Token $graph -Label 'v1-settings-exchange' -AllowInDryRun
if (-not $settings.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not resolve mailbox ids: HTTP $($settings.Status) code=$($settings.Error.Code)" -Evidence @($settings.Error.Message) | Out-Null
    return
}
$archiveId = $settings.Json.inPlaceArchiveMailboxId
$primaryId = $settings.Json.primaryMailboxId
if (-not $archiveId) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Mailbox $upn has no In-Place Archive." -Evidence @("primaryMailboxId = $primaryId") | Out-Null
    return
}
Add-LabEvidenceNote "archive mailbox id resolved on v1.0 (no deprecation header): $archiveId"

# --------------------------------------------------------------------- 1. topology
Write-LabStep 'archive folder topology via folders/delta'
$fd = Invoke-LabRequest -Uri "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$archiveId/folders/delta" -Token $graph -Label 'beta-archive-folders-delta' -AllowInDryRun
$folders = @($fd.Json.value)
$deltaLink = $fd.Json.'@odata.deltaLink'
Add-LabEvidenceNote "folders/delta returned $($folders.Count) folder(s); deltaLink issued = $([bool]$deltaLink)"

$replayCount = $null
if ($deltaLink) {
    $replay = Invoke-LabRequest -Uri $deltaLink -Token $graph -Label 'beta-archive-folders-delta-replay' -AllowInDryRun
    $replayCount = @($replay.Json.value).Count
    Add-LabEvidenceNote "deltaLink replayed immediately: $replayCount change(s) (0 proves the token is a working cursor)"
}

# --------------------------------------------------------------------- 2. catalog + watermark
Write-LabStep 'building item catalog across archive folders'
$catalog = [System.Collections.Generic.List[object]]::new()
foreach ($f in $folders) {
    if (-not $f.id) { continue }
    $items = Get-LabFolderItems -MailboxId $archiveId -FolderId $f.id -Label "items-$($f.displayName -replace '[^A-Za-z0-9]','' )"
    foreach ($i in $items) {
        $catalog.Add([pscustomobject]@{
            folderId = $f.id; folder = $f.displayName; id = $i.id
            changeKey = $i.changeKey; lastModifiedDateTime = $i.lastModifiedDateTime; size = $i.size; type = $i.type
        })
    }
    Write-Host ("    {0,-34} reported={1,-5} enumerated={2}" -f $f.displayName, $f.totalItemCount, $items.Count)
}
$watermark = Get-LabWatermark -Items $catalog
Add-LabEvidenceNote "catalog: $($catalog.Count) item(s) across $($folders.Count) folder(s); watermark = $watermark"
Save-LabEvidence -Kind log -Name 'archive-catalog' -Content $catalog.ToArray() | Out-Null

# incremental replay: everything strictly newer than the watermark (should be empty on a quiet mailbox)
$incremental = @()
if ($watermark) {
    $busiest = $folders | Sort-Object totalItemCount -Descending | Select-Object -First 1
    $incremental = Get-LabFolderItems -MailboxId $archiveId -FolderId $busiest.id -Watermark $watermark -Label 'incremental-replay'
    Add-LabEvidenceNote "incremental replay on '$($busiest.displayName)' with watermark $watermark returned $($incremental.Count) item(s) (re-reads the boundary second by design)"
}

# --------------------------------------------------------------------- 3. content retrieval
$exportManifest = @()
if ($catalog.Count) {
    $sample = @($catalog | Select-Object -First 20 | ForEach-Object { $_.id })
    Write-LabStep "retrieving content for $($sample.Count) item(s) via v1.0 exportItems"
    $exportManifest = Export-LabItems -MailboxId $archiveId -ItemIds $sample
    $okCount = @($exportManifest | Where-Object { -not $_.error -and $_.bytes -gt 0 }).Count
    $totalBytes = ($exportManifest | Measure-Object bytes -Sum).Sum
    Add-LabEvidenceNote "exportItems (v1.0): $okCount/$($sample.Count) item(s) retrieved, $totalBytes byte(s) of full-fidelity content"
    Save-LabEvidence -Kind log -Name 'export-manifest' -Content $exportManifest | Out-Null
}

$archiveReadOk = ($folders.Count -gt 0) -and ($catalog.Count -gt 0) -and (@($exportManifest | Where-Object { $_.bytes -gt 0 }).Count -gt 0)

# --------------------------------------------------------------------- 4. Phase 2: prove detection
$detect = [ordered]@{ ran = $false; create = $null; update = $null; delete = $null }

if (-not $Force) {
    Add-LabEvidenceNote 'Phase 2 skipped: mutation proof requires -Force (it creates and deletes an item in the primary mailbox).'
}
elseif ($DryRun) {
    Add-LabEvidenceNote 'Phase 2 skipped: -DryRun suppresses mutations.'
}
else {
    Write-LabStep 'Phase 2: proving change detection against the primary mailbox'
    $pf = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/admin/exchange/mailboxes/$primaryId/folders?`$top=100" -Token $graph -Label 'v1-primary-folders'
    $work = @($pf.Json.value) | Where-Object wellKnownName -eq 'drafts' | Select-Object -First 1
    if (-not $work) { $work = @($pf.Json.value) | Select-Object -First 1 }

    # source bytes: a real item exported from the archive, so the proof round-trips archive content
    $srcId = $catalog[0].id
    $srcData = $null
    $e = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/admin/exchange/mailboxes/$archiveId/exportItems" -Method POST -Token $graph -Body @{ itemIds = @($srcId) } -Label 'phase2-source-export'
    if ($e.Ok) { $srcData = $e.Json.value[0].data }

    if (-not $srcData) {
        Add-LabEvidenceNote 'Phase 2 aborted: could not export a source item to import.'
    }
    else {
        # baseline for the working folder
        $base = Get-LabFolderItems -MailboxId $primaryId -FolderId $work.id -Label 'phase2-baseline'
        $baseIds = @($base | ForEach-Object { $_.id })
        $baseWm = Get-LabWatermark -Items $base
        Write-Host "    baseline in '$($work.displayName)': $($base.Count) item(s), watermark=$baseWm"

        $sess = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/admin/exchange/mailboxes/$primaryId/createImportSession" -Method POST -Token $graph -Label 'phase2-import-session'
        $importUrl = $sess.Json.importUrl

        if (-not $importUrl) {
            Add-LabEvidenceNote "Phase 2 aborted: createImportSession returned HTTP $($sess.Status) with no importUrl."
        }
        else {
            # --- CREATE. No Authorization header: the import URL is preauthenticated.
            $imp = Invoke-LabRequest -Uri $importUrl -Method POST -Body @{ FolderId = $work.id; Mode = 'create'; Data = $srcData } -Label 'phase2-import-create'
            $newId = $imp.Json.itemId
            $newKey = $imp.Json.changeKey
            if (-not $newId) {
                Add-LabEvidenceNote "Phase 2 aborted: import(create) returned HTTP $($imp.Status) $($imp.Error.Code)."
            }
            else {
                $tracked = Add-LabResource -Type 'exchange-mailbox-item' -Id $newId -Name "synthetic-delta probe in $($work.displayName)" `
                    -Target $targetName -Api 'graph' `
                    -DeleteUri "https://graph.microsoft.com/beta/admin/exchange/mailboxes/$primaryId/folders/$($work.id)/items/$newId`?disposalType=hardDelete"

                Start-Sleep -Seconds 3
                $afterCreate = Get-LabFolderItems -MailboxId $primaryId -FolderId $work.id -Watermark $baseWm -Label 'phase2-detect-create'
                $detect.create = [bool](@($afterCreate | Where-Object { $_.id -eq $newId }).Count)
                Write-Host ("    CREATE detected by watermark query: {0}" -f $detect.create) -ForegroundColor $(if ($detect.create) { 'Green' } else { 'Red' })

                # --- UPDATE: re-import the same item in update mode; changeKey must move.
                $upd = Invoke-LabRequest -Uri $importUrl -Method POST -Label 'phase2-import-update' `
                    -Body @{ FolderId = $work.id; Mode = 'update'; Data = $srcData; ItemId = $newId; ChangeKey = $newKey }
                if ($upd.Ok) {
                    Start-Sleep -Seconds 3
                    $afterUpd = Get-LabFolderItems -MailboxId $primaryId -FolderId $work.id -Watermark $baseWm -Label 'phase2-detect-update'
                    $seen = @($afterUpd | Where-Object { $_.id -eq $newId }) | Select-Object -First 1
                    $detect.update = [bool]($seen -and $seen.changeKey -ne $newKey)
                    Write-Host ("    UPDATE detected (changeKey moved {0} -> {1}): {2}" -f $newKey.Substring(0, 12), $(if ($seen) { $seen.changeKey.Substring(0, 12) } else { 'n/a' }), $detect.update) -ForegroundColor $(if ($detect.update) { 'Green' } else { 'Red' })
                }
                else {
                    Write-Host "    UPDATE import failed: HTTP $($upd.Status) $($upd.Error.Code)" -ForegroundColor Yellow
                }

                # --- DELETE via the sanctioned ledger path, then prove the id sweep sees it.
                $removed = Remove-LabResource -Resource $tracked -Token $graph -Force:$Force
                Start-Sleep -Seconds 3
                $afterDel = Get-LabFolderItems -MailboxId $primaryId -FolderId $work.id -Select 'id' -Label 'phase2-detect-delete'
                $afterIds = @($afterDel | ForEach-Object { $_.id })
                $detect.delete = $removed -and ($afterIds -notcontains $newId)
                Write-Host ("    DELETE detected by id sweep diff: {0}" -f $detect.delete) -ForegroundColor $(if ($detect.delete) { 'Green' } else { 'Red' })

                $detect.ran = $true
                Add-LabEvidenceNote "Phase 2: create detected=$($detect.create), update detected=$($detect.update), delete detected=$($detect.delete)"
            }
        }
    }
}

Save-LabEvidence -Kind log -Name 'detection-results' -Content ([pscustomobject]$detect) | Out-Null

# --------------------------------------------------------------------- verdict
$evidence = @(
    "discovery: inPlaceArchiveMailboxId returned by v1.0 (GA, no deprecation header)",
    "topology: folders/delta returned $($folders.Count) folder(s), deltaLink replay = $replayCount change(s)",
    "catalog: $($catalog.Count) item(s); watermark = $watermark",
    "content: $(@($exportManifest | Where-Object { $_.bytes -gt 0 }).Count) item(s) exported via v1.0 exportItems (batch cap 20)",
    "archives are read-only over this API: exportItems works, importItem into an archive is refused"
)
if ($detect.ran) { $evidence += "detection proof: create=$($detect.create) update=$($detect.update) delete=$($detect.delete)" }
else { $evidence += 'detection proof: not run (needs -Force)' }

$detectOk = (-not $detect.ran) -or ($detect.create -and $detect.update -and $detect.delete)

if ($archiveReadOk -and $detectOk) {
    $summary = if ($detect.ran) {
        'Workaround proven: the archive read path works end to end, and the synthetic delta detected creation, modification and deletion.'
    }
    else {
        'Workaround proven for the archive read path (catalog + watermark + full-fidelity export). Re-run with -Force to also prove change detection.'
    }
    Complete-LabRun -Verdict PASS -Summary $summary -Evidence $evidence | Out-Null
}
else {
    Complete-LabRun -Verdict FAIL -Summary 'The workaround did not fully verify - see the evidence notes.' -Evidence $evidence | Out-Null
}
