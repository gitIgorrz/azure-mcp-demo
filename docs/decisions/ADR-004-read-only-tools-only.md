# ADR-004: Read-only MCP tools only — no destructive operations

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server exposes Azure capabilities as tools to AI agents. The scope of permissible
operations must be defined explicitly, as AI agents can (and will) call any tool the server
exposes.

## Decision

The MCP server exposes **only read-only tools**. No write, delete, restart, scale, or any
other mutating Azure operation is permitted anywhere in `app/`. This is a hard codebase rule,
enforced by code review on every PR.

Tools exposed:
- `health` — server health + attached identity metadata
- `get_subscription` — current subscription name, ID, tenant
- `list_resource_groups` — all resource groups visible to the UAMI
- `list_resources` — resource inventory query via Azure Resource Graph (filterable)

## Rationale

- **Lab safety**: the UAMI has `Reader` scope (ADR-009), making destructive calls impossible
  at the RBAC level. But defence-in-depth means the tools themselves should also not attempt
  mutations — the RBAC refusal would surface as an unhelpful error rather than a clear intent.
- **Demo focus**: the purpose of this lab is to demonstrate the *connectivity and identity*
  paved road, not a comprehensive management plane. A minimal, read-only tool set proves the
  end-to-end secretless path without scope creep.
- **Agent safety**: AI agents are autonomous. Exposing write tools — even with RBAC guards —
  creates a path for an agent to attempt destructive actions, producing confusing errors at best
  and (with misconfigured RBAC) unintended mutations at worst.
- **Regulatory posture**: a read-only offering is far easier to justify for a shared platform
  capability. Write tools require per-consumer scoping, approval workflows, and audit trails
  beyond this lab's scope.

## Consequences

- The `app/` directory must be reviewed for any PR that adds tools to ensure no mutating
  Azure SDK call is introduced.
- The UAMI's `Reader` role provides an RBAC backstop, but the code-level rule is the
  primary control.
- Future write-capable tools (if ever needed) require: a separate ADR, a scoped custom RBAC
  role, per-caller authorisation at the tool level, and explicit PR approval.

## Enterprise target

Same posture for the reference server. Per-consumer scoping of write tools, if ever needed,
should be a separate server instance with a separate UAMI and a narrowly scoped custom role —
not mixed into the read-only reference server.
