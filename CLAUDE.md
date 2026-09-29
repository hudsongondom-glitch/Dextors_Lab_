# CLAUDE.md — Dextors Lab

Read this before doing anything in this repository.
Human-facing reference: [docs/USER-GUIDE.md](docs/USER-GUIDE.md).

## Purpose

A personal lab for reproducing Microsoft 365 / Power Platform / Power BI backup and restore
behaviour. The owner investigates a support case elsewhere, forms a hypothesis, then uses this
lab to build test artifacts, execute the experiment, collect evidence, and clean up.

Microsoft-side validation only; backup-platform automation is out of scope.

This repo is **not** a product. No CI/CD, no frontend, no database, no ticket ingestion, no
customer data. Keep it small.

## Hard boundary — lab only

This lab may only ever touch:

- the owner's own Microsoft test tenant
- the owner's own Power Platform / Power BI test environments
- credentials created specifically for this lab

**Never** use, request, accept, or configure customer or production credentials, tenants,
sites, environments or endpoints. If a task appears to require one, stop and say so.

The boundary is enforced in code, not just documentation:

- `config/lab.policy.json` → `allowedTenantIds` gates every token. Empty list = the lab refuses to authenticate.
- Token `tid` claims are checked against the policy **after** acquisition (`Assert-LabTokenClaims`), so a misconfigured client can't sneak into another tenant.
- `allowedApiHosts` gates every HTTP call (`Assert-LabApiHost`), including raw/ad-hoc calls.
- `denyNamePatterns` rejects any target that looks like production/customer (`*prod*`, `*customer*`, …).
- Destructive operations require `Assert-LabDestructive`, which needs both an explicit allow and a resource present in the lab ledger.

## Operating model

Five modes, passed to the dispatcher:

| Mode | Meaning |
|---|---|
| `BUILD` | Create controlled test resources/artifacts |
| `TEST` | Execute a defined experiment |
| `REPRODUCE` | Reproduce a known condition/failure |
| `INSPECT` | Read-only inspection + evidence collection |
| `CLEANUP` | Remove resources the lab created |

```powershell
.\lab.ps1 LIST
.\lab.ps1 INSPECT lab/validate-framework
.\lab.ps1 REPRODUCE powerbi/report-rest-export -ReportId <guid>
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force
```

On a machine that has never run the lab, `lab/init` seeds `LAB_HOME` and nominates the tenant
boundary, then `lab/setup-app-registration` creates the Entra apps and prints an admin consent URL
per app. Consent is a browser action and cannot be automated — hand the URL over and wait.

## Layout

**Code and state are separate.** `LabRoot` is this checkout; `LabHome` is per-user state and is
where every write goes. Resolution: `$env:LAB_HOME`, else this checkout when
`config/lab.config.json` sits beside the code, else `~/.dextors-lab`. Use `Get-LabHome` for
anything written, `Get-LabRoot` only for reading shipped code. `lab.config.json` and
`lab.policy.json` are **git-ignored local state**, seeded from `templates/` by `lab/init` — never
commit a populated one.

```
LabRoot (code, shippable)
  lab.ps1          recipe dispatcher
  core/            framework: Config, Safety, Auth (contract only), Http, Evidence, Run,
                   Resources, Log  (loader: Core.Context.ps1 - dot-source this, it loads the rest)
  tools/microsoft/ Ms.Auth.ps1 (token per API audience - provider-owned, not core), Ms.Cert, Spo.Rest, Dv.Api
  tools/powerbi/   Pbi.SeedData, Pbi.Mashup
  tools/powerplatform/ Dv.DependencyModel, Dv.PowerPages, Dv.Flows
  recipes/<product>/<recipe>.ps1   one experiment per file, auto-discovered
  templates/       lab.config / lab.policy templates that lab/init seeds from
  tests/           offline self-tests (framework, dependency model)
  docs/            operator guide, concept and usage guides, Power BI coverage findings
  skills/ commands/ hooks/ .claude-plugin/   Claude Code plugin components

LabHome (state, never committed)
  config/          lab.config.json, lab.policy.json, secrets, certs, token cache
  runs/            evidence, one directory per run + _ledger.jsonl resource ledger
  artifacts/       generated PBIP projects, dataflow models, seed manifests
```

## Writing a new tool

Put reusable capability in `tools/`, never in a recipe. Before adding a wrapper, check whether
PowerShell, `pac` or Graph already does it — do not reimplement existing tools.
Keep abstractions thin; add a layer only when a second caller genuinely needs it.

All Microsoft API auth goes through `Get-LabAccessToken -Api Graph|PowerBI|Fabric|Dataverse|SharePoint`.
Audiences differ per API and a token for one is not valid for another — never assume one token
covers two services; acquire per API and report the audience in evidence.

Auth model is fixed per product — do not change it without being asked:

| Product | Mode | Identity | Why |
|---|---|---|---|
| Graph (M365, mailboxes, sites) | app-only (`clientsecret`) | `msg-app` | unattended, app permissions consented |
| **SharePoint REST (`_api`)** | app-only (**`certificate`**) | `msg-app-cert` | SPO REST rejects secret-based app-only tokens — see below |
| Power Platform / Dataverse | **delegated** (`devicecode`) | `dverse-app` | app holds Dataverse `user_impersonation`; no Application User needed |
| Power BI / Fabric | **delegated** (`devicecode`) | `kslab-pbi` | avoids service-principal export restrictions |

Delegated identities need **Allow public client flows = Yes** in Entra. Refresh tokens are cached
in `config/.tokencache.local.json` (git-ignored) so repeat runs do not re-prompt for sign-in.

**SharePoint has two distinct APIs with separate permissions — do not confuse them:**

| | Permission resource | Endpoint | Credential |
|---|---|---|---|
| Graph | Microsoft Graph `Sites.*` | `graph.microsoft.com/v1.0/sites` | secret or certificate |
| SPO REST (primary here) | Office 365 SharePoint Online `Sites.*` | `<tenant>.sharepoint.com/_api` | **certificate only** |

A client-secret app-only token against SPO REST returns HTTP 401 `Unsupported app only token`
(`appidacr=1`). This is a hard SharePoint constraint, not a consent problem. Generate the
credential with `.\lab.ps1 BUILD lab/setup-app-certificate -Identity <name>` and upload the `.cer`.

Run `.\lab.ps1 INSPECT lab/status` for a non-interactive readiness check of every product.

App-context (client-credentials) paths for Dataverse and Power BI are **built but reserved**:
`dverse-app-appauth`, `kslab-pbi-appauth`. `"reserved": true` means they are refused when
inherited from a target and only usable when named explicitly — never switch a product to
app-context unless the owner asks:

```powershell
.\lab.ps1 INSPECT powerplatform/inspect-dataverse -Identity dverse-app-appauth
.\lab.ps1 REPRODUCE powerbi/report-rest-export   -Identity kslab-pbi-appauth
```

## Writing a new recipe

A recipe is one self-contained `.ps1` in `recipes/<product>/`. Required shape:

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

Rules:

- Every HTTP call uses `Invoke-LabRequest`. Never call `Invoke-WebRequest`/`Invoke-RestMethod` directly in a recipe.
- Every created resource is registered with `Add-LabResource`. Include a `DeleteUri` wherever a generic delete exists, or cleanup cannot remove it; resources that intentionally have none (local artifacts, bulk record sets) record a `purgeRecipe` or local `path` so cleanup reports them as manual/special cleanup.
- Name created resources with `New-LabResourceName` so they are identifiable as lab-owned.
- Define what PASS/FAIL/INCONCLUSIVE mean **in the file header**. For reproduction recipes,
  PASS conventionally means "the reported limitation was reproduced".
- Missing config must produce a clean `BLOCKED` stop listing exactly what is missing — never a stack trace.
- Never write secrets to evidence. `Invoke-LabRequest` already redacts the Authorization header; keep it that way.

## Evidence

Every run writes `runs/<timestamp>-<name>/` containing `request.md`, `plan.md`, `metadata.json`,
`result.md`, `resources.json`, and `requests/` `responses/` `logs/`. Raw response bodies —
including error bodies — are always saved; the exact Microsoft error code is what makes a
reproduction useful, so preserve it verbatim rather than reformatting it.

`runs/` is git-ignored. It may contain tenant identifiers; treat it as local-only.

## Secrets

Secrets are consumed through environment variables only — never read from config files, never in
code, never in `runs/`, never in git. `config/lab.config.json` and `config/lab.policy.json` hold
ids and policy only (tenant, client, workspace) and are git-ignored local state.
`config/lab.secrets.local.json` (git-ignored, under `LabHome`) is an optional convenience loader
that fills those environment variables at start; an existing session variable always wins. If a
secret is needed and absent, stop and tell the owner which variable to set.

## Manual intervention

Some steps genuinely cannot be automated (authoring a PBIX, assigning capacity, tenant admin
toggles, Keepit portal configuration). When you hit one, stop and give: the app/site to open,
the item to select, the exact clicks, the value to choose, what they should see, and the command
to run afterwards. Do not drive desktop UIs with mouse/keyboard automation.
