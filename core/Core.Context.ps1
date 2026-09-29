# Core.Context.ps1 - single entry point for the shared framework, and runtime/context
# (where the code lives vs where state lives). Every recipe starts with:
#   . "$PSScriptRoot\..\..\core\Core.Context.ps1"

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:LabRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# LabRoot is CODE. LabHome is STATE - config, credentials, certificates, evidence, artifacts.
# They are the same directory in a personal checkout and must not be when the framework is
# installed somewhere replaceable (a plugin directory is overwritten on every update).
#
#   $env:LAB_HOME set                      -> use it
#   <LabRoot>\config\lab.config.json exists -> LabRoot      (repo mode; existing setups unchanged)
#   otherwise                              -> ~\.dextors-lab (installed mode; lab/init seeds it)
$script:LabHome =
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_HOME)) { $env:LAB_HOME }
    elseif (Test-Path (Join-Path $script:LabRoot 'config\lab.config.json')) { $script:LabRoot }
    else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dextors-lab' }

$script:LabRun = $null
$script:LabDryRun = $false
$script:LabSeq = 0
$script:LabConfigCache = $null
$script:LabPolicyCache = $null

# Load order within core/ doesn't matter for correctness (PowerShell resolves function calls at
# invocation time, well after all dot-sourcing here completes) - kept in dependency-reading order
# for humans: logging first (everything logs), config next (almost everything reads it), then the
# safety/auth contracts, HTTP, evidence, run lifecycle, resource tracking.
. (Join-Path $PSScriptRoot 'Core.Log.ps1')
. (Join-Path $PSScriptRoot 'Core.Config.ps1')
. (Join-Path $PSScriptRoot 'Core.Safety.ps1')
. (Join-Path $PSScriptRoot 'Core.Auth.ps1')
. (Join-Path $PSScriptRoot 'Core.Http.ps1')
. (Join-Path $PSScriptRoot 'Core.Evidence.ps1')
. (Join-Path $PSScriptRoot 'Core.Run.ps1')
. (Join-Path $PSScriptRoot 'Core.Resources.ps1')

# Providers: how each product actually authenticates and talks to its API. Core does not know
# these details (see Core.Auth.ps1's header) - it only loads them so a recipe gets the whole
# framework from one dot-source.
. (Join-Path $script:LabRoot 'tools\microsoft\Ms.Cert.ps1')
. (Join-Path $script:LabRoot 'tools\microsoft\Ms.Auth.ps1')
. (Join-Path $script:LabRoot 'tools\microsoft\Dv.Api.ps1')
. (Join-Path $script:LabRoot 'tools\powerbi\Pbi.SeedData.ps1')
. (Join-Path $script:LabRoot 'tools\powerbi\Pbi.Mashup.ps1')
. (Join-Path $script:LabRoot 'tools\powerplatform\Dv.DependencyModel.ps1')
. (Join-Path $script:LabRoot 'tools\powerplatform\Dv.PowerPages.ps1')
. (Join-Path $script:LabRoot 'tools\powerplatform\Dv.Flows.ps1')

Import-LabSecrets

function Get-LabRoot { $script:LabRoot }          # code
function Get-LabHome { $script:LabHome }          # state: config, credentials, runs, artifacts

# Creates the state directory tree on demand. Safe to call repeatedly.
function Initialize-LabHome {
    foreach ($sub in '', 'config', 'runs', 'artifacts') {
        $p = if ($sub) { Join-Path $script:LabHome $sub } else { $script:LabHome }
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    $script:LabHome
}
