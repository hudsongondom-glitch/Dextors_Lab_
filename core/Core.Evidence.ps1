# Core.Evidence.ps1 - writes artifacts into the current run (runs/<run>/requests|responses|logs)
# and the running list of evidence notes shown in result.md. Run scaffold/lifecycle itself lives
# in Core.Run.ps1; this only writes files and notes into a run that Start-LabRun already opened.

# Writes an arbitrary artifact into the run. Returns the file path.
function Save-LabEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Content,
        [ValidateSet('request', 'response', 'log')][string]$Kind = 'response',
        [string]$Extension = 'json'
    )
    if (-not $script:LabRun) { throw 'Save-LabEvidence called outside a run. Call Start-LabRun first.' }
    $dir = switch ($Kind) { 'request' { $script:LabRun.RequestsDir } 'response' { $script:LabRun.ResponsesDir } default { $script:LabRun.LogsDir } }
    $seq = '{0:d3}' -f (++$script:LabSeq)
    $safe = ($Name -replace '[^A-Za-z0-9\-\._]', '-')
    $file = Join-Path $dir "$seq-$safe.$Extension"
    if ($Content -is [string]) { Set-Content -Path $file -Value $Content -Encoding utf8 }
    else { $Content | ConvertTo-Json -Depth 30 | Set-Content -Path $file -Encoding utf8 }
    return $file
}

function Add-LabEvidenceNote {
    param([Parameter(Mandatory)][string]$Note)
    if ($script:LabRun) { $script:LabRun.Evidence.Add($Note) }
    Write-LabLog $Note -Level INFO
}
