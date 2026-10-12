# Config drift: `AT_ENVIRONMENT` on the staging box

**Status:** known, deliberately unreconciled. Do not "fix" this in isolation.

**Observed:** 2026-10-12, on the instance serving `api.relavoi.com`
(`i-0603adf4be9f10f99`, tagged `relavoi-staging`).

## What the drift is

| Source | Value |
|---|---|
| `envs/staging/terraform.tfvars` | `at_environment = "production"` |
| `/opt/relavoi/.env` on the box | `AT_ENVIRONMENT=sandbox` |

The deployed value has drifted from Terraform. The box has been redeployed
several times since, and the drift survives each one, so `.env` is not being
regenerated from the Terraform variable on deploy — `scripts/deploy-staging.sh`
pulls, rebuilds the image and recreates the container, but never rewrites
`.env`. The file was written once by `user-data.sh` at instance creation and has
been hand-edited since.

## Why it matters

`AT_ENVIRONMENT` is read in exactly one place now: the CPaaS webhook signature
gate in `src/api/routes/webhooks.ts`.

```ts
if (config.AT_ENVIRONMENT !== 'sandbox' && !cpaasSignatureValid(req)) { ...403 }
```

With the deployed value of `sandbox`, that check is skipped. **Inbound CPaaS
webhooks are currently unauthenticated in production.** A forged
`POST /v1/webhooks/cpaas/voice` naming a live proxy number is answered with a
`<Dial>` containing the other party's real number, so this is a masking breach,
not merely a billing exposure.

It previously mattered for a second reason: sandbox-mode call and SMS gating was
also keyed off `AT_ENVIRONMENT`, so a box set to `sandbox` would place real,
billable calls for sandbox tenants. That coupling was removed — the sandbox
guard now keys off the session alone — so this drift no longer affects tenant
mode at all. `AT_ENVIRONMENT` should only ever describe which provider endpoint
and credentials we use.

## Why it is not being reconciled yet

Setting it to `production` would make signature verification mandatory
immediately. We do not yet know whether the provider signs voice callbacks, or
with what scheme. If it does not, flipping this value takes **every live call
down** the moment it deploys.

Shadow-mode logging now runs on both CPaaS webhook routes
(`cpaas-webhook-auth-shadow` in the application log) recording, per callback:
source IP, `x-forwarded-for`, whether a signature header was present and under
which name, whether it would have verified, the header names seen, and the
user agent. No header values and no body are logged — a signature is a
bearer-equivalent secret and the body carries subscriber numbers.

## How to close it

1. Collect shadow-mode output across real inbound traffic.
2. Pick the enforcement mechanism from evidence:
   - if the provider signs, enforce the signature;
   - if it does not, use a source-IP allowlist plus a secret path segment in the
     callback URL registered with the provider.
3. Implement and verify enforcement against real traffic.
4. **Then** reconcile `AT_ENVIRONMENT`, and make the deploy script render `.env`
   from Terraform so it cannot drift again.

Until step 3 lands, changing this value is a regression, not a fix.
