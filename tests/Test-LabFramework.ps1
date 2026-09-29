<#
Offline self-test for the lab framework. No network, no credentials, no tenant access.
Run:  pwsh -File tests\Test-LabFramework.ps1
#>
[CmdletBinding()]
param([switch]$KeepRun)

. (Join-Path $PSScriptRoot '..\core\Core.Context.ps1')

$pass = 0; $fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
        else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:fail++ }
    }
    catch { Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}
function Throws([scriptblock]$Block, [string]$Match) {
    try { & $Block; return $false } catch { return ($_.Exception.Message -like "*$Match*") }
}

Write-Host "`nLab framework self-test (offline)`n" -ForegroundColor Cyan

Check 'config loads' { (Get-LabConfig).labName -eq 'dextors-lab' }
Check 'policy loads' { $null -ne (Get-LabPolicy).allowedApiHosts }
Check 'config gaps are reported for a missing target' { (Test-LabConfigReady -Target 'no-such-target').Count -gt 0 }
Check 'missing target field is reported' { @(Test-LabConfigReady -Target 'no-such-target-with-fields' -RequiredTargetFields @('nonexistentField') -SkipMicrosoftIdentity).Count -gt 0 }
Check 'certificate identity is recognized (regression: authMode=certificate used to fall through to "must be clientsecret, devicecode or token")' {
    @(Test-LabConfigReady -Identity 'msg-app-cert').Count -eq 0
}
Check 'certificate identity flags a missing password env var' {
    $orig = $env:LAB_CERT_PASSWORD
    Remove-Item Env:\LAB_CERT_PASSWORD -ErrorAction SilentlyContinue
    try { @(Test-LabConfigReady -Identity 'msg-app-cert').Count -gt 0 }
    finally { if ($orig) { $env:LAB_CERT_PASSWORD = $orig } }
}

Check 'allowed API host passes' { Assert-LabApiHost -Uri 'https://graph.microsoft.com/v1.0/me'; $true }
Check 'wildcard API host passes' { Assert-LabApiHost -Uri 'https://contoso.sharepoint.com/sites/x'; $true }
Check 'unknown API host is blocked' { Throws { Assert-LabApiHost -Uri 'https://evil.example.com/api' } 'not in policy allowedApiHosts' }
Check 'unlisted tenant is blocked' { Throws { Assert-LabTenant -TenantId '11111111-1111-1111-1111-111111111111' } 'SAFETY' }
Check 'production-looking target is blocked' {
    Throws { Assert-LabTarget -Name 'spo-prod' -Target ([pscustomobject]@{ siteUrl = 'https://x.sharepoint.com/sites/prod' }) } 'deny pattern'
}
Check 'legitimate target is NOT blocked by key names' {
    # Regression: the deny scan used to match the property NAME "product" against *prod*.
    Assert-LabTarget -Name 'dataverse-main' -Target ([pscustomobject]@{ product = 'powerplatform'; environmentUrl = 'https://orgtestlab.crm.dynamics.com' }); $true
}
Check 'reserved identity is refused when inherited from a target' {
    Throws { Get-LabIdentity -Target ([pscustomobject]@{ identity = 'dverse-app-appauth' }) } 'reserved'
}
Check 'reserved identity is allowed when named explicitly' {
    (Get-LabIdentity -Name 'dverse-app-appauth').authMode -eq 'clientsecret'
}
Check 'destructive op blocked by default' { Throws { Assert-LabDestructive -Operation DELETE -ResourceDescription 'thing' -IsTracked } 'blocked' }
Check 'destructive op blocked for untracked resource' { Throws { Assert-LabDestructive -Operation DELETE -ResourceDescription 'thing' -Force } 'resource ledger' }

Check 'error extraction: Power BI shape' {
    (Get-LabApiError -RawBody '{"error":{"code":"ModelWithIncrementalRefreshIsNotDownloadable","message":"nope"}}' -Status 400).Code -eq 'ModelWithIncrementalRefreshIsNotDownloadable'
}
Check 'error extraction: garbage body' { $null -ne (Get-LabApiError -RawBody '<html>500</html>' -Status 500) }
Check 'JWT decode' {
    $t = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJodHRwczovL2dyYXBoLm1pY3Jvc29mdC5jb20iLCJ0aWQiOiJ0LTEiLCJhcHBpZCI6ImEtMSIsImV4cCI6MjAwMDAwMDAwMH0.x'
    (ConvertFrom-LabJwt $t).tid -eq 't-1'
}
Check 'scope mapping differs per API' {
    (Get-LabApiScope -Api Graph).Scope -ne (Get-LabApiScope -Api PowerBI).Scope -and (Get-LabApiScope -Api Fabric).Aud -eq 'https://api.fabric.microsoft.com'
}

# --- run + evidence + ledger (isolated ledger) -------------------------------
$env:LAB_LEDGER = Join-Path ([IO.Path]::GetTempPath()) "lab-selftest-$([guid]::NewGuid()).jsonl"
$run = Start-LabRun -Name 'framework-selftest' -Mode INSPECT -Product lab -Request 'offline self-test' -Plan @('assert', 'close') -DryRun

Check 'run scaffold created' { (Test-Path (Join-Path $run.Dir 'request.md')) -and (Test-Path (Join-Path $run.Dir 'plan.md')) -and (Test-Path (Join-Path $run.Dir 'metadata.json')) -and (Test-Path $run.RequestsDir) }
Check 'evidence saved' { Test-Path (Save-LabEvidence -Kind response -Name 'sample' -Content ([pscustomobject]@{ a = 1 })) }
Check 'logging writes to run log' { Write-LabLog 'self-test log line'; (Get-Content (Join-Path $run.LogsDir 'run.log') -Raw) -like '*self-test log line*' }
Check 'resource naming uses lab prefix' { $n = New-LabResourceName -Suffix 'x'; (Test-LabResourceName -Name $n) -and $n -like "*$($run.RunId)*" }
Check 'resource tracking round-trips' {
    Add-LabResource -Type 'selftest' -Id 'id-1' -Name (New-LabResourceName -Suffix 'x') -Api 'fabric' -DeleteUri 'https://api.fabric.microsoft.com/v1/x' | Out-Null
    (Get-LabResources -Type 'selftest').Count -eq 1
}
Check 'resource status change removes it from active set' {
    Set-LabResourceStatus -Resource (Get-LabResources -Type 'selftest')[0] -Status 'deleted' -Note 'selftest'
    (Get-LabResources -Type 'selftest').Count -eq 0
}
Check 'dry-run blocks writes but allows reads' {
    $r = Invoke-LabRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body @{ x = 1 } -Label 'dryrun-check'
    $r.DryRun -eq $true
}
Check 'run closes and writes result.md' {
    $d = $run.Dir
    Complete-LabRun -Verdict DONE -Summary 'self-test complete' | Out-Null
    (Get-Content (Join-Path $d 'result.md') -Raw) -like '*DONE*' -and ((Get-Content (Join-Path $d 'metadata.json') -Raw | ConvertFrom-Json).verdict -eq 'DONE')
}

Remove-Item $env:LAB_LEDGER -ErrorAction SilentlyContinue
Remove-Item Env:\LAB_LEDGER -ErrorAction SilentlyContinue
if (-not $KeepRun) { Remove-Item $run.Dir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n$pass passed, $fail failed`n" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
