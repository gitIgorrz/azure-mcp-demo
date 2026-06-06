# ADR-009: UAMI with built-in Reader at resource-group scope

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server's runtime identity (User-Assigned Managed Identity) needs RBAC permission to
call ARM and Azure Resource Graph to fulfil the read-only tools (ADR-004). Options:
- Subscription-scoped Reader
- Resource-group-scoped Reader (built-in)
- Custom read-only role at any scope
- Data-plane roles per service

## Decision

**UAMI assigned built-in `Reader` role at resource-group scope** (`rg-mcp-demo-lab`).

The UAMI is named `id-mcp-demo-{env}` and attached to the Container App.

## Rationale

- **Narrowest viable scope**: Reader at RG scope is the smallest grant that lets the server
  list resource groups and query Resource Graph for resources within that scope. It cannot
  read resources in other resource groups or subscriptions.
- **Built-in role**: the built-in `Reader` role is stable, well-understood, and covers ARM
  read operations without needing custom role maintenance.
- **Blast radius**: if the UAMI were compromised, an attacker could only read metadata from
  one resource group — not the full subscription, not data-plane secrets, not other envs.
- A custom read-only role would be marginally more restrictive (could exclude
  `Microsoft.Resources/subscriptions/resourceGroups/read` at sub scope) but adds maintenance
  overhead and complexity not warranted for the lab.

## Open question resolved

Design pass §4 Q2: custom role vs built-in Reader. Decision: **built-in Reader at RG scope**
for the lab. Custom role documented as the enterprise refinement if tighter scoping is needed.

## Consequences

- Resource Graph queries return results bounded to the resource group, not the full subscription.
  This is intentional — it limits the blast radius of the demo.
- If a future tool requires subscription-level reads (e.g. listing all resource groups), the
  role assignment scope must be moved to subscription — this requires a new ADR and justification.
- Data-plane access (Key Vault secrets, Storage blobs, Log Analytics data) is NOT granted.
  If future tools need data-plane access, a separate, scoped data-plane role per service is
  required — not broadening the ARM Reader grant.

## Enterprise target

Custom read-only role with explicit `actions` (no wildcards), scoped per service, per
environment. Each env's UAMI has its own role assignment bounded to that env's resources.
Data-plane roles added per tool, per service, with least-privilege data actions.
