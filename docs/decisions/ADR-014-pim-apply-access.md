# ADR-014: Privileged Identity Management (PIM) for apply access

**Date:** 2026-06-04
**Status:** Accepted (manual setup — see scripts/)

## Context

Running `terraform apply` requires elevated Azure RBAC (e.g. `Contributor` or
`Owner` at resource-group scope to create and assign roles). Granting these permanently
(standing access) violates least-privilege principles. PIM provides time-bound, on-demand
elevation.

## Decision

Use **Azure AD Privileged Identity Management (PIM)** for the Azure role needed by the
service principal / federated identity that runs `terraform apply`.

Recommended setup:
- **Entra group**: `grp-mcp-demo-tf-apply` (or similar)
- **Role**: `Contributor` at resource-group scope (`rg-mcp-demo-lab`) — eligible, not permanent
- **Activation**: self-service, time-limited (e.g. 1 hour), requires justification text
- **Approval workflow**: for lab, self-approval is acceptable (see risk below)
- **Access review**: schedule quarterly review even for a lab

The GitHub Actions apply workflow's federated identity (ADR-008) must be a member of (or
be the subject of) the PIM-eligible assignment to benefit from this pattern.

> **Note**: PIM for service principals / workload identities (not just human users) is
> available in Entra ID P2. Verify your licence tier before implementation.

## Rationale

- **No standing Contributor access**: without PIM, the service principal would hold
  Contributor permanently — a broad standing grant that could be exploited if the federated
  credential's trust relationship were ever misconfigured.
- **Audit trail**: every PIM activation is logged in Entra audit logs with justification,
  duration, and actor.
- **Blast-radius control**: if the GitHub Actions OIDC trust were somehow exploited (e.g.
  a wildcard subject misconfiguration — prevented by ADR-008, but defence-in-depth matters),
  PIM means the elevated role is not available without an explicit activation.
- **Habit formation**: this lab exists to demonstrate enterprise patterns. PIM is the
  enterprise standard for elevated access; demonstrating it in the lab makes the promotion
  path credible.

## ⚠️ RISK: Lab self-activation

Single-maintainer lab: `gitIgorrz` activates their own PIM eligibility. Same self-approval
risk as ADR-013. Accepted for lab; document clearly.

## Manual setup steps

See `scripts/manual-pim-setup.sh` for exact portal and CLI steps, including:
1. Create Entra group `grp-mcp-demo-tf-apply`
2. Assign PIM-eligible `Contributor` at `rg-mcp-demo-lab` scope to the group
3. Add the service principal / managed identity to the group
4. Configure activation policy (max duration, justification required)
5. Verify activation works before first apply

## Consequences

- The HCP apply run requires the deploy identity (HCP TF SP) to hold Contributor — activated
  via PIM (or the standing fallback grant) before the apply is approved in HCP.
- In VCS-driven mode the human approves the apply in HCP after activating PIM (where P2 exists).
- PIM requires Entra ID P2 licence (or Microsoft Entra ID Governance).
- For the lab, if PIM licencing is unavailable, document as a known gap and use permanent
  Contributor as a fallback with compensating controls (short-lived federated credential
  scoping, audit logging).

## Enterprise target

Multi-approver PIM with mandatory justification, approval from a separate team, access
reviews every 90 days, integration with PAM tooling. PIM for both human operators and
workload identities. Separation of duties enforced at both GitHub (ADR-013) and Azure (PIM)
layers simultaneously.
