# Architecture Intent — Enterprise Vision

> One-page distillation of the MCP Enabling Capability pitch. This is the authoritative
> summary; the raw pitch is in the same directory but excluded from Claude's scan path.
> Enterprise-target sections throughout this repo reference this document.

## The problem we solve

AI agents (Azure SRE Agent and future agents) consume MCP servers over HTTPS. Left ungoverned,
every team spins up its own server with ad-hoc secrets, ad-hoc networking, and no audit trail.
The enabling team's job: solve networking + identity **once**, as a paved road, before shadow
MCP servers proliferate.

## Three layers of the offering

| Layer | What it is | Who owns it |
|-------|-----------|-------------|
| **A — Hosting pattern** | Container Apps + UAMI, deployed via Terraform module | Enabling team |
| **B — Connectivity** | Private-by-default networking: to/from MCP server, DNS, VWAN | Enabling team |
| **C — Identity** | Secretless end-to-end: federated inbound, managed-identity outbound | Enabling team |

Consumers bring: their tool logic and container image. We bring: A + B + C as a module.

## Secretless model (the headline benefit)

```
Agent/caller ──Entra JWT──► MCP server ──UAMI (short-lived token)──► Azure resources
                             validates:                               no secret anywhere
                             iss / aud / exp / claims
```

- **Inbound**: callers present Entra-issued tokens; server validates before acting.
  SRE Agent uses managed-identity connector auth (GA target; preview at time of writing).
- **Outbound**: server uses its User-Assigned Managed Identity. RBAC grants least privilege.
  No client secret, nothing to rotate, nothing to leak.
- **CI/pipelines**: GitHub OIDC federated to Azure; HCP Dynamic Provider Credentials for
  Terraform. Trust via OIDC issuer + subject claims — no shared secret anywhere in the chain.
- **Audit**: every token exchange is an Entra sign-in event; Conditional Access + RBAC apply.

## Connectivity — to/from the MCP server

**To (inbound):**
- *Internal consumers*: reach MCP server via a **private endpoint** on the MCP spoke; traffic
  stays on the private backbone; DNS resolves FQDN to private IP.
- *External managed consumers (SRE Agent)*: governed ingress (Front Door / App Gateway + WAF)
  → private backend; locked down with Entra auth, IP allow-list, WAF + rate limiting.
  This is the deliberate, audited exception to "private only."

**From (outbound / egress):**
- All egress routed through VWAN secured hub (Azure Firewall): inspected, logged, policy-gated.
- Azure PaaS reached via **private endpoints** (Key Vault, Storage, Log Analytics AMPLS, etc.).
- External SaaS via explicit firewall FQDN allow-rules; default deny.

## DNS / Private DNS zones

Zones live in the connectivity/hub subscription, linked to spokes via virtual network links —
**not** per-spoke. Resolution: workloads → Azure DNS Private Resolver → Private DNS zones.
Governs the most common "private endpoint but still resolving public IP" failure mode.

Key zones: `privatelink.{region}.azurecontainerapps.io`, `privatelink.azurewebsites.net`,
`privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net`, AMPLS zones for
Azure Monitor/Log Analytics. Verify current ARM private-link zone names at build time.

## VWAN topology

Secured virtual hub + Azure Firewall = inspection + routing core. MCP spoke is a normal
spoke connection; consumers in other spokes reach MCP through the hub. Routing intent steers
egress through firewall, making the "from" controls non-optional.

## Cross-environment isolation

One MCP server instance per environment (lab → INT → prod). Each env has its own spoke,
UAMI, federated credentials, RBAC scope, and OIDC subject. No cross-env traffic by default;
hub-routed firewall exception required for any sharing. Promotion = same Terraform module,
different tfvars — config change, not rebuild.

## Lab vs enterprise delta (summary)

| Concern | Lab build (this repo) | Enterprise target |
|---------|-----------------------|-------------------|
| Ingress | Public HTTPS | Private endpoint + governed Front Door/WAF |
| Registry | GHCR (free) | ACR Premium + private endpoint + `AcrPull` MI + signing |
| Image base | `python:3.12-slim` | Azure Linux (Mariner) distroless from MCR |
| Networking | No VNet integration | VNet-injected spoke + VWAN hub + firewall |
| DNS | Public Azure DNS | Private DNS zones (centralised hub) |
| Monitoring | Log Analytics (public, min retention) | AMPLS private monitoring |
| Environments | Lab only | Lab → INT → prod with env-scoped federation subjects |
| Auth (agent inbound) | Entra JWT validation (generic) | MI connector auth (preview → GA) |
