---
name: lab-setup
description: Set up Dextors Lab on this machine - seed LAB_HOME, create the Entra app registrations, and report readiness.
argument-hint: "[tenant domain, e.g. contosolab.onmicrosoft.com]"
---

Set up the lab on this machine. Tenant domain (may be empty): `$1`

Work through these in order, stopping at the first thing that needs the user.

**1. Check what already exists.**

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" INSPECT lab/status
```

This never triggers a sign-in prompt. If it reports everything READY, say so and stop — there is
nothing to set up.

If it fails because there is no configuration yet, that is expected on a first run; continue.

**2. Seed LAB_HOME.**

If `$1` is empty, ask the user for their **test** tenant domain before going further. Confirm it
is a test tenant, not production — this value becomes the enforced boundary for everything the
lab subsequently does.

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" BUILD lab/init -TenantDomain <domain>
```

Report the resolved tenant GUID and the "Next steps" list it prints.

**3. Create the app registrations.**

Tell the user this signs in via device code and needs an account that can create app
registrations (Application Administrator or higher), then run:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" BUILD lab/setup-app-registration
```

Surface the device code and URL verbatim and wait for them to complete it. Do not retry or assume
success.

**4. Hand over admin consent.**

The recipe prints one consent URL per app. Consent happens in a browser and cannot be automated.
Give the user the URLs as a numbered list and wait for confirmation that each is approved.

**5. Certificate for SharePoint REST**, only if they intend to use SharePoint `_api`:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" BUILD lab/setup-app-certificate -Identity msg-app-cert
```

Then tell them to upload the generated `.cer` to that app registration under
Certificates & secrets. A client-secret app-only token is rejected by SPO REST with
`401 Unsupported app only token`; this is a hard SharePoint constraint, not a consent problem.

**6. Confirm.**

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/lab.ps1" INSPECT lab/status
```

Report the final table. Anything still not READY: name it, say which of the steps above covers it,
and what per-product value may still be missing from `LAB_HOME/config/lab.config.json` (a workspace
id, site URL or Dataverse environment URL). Do not invent those values — ask.
