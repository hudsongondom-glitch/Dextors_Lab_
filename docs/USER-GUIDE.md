# Dextors Lab — Operator Guide

How to run the lab, what each recipe does, and what the errors mean.

Companion documents: [what-is-dextors-lab.md](what-is-dextors-lab.md) (concepts),
[how-to-use-dextors-lab.md](how-to-use-dextors-lab.md) (step-by-step walkthrough).

---

## 1. What this is

A PowerShell toolkit for reproducing Microsoft 365 / Power Platform / Power BI backup and restore
behaviour in a test tenant. You investigate a support case elsewhere, form a hypothesis, then use the lab
to build test artifacts, run the experiment, collect evidence, and clean up.

Microsoft-side validation only; backup-platform automation is out of scope.

The working loop:

```
hypothesis  ->  BUILD a test artifact  ->  TEST / REPRODUCE  ->  read the evidence  ->  CLEANUP
```

Everything is PowerShell 7 + raw REST. No modules to install, no build step, no services.

**Hard boundary:** the lab only ever touches your own test tenant and test environments. This is
enforced in code (section 8), not just documentation.

---

## 2. One-time setup

### 2.1 Prerequisites

PowerShell 7 (`pwsh`). Nothing else. Verify:

```powershell
$PSVersionTable.PSVersion
```

### 2.2 Non-secret configuration — `config/lab.config.json`

**Code and state are separate.** `LabRoot` is the checkout (code). `LabHome` is per-user state
(config, credentials, certificates, `runs/`, `artifacts/`). `LabHome` is `$env:LAB_HOME` if set,
otherwise the checkout when `config/lab.config.json` sits beside the code, otherwise
`~/.dextors-lab`. Every `config/…` and `runs/…` path in this guide is relative to `LabHome`.

`config/lab.config.json` (and `config/lab.policy.json`, section 2.5) is **git-ignored local
state**. It is not committed: `lab/init` seeds it from `templates/lab.config.template.json`.
Never commit a populated one.

| Key | Meaning |
|---|---|
| `labName`, `resourcePrefix` | identity of the lab; the prefix is applied to every resource it creates |
| `tenant.id` / `.domain` / `.displayName` | your test tenant |
| `identities.*` | one entry per app registration (see 2.4) |
| `targets.*` | one entry per test environment (workspace, site, Dataverse env) |
| `defaults.target` | target used when a recipe is run without `-Target` |

### 2.3 Secrets — environment variables

Secrets are consumed through **environment variables only** (for example `LAB_SECRET_MSGAPP`).
They are never read from `lab.config.json` or `lab.policy.json`, never written to evidence, and
never committed.

`config/lab.secrets.local.json` is an **optional, git-ignored convenience loader**: at framework
start its entries are copied into environment variables. Existing session variables win, so you
can override any value for a single shell. Use it, or set the variables yourself — either works.
A committed `config/lab.secrets.example.json` shows the shape.

```json
{
  "LAB_SECRET_MSGAPP": "...",
  "LAB_SECRET_DVERSE": "...",
  "LAB_CERT_PASSWORD": "..."
}
```

Never put secrets in `lab.config.json` (it holds identifiers only).

Other git-ignored local files: `config/.tokencache.local.json` (delegated refresh tokens),
`config/*.local.pfx` / `*.local.cer` (certificates), and the whole `runs/` directory.

### 2.4 Identities

An identity is an app registration plus how to authenticate as it. Each target names the
identity it uses, so one run can authenticate differently per API.

| Field | Meaning |
|---|---|
| `clientId` | application (client) ID |
| `authMode` | `clientsecret`, `certificate`, or `devicecode` |
| `secretEnvVar` | env var holding the client secret (`clientsecret`) |
| `certPath` / `certPasswordEnvVar` | PFX path and password env var (`certificate`) |
| `reserved` | `true` = dormant; usable only when named explicitly with `-Identity` |

### 2.5 Safety policy — `config/lab.policy.json`

Git-ignored local state in `LabHome`, seeded from `templates/lab.policy.template.json` by
`lab/init` (which also sets `allowedTenantIds` to the one tenant you nominate).

| Key | Effect |
|---|---|
| `allowedTenantIds` | **empty list = the lab refuses to authenticate at all** |
| `allowedApiHosts` | every HTTP call must match one of these (wildcards allowed) |
| `denyNamePatterns` | target values matching these are refused (`*prod*`, `*customer*`, …) |
| `allowDestructive` | must be true (or `-Force` passed) before anything is deleted |
| `requireTrackedResourceForDelete` | deletion only for resources in the ledger |
| `maxResourcesPerRun` | cap on resources a single run may create |

---

## 3. Running the lab

```powershell
.\lab.ps1 <MODE> <recipe> [-Target name] [-Identity name] [-DryRun] [-Force] [recipe args]
```

| Mode | Meaning |
|---|---|
| `LIST` | show all recipes (default when no recipe is given) |
| `BUILD` | create controlled test resources/artifacts |
| `TEST` | execute a defined experiment |
| `REPRODUCE` | reproduce a known condition/failure |
| `INSPECT` | read-only inspection and evidence collection |
| `CLEANUP` | remove resources the lab created |

A recipe only accepts the modes it declares; the dispatcher refuses others.

Start here, in order (after `lab/init` has seeded LabHome, which the self-test reads):

```powershell
pwsh -File tests\Test-LabFramework.ps1        # offline self-test, no credentials needed
.\lab.ps1 LIST                                # what is available
.\lab.ps1 INSPECT lab/status                  # readiness of every product
```

`-DryRun` lets reads through but skips every write, logging what it would have done.

---

## 4. Recipe reference

`.\lab.ps1 LIST` discovers **33** recipes. The names, modes, destructive flag and purpose below are
taken verbatim from each recipe's `$Recipe` metadata (the same data `LIST` prints); the argument
column is each recipe's own `param()` block, in addition to the common `-Target`, `-DryRun`,
`-Force`. **Read a recipe's file header before running it** - it defines exactly what PASS, FAIL,
INCONCLUSIVE and BLOCKED mean for that experiment. "Destructive: yes" recipes delete or mutate
existing state and are gated by the safety policy (section 8).

### Exchange (2)

| Recipe | Modes | Destructive | Purpose | Arguments |
|---|---|---|---|---|
| `exchange/archive-graph-delta` | REPRODUCE, INSPECT | no | Graph v1.0 vs beta against an In-Place Archive mailbox: folder/item enumeration and delta. | `-Mailbox` `-Identity` |
| `exchange/archive-incremental-sync` | TEST, INSPECT | yes | Synthetic delta workaround for In-Place Archive: watermark + id sweep + exportItems. | `-Mailbox` `-Identity` `-Since` |

### Framework (`lab/`) (7)

| Recipe | Modes | Destructive | Purpose | Arguments |
|---|---|---|---|---|
| `lab/cleanup-tracked-resources` | CLEANUP, INSPECT | yes | Delete resources recorded in the lab ledger. -DryRun to preview; -Force to actually delete. | `-RunId` `-Type` |
| `lab/init` | BUILD | no | Seed LAB_HOME (config, policy, evidence dirs) and set the tenant boundary. Run this first on a new machine. | `-TenantId` `-TenantDomain` `-LabName` `-ResourcePrefix` |
| `lab/inspect-app-permissions` | INSPECT | no | Resolve app registration permission GUIDs to names and show what is consented. | `-Identity` `-AuthAs` |
| `lab/setup-app-certificate` | BUILD | no | Create a self-signed cert for certificate-based app-only auth (required by SharePoint REST). | `-Identity` `-Years` |
| `lab/setup-app-registration` | BUILD | no | Create the Entra app registrations the lab needs, add their permissions, and record the client ids. | `-App` `-BootstrapClientId` `-NoConsentUrl` |
| `lab/status` | INSPECT | no | Readiness of every product: identities, credentials, and a live probe per API. | - |
| `lab/validate-framework` | INSPECT | no | Read-only framework + credentials validation. Run this first. | - |

### SharePoint (4)

| Recipe | Modes | Destructive | Purpose | Arguments |
|---|---|---|---|---|
| `sharepoint/build-test-site` | BUILD | no | Create a team site with a sample list and document library, tracked for cleanup. | `-SiteName` `-Identity` `-CertIdentity` |
| `sharepoint/inspect-site-rest` | INSPECT | no | Read-only SharePoint inspection over the SPO REST _api (certificate app-only). | `-Identity` `-ListTitle` |
| `sharepoint/inspect-site` | INSPECT | no | Read-only SharePoint site/lists/drive inspection via Graph. | - |
| `sharepoint/prepare-modern-page` | BUILD | no | Populate a modern Site Page with real canvas content as a restore-test source. | `-SiteUrl` `-Identity` `-NoArticlePage` |

### Power Platform (13)

| Recipe | Modes | Destructive | Purpose | Arguments |
|---|---|---|---|---|
| `powerplatform/build-dependency-model` | BUILD | no | Create the account/contact/order tables and their obligatory + optional lookups for the restore dependency scenarios. Reuses anything that already exists. | `-Identity` `-ModelProfile` `-Publish` |
| `powerplatform/build-flow-solution-testset` | BUILD | no | Create/reuse a Cloud Flow in two solutions plus a cloned copy in a third, for a backup-connector solution-awareness experiment. | `-Identity` `-SourceFlowId` `-Prefix` `-CreateFlowIfMissing` |
| `powerplatform/build-powerpages-edm-testset` | BUILD | no | Create a minimal, uniquely-prefixed web page + content snippet + site setting (+ web file) on an existing Enhanced Data Model Power Pages site, for backup validation. Nothing is deleted. | `-Identity` `-SiteId` `-SiteName` `-Prefix` `-NoWebFile` |
| `powerplatform/inspect-dataverse` | INSPECT | no | Read-only Dataverse WhoAmI + table enumeration via the Web API. | `-Identity` |
| `powerplatform/inspect-dependency-graph` | INSPECT | no | Read the account/contact/order lookup graph, classify each edge obligatory or optional, detect cycles and derive the required creation order. | `-Identity` `-ModelProfile` `-Discover` |
| `powerplatform/inspect-field-security-scenario` | INSPECT | no | Read-only recon of a table's columns, security state, a named record's owner, and existing field security profiles - groundwork for reproducing a column-level-security restore failure. | `-Identity` `-TableDisplayName` `-RecordName` |
| `powerplatform/inspect-powerpages-site` | INSPECT | no | Resolve a Power Pages EDM site, confirm it against the powerpagesite system table, and enumerate its site language / publishing state / page template prerequisites. | `-Identity` `-SiteId` `-SiteName` |
| `powerplatform/inspect-teams-environment` | INSPECT | no | Read-only: resolve a Dataverse for Teams environment's Web API URL via Global Discovery, then probe WhoAmI + EntityDefinitions to test whether the documented "no API access" restriction actually blocks calls. | `-EnvironmentId` `-OrganizationId` `-Identity` |
| `powerplatform/purge-lab-records` | CLEANUP, INSPECT | yes | Delete lab-owned records from the dependency model tables in reverse dependency order. Preview by default; -Force to delete. | `-Identity` `-ModelProfile` `-RunId` `-BatchSize` |
| `powerplatform/reproduce-field-security-restore` | REPRODUCE | no | Reproduces a field-security (0x80040265) restore failure by contrasting a direct write against an impersonated (non-admin) write on the same secured column. | `-Identity` `-TableLogicalName` `-EntitySet` `-RecordId` `-SecuredColumn` `-ImpersonateUserId` |
| `powerplatform/reproduce-flow-solution-restore` | TEST | yes | Deletes the cloned test flow (Solution C membership) as the setup step for a backup-restore-and-check test; records the pre-delete solution membership baseline. | `-Identity` `-Prefix` `-WorkflowId` `-SolutionId` |
| `powerplatform/seed-cycle-dataset` | BUILD | no | Seed one scenario arm (A / B-test / B-control / C) of the restore dependency experiment and write a manifest for later verification. | `-Identity` `-ModelProfile` `-Scenario` `-PaddingContacts` `-Orders` `-CyclePosition` `-BatchSize` `-ProbeRequiredLevel` |
| `powerplatform/verify-dataset-state` | INSPECT | no | Check whether an environment is empty of lab records (pre-restore) or holds the complete seeded set with intact references (post-restore), and name the failure signature. | `-Identity` `-ModelProfile` `-RunId` `-Expect` |

The scenario arms of the Dataverse restore dependency experiment (A / B-test / B-control / C) are
defined in the `powerplatform/seed-cycle-dataset` recipe header.

### Power BI (7)

| Recipe | Modes | Destructive | Purpose | Arguments |
|---|---|---|---|---|
| `powerbi/backup-coverage-matrix` | INSPECT, TEST, REPRODUCE | no | Per-item coverage matrix: which API surface sees each item, and whether its definition can be retrieved. | `-Identity` `-NoExport` `-IncludeScan` `-KeepPbix` `-MaxExports` |
| `powerbi/build-gen1-dataflow` | BUILD, TEST | no | Create a Gen1 Power BI dataflow from a generated CDM model.json via the Imports API; falls back to portal import steps. | `-Identity` `-SalesRows` `-WriteOnly` `-OutputPath` |
| `powerbi/build-gen2-dataflow` | BUILD, TEST | no | Give a Dataflow Gen2 a real Power Query mashup (dimensions, calendar, fact, and a join+group query) instead of an empty stub. | `-Identity` `-DataflowId` `-CreateNew` `-SalesRows` |
| `powerbi/build-pbip-project` | BUILD | no | Generate a PBIP (TMDL model + PBIR report) on disk for Power BI Desktop to open and publish, so artifacts are PBIX-backed. | `-ProjectName` `-OutputPath` `-SalesRows` |
| `powerbi/build-seed-artifacts` | BUILD, TEST | no | Seed a workspace with one of each Power BI/Fabric artifact type, including a star-schema push model with generated data. | `-Identity` `-Only` `-SalesRows` |
| `powerbi/dataflow-gen2-visibility` | REPRODUCE, TEST, BUILD | no | Dataflow Gen2 (CI/CD) visible in Fabric REST but missing from legacy Power BI REST. | `-Identity` `-NoCreate` `-DataflowId` |
| `powerbi/report-rest-export` | REPRODUCE, TEST, INSPECT | no | PBIX REST export failing due to semantic-model configuration (premium files / incremental refresh). | `-Identity` `-ReportId` `-ListOnly` |

Why items go missing, the error-code reference and the triage order:
[powerbi-backup-coverage.md](powerbi-backup-coverage.md).

### Verdicts

| Verdict | Meaning |
|---|---|
| `PASS` | the recipe's success condition was met. **For reproduction recipes this means the reported limitation was reproduced** — the opposite of the usual test convention. Each recipe states its own definition in its file header. |
| `FAIL` | success condition not met |
| `INCONCLUSIVE` | could not obtain the data needed to decide (usually auth or permissions) |
| `BLOCKED` | prerequisites missing; the output lists exactly what |
| `DONE` | informational recipe finished; for cleanup, generic cleanup completed and nothing requiring further attention remains |

---

## 5. Authentication model

Fixed per product. Do not change it casually — each choice works around a specific constraint.

| Product | Mode | Identity | Why |
|---|---|---|---|
| Graph (M365, mailboxes, sites) | app-only `clientsecret` | `msg-app` | unattended; app permissions consented |
| **SharePoint REST (`_api`)** | app-only **`certificate`** | `msg-app-cert` | SPO REST rejects secret-based app-only tokens |
| Dataverse | **delegated** `devicecode` | `dverse-app` | app holds `user_impersonation`; no Application User needed |
| Power BI / Fabric | **delegated** `devicecode` | `kslab-pbi` | avoids service-principal export restrictions |

Key facts:

- **Audiences differ per API.** A Graph token is not valid for Power BI, Fabric, Dataverse or
  SharePoint. Always acquire per API; `Get-LabAccessToken -Api <name>` handles this.
- **SharePoint has two separate APIs** with separate permissions. Granting `Sites.*` on one does
  nothing for the other:

  | | Permission resource | Endpoint | Credential |
  |---|---|---|---|
  | Graph | Microsoft Graph `Sites.*` | `graph.microsoft.com/v1.0/sites` | secret or certificate |
  | SPO REST | Office 365 SharePoint Online `Sites.*` | `<tenant>.sharepoint.com/_api` | **certificate only** |

- **Delegated identities** need *Allow public client flows = Yes* in Entra. Refresh tokens are
  cached, so you sign in once rather than once per run.
- **Reserved identities** (`*-appauth`) are complete app-context paths kept dormant. They are
  refused when inherited from a target and only work when named explicitly:

  ```powershell
  .\lab.ps1 INSPECT powerplatform/inspect-dataverse -Identity dverse-app-appauth
  ```

---

## 6. Evidence

Every run writes a directory under `runs/`:

```
runs/<timestamp>-<name>/
    request.md        what was asked, mode, target, start time
    plan.md           the steps the recipe intended to take
    metadata.json     runId, mode, tenant, verdict, timings, host
    result.md         verdict, summary, evidence list
    resources.json    resources this run created
    requests/         outbound calls (Authorization header redacted)
    responses/        raw response bodies, including errors
    logs/run.log      execution log
```

Raw bodies are stored verbatim — the exact Microsoft error code is the point of a reproduction,
so nothing is reformatted. `runs/` is git-ignored and may contain tenant identifiers; treat it as
local-only.

Authorization headers are always redacted. `Invoke-LabRequest` also takes a `-RedactElements`
list for any call whose body can carry other sensitive values.

---

## 7. Resource tracking and cleanup

Anything the lab creates is appended to the ledger, `runs/_ledger.jsonl`. Cleanup only ever
touches ledger entries — never anything it merely finds in the tenant.

```powershell
.\lab.ps1 INSPECT lab/cleanup-tracked-resources          # preview: list, delete nothing
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force   # actually delete
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force -RunId 20260805-0012
```

**Not every tracked resource has a generic delete path.** Most resources created through an API
(Graph, Fabric/Power BI, Dataverse records, SharePoint/M365 groups) are recorded with a `DeleteUri`
and are removed by `lab/cleanup-tracked-resources`. Some are tracked deliberately *without* one and
need manual or special cleanup instead — for example a local artifact (`api: local`, with its
recorded `path`) or a bulk Dataverse record set whose entry carries a `purgeRecipe` (such as
`powerplatform/purge-lab-records`). They stay visible in the ledger.

A resource is generically deletable only if it is in the ledger, has a recorded delete URI and a
supported api, and either carries the lab name prefix or is flagged `explicitName` (used when you
chose the name yourself). `lab/cleanup-tracked-resources` classifies each active entry as:

| Class | Meaning |
|---|---|
| deleted | generic delete succeeded (ledger status becomes `deleted`) |
| failed | a real delete attempt failed |
| skipped | it should be deletable but was refused for safety/auth (unprefixed name that is not `explicitName`, or an api with no auth mapping) |
| manual | no generic delete path by design; the `purgeRecipe` or local path is reported and the entry is left untouched in the ledger |

The verdict follows from that:

| Verdict | Meaning |
|---|---|
| `DONE` | generic cleanup completed and nothing requiring attention remains (also: empty ledger, or a preview-only listing) |
| `INCONCLUSIVE` | every deletable resource succeeded, but manual/special-cleanup resources remain |
| `FAIL` | a deletion failed, or an expected generic cleanup was blocked/skipped (takes precedence over INCONCLUSIVE) |

> **Microsoft 365 groups soft-delete.** Deleting a group-connected site puts it in the deleted
> container for 30 days and keeps its mailNickname reserved. Rebuilding with the same name inside
> that window fails unless you purge it first, or use a different `-SiteName`.

---

## 8. Safety boundary

Enforced in code. All of these throw:

| Check | Function | What it prevents |
|---|---|---|
| Tenant allow-list | `Assert-LabTenant` | authenticating to any tenant not in policy |
| Token claim check | `Assert-LabTokenClaims` | a misconfigured client reaching another tenant — validated against the **issued token's `tid`**, not config |
| Host allow-list | `Assert-LabApiHost` | any HTTP call to an unlisted host, including ad-hoc calls |
| Deny patterns | `Assert-LabTarget` | targeting anything that looks like production or a customer |
| Destructive gate | `Assert-LabDestructive` | deleting without an explicit allow **and** a ledger entry |

Because host checking lives inside the single HTTP wrapper, a new recipe cannot bypass it by
accident. That is the reason every call must go through `Invoke-LabRequest`.

---

## 9. Framework reference

Dot-source `core/Core.Context.ps1`; it loads everything below.

**Config** — `Get-LabConfig`, `Get-LabPolicy`, `Test-LabConfigReady`, `Get-LabTarget`,
`Get-LabIdentity`, `Import-LabSecrets`, `New-LabResourceName`, `Test-LabResourceName`

**Runs and evidence** — `Start-LabRun`, `Complete-LabRun`, `Stop-LabRunBlocked`,
`Save-LabEvidence`, `Add-LabEvidenceNote`, `Save-LabMetadata`, `Get-LabRoot`

**HTTP** — `Invoke-LabRequest`, `Get-LabApiError`

**Safety** — `Assert-LabTenant`, `Assert-LabTarget`, `Assert-LabApiHost`,
`Assert-LabTokenClaims`, `Assert-LabDestructive`

**Resources** — `Add-LabResource`, `Get-LabResources`, `Set-LabResourceStatus`,
`Remove-LabResource`

**Logging** — `Write-LabLog`, `Write-LabStep`

**Microsoft auth** — `Get-LabAccessToken`, `Get-LabApiScope`, `ConvertFrom-LabJwt`,
`Show-LabTokenInfo`, `Get-LabCachedRefreshToken`, `Save-LabCachedRefreshToken`

**Certificates** — `New-LabSigningCertificate`, `Get-LabCertificate`, `New-LabClientAssertion`

**SharePoint REST** (`tools/microsoft/Spo.Rest.ps1`) — `Invoke-SpoRequest`, `Get-SpoWeb`,
`Get-SpoLists`, `Get-SpoListItems`, `New-SpoList`, `New-SpoField`, `Add-SpoViewField`,
`New-SpoListItem`, `Get-SpoListEntityType`, `Add-SpoFile`, `Get-SpoSiteUri`

### Invoke-LabRequest

The single HTTP path. Never throws on an HTTP error — it returns the status and body so the
error can be preserved as evidence.

```powershell
$r = Invoke-LabRequest -Uri $uri -Method POST -Token $tok -Body @{ a = 1 } `
        -ContentType 'application/json' -Label 'my-call' -RedactElements @('password')
```

| Returned | Meaning |
|---|---|
| `.Status` `.Ok` | HTTP status; `$true` for 2xx |
| `.Raw` `.Json` | body as text and parsed |
| `.Error.Code` `.Error.Message` | extracted from Microsoft's error shapes |
| `.Headers` `.ElapsedMs` `.EvidenceFile` | response headers, timing, saved evidence path |
| `.DryRun` | `$true` if the call was skipped by `-DryRun` |

---

## 10. Writing a new recipe

One self-contained `.ps1` in `recipes/<product>/`:

```powershell
param([string]$Mode='TEST', [string]$Target, [switch]$DryRun, [switch]$Force,
      [switch]$LabInfo, <recipe args>)

$Recipe = @{ Name='product/thing'; Product='product'; Modes=@('TEST','REPRODUCE')
             Destructive=$false; Description='...' }
if ($LabInfo) { return $Recipe }        # must return before doing any work

. (Join-Path $PSScriptRoot '..\..\core\Core.Context.ps1')

$problems = Test-LabConfigReady -Target $Target -RequiredTargetFields @('workspaceId')
$run = Start-LabRun -Name '...' -Mode $Mode -Product '...' -Target $Target -DryRun:$DryRun `
        -Request '...' -Plan @('...')
if ($problems.Count) { Stop-LabRunBlocked -Problems $problems -NextStep '...'; return }

# ... Invoke-LabRequest / Add-LabResource / Add-LabEvidenceNote ...

Complete-LabRun -Verdict PASS -Summary '...' -Evidence $ev | Out-Null
```

Rules: every HTTP call through `Invoke-LabRequest`; every created resource through
`Add-LabResource` (with a `DeleteUri` wherever a generic delete exists; otherwise record a
`purgeRecipe` or local `path` so cleanup can point at the manual route); name resources with `New-LabResourceName`; define
PASS/FAIL/INCONCLUSIVE in the file header; missing config produces a clean `BLOCKED`, never a
stack trace. The recipe is discovered automatically — no registration step.

---

## 11. Troubleshooting

Every entry below was observed in this lab, not theorised.

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unsupported app only token` from `<tenant>.sharepoint.com/_api` (token shows `appidacr=1`) | SPO REST rejects **client-secret** app-only tokens | Use a certificate identity: `lab/setup-app-certificate`, upload the `.cer`, set `authMode=certificate` |
| `AADSTS700027: key not found` | the certificate's `.cer` is not uploaded to the app registration | Upload it; the thumbprint in Entra must match the one the recipe prints |
| `AADSTS7000218` / device code request refused | *Allow public client flows* is No | Entra → app → Authentication → Advanced settings → set to Yes |
| `403 accessDenied` from `graph.microsoft.com/v1.0/sites` | Graph `Sites.*` not consented — SharePoint Online `Sites.*` is a **different** permission | Add Microsoft Graph → Application → `Sites.Read.All`, then Grant admin consent |
| Dataverse `403 0x80072560` "user is not a member of the organization" | delegated: signed-in user has no Dataverse security role. app-only: no Application User record | Delegated → give the user a role. App-only → Power Platform admin centre → Application users → New app user |
| Power BI / Fabric `401` for a service principal | tenant setting off, or SP not in the workspace | Enable *Service principals can use Fabric APIs*, add the SP to the workspace as Admin |
| HTTP 200 but `$r.Json` is empty | body has keys differing only in case (SharePoint returns both `Id` and `ID`) | Use an explicit `$select`; the wrapper also falls back to `-AsHashtable` and logs at DEBUG |
| `SAFETY: host '<x>' is not in policy allowedApiHosts` | calling a host the policy does not list | Add it to `allowedApiHosts` if it is genuinely part of your lab |
| `SAFETY: target ... matches deny pattern` | a target value looks like production/customer | Rename the target, or adjust `denyNamePatterns` if it is a false positive |
| `Identity '<x>' is reserved` | a reserved app-context identity was inherited from a target | Pass it explicitly: `-Identity <x>` |
| Device-code prompt on every run | no cached refresh token | Sign in once; the token is cached in `config/.tokencache.local.json` |
| `BLOCKED` with a list of missing settings | prerequisites absent | The list is exact — fill in each item and rerun |
| Group/site rebuild fails with a name conflict | M365 group soft-delete holds the name 30 days | Purge the deleted group, or use a different `-SiteName` |

Every failed call's raw body is in the run's `responses/` directory — check it before guessing.

---

## 12. Known constraints

- **PBIX export is documented as unsupported for service principals** in some configurations,
  which is why Power BI uses delegated auth — a service-principal 401 would be ambiguous against
  the semantic-model limitation being investigated.
