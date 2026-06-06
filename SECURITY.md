# Security

## Security model

This project is designed with a **zero-standing-secrets** security posture end-to-end.

### Authentication & identity

| Path | Mechanism | Notes |
|------|-----------|-------|
| GitHub Actions → Azure | GitHub OIDC → Azure federated credential | Subject scoped per-repo + per-branch/environment (never wildcard) |
| HCP Terraform → Azure | HCP Dynamic Provider Credentials (OIDC) | Default; SP federated-cred toggle documented as alternative |
| MCP server → Azure resources | User-Assigned Managed Identity (UAMI) | Reader at resource-group scope; short-lived tokens issued by Azure |
| MCP client → MCP server | Entra-issued JWT | Server validates issuer, audience, expiry, and required claims |

No client secrets, no API keys, no long-lived tokens anywhere in the chain.

### MCP server guardrails

- **Read-only tools only.** The server exposes: `health`, `get_subscription`,
  `list_resource_groups`, `list_resources`. No write, delete, or action operations exist
  anywhere in the codebase.
- **JWT validation is mandatory** before any tool executes: `iss`, `aud`, `exp`, and required
  claims are checked. Unauthenticated or invalid requests are rejected with HTTP 401.
- **HTTPS only.** Container App ingress enforces HTTPS; HTTP is not accepted.
- **Non-root container.** The server process runs as a non-root user.
- **Image pinned by digest.** Container image references use SHA digest, not mutable tags.

### Infrastructure guardrails

- Least-privilege RBAC: UAMI gets built-in `Reader` at resource-group scope only.
- All changes go through Terraform; no manual az-CLI mutations to managed resources.
- `gitleaks` runs in CI on every PR and in the pre-commit hook.
- `checkov` and `trivy` scan IaC and container images in CI.
- `terraform plan` is reviewed in PR before any `apply`.

### Lab limitations (known, accepted)

| Limitation | Lab posture | Enterprise target |
|-----------|-------------|-------------------|
| Public HTTPS ingress | Accepted for lab | Front Door / App Gateway + WAF, IP allow-listing |
| No WAF | Accepted for lab | WAF in front of Container App |
| Log Analytics public endpoint | Accepted for lab | AMPLS private monitoring |
| Single maintainer self-approves PRs | RISK (see ADR-013) | Separate reviewer required |
| PIM not enforced in lab | Manual guidance provided | Entra PIM group with activation workflow |

---

## Reporting a vulnerability

This is a personal lab repository. If you find a security issue:

1. **Do not open a public GitHub issue.**
2. Email: `igor_111@hotmail.com` with subject `[SECURITY] azure-mcp-demo — <brief description>`.
3. Include: description, reproduction steps, potential impact.
4. Allow up to 14 days for an initial response.

If you discover a **committed secret or credential**, please report it immediately — that is
the highest-priority finding.

---

## Dependency scanning

- Container images: scanned with `trivy` in CI.
- Python dependencies: `pip-audit` / `trivy` *(wired in Phase 6)*.
- IaC: `checkov` in CI.
- Secrets: `gitleaks` in CI and pre-commit.

---

## GPG commit signing

All commits to `main` are GPG-signed. The "Verified" badge on GitHub confirms the signing
key matches the key registered in the author's GitHub account. See [CONTRIBUTING.md](CONTRIBUTING.md).
