---
name: lab-status
description: Report Dextors Lab readiness - identities, credentials and a live probe of every configured product.
---

Run the lab's readiness check. It is read-only and non-interactive; it never triggers a sign-in
prompt, so it is safe to run at any time.

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" INSPECT lab/status
```

Then summarise for the user:

- Which products are READY and therefore usable right now.
- Anything NOT SIGNED IN — these are delegated products needing a one-off device-code sign-in,
  which happens automatically the first time a recipe for that product runs.
- Anything NOT CONFIGURED or erroring, with the specific next action. Common causes, in rough
  order of likelihood:
  - client id missing → `/lab-setup`
  - permissions not consented → the admin consent URL from `lab/setup-app-registration`
  - a per-product value missing from `LAB_HOME/config/lab.config.json` (workspace id, site URL,
    Dataverse environment URL) → ask the user for it; never guess
  - `401 Unsupported app only token` from SharePoint `_api` → needs the certificate identity, not
    a client secret

If the check itself fails because there is no configuration, say the lab is not set up on this
machine yet and point at `/lab-setup`.

Keep it to a short table plus the next action. Do not paste the whole run log.
