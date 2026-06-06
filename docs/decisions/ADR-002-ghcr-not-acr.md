# ADR-002: GHCR instead of Azure Container Registry

**Date:** 2026-06-04
**Status:** Accepted

## Context

A container registry is needed to store the MCP server image. Options: GHCR, ACR (Basic/Standard/Premium).

## Decision

Use **GHCR** (`ghcr.io/gitigorrz/azure-mcp-demo`) as the container registry for the lab.
Push via GitHub Actions OIDC (no registry password).

## Rationale

ACR's main enterprise value is **private-endpoint pull** — keeping image traffic on the
private backbone. That requires ACR Premium (~£40/month). ACR Basic (~£4/month) does not
support private endpoints.

This lab uses **public HTTPS ingress**, so:
- Private-endpoint pull provides no security benefit — the Container App and its pull path
  are already on a public network plane.
- ACR Basic would add standing cost for no additional security posture.
- GHCR is free for public repos and Container Apps can pull public GHCR images without
  registry credentials.

Image supply-chain security (non-root, digest-pinned, multi-stage build) is handled at
build time regardless of registry — see ADR-011.

## Consequences

- No registry cost in the lab.
- Image is publicly visible on GHCR (acceptable for a demo; no sensitive data in the image).
- GitHub Actions push workflow uses OIDC token (`packages: write` permission) — no registry secret.

## Enterprise target

ACR Premium + private endpoint (no public pull) + managed-identity `AcrPull` role assignment
(Container App's UAMI) + image signing (Notary v2 / cosign). Private pull keeps image traffic
on the private backbone and enables the "no public endpoints" posture.
