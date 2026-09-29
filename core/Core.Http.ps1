# Core.Http.ps1 - the single HTTP path for the whole lab.
# Every API call goes through here so that host allow-listing, dry-run, evidence capture
# and structured error extraction are impossible to forget.

function Get-LabApiError {
    param([string]$RawBody, [int]$Status)
    $code = $null; $message = $null
    try {
        $j = $RawBody | ConvertFrom-Json -ErrorAction Stop
        $code = $j.error.code ?? $j.error_description ?? $j.errorCode ?? $j.code ?? $j.'odata.error'.code
        $message = $j.error.message ?? $j.message ?? $j.error_description
        if ($message -is [pscustomobject]) { $message = $message.value }
        # Power BI nests the interesting code inside pbi.error.code / detail
        if (-not $code -and $j.error.pbi) { $code = $j.error.pbi.code }
    }
    catch { }
    if (-not $code -and $RawBody -match '"code"\s*:\s*"([^"]+)"') { $code = $Matches[1] }
    [pscustomobject]@{ Status = $Status; Code = $code; Message = $message }
}

# Shared by both the request and response evidence paths below - strips known-sensitive element
# values out of a string body before it reaches runs/. Only string bodies can be redacted (an
# already-parsed JSON object has no XML/JSON element text to regex against); the request and
# response sides used to duplicate this loop, so it's factored out once here.
function Protect-LabEvidenceBody {
    param($Body, [string[]]$RedactElements = @())
    foreach ($el in $RedactElements) {
        if ($Body -is [string]) { $Body = [regex]::Replace($Body, "(?is)(<$el>)(.+?)(</$el>)", '$1[REDACTED]$3') }
    }
    return $Body
}

function Invoke-LabRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [string]$Token,
        $Body,
        [hashtable]$Headers = @{},
        [string]$OutFile,
        [string]$ContentType = 'application/json',
        [string]$Label,
        [switch]$NoEvidence,
        [switch]$AllowInDryRun,          # for reads that must still happen during a dry run
        [string[]]$RedactElements = @()  # XML/JSON element names whose values must never reach evidence
    )
    Assert-LabApiHost -Uri $Uri
    if (-not $Label) { $Label = "$Method-" + (([Uri]$Uri).AbsolutePath.Trim('/') -replace '[^A-Za-z0-9]', '-') }
    if ($Label.Length -gt 70) { $Label = $Label.Substring(0, 70) }

    $isRead = $Method -in 'GET', 'HEAD'
    if ($script:LabDryRun -and -not $isRead -and -not $AllowInDryRun) {
        Write-LabLog "DRY-RUN skip: $Method $Uri" -Level WARN
        return [pscustomobject]@{ Status = 0; Ok = $false; DryRun = $true; Raw = ''; Json = $null; Error = $null; Headers = @{}; Uri = $Uri; Method = $Method }
    }

    $h = @{} + $Headers
    if ($Token) { $h['Authorization'] = "Bearer $Token" }

    $params = @{ Uri = $Uri; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true; MaximumRedirection = 5 }
    if ($null -ne $Body) {
        $params.Body = if ($Body -is [string] -or $Body -is [byte[]]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
        $params.ContentType = $ContentType
    }
    if ($OutFile) { $params.OutFile = $OutFile; $params.PassThru = $true }

    if (-not $NoEvidence -and $script:LabRun) {
        # Never serialise a binary body: a 6 KB PNG becomes a 55 KB JSON array of integers, which
        # is useless as evidence and expensive for anything that later reads the file.
        $evReqBody = if ($Body -is [byte[]]) { "<binary body, $($Body.Length) bytes, not serialised>" }
        elseif ($Body -is [string] -and $Body.Length -gt 20000) { "<string body, $($Body.Length) chars, truncated>`n" + $Body.Substring(0, 20000) }
        else { $Body }
        $evReqBody = Protect-LabEvidenceBody -Body $evReqBody -RedactElements $RedactElements
        Save-LabEvidence -Kind request -Name $Label -Content ([pscustomobject]@{
                sentUtc = (Get-Date).ToUniversalTime().ToString('o'); method = $Method; uri = $Uri
                headers = @($h.Keys | Where-Object { $_ -ne 'Authorization' }); authorization = $(if ($Token) { '<redacted bearer token>' } else { $null })
                body    = $evReqBody
            }) | Out-Null
    }

    Write-LabLog "$Method $Uri" -Level DEBUG
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $resp = Invoke-WebRequest @params }
    catch {
        $sw.Stop()
        Write-LabLog "transport failure: $($_.Exception.Message)" -Level ERROR
        $r = [pscustomobject]@{ Status = -1; Ok = $false; DryRun = $false; Raw = $_.Exception.Message; Json = $null
            Error = [pscustomobject]@{ Status = -1; Code = 'TransportFailure'; Message = $_.Exception.Message }
            Headers = @{}; Uri = $Uri; Method = $Method; ElapsedMs = 0
        }
        if (-not $NoEvidence -and $script:LabRun) { Save-LabEvidence -Kind response -Name "$Label-transport-error" -Content $r | Out-Null }
        return $r
    }
    $sw.Stop()

    $status = [int]$resp.StatusCode
    $raw = if ($OutFile) { try { Get-Content $OutFile -Raw -ErrorAction Stop } catch { '' } } else { [string]$resp.Content }
    $ok = ($status -ge 200 -and $status -lt 300)
    $json = $null
    if ($raw) {
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
        catch {
            # SharePoint returns both "Id" and "ID"; ConvertFrom-Json rejects keys differing only
            # by case. Fall back to a case-sensitive hashtable rather than silently yielding null.
            try { $json = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
            catch { Write-LabLog "response body did not parse as JSON ($($_.Exception.Message.Split([char]10)[0]))" -Level DEBUG }
        }
    }

    $result = [pscustomobject]@{
        Status    = $status
        Ok        = $ok
        DryRun    = $false
        Raw       = $raw
        Json      = $json
        Error     = $(if ($ok) { $null } else { Get-LabApiError -RawBody $raw -Status $status })
        Headers   = $resp.Headers
        Uri       = $Uri
        Method    = $Method
        ElapsedMs = [int]$sw.ElapsedMilliseconds
        OutFile   = $OutFile
    }

    $lvl = if ($ok) { 'OK' } else { 'WARN' }
    Write-LabLog "HTTP $status ($($result.ElapsedMs)ms)$(if (-not $ok -and $result.Error.Code) { " code=$($result.Error.Code)" })" -Level $lvl

    if (-not $NoEvidence -and $script:LabRun) {
        $evBody = $(if ($json) { $json } elseif ($OutFile) { "<binary saved to $(Split-Path $OutFile -Leaf)>" } else { $raw })
        $evBody = Protect-LabEvidenceBody -Body $evBody -RedactElements $RedactElements
        $ev = [pscustomobject]@{
            capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
            method      = $Method; uri = $Uri; httpStatus = $status; elapsedMs = $result.ElapsedMs
            requestId   = ($resp.Headers['RequestId'] | Select-Object -First 1)
            errorCode   = $result.Error.Code
            body        = $evBody
        }
        $result | Add-Member -NotePropertyName EvidenceFile -NotePropertyValue (Save-LabEvidence -Kind response -Name $Label -Content $ev) -Force
    }
    return $result
}
