<#
Creates a Gen1 (Power BI) dataflow by generating a CDM model.json and importing it through the
Power BI Imports API.

Why Gen1 specifically: Gen2 dataflows are invisible to the legacy Power BI REST dataflow API (see
powerbi/dataflow-gen2-visibility), so a backup product enumerating dataflows the documented way sees
nothing. Gen1 dataflows DO appear there, and they work on shared capacity, so this also fills the
gap in a Pro workspace where Gen2 is refused outright.

There is no public "create dataflow" endpoint. The Imports API was the only candidate programmatic
route, and it does NOT work - established here, not assumed:

    payload 1.1 KB  -> HTTP 403 ImportSizeErrorCode
    payload  30 KB  -> HTTP 403 ImportSizeErrorCode
    payload 111 KB  -> HTTP 403 ImportSizeErrorCode
    ... all with Content.Create granted and present in the token's scp claim.

Identical results across a 100x size range rule out the error code's own explanation, and the scope
was verified present, so it is neither size nor permissions. The portal's "Import Model" uses an
internal endpoint that is not exposed publicly.

The recipe therefore expects to FAIL at the import step. Its real output is the model.json on disk
plus exact portal steps - Gen1 creation is a manual operation, and this makes it a two-minute one.

The mashup is identical to the Gen2 one (New-LabSeedMashup), so the two generations hold the same
six queries and a restore can be compared across them.

Verdict meaning (explicit):
  PASS         = a Gen1 dataflow exists in the workspace and the legacy Power BI API lists it.
  FAIL         = the import was refused; model.json written to disk, manual steps printed.
  INCONCLUSIVE = import accepted but the dataflow never appeared in the legacy API.
  BLOCKED      = config/credentials missing.

  .\lab.ps1 BUILD powerbi/build-gen1-dataflow -Target powerbi-main
  .\lab.ps1 BUILD powerbi/build-gen1-dataflow -Target powerbi-fabric -SalesRows 500
  .\lab.ps1 BUILD powerbi/build-gen1-dataflow -Target powerbi-main -WriteOnly
#>
[CmdletBinding()]
param(
    [string]$Mode = 'BUILD',
    [string]$Target = 'powerbi-main',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$LabInfo,
    [string]$Identity,
    [int]$SalesRows = 1000,
    [switch]$WriteOnly,           # generate model.json, skip the import attempt
    [string]$OutputPath
)

$Recipe = @{
    Name        = 'powerbi/build-gen1-dataflow'
    Product     = 'powerbi'
    Modes       = @('BUILD', 'TEST')
    Destructive = $false
    Description = 'Create a Gen1 Power BI dataflow from a generated CDM model.json via the Imports API; falls back to portal import steps.'
}
if ($LabInfo) { return $Recipe }

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('workspaceId')
if ($SalesRows -lt 1 -or $SalesRows -gt 20000) { $problems = @($problems) + '-SalesRows must be between 1 and 20000.' }

$run = Start-LabRun -Name 'pbi-build-gen1-dataflow' -Mode $Mode -Product powerbi -Target $Target -DryRun:$DryRun `
    -Request 'Create a Gen1 Power BI dataflow, which unlike Gen2 is visible to the legacy Power BI REST dataflow API and therefore to anything enumerating dataflows the documented way.' `
    -Plan @(
    'Build the shared six-query mashup'
    'Emit a CDM model.json with one LocalEntity per query'
    'Write model.json to disk as a fallback for manual import'
    'POST it to the Imports API as multipart/form-data'
    'Poll the import to completion'
    'Confirm the dataflow is listed by the legacy Power BI REST dataflow API'
)
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep 'Fix config and rerun.'; return }

$tgt = Get-LabTarget -Name $Target
$ws = $tgt.workspaceId
Add-LabEvidenceNote "workspace: $ws ($($tgt.workspaceName))"

if (-not $OutputPath) { $OutputPath = Join-Path (Get-LabHome) 'artifacts\dataflows' }

# --- build model.json --------------------------------------------------------

Write-LabStep "building mashup ($SalesRows sales rows)"
$seed = New-LabSeedMashup -SalesRowCount $SalesRows
$dfName = New-LabResourceName -Suffix 'dfgen1'
Add-LabEvidenceNote "mashup: $($seed.Definitions.Count) queries ($($seed.Definitions.Keys -join ', '))"

Write-LabStep 'building CDM model.json'

$entities = @()
foreach ($qName in $seed.Schema.Keys) {
    $attrs = @()
    foreach ($col in $seed.Schema[$qName].Keys) {
        $attrs += [ordered]@{
            name        = $col
            dataType    = $seed.Schema[$qName][$col]
            description = ''
        }
    }
    $entities += [ordered]@{
        '$type'            = 'LocalEntity'
        name               = $qName
        description        = ''
        'pbi:refreshPolicy' = [ordered]@{
            '$type'   = 'FullRefreshPolicy'
            location = "$qName.csv"
        }
        attributes         = $attrs
    }
}

$queriesMetadata = [ordered]@{}
foreach ($qName in $seed.Definitions.Keys) {
    $queriesMetadata[$qName] = [ordered]@{
        queryId     = [guid]::NewGuid().ToString()
        queryName   = $qName
        loadEnabled = $true
    }
}

# The Gen1 model.json carries the M section document inline under pbi:mashup.document - the same
# text that Gen2 stores as a separate mashup.pq part.
$model = [ordered]@{
    name         = $dfName
    description  = 'Dextors Lab Gen1 seed dataflow'
    version      = '1.0'
    culture      = 'en-US'
    modifiedTime = (Get-Date).ToUniversalTime().ToString('o')
    'pbi:mashup' = [ordered]@{
        fastCombine        = $false
        allowNativeQueries = $false
        queriesMetadata    = $queriesMetadata
        document           = $seed.Document
    }
    annotations  = @(
        [ordered]@{ name = 'pbi:QueryGroups'; value = '[]' }
    )
    entities     = $entities
}
$modelJson = $model | ConvertTo-Json -Depth 30

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$modelPath = Join-Path $OutputPath "$dfName.model.json"
[IO.File]::WriteAllText($modelPath, $modelJson, [Text.UTF8Encoding]::new($false))
Save-LabEvidence -Kind request -Name 'gen1-model' -Content $modelJson -Extension 'json' | Out-Null
Add-LabEvidenceNote "model.json written: $modelPath ($([math]::Round($modelJson.Length / 1KB)) KB, $($entities.Count) entities)"

function Show-ManualSteps {
    param([string]$Reason)
    Write-Host ''
    Write-Host '  Import it by hand instead:' -ForegroundColor Cyan
    Write-Host "    1. https://app.powerbi.com  ->  open the '$($tgt.workspaceName)' workspace"
    Write-Host '    2. + New item  ->  Dataflow  (Gen1; on a Fabric workspace pick "Dataflow" not "Dataflow Gen2")'
    Write-Host '    3. Choose  "Import Model"'
    Write-Host "    4. Select:  $modelPath"
    Write-Host '    5. Save, name it when prompted, then Refresh now'
    Write-Host ''
    Write-Host "    Then confirm the legacy API can see it:  .\lab.ps1 REPRODUCE powerbi/dataflow-gen2-visibility -Target $Target -NoCreate" -ForegroundColor Cyan
    Write-LabLog "manual import required: $Reason" -Level WARN
}

if ($WriteOnly) {
    Show-ManualSteps -Reason '-WriteOnly specified'
    Complete-LabRun -Verdict DONE -Summary "model.json generated at $modelPath; import skipped (-WriteOnly)." | Out-Null
    return
}
if ($script:LabRun.DryRun) {
    Complete-LabRun -Verdict DONE -Summary "Dry run: model.json generated at $modelPath, no import attempted." | Out-Null
    return
}

# --- import ------------------------------------------------------------------

Write-LabStep 'importing model.json'
$pbiToken = Get-LabAccessToken -Api PowerBI -Target $tgt -Identity $Identity

# The Imports API requires the dataflow payload to be filed as 'model.json'.
$boundary = "----LabBoundary$([guid]::NewGuid().ToString('N'))"
$nl = "`r`n"
$head = "--$boundary$nl" +
"Content-Disposition: form-data; name=`"model.json`"; filename=`"model.json`"$nl" +
"Content-Type: application/json$nl$nl"
$tail = "$nl--$boundary--$nl"
$bytes = [byte[]]@(
    [Text.Encoding]::UTF8.GetBytes($head) +
    [Text.Encoding]::UTF8.GetBytes($modelJson) +
    [Text.Encoding]::UTF8.GetBytes($tail)
)

$uri = "https://api.powerbi.com/v1.0/myorg/groups/$ws/imports?datasetDisplayName=model.json&nameConflict=GenerateUniqueName"
$imp = Invoke-LabRequest -Method POST -Uri $uri -Token $pbiToken -Body $bytes `
    -ContentType "multipart/form-data; boundary=$boundary" -Label 'import-gen1-dataflow'

if (-not $imp.Ok) {
    $ev = @(
        "import HTTP $($imp.Status) code=$($imp.Error.Code) $($imp.Error.Message)"
        "model.json: $modelPath ($([math]::Round($modelJson.Length / 1KB)) KB)"
    )

    # ESTABLISHED 2026-08-09, not a guess: HTTP 403 ImportSizeErrorCode comes back for payloads of
    # 1.1 KB, 30 KB and 111 KB alike, with Content.Create present in the token. So the code is
    # misleading - it is neither a size limit nor a missing scope. The public Imports API does not
    # accept a dataflow model.json; the portal's Import Model uses a different, internal path.
    # Treat this FAIL as the expected outcome and use the manual steps.
    $note = ''
    if ($imp.Status -in 401, 403) {
        $scp = (ConvertFrom-LabJwt $pbiToken).scp
        $note = " Token scopes: '$scp'."
        $ev += 'known: ImportSizeErrorCode is returned at any payload size with Content.Create granted - the public Imports API does not accept dataflow model.json'
    }

    Show-ManualSteps -Reason "Imports API returned HTTP $($imp.Status) $($imp.Error.Code)"
    Complete-LabRun -Verdict FAIL -Summary "The Imports API refused the dataflow model.json (HTTP $($imp.Status) code=$($imp.Error.Code)).$note This is the expected result: there is no public create-dataflow endpoint and the Imports API rejects model.json regardless of size or scope. Import by hand using the printed steps." -Evidence $ev | Out-Null
    return
}

$importId = $imp.Json.id
Write-LabLog "import accepted, id=$importId - polling" -Level INFO
$state = $null
for ($i = 0; $i -lt 30 -and $state -ne 'Succeeded'; $i++) {
    Start-Sleep -Seconds 3
    $st = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/imports/$importId" -Token $pbiToken -Label 'import-status' -NoEvidence
    $state = $st.Json.importState
    if ($state -eq 'Failed') { Write-LabLog "import failed: $($st.Raw)" -Level ERROR; break }
}
Add-LabEvidenceNote "import state: $state"

# --- verify against the legacy API ------------------------------------------

Write-LabStep 'verifying via the legacy Power BI dataflow API'
$list = Invoke-LabRequest -Uri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dataflows" -Token $pbiToken -Label 'list-gen1-dataflows'
$found = @($list.Json.value | Where-Object { Test-LabResourceName -Name $_.name })

foreach ($d in $found) {
    Add-LabResource -Type 'powerbi-dataflow-gen1' -Id $d.objectId -Name $d.name -Target $tgt._name -Api 'powerbi' `
        -DeleteUri "https://api.powerbi.com/v1.0/myorg/groups/$ws/dataflows/$($d.objectId)" | Out-Null
}

Write-Host ''
Write-Host "  Legacy Power BI dataflow API: $(@($list.Json.value).Count) dataflow(s)"
foreach ($d in @($list.Json.value)) { Write-Host "     $($d.objectId)  '$($d.name)'" }

$ev = @(
    "model.json: $modelPath"
    "import state: $state"
    "legacy API now lists $(@($list.Json.value).Count) dataflow(s); $($found.Count) lab-owned"
)

if ($found.Count -gt 0) {
    Complete-LabRun -Verdict PASS -Summary "Gen1 dataflow created and visible to the legacy Power BI REST dataflow API - unlike Gen2, which the same endpoint does not return." -Evidence $ev | Out-Null
}
else {
    Show-ManualSteps -Reason "import reported '$state' but no lab-owned dataflow is listed"
    Complete-LabRun -Verdict INCONCLUSIVE -Summary "Import reported '$state' but the legacy API lists no lab-owned dataflow." -Evidence $ev | Out-Null
}
