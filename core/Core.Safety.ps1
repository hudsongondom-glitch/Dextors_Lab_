# Core.Safety.ps1 - the enforced boundary between "my lab" and everything else: which targets,
# which API hosts, and which destructive operations are allowed. Tenant/token-claim validation
# lives in Core.Auth.ps1. Every assertion here throws. Nothing in this lab should bypass them.

function Assert-LabTarget {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Target)
    $pol = Get-LabPolicy
    if ($pol.allowedTargets -and $pol.allowedTargets -notcontains '*' -and $Name -notin $pol.allowedTargets) {
        throw "SAFETY: target '$Name' is not in policy allowedTargets."
    }
    # Catch anything that smells like a real customer/production environment.
    # Scan VALUES only - property names are lab vocabulary ("product") and would false-positive.
    $values = @($Name) + @($Target.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { [string]$_.Value })
    foreach ($p in $pol.denyNamePatterns) {
        foreach ($v in $values) {
            if ($v -and $v -like $p) {
                throw "SAFETY: target '$Name' has value '$v' matching deny pattern '$p'. This lab must never touch production or customer environments."
            }
        }
    }
}

function Assert-LabApiHost {
    param([Parameter(Mandatory)][string]$Uri)
    $pol = Get-LabPolicy
    $h = ([Uri]$Uri).Host
    foreach ($allowed in $pol.allowedApiHosts) { if ($h -like $allowed) { return } }
    throw "SAFETY: host '$h' is not in policy allowedApiHosts. Add it to config/lab.policy.json if it is genuinely part of your lab."
}

# Gate for anything that deletes or mutates existing state.
function Assert-LabDestructive {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$ResourceDescription,
        [switch]$Force,
        [switch]$IsTracked
    )
    $pol = Get-LabPolicy
    if (-not $pol.allowDestructive -and -not $Force) {
        throw "SAFETY: '$Operation' on '$ResourceDescription' blocked. Set allowDestructive=true in config/lab.policy.json or pass -Force."
    }
    if ($pol.requireTrackedResourceForDelete -and -not $IsTracked) {
        throw "SAFETY: '$ResourceDescription' is not in the lab resource ledger. Cleanup only removes resources this lab created."
    }
    Write-LabLog "destructive op allowed: $Operation -> $ResourceDescription" -Level WARN
}
