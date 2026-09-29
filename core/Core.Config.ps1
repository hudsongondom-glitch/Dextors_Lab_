# Core.Config.ps1 - configuration and target resolution. Never reads or stores secrets.

# Shared "load a required JSON file, or throw a specific message" pattern used by both
# Get-LabConfig and Get-LabPolicy below - they differed only in path and missing-file message.
function Get-LabJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MissingMessage)
    if (-not (Test-Path $Path)) { throw $MissingMessage }
    Get-Content $Path -Raw | ConvertFrom-Json
}

function Get-LabConfig {
    if ($script:LabConfigCache) { return $script:LabConfigCache }
    $path = if ($env:LAB_CONFIG) { $env:LAB_CONFIG } else { Join-Path $script:LabHome 'config\lab.config.json' }
    $script:LabConfigCache = Get-LabJsonFile -Path $path -MissingMessage "Lab config not found: $path - run: lab.ps1 BUILD lab/init"
    $script:LabConfigCache | Add-Member -NotePropertyName '_path' -NotePropertyValue $path -Force
    return $script:LabConfigCache
}

# Loads config/lab.secrets.local.json (git-ignored) into process env vars.
# Existing env vars always win, so a session variable can override the file.
# Values are never logged, never echoed, never written to evidence.
function Import-LabSecrets {
    $path = Join-Path $script:LabHome 'config\lab.secrets.local.json'
    if (-not (Test-Path $path)) { return }
    $loaded = @()
    (Get-Content $path -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
        if ($_.Name -like '_*') { return }
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_.Name))) {
            [Environment]::SetEnvironmentVariable($_.Name, $_.Value)
            $loaded += $_.Name
        }
    }
    if ($loaded.Count) { Write-LabLog "loaded $($loaded.Count) secret(s) from lab.secrets.local.json: $($loaded -join ', ')" -Level DEBUG }
}

# Config and policy are cached for the life of a run. lab/init writes them mid-run, so it needs
# to drop the cache before the freshly written files are read back.
function Reset-LabConfigCache {
    $script:LabConfigCache = $null
    $script:LabPolicyCache = $null
}

function Get-LabPolicy {
    if ($script:LabPolicyCache) { return $script:LabPolicyCache }
    $path = Join-Path $script:LabHome 'config\lab.policy.json'
    $script:LabPolicyCache = Get-LabJsonFile -Path $path -MissingMessage "Lab policy not found: $path - run: lab.ps1 BUILD lab/init"
    return $script:LabPolicyCache
}

# Resolves .targets.<TargetName> from config and reports a problem if it's named but not
# defined. Returns the resolved target object, or $null if no name was given. Shared by both
# branches of Test-LabConfigReady below, which used to duplicate this resolve-and-report step.
function Resolve-LabConfigTarget {
    param($Config, [string]$TargetName, [System.Collections.Generic.List[string]]$Problems)
    if (-not $TargetName) { return $null }
    $t = $Config.targets.$TargetName
    if (-not $t) { $Problems.Add("config/lab.config.json -> targets.$TargetName is not defined.") }
    return $t
}

# Reports a problem for each required field that's empty on an already-resolved target.
function Add-LabRequiredTargetFieldProblems {
    param($ResolvedTarget, [string]$TargetName, [string[]]$RequiredTargetFields, [System.Collections.Generic.List[string]]$Problems)
    if (-not $ResolvedTarget) { return }
    foreach ($f in $RequiredTargetFields) {
        if ([string]::IsNullOrWhiteSpace($ResolvedTarget.$f)) { $Problems.Add("config/lab.config.json -> targets.$TargetName.$f is empty.") }
    }
}

# Returns a list of human-readable problems with the current configuration. Empty = ready.
function Test-LabConfigReady {
    param(
        [string]$Target,
        [string[]]$RequiredTargetFields,
        [switch]$SkipMicrosoftIdentity,        # for products that do not authenticate via Entra ID
        [string[]]$RequiredEnvVars,            # extra secrets this recipe needs
        [string]$Identity                      # check this identity explicitly instead of the target's default (e.g. a recipe that authenticates with a non-default identity such as a certificate credential)
    )
    $problems = [System.Collections.Generic.List[string]]::new()

    try { $cfg = Get-LabConfig } catch { $problems.Add($_.Exception.Message); return $problems }
    try { $pol = Get-LabPolicy } catch { $problems.Add($_.Exception.Message); return $problems }

    foreach ($v in $RequiredEnvVars) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v))) {
            $problems.Add("Environment variable `$env:$v is not set (add it to config/lab.secrets.local.json).")
        }
    }

    if ($SkipMicrosoftIdentity) {
        $t = Resolve-LabConfigTarget -Config $cfg -TargetName $Target -Problems $problems
        Add-LabRequiredTargetFieldProblems -ResolvedTarget $t -TargetName $Target -RequiredTargetFields $RequiredTargetFields -Problems $problems
        return $problems
    }

    if ([string]::IsNullOrWhiteSpace($cfg.tenant.id)) { $problems.Add("config/lab.config.json -> tenant.id is empty (your test tenant's Directory ID).") }
    if (-not $pol.allowedTenantIds -or $pol.allowedTenantIds.Count -eq 0) { $problems.Add("config/lab.policy.json -> allowedTenantIds is empty. Add your test tenant id; the lab refuses to authenticate otherwise.") }
    elseif ($cfg.tenant.id -and $cfg.tenant.id -notin $pol.allowedTenantIds) { $problems.Add("config/lab.config.json tenant.id is not listed in config/lab.policy.json allowedTenantIds.") }

    $t = Resolve-LabConfigTarget -Config $cfg -TargetName $Target -Problems $problems

    $ident = try { Get-LabIdentity -Target $t -Name $Identity -Explicit:([bool]$Identity) } catch { $problems.Add($_.Exception.Message); $null }
    if ($ident) {
        if ([string]::IsNullOrWhiteSpace($ident.clientId)) { $problems.Add("config/lab.config.json -> identity '$($ident._name)' has no clientId.") }
        switch ($ident.authMode) {
            'clientsecret' {
                $envName = if ($ident.secretEnvVar) { $ident.secretEnvVar } else { 'LAB_CLIENT_SECRET' }
                if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
                    $problems.Add("Environment variable `$env:$envName is not set (client secret for '$($ident._name)' / $($ident.displayName)). Add it to config/lab.secrets.local.json.")
                }
            }
            'certificate' {
                # Mirrors the clientsecret check above: a certificate identity needs a PFX on disk
                # (Get-LabCertificate resolves the same default path when certPath is unset) and its
                # password env var, so both are validated here rather than failing later with an
                # opaque error the first time Get-LabAccessToken tries to sign a token request.
                $certPath = if ($ident.certPath) { Join-Path $script:LabHome $ident.certPath } else { Join-Path $script:LabHome 'config\lab-app-cert.local.pfx' }
                if (-not (Test-Path $certPath)) {
                    $problems.Add("Certificate not found for identity '$($ident._name)': $certPath. Run: .\lab.ps1 BUILD lab/setup-app-certificate -Identity $($ident._name), then upload the .cer to the app registration.")
                }
                $pwEnv = if ($ident.certPasswordEnvVar) { $ident.certPasswordEnvVar } else { 'LAB_CERT_PASSWORD' }
                if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($pwEnv))) {
                    $problems.Add("Environment variable `$env:$pwEnv is not set (certificate password for '$($ident._name)' / $($ident.displayName)). Add it to config/lab.secrets.local.json.")
                }
            }
            'devicecode' { }
            'token' { $problems.Add("authMode 'token' requires a per-resource token env var, e.g. `$env:LAB_TOKEN_GRAPH.") }
            default { $problems.Add("config/lab.config.json -> identity '$($ident._name)' authMode must be clientsecret, certificate, devicecode or token.") }
        }
    }

    Add-LabRequiredTargetFieldProblems -ResolvedTarget $t -TargetName $Target -RequiredTargetFields $RequiredTargetFields -Problems $problems
    return $problems
}

# Resolves which app registration to use. A target may name one via its "identity" field;
# otherwise the top-level "identity" block is the default.
function Get-LabIdentity {
    param($Target, [string]$Name, [switch]$Explicit)
    $cfg = Get-LabConfig
    if ($Name) { $Explicit = $true }
    if (-not $Name -and $Target -and $Target.identity) { $Name = $Target.identity; $Explicit = $false }
    if ($Name) {
        $id = $cfg.identities.$Name
        if (-not $id) { throw "Identity '$Name' is not defined in config/lab.config.json identities (defined: $(($cfg.identities.PSObject.Properties.Name) -join ', '))." }
        $id | Add-Member -NotePropertyName '_name' -NotePropertyValue $Name -Force
        # Reserved identities are built and ready but dormant: usable only when named explicitly,
        # never inherited from a target. Prevents silently falling back to app-only auth.
        if ($id.reserved -and -not $Explicit) {
            throw "Identity '$Name' is reserved (app-context auth, kept dormant). Pass -Identity $Name explicitly to use it."
        }
        if ($id.reserved) { Write-LabLog "using RESERVED identity '$Name' ($($id.authMode)) - explicitly requested" -Level WARN }
        return $id
    }
    $cfg.identity | Add-Member -NotePropertyName '_name' -NotePropertyValue 'default' -Force -PassThru
}

function Get-LabTarget {
    param([string]$Name)
    $cfg = Get-LabConfig
    if (-not $Name) { $Name = $cfg.defaults.target }
    if (-not $Name) { throw 'No target specified and defaults.target is not set.' }
    $t = $cfg.targets.$Name
    if (-not $t) { throw "Target '$Name' is not defined in config/lab.config.json (defined: $(($cfg.targets.PSObject.Properties.Name) -join ', '))." }
    Assert-LabTarget -Name $Name -Target $t
    $t | Add-Member -NotePropertyName '_name' -NotePropertyValue $Name -Force
    return $t
}

# Consistent, identifiable naming for everything the lab creates.
function New-LabResourceName {
    param([Parameter(Mandatory)][string]$Suffix)
    $cfg = Get-LabConfig
    $prefix = if ($cfg.resourcePrefix) { $cfg.resourcePrefix } else { 'dextorslab' }
    $runId = if ($script:LabRun) { $script:LabRun.RunId } else { (Get-Date).ToString('yyyyMMdd-HHmmss') }
    "$prefix-$runId-$Suffix"
}

function Test-LabResourceName {
    param([string]$Name)
    $cfg = Get-LabConfig
    $prefix = if ($cfg.resourcePrefix) { $cfg.resourcePrefix } else { 'dextorslab' }
    return ($Name -like "$prefix-*")
}
