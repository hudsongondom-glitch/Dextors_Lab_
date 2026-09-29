<#
Read-only inspection of a SharePoint Online test site via Microsoft Graph.
Creates nothing, changes nothing. First proof that the SharePoint path works end to end.

  PASS         = site resolved and its lists/drive were enumerated.
  INCONCLUSIVE = auth or permissions prevented the read.

Uses the Graph audience (Sites.Read.All). SharePoint REST/CSOM-only operations would need the
SharePoint audience instead - Get-LabAccessToken -Api SharePoint covers that when needed.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo
)

$Recipe = @{
    Name        = 'sharepoint/inspect-site'
    Product     = 'sharepoint'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only SharePoint site/lists/drive inspection via Graph.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$targetName = if ($Target) { $Target } else { 'spo-main' }
$problems = Test-LabConfigReady -Target $targetName -RequiredTargetFields @('siteUrl')
$run = Start-LabRun -Name 'spo-inspect-site' -Mode INSPECT -Product sharepoint -Target $targetName -DryRun:$DryRun `
    -Request 'Enumerate a SharePoint test site, its lists and its default document library via Microsoft Graph.' `
    -Plan @('Acquire Graph token', 'Resolve site by URL', 'List lists', 'List root drive children')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep "Add targets.$targetName with a siteUrl to config/lab.config.json."; return }

$tgt = Get-LabTarget -Name $targetName
$uri = [Uri]$tgt.siteUrl
$graph = Get-LabAccessToken -Api Graph -Target $tgt

Write-LabStep "resolving site $($tgt.siteUrl)"
$site = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath)" -Token $graph -Label 'graph-site'
if (-not $site.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Could not resolve the site: HTTP $($site.Status) code=$($site.Error.Code)" -Evidence @(
        $site.Error.Message, 'App-only access needs Sites.Read.All (or Sites.Selected with a grant on this site) with admin consent.') | Out-Null
    return
}
$siteId = $site.Json.id
Add-LabEvidenceNote "site '$($site.Json.displayName)' id=$siteId web=$($site.Json.webUrl)"

Write-LabStep 'listing lists'
$lists = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/lists" -Token $graph -Label 'graph-site-lists'
$listItems = @($lists.Json.value)
$listItems | ForEach-Object { Write-Host ("    {0,-34} template={1}" -f $_.displayName, $_.list.template) }
Add-LabEvidenceNote "$($listItems.Count) list(s): $((@($listItems.displayName) | Select-Object -First 10) -join ', ')"

Write-LabStep 'listing default document library root'
$drive = Invoke-LabRequest -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/drive/root/children" -Token $graph -Label 'graph-drive-root'
$driveItems = @($drive.Json.value)
$driveItems | ForEach-Object { Write-Host ("    {0,-34} {1}" -f $_.name, $(if ($_.folder) { "folder ($($_.folder.childCount) items)" } else { "$($_.size) bytes" })) }
Add-LabEvidenceNote "$($driveItems.Count) root item(s) in the default document library"

Complete-LabRun -Verdict $(if ($lists.Ok -and $drive.Ok) { 'PASS' } else { 'INCONCLUSIVE' }) `
    -Summary "SharePoint read path verified against '$($site.Json.displayName)'. Nothing was created or modified." | Out-Null
