<#
PreToolUse guard: refuse agent edits to the enforced safety policy.

lab.policy.json is the boundary - the tenant allow-list, the API host allow-list, the deny
patterns and the destructive gate. Every other check in the lab reads from it, which means an
agent that can rewrite it can dissolve every other check at once.

The lab's own recipes write this file through PowerShell (lab/init), not through the Write or
Edit tools, so they are unaffected. The user editing it by hand is unaffected. This blocks
exactly one thing: an agent widening its own boundary mid-task, which should always be a
deliberate human act.

Emits a PreToolUse deny decision; any unexpected condition falls through to allow rather than
wedging the session.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $ev = $raw | ConvertFrom-Json

    $path = $ev.tool_input.file_path
    if (-not $path) { exit 0 }

    $leaf = Split-Path $path -Leaf
    if ($leaf -ne 'lab.policy.json') { exit 0 }

    $reason = @'
Refused: lab.policy.json is the lab's enforced safety boundary.

It holds the tenant allow-list, the API host allow-list, the production/customer deny patterns
and the destructive gate. Editing it from inside a task would let the assistant widen its own
boundary, so this is blocked by design - a refusal here is the boundary working, not a bug.

If a call was refused and the boundary genuinely needs to change, tell the user exactly what was
refused and which setting would have to change, and let them make the edit themselves. To add a
tenant legitimately, they should run:  lab.ps1 BUILD lab/init -TenantDomain <domain>
'@

    @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 5 -Compress

    exit 0
}
catch {
    # Never let a guard failure block ordinary work.
    exit 0
}
