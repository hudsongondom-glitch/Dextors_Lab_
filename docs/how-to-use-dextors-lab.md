# How to use Dextors Lab

**Audience:** support engineers who want to reproduce a Microsoft 365, Power Platform or Power BI
backup or restore behaviour in their own test tenant and collect evidence for a case.

New to the lab? Read [what-is-dextors-lab.md](what-is-dextors-lab.md) first. For every recipe,
config key and error message, see the [Operator Guide](USER-GUIDE.md).

---

## Contents

1. [Before you start](#1-before-you-start)
2. [One-time setup](#2-one-time-setup)
3. [From ticket to evidence: the everyday workflow](#3-from-ticket-to-evidence-the-everyday-workflow)
4. [Choosing a recipe](#4-choosing-a-recipe)
5. [Running a recipe](#5-running-a-recipe)
6. [Reading the result](#6-reading-the-result)
7. [Worked example: a Power BI report won't export](#7-worked-example-a-power-bi-report-wont-export)
8. [Cleaning up](#8-cleaning-up)
9. [Using the lab from Claude Code](#9-using-the-lab-from-claude-code)
10. [Do's and don'ts](#10-dos-and-donts)
11. [Common problems](#11-common-problems)
12. [FAQ](#12-faq)

---

## 1. Before you start

You need:

| Requirement | Details |
|---|---|
| **PowerShell 7** | Check with `$PSVersionTable.PSVersion`. It must be 7.x (`pwsh`), not Windows PowerShell 5.1 |
| **Your own Microsoft test tenant** | A tenant that belongs to you or your team for testing, such as a developer tenant. **Never a customer or production tenant** |
| **An admin account in that tenant** | Application Administrator (or higher) to create app registrations, and someone who can grant admin consent |
| **Product environments you want to test** | For example a Power BI workspace, a Dataverse environment, a SharePoint site or a test mailbox |
| **This repository** | Cloned locally, or installed as a Claude Code plugin (see [section 9](#9-using-the-lab-from-claude-code)) |

---

## 2. One-time setup

Do this once per machine. Run every command from the repository folder.

### Step 1: Seed your LabHome and set the tenant boundary

```powershell
.\lab.ps1 BUILD lab/init -TenantDomain yourlab.onmicrosoft.com
```

This will:

- create your local state folder (LabHome), with `config/lab.config.json` and
  `config/lab.policy.json` copied from `templates/`,
- look up the tenant ID for the domain you gave,
- put **that one tenant** on the allow-list. From now on the lab refuses every other tenant.

It ends with a "Next steps" list. Keep it handy.

Now run the offline self-test. It needs no credentials, but it does need the LabHome that
`lab/init` just created. It confirms the framework works on your machine:

```powershell
pwsh -File tests\Test-LabFramework.ps1
```

> Double-check the domain is your **test** tenant. This value becomes the enforced boundary for
> everything the lab does.

### Step 2: Create the app registrations

```powershell
.\lab.ps1 BUILD lab/setup-app-registration
```

- The recipe prints a **device code** and a URL. Open the URL, enter the code and sign in with your
  test-tenant admin account.
- It then creates the Entra apps the lab needs, adds their API permissions, turns on public client
  flows and writes the client IDs into your config.
- At the end it prints **one admin consent URL per app**.

### Step 3: Grant admin consent (manual, in a browser)

Microsoft doesn't allow consent to be automated. For each consent URL from step 2:

1. Open the URL in a browser.
2. Sign in as a tenant admin of your **test** tenant.
3. Review the permissions and select **Accept**.

### Step 4: Add the Graph client secret

The Graph identity (`msg-app`) signs in with a client secret, and you create that secret
yourself:

1. Go to the **Microsoft Entra admin center** → **App registrations** → the lab's Graph app.
2. Open **Certificates & secrets** → **Client secrets** → **New client secret**, then copy the
   **Value**.
3. Make it available as an environment variable, either for the current session:

   ```powershell
   $env:LAB_SECRET_MSGAPP = '<secret value>'
   ```

   or permanently in `<LabHome>/config/lab.secrets.local.json` (git-ignored). Use
   `config/lab.secrets.example.json` as the template.

Secrets are **only** read from environment variables. Never put them in `lab.config.json`.

### Step 5: Certificate for SharePoint REST (only if you'll test SharePoint `_api`)

```powershell
.\lab.ps1 BUILD lab/setup-app-certificate -Identity msg-app-cert
```

Then upload the generated `.cer` file to the same app registration under **Certificates &
secrets** → **Certificates** → **Upload certificate**. SharePoint REST rejects secret-based app
tokens, so this step is required for any `sharepoint/*-rest` recipe.

### Step 6: Tell the lab where your test environments are

Open `<LabHome>/config/lab.config.json` and fill in the `targets` you plan to use:

| Target | Field to fill in | Where to find it |
|---|---|---|
| `powerbi-main` | `workspaceId` | The GUID after `/groups/` in the workspace URL in app.powerbi.com |
| `dataverse-main` | `environmentUrl` | Power Platform admin center → environment → **Environment URL**, such as `https://yourorg.crm.dynamics.com` |
| `spo-main` | `siteUrl` | The full URL of your test site |
| `exchange-main` | `mailbox` | A test mailbox's address |

You only need to fill in the targets for the products you'll actually use. If a value is missing
when you run a recipe, the lab stops with `BLOCKED` and names the missing field.

### Step 7: Check readiness

```powershell
.\lab.ps1 INSPECT lab/status
```

This is read-only and never prompts you to sign in. You'll see a table per product:

| State | Meaning | What to do |
|---|---|---|
| `READY` | Usable now | Nothing |
| `not signed in yet` | Delegated product (Power BI, Dataverse) with no cached sign-in | Nothing. The first recipe you run prints a device code |
| `SECRET MISSING` / `PFX MISSING` | Credential isn't available | Redo step 4 or step 5 |
| `NO CLIENT ID` | App wasn't created | Redo step 2 |
| An HTTP error | Usually consent or a missing permission | Redo step 3, or see [section 11](#11-common-problems) |

---

## 3. From ticket to evidence: the everyday workflow

Use this checklist for every case:

1. **Write down the hypothesis** in one sentence, such as "Export fails because the model uses
   large semantic model storage format."
2. **Find a recipe** that tests it ([section 4](#4-choosing-a-recipe)). Read its file header to see
   what PASS, FAIL and INCONCLUSIVE mean for that recipe.
3. **Check readiness:** `.\lab.ps1 INSPECT lab/status`.
4. **Build the condition** in your test tenant with a `BUILD` recipe or, where the header says so,
   manually (for example by changing a semantic model setting in the Power BI service).
5. **Dry-run** anything that writes: add `-DryRun`.
6. **Run the experiment** in `TEST` or `REPRODUCE` mode.
7. **Read `result.md`**, and take the exact error code from `responses/`.
8. **Record the conclusion** in the case: the hypothesis, the verdict, the exact Microsoft error
   code and message, and a Microsoft documentation link if there is one.
9. **Clean up** ([section 8](#8-cleaning-up)).

---

## 4. Choosing a recipe

List everything available:

```powershell
.\lab.ps1 LIST
```

Common case symptoms and where to start:

| The customer says… | Start with | Mode |
|---|---|---|
| "Power BI reports are missing from the backup" | `powerbi/backup-coverage-matrix` | `INSPECT` |
| "A report downloads in the browser but the backup can't export it" | `powerbi/report-rest-export` | `REPRODUCE` |
| "Our Dataflow Gen2 isn't in the backup" | `powerbi/dataflow-gen2-visibility` | `REPRODUCE` |
| "I need a workspace full of realistic Power BI items to test with" | `powerbi/build-seed-artifacts` | `BUILD` |
| "Dataverse restore fails on lookups / related records" | `powerplatform/build-dependency-model` → `seed-cycle-dataset` → `verify-dataset-state` (scenario arms are described in the `seed-cycle-dataset` recipe header) | `BUILD`, then `INSPECT` |
| "Restore fails on a column with field-level security" | `powerplatform/inspect-field-security-scenario` → `reproduce-field-security-restore` | `INSPECT`, then `REPRODUCE` |
| "A restored cloud flow is in the wrong solution" | `powerplatform/build-flow-solution-testset` → `reproduce-flow-solution-restore` | `BUILD`, then `TEST` |
| "Power Pages content isn't backed up" | `powerplatform/inspect-powerpages-site` → `build-powerpages-edm-testset` | `INSPECT`, then `BUILD` |
| "Dataverse for Teams environment can't be backed up" | `powerplatform/inspect-teams-environment` | `INSPECT` |
| "Restored SharePoint page is blank or broken" | `sharepoint/build-test-site` → `prepare-modern-page` | `BUILD` |
| "What's in this SharePoint site / list?" | `sharepoint/inspect-site` (Graph) or `inspect-site-rest` (SPO REST) | `INSPECT` |
| "In-Place Archive backup is empty or incomplete" | `exchange/archive-graph-delta` | `REPRODUCE` |

If nothing fits, don't improvise with ad-hoc API calls. Write a new recipe instead (see [USER-GUIDE.md §10](USER-GUIDE.md#10-writing-a-new-recipe)).

---

## 5. Running a recipe

### Command shape

```powershell
.\lab.ps1 <MODE> <recipe> [-Target <name>] [-Identity <name>] [-DryRun] [-Force] [recipe arguments]
```

| Part | Meaning |
|---|---|
| `<MODE>` | `BUILD`, `TEST`, `REPRODUCE`, `INSPECT` or `CLEANUP`. Must be one the recipe supports |
| `<recipe>` | The name from `LIST`, such as `powerbi/report-rest-export` |
| `-Target` | Which environment from your config. **Pass it explicitly**: without it the lab uses `defaults.target`, which is `spo-main` out of the box |
| `-Identity` | Override which app identity to use. Normally leave it out |
| `-DryRun` | Do all the reads, skip all the writes, and log what would have been written |
| `-Force` | Needed to actually delete anything |
| recipe arguments | Listed in the recipe's `param()` block and in [USER-GUIDE.md §4](USER-GUIDE.md#4-recipe-reference) |

### Always dry-run first when a recipe writes

```powershell
.\lab.ps1 BUILD powerbi/build-seed-artifacts -Target powerbi-main -DryRun
```

Check the output, then run it again without `-DryRun`. `INSPECT` runs are read-only, so they
don't need a dry run.

### Signing in with a device code

The first time you run a Power BI or Dataverse recipe, you'll see something like:

```
To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code ABCD-EFGH.
```

Open the URL, enter the code and sign in with your **test tenant** account. The recipe continues
by itself. Your sign-in is cached, so you won't be asked again on later runs.

---

## 6. Reading the result

### In the console

Each run ends with a verdict and a one-line summary:

| Verdict | Normal recipe | `REPRODUCE` recipe |
|---|---|---|
| `PASS` | It worked | **The reported problem was reproduced** |
| `FAIL` | It didn't work | The problem did **not** occur |
| `INCONCLUSIVE` | Couldn't decide, usually because of auth or permissions | Same |
| `BLOCKED` | Setup is missing something. The list is exact | Same |
| `DONE` | Informational run finished | – |

> Always confirm the meaning in the recipe's file header. Each recipe defines its own verdicts.

### In the run folder

Every run creates `<LabHome>/runs/<timestamp>-<name>/`. Read the files in this order:

1. **`result.md`**: verdict, summary and key findings.
2. **`responses/`**: raw Microsoft responses. **Copy the error code and message exactly as they
   appear here.** Don't paraphrase them.
3. **`plan.md`** and **`logs/run.log`**: what the recipe tried to do and in what order.
4. **`resources.json`**: anything this run created, which you'll need for cleanup.

### What to put in the case

- The hypothesis you tested.
- The recipe name, the mode and the verdict.
- The exact Microsoft error code and message from `responses/`.
- What you changed in your test setup to trigger it (such as "enabled incremental refresh").
- A Microsoft Learn link that documents the behaviour, if there is one.

**Don't** paste whole run folders into tickets or chats. They contain your test tenant's IDs.
Share only the relevant excerpt.

---

## 7. Worked example: a Power BI report won't export

**Case:** *"We can download report X from the Power BI service, but the backup job says it
couldn't export it."*

**Hypothesis:** the report's semantic model has a setting (incremental refresh, large model
storage format or Direct Lake) that blocks the REST export API, even though the browser download
works.

**1. Check readiness**

```powershell
.\lab.ps1 INSPECT lab/status
```

Confirm Power BI shows `READY` or `not signed in yet`.

**2. See which reports are in your test workspace**

```powershell
.\lab.ps1 INSPECT powerbi/report-rest-export -Target powerbi-main -ListOnly
```

**3. Build the condition.** In the Power BI service, open a test semantic model and turn on the
suspected setting. For example, go to **Settings** → **Large semantic model storage format** →
**On**. This is a manual step; the lab doesn't change tenant or model settings for you.

**4. Reproduce**

```powershell
.\lab.ps1 REPRODUCE powerbi/report-rest-export -Target powerbi-main -ReportId <report-guid>
```

**5. Read the result**

- `PASS` means the export failed and the error code was captured, so the limitation is
  reproduced.
- `FAIL` means the export succeeded, so this setting isn't the cause.
- In `responses/`, find the error code, for example
  `ServerError_PremiumFilesErrors_OperationIsNotSupportedForPremiumFilesModel`.

**6. Match it to known behaviour.** Look the code up in
[powerbi-backup-coverage.md](powerbi-backup-coverage.md). It explains each code, whether the item
can still be downloaded in the UI, and whether the vendor can do anything about it.

**7. Revert the setting** in the Power BI service so the next experiment starts clean.

---

## 8. Cleaning up

Everything the lab creates is recorded in a ledger (`runs/_ledger.jsonl`). Cleanup **only** acts on
ledger entries, never on anything it simply finds in your tenant.

**Preview (deletes nothing):**

```powershell
.\lab.ps1 INSPECT lab/cleanup-tracked-resources
```

**Delete:**

```powershell
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force
```

**Delete only what one run created:**

```powershell
.\lab.ps1 CLEANUP lab/cleanup-tracked-resources -Force -RunId 20260929-101500
```

Cleanup verdicts:

| Verdict | Meaning |
|---|---|
| `DONE` | Everything deletable was deleted and nothing else needs attention |
| `INCONCLUSIVE` | Some items need manual or special cleanup. The output names the recipe or path, such as `powerplatform/purge-lab-records` for bulk Dataverse records |
| `FAIL` | A delete failed or was refused. Check `responses/` |

> **SharePoint / Microsoft 365 groups:** a deleted group-connected site stays in the recycle bin
> for 30 days and keeps its name reserved. To rebuild right away, pick a different `-SiteName`.

---

## 9. Using the lab from Claude Code

The repository is also a Claude Code plugin, so you can drive the lab in plain English:

```
/plugin marketplace add hudsongondom-glitch/Dextors-Lab
/plugin install dextors-lab
```

| Command | What it does |
|---|---|
| `/lab-setup yourlab.onmicrosoft.com` | Walks you through the whole of [section 2](#2-one-time-setup) |
| `/lab-status` | Runs the readiness check and summarises what's left to do |
| `/lab-run <what you want>` | Picks the recipe, dry-runs it, runs it, and reports the verdict with the exact error code |

Example:

```
/lab-run check whether a report with incremental refresh can be exported via REST in powerbi-main
```

Claude follows the same rules as you: it can't widen the safety policy (a hook blocks edits to
`lab.policy.json`), it dry-runs before writing, and it hands you device codes and consent URLs
instead of trying to complete them itself.

---

## 10. Do's and don'ts

**Do**

- Use only your own test tenant and test environments.
- Pass `-Target` explicitly.
- Dry-run before anything that writes.
- Read the recipe header before you interpret a verdict.
- Quote error codes exactly as they appear in `responses/`.
- Clean up when you're done, and revert any manual settings you changed.

**Don't**

- Point the lab at a customer or production tenant, or copy customer data into it.
- Put secrets in `lab.config.json`, in code or in a ticket.
- Edit `lab.policy.json` to get past a safety refusal. Policy changes should be deliberate and
  made by hand, never as a workaround.
- Call Microsoft APIs directly with `Invoke-RestMethod` "just this once". Only recipes that go
  through the lab's HTTP layer get the safety checks and evidence capture.
- Share full run folders outside your machine.

---

## 11. Common problems

| You see | Why | Fix |
|---|---|---|
| `BLOCKED` with a list | A config value or credential is missing | Fill in exactly what's listed and rerun |
| `Recipe '<x>' does not support mode <Y>` | Wrong mode for that recipe | Use one of the modes it lists |
| `Recipe '<x>' not found` / `is ambiguous` | Typo or partial name | Run `.\lab.ps1 LIST` and copy the full name |
| `SAFETY: target ... matches deny pattern` | The target's name looks like production (`prod`, `customer`, `live`…) | Rename your test resource or target |
| `SAFETY: host '<x>' is not in policy allowedApiHosts` | The recipe tried to call an unlisted host | Add it to `allowedApiHosts` only if it's genuinely part of your test environment |
| `401 Unsupported app only token` (SharePoint `_api`) | SharePoint REST needs a certificate, not a secret | [Step 5](#step-5-certificate-for-sharepoint-rest-only-if-youll-test-sharepoint-_api) |
| `AADSTS700027: key not found` | Certificate not uploaded to the app | Upload the `.cer` to the app registration |
| `AADSTS7000218` or device code refused | *Allow public client flows* is off | Entra → app → **Authentication** → **Allow public client flows** = **Yes** |
| `403 accessDenied` from Graph `/sites` | Graph `Sites.*` permission not consented | Grant admin consent again ([step 3](#step-3-grant-admin-consent-manual-in-a-browser)) |
| Dataverse `403 0x80072560` | Your user has no security role in that environment | Power Platform admin center → environment → **Users** → give your user a role |
| Device code prompt on every run | Sign-in isn't being cached | Complete the sign-in once. The token is cached in `config/.tokencache.local.json` |
| `Identity '<x>' is reserved` | An alternative app-only identity was picked up from a target | Pass it explicitly with `-Identity <x>` if you really mean to use it |

The complete list is in [USER-GUIDE.md §11](USER-GUIDE.md#11-troubleshooting). Before you guess,
always look at the raw body in the run's `responses/` folder.

---

## 12. FAQ

**Can I use a customer's tenant if they give me credentials?**
No. The lab is for your own test tenant only, and it will refuse any tenant that isn't on its
allow-list. Rebuild the customer's condition in your test tenant instead.

**The verdict says PASS. Does that mean everything is fine?**
Not for `REPRODUCE` recipes. There, PASS means the problem was reproduced. Check the recipe
header.

**Will the lab delete things I created by hand?**
No. Cleanup only removes items in the lab's ledger, and only with `-Force`.

**Does the lab test the backup product itself?**
No. It covers the Microsoft side only: what Microsoft's APIs return. Backup-platform automation is
out of scope.

**Where is my data stored?**
Everything lives in your LabHome folder (`$env:LAB_HOME`, the checkout, or `~/.dextors-lab`).
None of it is committed to git.

**I need an experiment that doesn't exist yet.**
Write a recipe. New recipes follow a fixed template (see [USER-GUIDE.md §10](USER-GUIDE.md#10-writing-a-new-recipe))
and are picked up automatically once added to `recipes/<product>/`.
