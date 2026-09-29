---
name: lab-run
description: Run a Dextors Lab experiment from a plain-English description - pick the recipe, dry run it, execute, and report the verdict and evidence.
argument-hint: "[what you want to build, test, reproduce or inspect]"
---

The user wants: `$1`

**1. Pick the recipe.** List what is available and match on product and intent:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" LIST
```

If several could fit, ask which. If nothing fits, say so plainly and offer to write a new recipe —
do not improvise with raw API calls, and do not force an unrelated recipe to approximate the
request.

**2. Work out the mode and arguments.** The mode follows the intent: `BUILD` to create, `TEST` to
run a defined experiment, `REPRODUCE` to reproduce a known failure, `INSPECT` to look without
changing anything, `CLEANUP` to remove. A recipe only accepts the modes it declares.

Read the recipe's file header before running it — it defines what PASS, FAIL and INCONCLUSIVE mean
for that specific experiment, and lists its arguments. For `REPRODUCE` recipes, PASS conventionally
means the reported limitation *was* reproduced.

If a required argument is missing (a report id, workspace, scenario arm), ask rather than guess.

**3. Dry run anything that writes.**

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" <MODE> <recipe> -DryRun [args]
```

Reads go through, writes are skipped and logged. Show the user what it would have done and get
agreement before running for real. Skip this step only for `INSPECT`.

**4. Run it.** If the recipe prints a device code and URL, surface both verbatim and wait — do not
retry or assume it completed.

**5. Report.** Give the user:

- the verdict, and what it means *for this recipe* per its header
- the one-line summary
- the exact Microsoft error code and message where something failed, quoted from the raw response
  body in the run's `responses/` directory rather than paraphrased — the precise code is usually
  the whole point
- the run directory path, so they can read the full evidence
- what was created, if anything, and an offer to clean it up

If the verdict is `BLOCKED`, the output lists exactly what is missing. Relay that list; do not try
to work around it by editing the policy.
