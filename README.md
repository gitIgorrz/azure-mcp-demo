# azure-mcp-demo

A secretless, governed MCP (Model Context Protocol) server on Azure — demonstrating an
enabling/platform capability for AI agents.

The server exposes **read-only** Azure inventory tools (subscription metadata, resource groups,
resource inventory via Resource Graph). Agents call it over Streamable-HTTP with Entra-issued
tokens. Zero standing secrets end-to-end: GitHub OIDC, HCP Dynamic Provider Credentials,
Azure federated credentials, and a User-Assigned Managed Identity at runtime.

> **Lab build.** This repo is a deliberate, cost-conscious subset of a larger enterprise vision.
> See [docs/background/architecture-intent.md](docs/background/architecture-intent.md) for the
> full picture (VWAN, private endpoints, DNS, cross-env INT routing).

---

## Architecture overview

```
MCP client (SRE Agent / Claude Code / VS Code)
      │  HTTPS + Entra JWT
      ▼
Azure Container App  (scale-to-zero, public HTTPS ingress — lab simplification)
      │  DefaultAzureCredential → UAMI
      ▼
Azure Resource Graph / ARM  (Reader @ resource-group scope)
```

**Key properties:**
- No secrets anywhere — OIDC + federated credentials + managed identity throughout
- Read-only tools only — no destructive operations exist in the codebase
- Agent-agnostic — any spec-compliant MCP client can connect; SRE Agent is one example
- Infrastructure-as-code via Terraform, state in HCP Terraform workspace `az-mcp-demo`

---

## Quick links

| Document | Purpose |
|----------|---------|
| [docs/background/architecture-intent.md](docs/background/architecture-intent.md) | Enterprise vision |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Implementation progress & handoff |
| [docs/cost.md](docs/cost.md) | Cost guide & decommission *(Phase 7)* |
| [docs/connecting-agents.md](docs/connecting-agents.md) | Connect any MCP client *(Phase 7)* |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |
| [SECURITY.md](SECURITY.md) | Security model & reporting |
| [CLAUDE.md](CLAUDE.md) | AI-assistant working instructions |

---

## Prerequisites

| Tool | Purpose | Version |
|------|---------|---------|
| Python | MCP server runtime | 3.12+ |
| Terraform | Infrastructure provisioning | >= 1.9 |
| Azure CLI (`az`) | Local auth + manual scripts | latest |
| GitHub CLI (`gh`) | Repo/environment management | latest |
| Docker | Build container image locally | latest |
| `ruff` | Python linter/formatter | latest |
| `tflint` | Terraform linter | latest |
| `checkov` | IaC security scanner | latest |
| `pre-commit` | Local hook runner | latest |
| GPG | Commit signing | installed + key configured |

---

## Setup (overview — full detail in docs)

> Full step-by-step in `docs/` *(Phase 7)*. This is the sequence of concerns.

1. **Verify billing**: `echo $env:ANTHROPIC_API_KEY` should be empty.
2. **Azure**: create resource group + UAMI manually (see `scripts/`), then Terraform manages the rest.
3. **GitHub**: create repo, configure OIDC federated credential (see `scripts/`), set required secrets (none — secretless).
4. **HCP Terraform**: create workspace `az-mcp-demo` in org `gitIgorrz` / project `igor-lab` (see `scripts/`).
5. **Local dev**: set up Python 3.12 + venv + deps (see [CONTRIBUTING.md → Local development environment](CONTRIBUTING.md#local-development-environment)), then `az login` and run `python -m app.server --transport stdio`.
6. **Deploy**: push to a branch → open PR → CI validates → merge to `main` → Environment gate approval → `terraform apply` + image push.

---

## MCP tools exposed

| Tool | Description | Azure call |
|------|-------------|-----------|
| `health` | Server health + identity info | UAMI metadata |
| `get_subscription` | Current subscription metadata | ARM |
| `list_resource_groups` | All resource groups in scope | ARM |
| `list_resources` | Resource inventory (filterable) | Azure Resource Graph |

All tools are **read-only**. No write, delete, or action operations exist.

---

## Cost profile

Expected lab cost (idle / low-traffic): **< £5/month**.
- Container Apps: scale-to-zero (zero cost at idle)
- GHCR: free
- Log Analytics: minimum retention (31 days)
- Azure Budget alert set at £10/month

See [docs/cost.md](docs/cost.md) for full breakdown and decommission instructions *(Phase 7)*.

---

## Security model

See [SECURITY.md](SECURITY.md) for the full security model, known limitations, and how to
report vulnerabilities. Key points:
- No standing secrets; all auth via OIDC / federated identity / managed identity
- Server validates Entra JWT (issuer, audience, expiry, claims) before any tool runs
- Read-only tools only; no destructive operations
- GPG-signed commits enforced; direct push to `main` blocked

---

## License

MIT — see [LICENSE](LICENSE) *(to be added)*.
