<#
Does GET /reports/{id}/Export (PBIX download) fail for a report that is downloadable in
the UI, because of semantic-model configuration?

Verdict meaning (explicit):
  PASS         = limitation REPRODUCED: export returned an error and the exact code was captured.
  FAIL         = export succeeded and a PBIX was saved (no limitation hit).
  INCONCLUSIVE = could not list/select a report, or auth failed.

Rerun after changing semantic-model settings:
  .\lab.ps1 REPRODUCE powerbi/report-rest-export -ReportId <guid>
#>
[CmdletBinding()]
param(
    [string]$Mode = 'REPRODUCE',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,        # override, e.g. -Identity kslab-pbi-appauth to test app-context
    [string]$ReportId,
    [switch]$ListOnly
)

$Recipe = @{
    Name        = 'powerbi/report-rest-export'
    Product     = 'powerbi'
    Modes       = @('REPRODUCE', 'TEST', 'INSPECT')
    Destructive = $false
    Description = 'PBIX REST export failing due to semantic-model configuration (premium files / incremental refresh).'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $(if ($Target) { $Target } else { (Get-LabConfig).defaults.target }) -RequiredTargetFields @('workspaceId')
$run = Start-LabRun -Name 'pbi-report-rest-export' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Confirm whether a report that is downloadable in the Power BI UI fails to export via the REST API, and capture the exact Microsoft error code.' `
    -Plan @('Acquire Power BI token', 'List reports', 'Select report', 'Read semantic model settings', 'Call the Export endpoint', 'Save PBIX or exact error code')

if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fill in config and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId

# --- 1/2. Token + report list ------------------------------------------------
Write-LabStep 'Power BI token + report list'
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity
$list = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/reports" -Token $pbiToken -Label 'powerbi-reports'
if (-not $list.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Report list failed: HTTP $($list.Status) code=$($list.Error.Code)" -Evidence @($list.Error.Message) | Out-Null
    return
}

$reports = @($list.Json.value)
Write-Host "`n  Reports in workspace ($($reports.Count)):"
$i = 0
$reports | ForEach-Object {
    Write-Host ("  [{0}] {1}" -f $i, $_.name)
    Write-Host ("       reportId={0}  datasetId={1}" -f $_.id, $_.datasetId)
    $i++
}

if ($ListOnly -or $Mode -eq 'INSPECT') {
    Complete-LabRun -Verdict DONE -Summary "Listed $($reports.Count) report(s)." -Evidence @($reports | ForEach-Object { "$($_.id)  $($_.name)" }) | Out-Null
    return
}
if ($reports.Count -eq 0) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'No reports in the workspace. Publish a PBIX first.' | Out-Null
    return
}

# --- 3. Select ---------------------------------------------------------------
if (-not $ReportId) {
    if ($reports.Count -eq 1) { $ReportId = $reports[0].id; Write-LabLog 'only one report - selecting it' -Level INFO }
    else {
        $sel = Read-Host "`n  Enter index or reportId to export"
        $ReportId = if ($sel -match '^\d+$' -and [int]$sel -lt $reports.Count) { $reports[[int]$sel].id } else { $sel.Trim() }
    }
}
$report = $reports | Where-Object { $_.id -eq $ReportId } | Select-Object -First 1
$reportName = if ($report) { $report.name } else { '<not in list>' }
Add-LabEvidenceNote "target report: '$reportName' id=$ReportId"

# Semantic model context helps explain an export failure.
$dsInfo = 'n/a'
if ($report.datasetId) {
    $ds = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/datasets/$($report.datasetId)" -Token $pbiToken -Label 'powerbi-semantic-model'
    if ($ds.Ok) {
        $dsInfo = "name='$($ds.Json.name)' targetStorageMode=$($ds.Json.targetStorageMode) isOnPremGatewayRequired=$($ds.Json.isOnPremGatewayRequired)"
        Add-LabEvidenceNote "semantic model: $dsInfo"
    }
}

# --- 4. Export ---------------------------------------------------------------
Write-LabStep 'calling Export'
$outFile = Join-Path $run.ResponsesDir "export-$ReportId.bin"
$exp = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/reports/$ReportId/Export" -Token $pbiToken -OutFile $outFile -Label 'powerbi-report-export'

$ev = @("Report: '$reportName' id=$ReportId", "Semantic model: $dsInfo", "Export HTTP status: $($exp.Status)")

if ($exp.Ok) {
    $pbix = [IO.Path]::ChangeExtension($outFile, '.pbix')
    Move-Item $outFile $pbix -Force
    Complete-LabRun -Verdict FAIL -Summary 'Export SUCCEEDED - no API limitation hit for this report/semantic-model configuration.' -Evidence ($ev + @(
            "PBIX saved: $(Split-Path $pbix -Leaf) ($((Get-Item $pbix).Length) bytes)")) | Out-Null
    return
}

# Failure path - preserve the exact Microsoft error code.
$errText = $exp.Raw
Save-LabEvidence -Kind response -Name 'export-error-verbatim' -Content $errText -Extension 'json' | Out-Null
Remove-Item $outFile -ErrorAction SilentlyContinue

$code = $exp.Error.Code
if (-not $code -and $errText -match '([A-Za-z_]*(PremiumFiles|NotDownloadable|IncrementalRefresh)[A-Za-z_]*)') { $code = $Matches[1] }
$reqId = $exp.Headers['RequestId'] | Select-Object -First 1

$ev += @(
    "Error code: $(if ($code) { $code } else { '<none parsed - see raw response>' })"
    "RequestId: $reqId"
    "Raw: $errText"
)
Write-LabLog "error code: $code" -Level WARN

if ($exp.Status -in 401, 403) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'HTTP 401/403 is an authorization problem, not a semantic-model limitation. Check identity permissions (note: PBIX export is documented as not supported for service principals in some configurations) and rerun, if needed under device-code sign-in.' -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict PASS -Summary 'Limitation REPRODUCED: the report is downloadable in the UI but REST export failed with the captured error code.' -Evidence $ev | Out-Null
}
Write-Host "Rerun after changing settings:  .\lab.ps1 REPRODUCE powerbi/report-rest-export -ReportId $ReportId" -ForegroundColor Cyan

