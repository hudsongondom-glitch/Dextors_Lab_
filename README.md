# Dextors Lab

Build controlled test artifacts in **your own** Microsoft 365 / Power Platform / Power BI test
tenant, run an experiment against them, collect evidence, and clean up.

Zero dependencies: PowerShell 7 + REST. No modules to install, no build step, no services.

Documentation:

- [What is Dextors Lab](docs/what-is-dextors-lab.md): concepts and how it works
- [How to use Dextors Lab](docs/how-to-use-dextors-lab.md): step-by-step setup and usage
- [Operator Guide](docs/USER-GUIDE.md): full reference for recipes, auth model, evidence and troubleshooting
- [Power BI backup coverage](docs/powerbi-backup-coverage.md): validated findings on why Power BI items go missing from backups

This page is the quickstart.

## Install

Clone the repository and run `lab.ps1` from its root with PowerShell 7.

Optionally, install it as a Claude Code plugin to run the same recipes from plain-English
requests. The plugin calls the same `lab.ps1` dispatcher and adds no functionality of its own:

```
/plugin marketplace add hudsongondom-glitch/dextors_lab_
/plugin install dextors-lab
```

## Setup

```powershell
.\lab.ps1 BUILD lab/init -TenantDomain <yours>.onmicrosoft.com
.\lab.ps1 BUILD lab/setup-app-registration
.\lab.ps1 INSPECT lab/status
```

- `lab/init` seeds your `LAB_HOME`, resolves the tenant GUID from the domain, and nominates that
  one tenant as the enforced boundary.
- `lab/setup-app-registration` creates the Entra apps, adds their permissions across Graph,
  SharePoint Online, Dataverse and Power BI, enables public client flows, and prints an **admin
  consent URL per app**. Consent happens in a browser — Entra does not allow it to be automated.
- `lab/status` is a non-interactive readiness check that never triggers a sign-in prompt.

From a Claude Code session, `/lab-setup` walks the whole sequence for you.

Some products need one more value in `LAB_HOME/config/lab.config.json` before use (a workspace id,
a site URL, a Dataverse environment URL). A missing value produces a clean `BLOCKED` listing
exactly what is absent.

### Where things live

**Code** is wherever you cloned or installed it. **State** is `LAB_HOME` — configuration,
credentials, certificates, evidence and generated artifacts. They are deliberately separate so the
code can be updated or replaced without touching your setup.

`LAB_HOME` resolves to `$env:LAB_HOME` if set, otherwise the checkout when
`config/lab.config.json` sits beside the code, otherwise `~/.dextors-lab`.

Secrets are consumed through environment variables only, and never appear in code, evidence,
`lab.config.json`, `lab.policy.json` or git. `LAB_HOME/config/lab.secrets.local.json` is an
optional, git-ignored convenience loader that fills those variables at start; an existing session
variable always wins. `lab.config.json` and `lab.policy.json` are git-ignored local state seeded
from `templates/` by `lab/init`.

## Use

```powershell
.\lab.ps1 LIST                                  # what is available
.\lab.ps1 <MODE> <recipe> [-Target name] [-Identity name] [-DryRun] [-Force] [recipe args]
```

Modes: `BUILD` (create test resources) · `TEST` (run an experiment) · `REPRODUCE` (reproduce a
known failure) · `INSPECT` (read-only) · `CLEANUP` (remove what the lab created). A recipe only
accepts the modes it declares.

`-DryRun` lets reads through and skips every write, logging what it would have done. Use it before
anything that writes.

Verdicts are `PASS` / `FAIL` / `INCONCLUSIVE` / `BLOCKED` / `DONE`. **For `REPRODUCE` recipes,
`PASS` means the reported limitation was reproduced** — each recipe defines its own criteria in
its file header.

Offline self-tests, no credentials needed (run `lab/init` first; they read LabHome):

```powershell
pwsh -File tests\Test-LabFramework.ps1
pwsh -File tests\Test-DependencyModel.ps1
```

## Evidence and cleanup

Every run writes `LAB_HOME/runs/<timestamp>-<name>/` with the request, plan, metadata, result, and
raw request/response bodies. Error bodies are kept verbatim — the exact Microsoft error code is
what makes a reproduction useful. Evidence may contain tenant identifiers; treat it as local-only.

Everything the lab creates is recorded in a ledger. Cleanup only ever touches ledger entries,
never anything it merely finds in your tenant:

```powershell
.\lab.ps1 INSPECT lab/cleanup-tracked-resources          # preview, deletes nothing
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force   # actually delete
```

Most API-created resources are recorded with a generic delete URI and are removed by that recipe.
A few are tracked deliberately without one and need manual or special cleanup (a local artifact's
recorded path, or a `purgeRecipe` such as `powerplatform/purge-lab-records`); they stay in the
ledger. Cleanup verdicts: `DONE` = generic cleanup completed and nothing requiring attention
remains · `INCONCLUSIVE` = manual/special-cleanup resources remain · `FAIL` = a deletion failed or
an expected generic cleanup was blocked/skipped. Details in the
[Operator Guide](docs/USER-GUIDE.md#7-resource-tracking-and-cleanup).

## Safety boundary

This lab is for test tenants you own. The boundary is enforced in code, not documentation — all of
these throw:

| Check | Prevents |
|---|---|
| `allowedTenantIds` | authenticating to any tenant not nominated. Empty list = refuses to authenticate at all |
| token `tid` claim check | a misconfigured client reaching another tenant — validated on the issued token, not on config |
| `allowedApiHosts` | any HTTP call to an unlisted host, including ad-hoc ones |
| `denyNamePatterns` | targeting anything that looks like production or a customer (`*prod*`, `*customer*`, …) |
| destructive gate | deleting without both an explicit allow and a ledger entry |

Host checking lives inside the single HTTP wrapper, so a new recipe cannot bypass it by accident.
When installed as a plugin, a `PreToolUse` hook additionally refuses agent edits to
`lab.policy.json` — widening the boundary should always be a deliberate human act.

## Layout

| Path | What |
|---|---|
| `lab.ps1` | recipe dispatcher |
| `core/` | framework: config, safety, auth contract, run/evidence, HTTP, resource ledger, logging |
| `tools/microsoft/` | token acquisition per API audience, SharePoint REST, Dataverse |
| `tools/powerbi/`, `tools/powerplatform/` | seed data, M expressions; dependency model, Power Pages and flow helpers |
| `recipes/<product>/` | one experiment per file, auto-discovered |
| `templates/` | config and policy templates `lab/init` seeds from |
| `tests/` | offline self-tests |
| `skills/`, `commands/`, `hooks/` | optional Claude Code plugin components |
| `docs/` | documentation |
