# Core.Log.ps1 - console + run-scoped file logging.

$script:LabLogColors = @{ DEBUG = 'DarkGray'; INFO = 'Gray'; STEP = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }

function Write-LabLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'STEP', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $prefix = switch ($Level) { 'STEP' { '==>' } 'OK' { ' ok ' } default { "[$Level]" } }
    Write-Host "$prefix $Message" -ForegroundColor $script:LabLogColors[$Level]

    if ($script:LabRun) {
        $line = '{0} {1,-5} {2}' -f $ts, $Level, $Message
        Add-Content -Path (Join-Path $script:LabRun.LogsDir 'run.log') -Value $line -Encoding utf8
    }
}

function Write-LabStep { param([string]$Message) Write-LabLog -Message $Message -Level STEP }
