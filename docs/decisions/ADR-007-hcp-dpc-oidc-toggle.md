# ADR-007: HCP Terraform — Dynamic Provider Credentials (OIDC) default with SP toggle

**Date:** 2026-06-04
**Status:** Accepted

## Context

HCP Terraform workspace `azure-mcp-demo` needs to authenticate to Azure to run `plan` and
`apply`. Options: (a) service principal with client secret (has a secret), (b) service
principal with federated credential / OIDC (secretless), (c) HCP Dynamic Provider Credentials
(DPC) which uses OIDC between HCP and Azure (secretless).

## Decision

**Default: HCP Dynamic Provider Credentials (DPC) via OIDC.**
**Toggle: service principal with Azure federated credential** (also secretless — no client
secret, federated trust only).

Both paths are secretless. No client secret is used in either path.

### DPC/OIDC (default)

HCP Terraform acts as an OIDC provider. Azure trusts it via a federated credential on an
Azure app registration (or UAMI). HCP issues a short-lived token per run; Azure exchanges it
for an access token. No credential stored in HCP.

Required HCP workspace variables (set as environment variables):
```
TFC_AZURE_PROVIDER_AUTH = true
TFC_AZURE_RUN_CLIENT_ID = <app registration or UAMI client ID>
ARM_TENANT_ID           = <azure tenant id>
ARM_SUBSCRIPTION_ID     = <azure subscription id>
```

### SP + federated credential toggle

An Azure app registration (service principal) with a federated credential trusting HCP's
OIDC issuer. Useful if DPC is unavailable or if explicit SP identity is required for audit.

Required workspace variables:
```
ARM_CLIENT_ID       = <service principal client ID>
ARM_TENANT_ID       = <azure tenant id>
ARM_SUBSCRIPTION_ID = <azure subscription id>
# ARM_CLIENT_SECRET  — NOT set. Federated credential only.
TFC_AZURE_PROVIDER_AUTH = true  (or use OIDC_REQUEST_TOKEN pattern)
```

See `scripts/manual-hcp-workspace-setup.sh` for exact step-by-step for both paths.

## Rationale

- DPC is the cleanest path: no identity artefact to manage in Azure (beyond the trust
  relationship). HCP's own OIDC issuer is the credential.
- The SP toggle provides an alternative for teams/environments where DPC is not available
  or where a named SP identity is required for audit traceability.
- Both are secretless — no client secret ever stored in HCP or committed to the repo.

## Consequences

- Workspace creation and federated credential setup are **manual steps** (see `scripts/`).
- Switching between modes requires updating the workspace variable set, not code.
- HCP workspace execution mode: **VCS-driven** (recommended, see Deliverable 5 guidance in
  docs). CLI-driven is the fallback for local development.

## Enterprise target

Same model per environment (lab/INT/prod), with environment-scoped federated credential
subjects so an INT run cannot produce a prod token.
