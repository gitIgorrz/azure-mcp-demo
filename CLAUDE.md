# CLAUDE.md — azure-mcp-demo

Source of truth for all AI-assisted work in this repository. Read this before starting any task.
Update it whenever an architectural or process decision changes.

---

## Purpose

A secretless, governed, enterprise-grade-but-lab-scale **MCP (Model Context Protocol) server**
on Azure, demonstrating an enabling/platform offering for AI agents. The server exposes
**read-only** Azure inventory tools; agents consume it over Streamable-HTTP with Entra-issued
tokens. Zero standing secrets end-to-end.

See [docs/background/architecture-intent.md](docs/background/architecture-intent.md) for the
enterprise vision. This lab is a deliberate, cost-conscious **subset** of that vision.

---

## Repo structure

```
azure-mcp-demo/
├── CLAUDE.md                     ← you are here
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODEOWNERS
├── .gitignore
├── .claudeignore
├── .github/
│   ├── pull_request_template.md
│   └── workflows/                ← CI/CD pipelines
├── app/                          ← MCP server (Python)
├── terraform/                    ← IaC (Azure resources)
├── docs/
│   ├── background/               ← architecture-intent.md + raw pitch (claudeignored)
│   ├── decisions/                ← ADRs (ADR-NNN-*.md)
│   ├── PROGRESS.md               ← session handoff file
│   └── ...                       ← additional docs (cost.md, connecting-agents.md, etc.)
├── scripts/                      ← RUN-MANUALLY scripts (never auto-executed)
└── tests/                        ← unit + integration tests
```

---

## Architecture summary

- **Hosting**: Azure Container Apps (scale-to-zero, native UAMI, VNet-integrable)
- **Registry**: GHCR (`ghcr.io/gitigorrz/azure-mcp-demo`), image pinned by digest
- **Identity**: User-Assigned Managed Identity → Reader at resource-group scope
- **Auth (inbound)**: Entra JWT validation (issuer / audience / expiry / claims)
- **Auth (CI)**: GitHub OIDC → Azure federated credential, tightly scoped per-repo + per-branch/env
- **Auth (IaC)**: HCP Dynamic Provider Credentials (OIDC) default; SP federated-cred toggle
- **Transport**: Streamable-HTTP (remote/agents); stdio (local dev only)
- **Tools**: health, subscription metadata, resource-group list, resource inventory (Resource Graph)
  — read-only only; **no destructive tools exist in this codebase**
- **Infra**: Resource Group, UAMI, Container App Environment + Container App, Log Analytics
  (minimum retention), diagnostics, role assignment, Azure Budget + cost alert

Full lab-vs-enterprise delta: [docs/background/architecture-intent.md](docs/background/architecture-intent.md)

---

## Naming & tagging conventions

### Resource naming

| Resource | Pattern | Example |
|----------|---------|---------|
| Resource Group | `rg-mcp-demo-{env}` | `rg-mcp-demo-lab` |
| User-Assigned MI | `id-mcp-demo-{env}` | `id-mcp-demo-lab` |
| Container App Env | `cae-mcp-demo-{env}` | `cae-mcp-demo-lab` |
| Container App | `ca-mcp-demo-{env}` | `ca-mcp-demo-lab` |
| Log Analytics WS | `law-mcp-demo-{env}` | `law-mcp-demo-lab` |
| Budget | `budget-mcp-demo-{env}` | `budget-mcp-demo-lab` |

`{env}` values: `lab`, `int`, `prod`

### Required tags (on all resources)

```hcl
tags = {
  environment  = var.environment          # lab | int | prod
  project      = "azure-mcp-demo"
  managed-by   = "terraform"
  repo         = "gitIgorrz/azure-mcp-demo"
  cost-centre  = "lab"
}
```

### Branch naming

`feat/`, `fix/`, `docs/`, `chore/`, `refactor/` — e.g. `feat/mcp-resource-graph-tool`

### HCP Terraform

- Org: `gitIgorrz` | Project: `igor-lab` | Workspace: `azure-mcp-demo`
- Environment directory: `terraform/` (single env for lab)

---

## Coding standards

### Python (`app/`)
- Formatter + linter: **ruff** (`ruff format` + `ruff check`)
- Type hints on all public functions
- `DefaultAzureCredential` for all Azure auth — never hardcode credentials
- Streamable-HTTP transport for remote; stdio for local dev only
- Validate Entra JWT (iss/aud/exp/claims) before any tool execution

### Terraform (`terraform/`)
- `terraform fmt` before every commit
- `tflint` with azurerm plugin
- `checkov` for security scanning
- Pin `required_version` and all provider versions (exact or `~>` minor)
- All resources must carry the standard tag block
- `terraform.lock.hcl` **is committed** (reproducible runs)

### GitHub Actions workflows
- Every action pinned to a **commit SHA + version comment**, e.g.:
  ```yaml
  uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
  ```
- Minimal OIDC token permissions per workflow; no `permissions: write-all`

### General
- Conventional commits: `type(scope): message`
- GPG-signed commits required (see CONTRIBUTING.md)
- YAML: 2-space indent; lint with `yamllint`
- Markdown: lint with `markdownlint`

---

## Security guardrails (non-negotiable)

1. **No committed secrets** — no passwords, client secrets, tokens, connection strings, API keys.
   Use GitHub Secrets, HCP workspace variables (sensitive), or environment references.
2. **No long-lived credentials** — OIDC / federated credentials / managed identity only.
3. **No destructive MCP tools** — no tool that mutates Azure state may exist in `app/`.
   Read-only tools only; this is enforced by code review.
4. **Entra JWT validation is mandatory** — validate `iss`, `aud`, `exp`, and required claims
   before executing any tool. See `app/` auth module.
5. **Least privilege** — UAMI gets Reader at resource-group scope. No broader grants without
   a documented justification in an ADR.
6. **HTTPS only** — Container App ingress enforces HTTPS; no HTTP allowed.
7. **Non-root container** — Dockerfile must run as a non-root user.
8. **Image pinned by digest** — not by tag.
9. **`gitleaks` runs in CI and pre-commit** — any secret detection failure blocks the build.
10. **No wildcard federated credential subjects** — always `repo:gitIgorrz/azure-mcp-demo:ref:…`
    scoped to a specific branch or environment.

---

## Model strategy

> Follow this every session. Switching is cheap; getting security wrong is not.

| Task class | Model | Why |
|-----------|-------|-----|
| Design pass, architecture decisions | **Opus** | Get-it-right-once |
| Identity/auth: OIDC, federated creds, subject scoping, RBAC, PIM | **Opus** | Security-critical |
| MCP server token-validation logic | **Opus** | Security-critical |
| Security review (final gate before "done") | **Opus** | Security-critical |
| Scaffolding, boilerplate, docs, Dockerfile, read-only tools, workflows, tests | **Sonnet** | Fast + cheap for mechanical work |

If a Sonnet session encounters security-critical logic (auth, identity, RBAC), **stop and
instruct a switch to Opus** before proceeding. Never silently continue on the wrong model.

---

## Destructive-command rules

**NEVER run automatically (session-wide):**
- `terraform apply` / `terraform destroy`
- `az role assignment create/delete`, `az ad app credential reset`
- GitHub branch-protection changes
- HCP workspace creation/deletion
- GPG key generation
- Any `az`, `gh`, or `terraform` command that mutates cloud, identity, or repo state

**DO:** emit these as commented scripts under `scripts/` marked `# RUN MANUALLY`, each with:
- Why it's manual
- Who runs it and what permission is needed
- Exact command or portal steps
- How to verify success

**MAY run automatically:** `terraform fmt`, `terraform validate`, `tflint`, `checkov`, `trivy`,
`gitleaks`, `ruff`, linters, unit tests, file scaffolding — all read-only or local-only.

---

## Token / cost discipline

- **Before each session:** verify `$env:ANTHROPIC_API_KEY` is empty (PowerShell).
  If set, Claude Code bills API rates not subscription. Unset: `$env:ANTHROPIC_API_KEY = $null`
- **Track usage:** `/usage` (aliases `/cost`, `/stats`); `/context` to see current window size.
  History/live burn: `npx ccusage@latest`; Claude-Code-Usage-Monitor. Note: on subscription,
  `$` figures are API-equivalent estimates; real consumption in Settings > Usage.
- **Keep context small:** `/clear` between phases; resume via `docs/PROGRESS.md`.
- **CHECKPOINT** at end of each phase: update PROGRESS.md, state next phase's model, offer
  `/clear` + resume.
- **`.claudeignore`** excludes `.terraform/`, `__pycache__/`, build artifacts, the raw pitch file.
- Do not re-read files already in context. Batch edits. Prefer targeted reads over whole-tree scans.

---

## Key document pointers

| Document | Purpose |
|----------|---------|
| [docs/background/architecture-intent.md](docs/background/architecture-intent.md) | Enterprise vision distillation |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records (ADR-001 … ADR-014) |
| [docs/auth-contract.md](docs/auth-contract.md) | Inbound Entra JWT auth contract (ADR-006); `app/auth/` |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Session handoff — current phase, next step, open questions |
| [docs/cost.md](docs/cost.md) | Cost guide, expected drivers, decommission (Phase 7) |
| [docs/connecting-agents.md](docs/connecting-agents.md) | How to connect MCP clients (Phase 7) |
| [scripts/](scripts/) | All RUN-MANUALLY scripts with instructions |
