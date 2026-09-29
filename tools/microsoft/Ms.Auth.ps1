# Ms.Auth.ps1 - Microsoft identity platform token acquisition for the lab.
#
# Secrets are NEVER read from config. Acquisition is driven by the identity's authMode:
#   clientsecret -> app-only client credentials, silent          (SharePoint / M365)
#   devicecode   -> delegated user sign-in, refresh-token cached (Dataverse / Power BI)
# $env:LAB_TOKEN_<API> always wins, for one-off debugging with a pasted token.
#
# Different Microsoft APIs need DIFFERENT audiences. Never assume one token works everywhere.

$script:MsTokenCache = @{}

# Delegated flows would otherwise demand a browser sign-in on every recipe run. Refresh tokens
# are cached in a git-ignored local file - same trust level as config/lab.secrets.local.json.
function Get-LabTokenCachePath { Join-Path $script:LabHome 'config\.tokencache.local.json' }

function Get-LabCachedRefreshToken {
    param([string]$Key)
    $p = Get-LabTokenCachePath
    if (-not (Test-Path $p)) { return $null }
    try { (Get-Content $p -Raw | ConvertFrom-Json).$Key } catch { $null }
}

function Save-LabCachedRefreshToken {
    param([string]$Key, [string]$RefreshToken)
    if ([string]::IsNullOrWhiteSpace($RefreshToken)) { return }
    $p = Get-LabTokenCachePath
    $o = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $o | Add-Member -NotePropertyName $Key -NotePropertyValue $RefreshToken -Force
    $o | ConvertTo-Json -Depth 5 | Set-Content $p -Encoding utf8
}

function Get-LabApiScope {
    param([Parameter(Mandatory)][string]$Api, $Target)
    $cfg = Get-LabConfig
    switch ($Api) {
        'Graph' { return @{ Scope = 'https://graph.microsoft.com/.default'; Aud = 'https://graph.microsoft.com' } }
        'PowerBI' { return @{ Scope = 'https://analysis.windows.net/powerbi/api/.default'; Aud = 'https://analysis.windows.net/powerbi/api' } }
        'Fabric' { return @{ Scope = 'https://api.fabric.microsoft.com/.default'; Aud = 'https://api.fabric.microsoft.com' } }
        'Dataverse' {
            if (-not $Target.environmentUrl) { throw "Dataverse token needs targets.<name>.environmentUrl in config." }
            $b = $Target.environmentUrl.TrimEnd('/')
            return @{ Scope = "$b/.default"; Aud = $b }
        }
        'SharePoint' {
            $domain = if ($Target.siteUrl) { ([Uri]$Target.siteUrl).Host } else { "$($cfg.tenant.domain -replace '\.onmicrosoft\.com$','').sharepoint.com" }
            # SPO issues tokens with aud = the Office 365 SharePoint Online resource GUID, not the host.
            return @{ Scope = "https://$domain/.default"; Aud = "https://$domain"; AltAud = @('00000003-0000-0ff1-ce00-000000000000') }
        }
        default { throw "Unknown API '$Api'. Known: Graph, PowerBI, Fabric, Dataverse, SharePoint." }
    }
}

function ConvertFrom-LabJwt {
    param([Parameter(Mandatory)][string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'Supplied value is not a JWT.' }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Show-LabTokenInfo {
    param([Parameter(Mandatory)][string]$Token, [string]$Label = 'token')
    $c = ConvertFrom-LabJwt $Token
    $exp = [DateTimeOffset]::FromUnixTimeSeconds($c.exp).ToLocalTime()
    $who = if ($c.upn) { $c.upn } elseif ($c.unique_name) { $c.unique_name } else { "app:$($c.appid)" }
    $perm = if ($c.roles) { "roles=$($c.roles -join ',')" } elseif ($c.scp) { "scp=$($c.scp)" } else { 'perms=<none>' }
    Write-LabLog "$Label aud=$($c.aud) tid=$($c.tid) id=$who $perm exp=$($exp.ToString('u'))" -Level INFO
    if ($exp -lt (Get-Date)) { Write-LabLog "$Label is EXPIRED" -Level WARN }
    return $c
}

function Get-LabAccessToken {
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'PowerBI', 'Fabric', 'Dataverse', 'SharePoint')][string]$Api,
        $Target,
        [string]$Identity,
        [switch]$Force,
        [switch]$NoPrompt,     # never start an interactive device-code flow (status checks)
        [string]$Scope         # explicit delegated scopes instead of /.default
    )
    $cfg = Get-LabConfig
    $ident = Get-LabIdentity -Target $Target -Name $Identity -Explicit:([bool]$Identity)
    $cacheKey = "$Api|$($Target._name)|$($ident._name)|$Scope"
    if (-not $Force -and $script:MsTokenCache.ContainsKey($cacheKey)) { return $script:MsTokenCache[$cacheKey] }

    $res = Get-LabApiScope -Api $Api -Target $Target
    # /.default only ever returns already-consented permissions, which is useless for bootstrap:
    # the app-registration recipe has to ask for Application.ReadWrite.All before anyone has
    # consented to it. An explicit scope makes Entra prompt for exactly that.
    if ($Scope) { $res = @{ Scope = $Scope; Aud = $res.Aud; AltAud = $res.AltAud } }
    $tokenUri = "https://login.microsoftonline.com/$($cfg.tenant.id)/oauth2/v2.0/token"
    Assert-LabApiHost -Uri $tokenUri
    $token = $null

    $cacheKeyRt = "$($cfg.tenant.id)|$($ident.clientId)"
    $envName = "LAB_TOKEN_$($Api.ToUpper())"
    $raw = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        Write-LabLog "using token from `$env:$envName" -Level INFO
        $token = $raw.Trim()
    }
    elseif ($ident.authMode -eq 'certificate') {
        # Required for SharePoint REST app-only; also valid everywhere a secret would work.
        $pfx = if ($ident.certPath) { Join-Path $script:LabHome $ident.certPath } else { Join-Path $script:LabHome 'config\lab-app-cert.local.pfx' }
        $pwEnv = if ($ident.certPasswordEnvVar) { $ident.certPasswordEnvVar } else { 'LAB_CERT_PASSWORD' }
        $pw = [Environment]::GetEnvironmentVariable($pwEnv)
        if ([string]::IsNullOrWhiteSpace($pw)) { throw "Identity '$($ident._name)' is authMode=certificate but `$env:$pwEnv is not set." }
        $cert = Get-LabCertificate -PfxPath $pfx -Password $pw
        Write-LabLog "acquiring $Api token via certificate (app-only) as '$($ident._name)' [thumbprint $($cert.Thumbprint)]" -Level INFO
        $assertion = New-LabClientAssertion -Certificate $cert -ClientId $ident.clientId -TokenUri $tokenUri
        $resp = Invoke-WebRequest -Method Post -Uri $tokenUri -SkipHttpErrorCheck -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id             = $ident.clientId
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $assertion
            scope                 = $res.Scope
            grant_type            = 'client_credentials'
        }
        $j = try { $resp.Content | ConvertFrom-Json } catch { $null }
        if ([int]$resp.StatusCode -ne 200) {
            $hint = if ("$($j.error_description)" -match 'AADSTS700027|AADSTS700�|not found.*certificate|Client assertion') {
                " -> the certificate's public key (.cer) is probably not uploaded to the app registration yet."
            }
            else { '' }
            throw "AAD certificate token request failed (HTTP $([int]$resp.StatusCode)): $($j.error) - $(($j.error_description -split "`r?`n")[0])$hint"
        }
        $token = $j.access_token
    }
    elseif ($ident.authMode -eq 'clientsecret') {
        $secretEnv = if ($ident.secretEnvVar) { $ident.secretEnvVar } else { 'LAB_CLIENT_SECRET' }
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($secretEnv))) {
            throw "Identity '$($ident._name)' is authMode=clientsecret but `$env:$secretEnv is not set."
        }
        Write-LabLog "acquiring $Api token via client credentials (app-only) as '$($ident._name)' [$($ident.displayName)]" -Level INFO
        $resp = Invoke-WebRequest -Method Post -Uri $tokenUri -SkipHttpErrorCheck -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id = $ident.clientId; client_secret = [Environment]::GetEnvironmentVariable($secretEnv)
            scope     = $res.Scope; grant_type = 'client_credentials'
        }
        $j = try { $resp.Content | ConvertFrom-Json } catch { $null }
        if ([int]$resp.StatusCode -ne 200) {
            # Surface the AAD error itself - "400 Bad Request" alone is useless for diagnosis.
            throw "AAD token request failed (HTTP $([int]$resp.StatusCode)): $($j.error) - $($j.error_description -split "`r?`n" | Select-Object -First 1)"
        }
        $token = $j.access_token
    }
    else {
        # Delegated. Try a cached refresh token first so repeat runs are silent.
        $rt = Get-LabCachedRefreshToken -Key $cacheKeyRt
        if ($rt) {
            Write-LabLog "refreshing delegated $Api token as '$($ident._name)'" -Level INFO
            $rr = Invoke-WebRequest -Method Post -Uri $tokenUri -SkipHttpErrorCheck -ContentType 'application/x-www-form-urlencoded' -Body @{
                client_id = $ident.clientId; grant_type = 'refresh_token'; refresh_token = $rt; scope = "$($res.Scope) offline_access"
            }
            $rj = try { $rr.Content | ConvertFrom-Json } catch { $null }
            if ([int]$rr.StatusCode -eq 200) {
                $token = $rj.access_token
                Save-LabCachedRefreshToken -Key $cacheKeyRt -RefreshToken $rj.refresh_token
            }
            else { Write-LabLog "refresh failed ($($rj.error)) - falling back to device code" -Level WARN }
        }
    }
    if (-not $token -and $NoPrompt -and $ident.authMode -eq 'devicecode') {
        throw "No cached delegated session for '$($ident._name)'. Run the recipe interactively once to sign in."
    }
    if (-not $token -and $ident.authMode -ne 'clientsecret' -and $ident.authMode -ne 'certificate' -and [string]::IsNullOrWhiteSpace($raw)) {
        Write-LabLog "acquiring $Api token via device code (delegated) as '$($ident._name)' [$($ident.displayName)]" -Level INFO
        $dcr = Invoke-WebRequest -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenant.id)/oauth2/v2.0/devicecode" `
            -SkipHttpErrorCheck -ContentType 'application/x-www-form-urlencoded' -Body @{ client_id = $ident.clientId; scope = "$($res.Scope) offline_access" }
        $dc = try { $dcr.Content | ConvertFrom-Json } catch { $null }
        if ([int]$dcr.StatusCode -ne 200) {
            $hint = if ("$($dc.error_description)" -match 'AADSTS7000218|public client') {
                " -> Entra: App registrations > $($ident.displayName) > Authentication > 'Allow public client flows' must be set to Yes."
            }
            else { '' }
            throw "Device code request failed: $($dc.error) - $(($dc.error_description -split "`r?`n")[0])$hint"
        }
        Write-Host ''
        Write-Host "  ==> Open $($dc.verification_uri) and enter code: $($dc.user_code)" -ForegroundColor Yellow
        Write-Host ''
        $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
        while ((Get-Date) -lt $deadline -and -not $token) {
            Start-Sleep -Seconds ([int]$dc.interval)
            $resp = Invoke-WebRequest -Method Post -Uri $tokenUri -SkipHttpErrorCheck -ContentType 'application/x-www-form-urlencoded' `
                -Body @{ client_id = $ident.clientId; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $dc.device_code }
            $j = $resp.Content | ConvertFrom-Json
            if ([int]$resp.StatusCode -eq 200) {
                $token = $j.access_token
                Save-LabCachedRefreshToken -Key $cacheKeyRt -RefreshToken $j.refresh_token
            }
            elseif ($j.error -notin 'authorization_pending', 'slow_down') { throw "Device code failed: $($j.error) - $($j.error_description)" }
        }
        if (-not $token) { throw 'Device code sign-in timed out.' }
    }

    $claims = Show-LabTokenInfo -Token $token -Label "[$Api]"
    Assert-LabTokenClaims -Claims $claims          # hard tenant boundary, checked on the real credential
    if ($claims.aud -notlike "*$($res.Aud)*" -and $res.Aud -notlike "*$($claims.aud)*" -and $claims.aud -notin @($res.AltAud)) {
        Write-LabLog "token audience '$($claims.aud)' does not match expected '$($res.Aud)' for $Api - calls may 401" -Level WARN
    }
    $script:MsTokenCache[$cacheKey] = $token
    return $token
}

