<#
Does a Dataflow Gen2 (CI/CD) item returned by the Fabric REST API also appear in the
legacy Power BI REST dataflow API?

Verdict meaning (explicit, so PASS is unambiguous):
  PASS         = limitation REPRODUCED: item present in Fabric API, absent from Power BI API.
  FAIL         = limitation NOT reproduced: the same object id appears in both APIs.
  INCONCLUSIVE = could not get the data needed to decide.
#>
[CmdletBinding()]
param(
    [string]$Mode = 'REPRODUCE',
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,        # override, e.g. -Identity kslab-pbi-appauth to test app-context
    [switch]$NoCreate,          # skip artifact creation, compare existing dataflows only
    [string]$DataflowId         # compare a specific existing dataflow instead of creating one
)

$Recipe = @{
    Name        = 'powerbi/dataflow-gen2-visibility'
    Product     = 'powerbi'
    Modes       = @('REPRODUCE', 'TEST', 'BUILD')
    Destructive = $false
    Description = 'Dataflow Gen2 (CI/CD) visible in Fabric REST but missing from legacy Power BI REST.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $(if ($Target) { $Target } else { (Get-LabConfig).defaults.target }) -RequiredTargetFields @('workspaceId')
$run = Start-LabRun -Name 'pbi-dataflow-gen2-visibility' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Confirm whether a Dataflow Gen2 (CI/CD) item returned by the Fabric REST API is also returned by the legacy Power BI REST dataflow API.' `
    -Plan @('Validate Fabric token + workspace', 'Create a Dataflow Gen2 test artifact', 'List dataflows via Fabric REST',
    'List dataflows via Power BI REST', 'Cross-check token audiences', 'Compare object ids')

if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fill in config and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId
Add-LabEvidenceNote "workspace: $ws ($($tgt.workspaceName))"

# --- 1. Fabric token + workspace reachable ----------------------------------
Write-LabStep 'Fabric token + workspace probe'
$fabricToken = Get-LabAccessToken -Api Fabric -Target $tgt -Identity $Identity
$probe = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws" -Token $fabricToken -Label 'fabric-workspace'
if (-not $probe.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Fabric token could not read workspace $ws (HTTP $($probe.Status), code=$($probe.Error.Code))." -Evidence @(
        "Fix access (service principal must be workspace Member/Admin, and the tenant setting 'Service principals can use Fabric APIs' must be enabled), then rerun.") | Out-Null
    return
}

# --- 2/3. Create the Gen2 artifact ------------------------------------------
$targetId = $DataflowId; $targetName = $null
if (-not $targetId -and -not $NoCreate) {
    $name = New-LabResourceName -Suffix 'dfgen2'
    Write-LabStep "creating Dataflow Gen2 '$name'"
    $create = Invoke-LabRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows" -Token $fabricToken `
        -Body @{ displayName = $name; description = 'Dextors Lab artifact' } -Label 'fabric-create-dataflow'

    if ($create.Status -eq 202) {
        $op = $create.Headers['x-ms-operation-id'] | Select-Object -First 1
        Write-LabLog "long-running operation $op - polling" -Level INFO
        for ($i = 0; $i -lt 30 -and -not $targetId; $i++) {
            Start-Sleep -Seconds 3
            $st = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op" -Token $fabricToken -Label 'fabric-operation-status' -NoEvidence
            if ($st.Json.status -eq 'Succeeded') {
                $r = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/operations/$op/result" -Token $fabricToken -Label 'fabric-create-result'
                $targetId = $r.Json.id; $targetName = $r.Json.displayName
            }
            elseif ($st.Json.status -eq 'Failed') { Write-LabLog "create failed: $($st.Raw)" -Level ERROR; break }
        }
    }
    elseif ($create.Ok) { $targetId = $create.Json.id; $targetName = $create.Json.displayName }

    if ($targetId) {
        Add-LabResource -Type 'fabric-dataflow' -Id $targetId -Name $targetName -Target $tgt._name -Api 'fabric' `
            -DeleteUri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows/$targetId" | Out-Null
        Add-LabEvidenceNote "created Dataflow Gen2 id=$targetId name='$targetName'"
    }
    else {
        Write-LabLog "could not create a Dataflow Gen2 via REST (HTTP $($create.Status) code=$($create.Error.Code)) - falling back to comparing existing dataflows" -Level WARN
        Add-LabEvidenceNote "create failed: HTTP $($create.Status) code=$($create.Error.Code)"
    }
}

# --- 4. Fabric dataflow list -------------------------------------------------
Write-LabStep 'Fabric REST dataflow list'
$fab = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows" -Token $fabricToken -Label 'fabric-dataflows'
$fabItems = @($fab.Json.value)

# --- 5. Power BI legacy dataflow list ---------------------------------------
Write-LabStep 'Power BI REST dataflow list'
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity
$pbi = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dataflows" -Token $pbiToken -Label 'powerbi-dataflows'
$pbiItems = @($pbi.Json.value)

# --- 6. Token audience cross-check ------------------------------------------
Write-LabStep 'token audience cross-check'
$x1 = Invoke-LabRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$ws/dataflows" -Token $pbiToken -Label 'xcheck-pbitoken-on-fabric'
$x2 = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dataflows" -Token $fabricToken -Label 'xcheck-fabrictoken-on-powerbi'

# --- 7. Compare --------------------------------------------------------------
Write-LabStep 'comparison'
Write-Host ("  Fabric API   : {0} dataflow(s)" -f $fabItems.Count)
$fabItems | ForEach-Object { Write-Host "    $($_.id)  $($_.displayName)" }
Write-Host ("  Power BI API : {0} dataflow(s)" -f $pbiItems.Count)
$pbiItems | ForEach-Object { Write-Host "    $($_.objectId)  $($_.name)" }

$ev = @(
    "Fabric list  : HTTP $($fab.Status), $($fabItems.Count) item(s)"
    "PowerBI list : HTTP $($pbi.Status), $($pbiItems.Count) item(s)"
    "Audiences: Fabric='https://api.fabric.microsoft.com', PowerBI='https://analysis.windows.net/powerbi/api'"
    "Cross-check: Power BI token on Fabric API -> HTTP $($x1.Status); Fabric token on Power BI API -> HTTP $($x2.Status)"
)

if (-not $fab.Ok -or -not $pbi.Ok) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'One or both dataflow list calls failed.' -Evidence ($ev + @(
            "Fabric error: $($fab.Error.Code) $($fab.Error.Message)", "Power BI error: $($pbi.Error.Code) $($pbi.Error.Message)")) | Out-Null
    return
}

$subjects = if ($targetId) { $fabItems | Where-Object { $_.id -eq $targetId } } else { $fabItems }
if (-not $subjects) {
    Complete-LabRun -Verdict INCONCLUSIVE -Summary 'No Dataflow Gen2 item available in the Fabric API to compare.' -Evidence ($ev + 'Create one (UI or -NoCreate:$false) and rerun.') | Out-Null
    return
}

$pbiIds = $pbiItems.objectId
$missing = @($subjects | Where-Object { $_.id -notin $pbiIds })
$present = @($subjects | Where-Object { $_.id -in $pbiIds })
$ev += $subjects | ForEach-Object {
    "id=$($_.id) name='$($_.displayName)': present in Fabric API, $(if ($_.id -in $pbiIds) { 'PRESENT in Power BI API' } else { 'ABSENT from Power BI API' })"
}

if ($missing.Count -gt 0 -and $present.Count -eq 0) {
    Complete-LabRun -Verdict PASS -Summary 'Limitation REPRODUCED: Dataflow Gen2 item(s) returned by Fabric REST are not returned by the legacy Power BI REST dataflow API.' -Evidence $ev | Out-Null
}
elseif ($missing.Count -eq 0) {
    Complete-LabRun -Verdict FAIL -Summary 'Limitation NOT reproduced: every Fabric dataflow id also appears in the Power BI API.' -Evidence $ev | Out-Null
}
else {
    Complete-LabRun -Verdict PASS -Summary "Mixed: $($missing.Count) absent, $($present.Count) present. The absent id(s) reproduce the limitation." -Evidence $ev | Out-Null
}

