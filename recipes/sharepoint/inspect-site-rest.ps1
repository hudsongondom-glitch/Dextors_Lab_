<#
Read-only SharePoint inspection via the SPO REST API (_api) - the primary SharePoint API
for this lab. Creates nothing, changes nothing.

  PASS         = web resolved and lists enumerated over SPO REST.
  INCONCLUSIVE = auth failed. 401 "Unsupported app only token" means a client secret was used;
                 SPO REST app-only requires a certificate credential (authMode=certificate).

Default identity is msg-app-cert (certificate app-only). Use -Identity to switch.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'INSPECT',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity = 'msg-app-cert',
    [string]$ListTitle          # optionally dump items from one list
)

$Recipe = @{
    Name        = 'sharepoint/inspect-site-rest'
    Product     = 'sharepoint'
    Modes       = @('INSPECT')
    Destructive = $false
    Description = 'Read-only SharePoint inspection over the SPO REST _api (certificate app-only).'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')
. (Join-Path $PSScriptRoot '..\..\tools\microsoft\Spo.Rest.ps1')

$targetName = if ($Target) { $Target } else { 'spo-main' }
$problems = Test-LabConfigReady -Target $targetName -Identity $Identity
$run = Start-LabRun -Name 'spo-inspect-rest' -Mode INSPECT -Product sharepoint -Target $targetName -DryRun:$DryRun `
    -Request 'Enumerate a SharePoint test site and its lists using the SPO REST API.' `
    -Plan @('Acquire SharePoint-audience token', 'GET /_api/web', 'GET /_api/web/lists', 'Optionally dump one list')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix config and rerun.'; return }

$tgt = Get-LabTarget -Name $targetName
$site = Get-SpoSiteUri -Target $tgt
Add-LabEvidenceNote "SPO REST base: $site"

try { $tok = Get-LabAccessToken -Api SharePoint -Target $tgt -Identity $Identity }
catch {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Token acquisition failed: $($_.Exception.Message)" -Evidence @(
        'If the certificate is not uploaded yet: .\lab.ps1 BUILD lab/setup-app-certificate -Identity msg-app') | Out-Null
    return
}

Write-LabStep 'GET /_api/web'
$web = Get-SpoWeb -Target $tgt -Token $tok
if (-not $web.Ok) {
    $unsupported = $web.Raw -match 'Unsupported app only token' -or ([string]$web.Raw).Length -eq 0
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "SPO REST call failed: HTTP $($web.Status)" -Evidence @(
        "Body: $($web.Raw)"
        $(if ($web.Status -eq 401 -and $unsupported) {
                'HTTP 401 "Unsupported app only token" = a client-secret app-only token. SPO REST requires a certificate credential: run lab/setup-app-certificate, upload the .cer, and use an identity with authMode=certificate.'
            }
            else { 'Check that the identity has Office 365 SharePoint Online Sites.* application permissions with admin consent.' })
    ) | Out-Null
    return
}
Add-LabEvidenceNote "web '$($web.Json.Title)' template=$($web.Json.WebTemplate) url=$($web.Json.Url)"

Write-LabStep 'GET /_api/web/lists'
$lists = Get-SpoLists -Target $tgt -Token $tok
$items = @($lists.Json.value | Where-Object { -not $_.Hidden })
$items | ForEach-Object { Write-Host ("    {0,-40} items={1,-6} template={2}" -f $_.Title, $_.ItemCount, $_.BaseTemplate) }
Add-LabEvidenceNote "$($items.Count) visible list(s): $((@($items.Title) | Select-Object -First 12) -join ', ')"

if ($ListTitle) {
    Write-LabStep "GET items from '$ListTitle'"
    $li = Get-SpoListItems -Target $tgt -Token $tok -ListTitle $ListTitle
    Add-LabEvidenceNote "list '$ListTitle' -> HTTP $($li.Status), $(@($li.Json.value).Count) item(s) returned"
}

Complete-LabRun -Verdict $(if ($lists.Ok) { 'PASS' } else { 'INCONCLUSIVE' }) `
    -Summary "SPO REST read path verified against $site. Nothing was created or modified." | Out-Null
