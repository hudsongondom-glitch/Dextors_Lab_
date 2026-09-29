<#
.SYNOPSIS
    Dextors Lab - recipe dispatcher.

.EXAMPLE
    .\lab.ps1 LIST
    .\lab.ps1 INSPECT lab/validate-framework
    .\lab.ps1 REPRODUCE powerbi/report-rest-export -ReportId <guid>
    .\lab.ps1 CLEANUP lab/cleanup-tracked-resources -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('LIST', 'BUILD', 'TEST', 'REPRODUCE', 'INSPECT', 'CLEANUP')][string]$Mode = 'LIST',
    [Parameter(Position = 1)][string]$Recipe,
    [string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Stop'
$recipeRoot = Join-Path $PSScriptRoot 'recipes'

function Get-RecipeCatalog {
    Get-ChildItem $recipeRoot -Recurse -Filter '*.ps1' -File | ForEach-Object {
        $rel = $_.FullName.Substring($recipeRoot.Length + 1).Replace('\', '/') -replace '\.ps1$', ''
        $info = try { & $_.FullName -LabInfo } catch { $null }
        [pscustomobject]@{
            Key         = $rel
            Path        = $_.FullName
            Product     = $info.Product
            Modes       = @($info.Modes)
            Destructive = [bool]$info.Destructive
            Description = $info.Description
        }
    }
}

$catalog = Get-RecipeCatalog

if ($Mode -eq 'LIST' -or -not $Recipe) {
    Write-Host "`nDextors Lab - recipes`n" -ForegroundColor Cyan
    $catalog | Sort-Object Key | ForEach-Object {
        Write-Host ("  {0,-42} {1}" -f $_.Key, ($_.Modes -join '|')) -ForegroundColor Green
        Write-Host ("  {0,-42} {1}" -f '', $_.Description)
    }
    Write-Host "`nUsage: .\lab.ps1 <MODE> <recipe> [-Target name] [-DryRun] [-Force] [recipe args]`n"
    return
}

$match = @($catalog | Where-Object { $_.Key -eq $Recipe -or $_.Key -like "*/$Recipe" })
if ($match.Count -ne 1) {
    Write-Host "Recipe '$Recipe' " -NoNewline -ForegroundColor Red
    Write-Host $(if ($match.Count -eq 0) { 'not found.' } else { "is ambiguous: $($match.Key -join ', ')" }) -ForegroundColor Red
    Write-Host "Run: .\lab.ps1 LIST"
    exit 1
}
$r = $match[0]

if ($r.Modes -and $Mode -notin $r.Modes) {
    Write-Host "Recipe '$($r.Key)' does not support mode $Mode (supports: $($r.Modes -join ', '))." -ForegroundColor Red
    exit 1
}

$callArgs = @{ Mode = $Mode }
if ($Target) { $callArgs.Target = $Target }
if ($DryRun) { $callArgs.DryRun = $true }
if ($Force) { $callArgs.Force = $true }

# Remaining args arrive as a flat array. Splatting an array binds POSITIONALLY, which would
# feed "-Identity" into the recipe's first positional parameter - so rebuild named pairs here.
$restList = @($Rest | Where-Object { $null -ne $_ })      # @($null) is a 1-element array, not empty
for ($i = 0; $i -lt $restList.Count; $i++) {
    $tok = [string]$restList[$i]
    if ($tok -notlike '-*') { Write-Host "Ignoring unexpected argument '$tok'." -ForegroundColor Yellow; continue }
    $key = $tok.TrimStart('-')
    $next = if ($i + 1 -lt $restList.Count) { [string]$restList[$i + 1] } else { $null }
    if ($null -ne $next -and $next -notlike '-*') { $callArgs[$key] = $next; $i++ }
    else { $callArgs[$key] = $true }          # switch parameter
}

& $r.Path @callArgs
