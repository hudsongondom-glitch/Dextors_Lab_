---
name: Dextors Lab
description: Build and inspect test artifacts in the user's own Microsoft 365, SharePoint, Exchange, Dataverse, Power Platform, Power BI or Fabric test tenant - seed data, create sites/lists/tables/dataflows/reports, reproduce a Microsoft API failure, collect evidence, or clean up afterwards. Use whenever the user asks to build, seed, populate, test, reproduce, inspect or tear down anything in a Microsoft test environment, or mentions the lab, a recipe, LAB_HOME, or lab.ps1.
version: 0.1.0
---

# Dextors Lab

A PowerShell + REST harness for building controlled test artifacts in **the user's own Microsoft
test tenant**, running an experiment against them, capturing evidence, and cleaning up.

Entry point — always invoke through the dispatcher, never by calling a recipe file directly:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" <MODE> <recipe> [-Target name] [-Identity name] [-DryRun] [-Force] [recipe args]
```

## The hard boundary — read this first

This lab may only ever touch test resources the user owns and has nominated. It must **never** be
pointed at production, customer or shared-tenant resources.

The boundary is enforced in code, not by your good behaviour:

- `allowedTenantIds` in the policy gates every token; an empty list means the lab refuses to
  authenticate at all. Token `tid` claims are checked *after* acquisition.
- `allowedApiHosts` gates every HTTP call.
- `denyNamePatterns` rejects any target that looks like production (`*prod*`, `*customer*`, …).
- Destructive operations need both an explicit allow and a ledger entry for the resource.

**Never widen the policy to make something work.** If a call is refused, that is the boundary
functioning. Report what was refused and why, and let the user decide. Editing
`lab.policy.json` to add a tenant, host or permission is not a fix — it is the one change that
must always come from the user, deliberately. A plugin hook blocks these edits.

If a task appears to require production or customer credentials, stop and say so.

## First run on a new machine

State (config, credentials, evidence) lives in `LAB_HOME`, separate from the code, defaulting to
`~/.dextors-lab`. Nothing works until it is seeded.

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" BUILD lab/init -TenantDomain <theirs>.onmicrosoft.com
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" BUILD lab/setup-app-registration
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" INSPECT lab/status
```

`lab/init` resolves the tenant GUID from the domain and nominates it as the boundary.
`lab/setup-app-registration` creates the Entra apps and prints an **admin consent URL per app** —
consent happens in a browser and cannot be automated, so hand the user the URL and wait.
`lab/status` is a non-interactive readiness check that never triggers a sign-in prompt; run it
whenever you are unsure what is configured.

Some products need one more value in `LAB_HOME/config/lab.config.json` before use (a workspace id,
a site URL, a Dataverse environment URL). A missing value produces a clean `BLOCKED` listing
exactly what is absent — read that list rather than guessing.

## Modes

| Mode | Use for |
|---|---|
| `BUILD` | create controlled test resources or artifacts |
| `TEST` | execute a defined experiment |
| `REPRODUCE` | reproduce a known condition or failure |
| `INSPECT` | read-only inspection and evidence collection |
| `CLEANUP` | remove resources the lab created |

A recipe only accepts the modes it declares. `LIST` shows everything available — run it rather
than guessing a recipe name:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" LIST
```

## Turning a request into a run

1. **Find the recipe.** Run `LIST` and match on product and intent. Recipe names are
   `<product>/<verb-thing>`. If nothing matches, say so — do not improvise with raw API calls.
2. **Check readiness** with `INSPECT lab/status` if you have not already this session.
3. **Dry run first** for anything that writes: `-DryRun` lets reads through and skips every write,
   logging what it would have done. Show the user that output before running for real.
4. **Run it**, then read the verdict and the evidence directory.
5. **Offer cleanup.** Everything created is tracked; leaving artifacts behind costs the user
   tenant quota and muddies later experiments.

Interactive sign-in: delegated products (Dataverse, Power BI) use device code on first use and
print a URL and a code. Surface both to the user verbatim and wait — do not retry or assume it
completed. Refresh tokens are cached afterwards, so this happens once, not once per run.

## Verdicts

| Verdict | Meaning |
|---|---|
| `PASS` | the recipe's success condition was met |
| `FAIL` | success condition not met |
| `INCONCLUSIVE` | could not obtain the data needed to decide (usually auth or permissions) |
| `BLOCKED` | prerequisites missing; the output lists exactly what |
| `DONE` | informational recipe finished |

**For `REPRODUCE` recipes, `PASS` means the reported limitation was reproduced** — the opposite of
the usual test convention. Each recipe states its own definition in its file header; read it
before interpreting a result to the user.

## Evidence

Every run writes `LAB_HOME/runs/<timestamp>-<name>/` containing `request.md`, `plan.md`,
`metadata.json`, `result.md`, `resources.json`, and `requests/` `responses/` `logs/`.

Raw response bodies, **including error bodies**, are saved verbatim. The exact Microsoft error
code is usually the entire point of a reproduction, so quote it rather than paraphrasing, and
check `responses/` before speculating about why something failed.

Evidence may contain tenant identifiers. It is local-only — never paste run contents into an
external service, issue tracker or message without the user explicitly asking.

## Cleanup

Anything created is appended to a ledger with a delete URI. Cleanup only ever touches ledger
entries — never anything it merely finds in the tenant.

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" INSPECT lab/cleanup-tracked-resources          # preview, deletes nothing
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" CLEANUP lab/cleanup-tracked-resources -Force   # actually delete
```

Always preview first and show the user the list before passing `-Force`.

## Writing a new recipe

Only when no existing recipe covers the need, and prefer extending `tools/` over duplicating
logic in a recipe. Required shape:

```powershell
param([string]$Mode='TEST', [string]$Target, [switch]$DryRun, [switch]$Force, [switch]$LabInfo, <recipe args>)

$Recipe = @{ Name='product/thing'; Product='product'; Modes=@('TEST','REPRODUCE'); Destructive=$false; Description='...' }
if ($LabInfo) { return $Recipe }          # must return before doing any work

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('workspaceId')
$run = Start-LabRun -Name '...' -Mode $Mode -Product '...' -Target $Target -DryRun:$DryRun -Request '...' -Plan @('...')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep '...'; return }

# ... Invoke-LabRequest / Add-LabResource / Add-LabEvidenceNote ...

Complete-LabRun -Verdict PASS -Summary '...' -Evidence $ev | Out-Null
```

Non-negotiable rules:

- Every HTTP call goes through `Invoke-LabRequest`. Never `Invoke-WebRequest`/`Invoke-RestMethod`
  in a recipe — host allow-listing, dry-run and evidence capture all live in that one path, so
  bypassing it silently disables the boundary.
- Every created resource is registered with `Add-LabResource` including a `DeleteUri`, or cleanup
  cannot remove it. Name it with `New-LabResourceName` so it is identifiable as lab-owned.
- Define what PASS/FAIL/INCONCLUSIVE mean in the file header.
- Missing config produces a clean `BLOCKED`, never a stack trace.
- Never write secrets to evidence. Secrets are consumed through environment variables only —
  never read from config files, never in code, never in a run directory, never in git.
  (`config/lab.secrets.local.json` is an optional git-ignored loader for those variables.)

Recipes are discovered automatically from `recipes/<product>/`; there is no registration step.

## Manual intervention

Some steps genuinely cannot be automated: authoring a PBIX, assigning capacity, tenant admin
toggles, granting admin consent. When you hit one, stop and give the user: the app or site to
open, the item to select, the exact clicks, the value to choose, what they should see, and the
command to run afterwards.

Do not drive desktop UIs with mouse or keyboard automation to get around this.
