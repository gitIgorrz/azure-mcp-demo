# ADR-003: Public HTTPS ingress for the lab

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server must be reachable by MCP clients (SRE Agent, Claude Code, VS Code, custom agents)
over HTTPS. Options for the lab: public ingress, private ingress + Front Door/App Gateway + WAF,
private ingress only.

## Decision

Use **public HTTPS ingress** on the Container App for the lab. The server's URL is publicly
addressable; access control relies on server-side Entra JWT validation (ADR-006).

## Rationale

The enterprise target — private ingress with Front Door/App Gateway + WAF as the governed
public path — requires VWAN, Private DNS zones, and a WAF resource, adding significant cost
and complexity. The pitch explicitly flags this as the right phase-1 simplification:

> "Cheap to prove: Container Apps scale-to-zero, a minimal VWAN hub, one read-only tool."

For a personal PAYG lab:
- WAF (Application Gateway + WAF2) costs ~£150+/month — prohibitive.
- Front Door Standard costs ~£20+/month base — disproportionate for a demo.
- The SRE Agent reachability question (managed-service agent reaching a private endpoint) is
  noted as an **open design question** in the pitch; public ingress sidesteps it for phase 1.

The server-side JWT validation (ADR-006) provides the primary access control. Without a valid
Entra token, no tool executes.

## Consequences

- The server URL is publicly reachable (but not publicly *useful* without a valid Entra token).
- No WAF, no IP allow-listing of agent egress ranges in the lab.
- **RISK**: a determined attacker can probe the HTTP endpoint. Mitigated by: JWT validation,
  read-only tools only, Container Apps rate limiting, no sensitive data-plane access.
- This is the **primary accepted lab limitation**. Document prominently in SECURITY.md and
  architecture docs.

## Enterprise target

Private ingress on the Container App + governed external path via Azure Front Door or
Application Gateway + WAF → private backend. Lock down with Entra auth at the MCP layer,
IP allow-list of agent egress ranges, WAF rules, rate limiting. This is the "reachable but
not open" posture described in the pitch.
