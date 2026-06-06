# ADR-006: Server-side Entra JWT validation

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server is reachable over public HTTPS (ADR-003). Without authentication, any caller
can invoke tools. Options: no auth (unacceptable), API key/bearer token (violates ADR-005),
Entra JWT validation.

## Decision

The MCP server validates **Entra-issued JWTs** on every inbound request before any tool
executes. The server is responsible for validating:

- `iss` (issuer): must be `https://login.microsoftonline.com/{tenant_id}/v2.0`
- `aud` (audience): must match the server's configured audience (the app registration / UAMI client ID)
- `exp` (expiry): token must not be expired
- Required claims: `sub`, `oid` (object ID), `tid` (tenant ID) present and matching expected tenant

Requests that fail validation receive HTTP 401 before any tool logic runs.

## Rationale

- Public ingress (ADR-003) means JWT validation is the **primary access control**. Without it,
  the server is open to any caller.
- Entra JWTs are short-lived (typically 1 hour), cryptographically signed, and validated
  against Microsoft's JWKS endpoint — no shared secret required.
- This approach is **auth provider-agnostic at the protocol level**: any caller that can
  obtain an Entra token for the correct audience can connect, regardless of which agent or
  client they use (SRE Agent, Claude Code, VS Code, custom agent).
- Validating `aud` prevents token confusion attacks (a token issued for one Azure resource
  cannot be replayed against this server).
- Validating `tid` (tenant ID) prevents cross-tenant token replay.

## Security note (authentication vs authorisation)

> Validating a token proves *who the caller is*. It does not automatically determine *what
> they may do*. This server's tool set is read-only (ADR-004), so per-tool authorisation
> is not needed at this stage. If write tools are ever added, per-tool/per-caller authorisation
> (checking `oid`, `roles`, or `groups` claims against an allow-list) must be implemented —
> it is **not** the same as authentication and must be a separate control.

## Implementation notes (for Phase 3 — Opus)

- Use a well-maintained JWT validation library (e.g. `python-jose` or `msal`) against the
  Microsoft JWKS endpoint; do not hand-roll JWT verification.
- Cache the JWKS public keys with an appropriate TTL to avoid per-request key fetches.
- Configuration (tenant ID, audience) must come from environment variables, not hardcoded.
- Log validation failures at WARN level (without echoing the token value).

## Enterprise target

Add Conditional Access policies on the Entra app registration. For the SRE Agent path: use
managed-identity connector auth (currently in preview) rather than generic bearer JWT, once GA.
