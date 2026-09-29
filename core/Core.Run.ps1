# Core.Run.ps1 - run lifecycle: scaffold a run, close it with a verdict, or stop it cleanly when
# prerequisites are missing. Evidence file capture lives in Core.Evidence.ps1.
#
# runs/<runId>-<name>/
#   request.md  plan.md  metadata.json  result.md  resources.json
#   requests/   responses/   logs/

function Start-LabRun {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('BUILD', 'TEST', 'REPRODUCE', 'INSPECT', 'CLEANUP')][string]$Mode = 'TEST',
        [string]$Product = 'lab',
        [string]$Request = '',
        [string[]]$Plan = @(),
        [string]$Target = '',
        [switch]$DryRun
    )
    $pol = Get-LabPolicy
    $runId = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $slug = ($Name -replace '[^A-Za-z0-9\-]', '-').Trim('-').ToLower()
    $dir = Join-Path $script:LabHome "runs\$runId-$slug"
    foreach ($sub in '', 'requests', 'responses', 'logs') {
        New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null
    }

    $script:LabSeq = 0
    $script:LabDryRun = [bool]($DryRun -or $pol.dryRunDefault)
    $script:LabRun = [pscustomobject]@{
        RunId        = $runId
        Name         = $Name
        Mode         = $Mode
        Product      = $Product
        Target       = $Target
        Dir          = $dir
        RequestsDir  = Join-Path $dir 'requests'
        ResponsesDir = Join-Path $dir 'responses'
        LogsDir      = Join-Path $dir 'logs'
        StartedUtc   = (Get-Date).ToUniversalTime()
        DryRun       = $script:LabDryRun
        Evidence     = [System.Collections.Generic.List[string]]::new()
    }

    Set-Content -Path (Join-Path $dir 'request.md') -Encoding utf8 -Value @"
# Request

**Run:** $runId-$slug
**Mode:** $Mode
**Target:** $Target
**Started (UTC):** $($script:LabRun.StartedUtc.ToString('o'))

$Request
"@

    $planBody = if ($Plan.Count) { ($Plan | ForEach-Object { "1. $_" }) -join "`n" } else { '_No plan recorded._' }
    Set-Content -Path (Join-Path $dir 'plan.md') -Encoding utf8 -Value "# Plan`n`n$planBody`n"

    Save-LabMetadata
    Write-LabStep "run $runId-$slug  mode=$Mode target=$Target dryRun=$($script:LabRun.DryRun)"
    return $script:LabRun
}

function Save-LabMetadata {
    param([string]$Verdict, [datetime]$EndedUtc)
    if (-not $script:LabRun) { return }
    $cfg = try { Get-LabConfig } catch { $null }
    [pscustomobject]@{
        runId      = $script:LabRun.RunId
        name       = $script:LabRun.Name
        mode       = $script:LabRun.Mode
        product    = $script:LabRun.Product
        target     = $script:LabRun.Target
        tenantId   = if ($cfg) { $cfg.tenant.id } else { $null }
        labName    = if ($cfg) { $cfg.labName } else { $null }
        dryRun     = $script:LabRun.DryRun
        startedUtc = $script:LabRun.StartedUtc.ToString('o')
        endedUtc   = if ($EndedUtc) { $EndedUtc.ToString('o') } else { $null }
        verdict    = $Verdict
        host       = @{ psVersion = $PSVersionTable.PSVersion.ToString(); os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription }
    } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:LabRun.Dir 'metadata.json') -Encoding utf8
}

function Complete-LabRun {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'INCONCLUSIVE', 'BLOCKED', 'DONE')][string]$Verdict,
        [string]$Summary = '',
        [string[]]$Evidence = @()
    )
    if (-not $script:LabRun) { throw 'Complete-LabRun called outside a run.' }
    $ended = (Get-Date).ToUniversalTime()
    $all = @($script:LabRun.Evidence) + $Evidence
    $body = @"
# Result: $Verdict

**Run:** $($script:LabRun.RunId)-$($script:LabRun.Name)
**Mode:** $($script:LabRun.Mode)
**Target:** $($script:LabRun.Target)
**Dry run:** $($script:LabRun.DryRun)
**Duration:** $([int]($ended - $script:LabRun.StartedUtc).TotalSeconds)s
**Ended (UTC):** $($ended.ToString('o'))

## Summary

$Summary

## Evidence

$(if ($all.Count) { ($all | ForEach-Object { "- $_" }) -join "`n" } else { '_none recorded_' })

## Artifacts

- requests/ - outbound calls
- responses/ - raw API responses (including errors)
- logs/run.log - execution log
- resources.json - resources created by this run
"@
    Set-Content -Path (Join-Path $script:LabRun.Dir 'result.md') -Value $body -Encoding utf8
    Save-LabMetadata -Verdict $Verdict -EndedUtc $ended

    $color = @{ PASS = 'OK'; DONE = 'OK'; FAIL = 'ERROR'; INCONCLUSIVE = 'WARN'; BLOCKED = 'WARN' }[$Verdict]
    Write-LabLog "VERDICT $Verdict - $($script:LabRun.Dir)" -Level $color
    Write-Host ''
    Write-Host $Verdict -ForegroundColor $(if ($Verdict -in 'PASS', 'DONE') { 'Green' } elseif ($Verdict -eq 'FAIL') { 'Red' } else { 'Yellow' })
    if ($Summary) { Write-Host $Summary }
    if ($all.Count) { Write-Host 'Evidence:'; $all | ForEach-Object { Write-Host "  $_" } }
    Write-Host "Run folder: $($script:LabRun.Dir)"
    $run = $script:LabRun
    $script:LabRun = $null
    return $run
}

# Stops a run cleanly when prerequisites are missing - used by every recipe's preflight.
function Stop-LabRunBlocked {
    param([Parameter(Mandatory)][string[]]$Problems, [string]$NextStep = '')
    $summary = "Cannot run: configuration or credentials are missing.`n`n" +
    (($Problems | ForEach-Object { "- $_" }) -join "`n") +
    $(if ($NextStep) { "`n`n**Next:** $NextStep" } else { '' })
    Complete-LabRun -Verdict BLOCKED -Summary $summary | Out-Null
}
