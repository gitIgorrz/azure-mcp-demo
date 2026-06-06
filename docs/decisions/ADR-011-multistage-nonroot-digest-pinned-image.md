# ADR-011: Multi-stage, non-root, digest-pinned container image

**Date:** 2026-06-04
**Status:** Accepted

## Context

The MCP server is packaged as a container image. Container image security and supply-chain
hygiene choices include: base image selection, build stages, user permissions, and image
reference pinning.

## Decision

- **Multi-stage build**: separate `builder` stage (installs deps) from `runtime` stage (minimal image).
- **Non-root user**: the server process runs as a non-root, non-privileged user (UID 1000).
- **Digest-pinned base image**: base image referenced by SHA digest, not by tag.
- **Lab base image**: `python:3.12-slim` (pinned by digest)
- **Image pushed to GHCR and referenced by digest** in the Terraform / Container App config.

## Rationale

**Multi-stage**: the `builder` stage installs pip dependencies (including build tools). The
`runtime` stage copies only the installed packages and application code — no build tools,
no pip cache, smaller attack surface, smaller image.

**Non-root**: running as root in a container is a well-known security risk. If the process
is compromised, root in the container maps to elevated capabilities on the host. Non-root
is a baseline container security requirement.

**Digest pinning**: tags are mutable — `python:3.12-slim` today may point to a different
image layer tomorrow. Digest pins (`python:3.12-slim@sha256:...`) ensure the exact image
used in CI is reproducible and tamper-evident. Mutable tag references are a supply-chain
risk (tag poisoning).

**`python:3.12-slim`**: appropriate for a lab — small, official, widely scanned. Not
distroless, but acceptable given the lab scope.

## Consequences

- The base image digest in the Dockerfile must be updated when the base image is refreshed.
  This is intentional — it forces a deliberate, reviewed update rather than silent drift.
- `trivy` in CI scans the image for CVEs and will catch any base-image vulnerabilities.
- The GHCR image digest is pinned in the Terraform `azurerm_container_app` resource so
  deployments are reproducible.

## Enterprise target

Azure Linux (CBL-Mariner) distroless base image from MCR
(`mcr.microsoft.com/azurelinux/distroless/python:3.12`). Distroless eliminates the shell,
package manager, and most OS utilities — significantly smaller attack surface. Image signing
via Notary v2 / cosign, verified at Container App pull time via ACR (ADR-002 enterprise target).
