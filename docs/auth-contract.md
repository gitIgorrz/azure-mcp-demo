# Auth contract — connecting to the MCP server

> Canonical contract for the inbound authentication boundary. Per-client walkthroughs
> (SRE Agent, Claude Code, VS Code, custom) are added in Phase 7 `docs/connecting-agents.md`,
> which references this document. Design basis: [ADR-006](decisions/ADR-006-server-side-jwt-validation.md),
> [ADR-005](decisions/ADR-005-secretless-auth-end-to-end.md). Implementation: [`app/auth/`](../app/auth/).

## Summary

The MCP server is on public HTTPS (ADR-003), so **the Entra JWT is the primary access
control**. Every request to the HTTP (Streamable-HTTP) endpoint must carry a valid
Entra-issued **v2.0** bearer token. The server validates it **before any tool runs** and
fails closed. There are no API keys and no shared secrets (ADR-005).

```
Agent / client ──(Entra v2.0 JWT, Bearer)──▶ EntraAuthMiddleware ──▶ MCP tools
                                              │ reject (401/503) if invalid
```

## What the caller must send

```
Authorization: Bearer <entra-v2-access-token>
```

The token must be an **access token** acquired for **this server's audience** — not an ID
token, and not a token for Microsoft Graph or any other resource. Typical acquisition:

- Request scope `api://<server-app-id>/.default` (or the configured audience) from
  `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`.
- Any Entra principal works: a managed identity (SRE Agent connector), a user (Claude Code /
  VS Code interactive sign-in), or an app registration (custom agent) — as long as the token's
  `aud`, `iss`, and `tid` match the contract below.

## What the server validates

| Check | Requirement | On failure |
|-------|-------------|-----------|
| Signature | RS256 only, against the tenant JWKS. `alg: none` and HS256 are rejected. | 401 `invalid_token` |
| `iss` | exactly `https://login.microsoftonline.com/<tenant-id>/v2.0` (v1.0 issuer rejected) | 401 `invalid_token` |
| `aud` | one of the server's configured audience value(s) | 401 `invalid_token` |
| `exp` / `nbf` | not expired / not before (≤ configured leeway for clock skew) | 401 `invalid_token` |
| `tid` | equals the server's configured tenant (blocks cross-tenant replay) | 401 `invalid_token` |
| `sub`, `oid` | present | 401 `invalid_token` |
| `ver` | `2.0` if present | 401 `invalid_token` |
| `azp`/`appid` | in the allow-list **if one is configured** (off by default) | 401 `invalid_token` |

> **AuthN, not AuthZ.** A valid token proves *who* the caller is. The tool set is read-only
> (ADR-004), so there is no per-tool authorisation today. If a write tool is ever added,
> per-caller authorisation (checking `oid`/`roles`/`groups` against an allow-list) is a
> **separate, mandatory** control — see ADR-006.

## Responses

- **200** — token valid; verified claims are attached as `request.state.auth` for the tools.
- **401 Unauthorized** — missing/invalid/expired token. Body:
  `{"error": "...", "error_description": "..."}`; header
  `WWW-Authenticate: Bearer error="...", error_description="..."`.
- **503 Service Unavailable** — the JWKS endpoint was temporarily unreachable, so the token
  could not be validated. Fail-closed; **retry** (the token is not necessarily bad).

Error descriptions are intentionally generic and never echo the token. Validation failures
are logged server-side at WARNING with the reason and request context only — never the token.

## Server configuration (operator)

All configuration is via environment variables — no identifiers are hardcoded (ADR-006).

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `MCP_TENANT_ID` | yes | — | Entra tenant GUID; pins `iss`, `tid`, and the JWKS URL |
| `MCP_AUDIENCE` | yes | — | expected `aud`; comma-separated to accept more than one form (e.g. `api://<guid>,<guid>`) |
| `MCP_ALLOWED_APP_IDS` | no | *(empty)* | comma-separated allow-list of caller `azp`/`appid` GUIDs (defence in depth) |
| `MCP_JWKS_CACHE_TTL_SECONDS` | no | `3600` | JWKS key cache TTL (min 60) |
| `MCP_JWT_LEEWAY_SECONDS` | no | `60` | clock-skew leeway for `exp`/`nbf` (max 300) |

The JWKS keys are cached for the TTL above to avoid a network fetch per request; Entra key
rollover is picked up automatically on cache refresh / `kid` miss.

## Local development

The stdio transport (ADR-010) is for local dev only and does **not** apply this middleware —
it has no network boundary to authenticate. It must never be exposed remotely. The remote
Streamable-HTTP transport always enforces the contract above.
