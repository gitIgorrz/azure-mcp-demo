# Runbook — azure-mcp-demo

End-to-end operator guide: bootstrap, deploy, operate, and destroy the `lab` environment.

> **Target audience:** `gitIgorrz` (the operator). Assumes an existing Azure subscription,
> GitHub account, and HCP Terraform account.
> **Model note:** security-critical steps (identity setup, PIM) should be reviewed with
> an Opus session before execution. See `CLAUDE.md § Model strategy`.

---

## Prerequisites

### Required tools

| Tool | Minimum version | Check |
|------|----------------|-------|
| Python | 3.12 | `python --version` |
| Terraform | 1.9 | `terraform version` |
| Azure CLI | 2.60 | `az version` |
| GitHub CLI | 2.40 | `gh --version` |
| Docker Desktop | latest | `docker version` |
| `ruff` | latest | `ruff --version` |
| `pre-commit` | latest | `pre-commit --version` |
| GPG | 2.2 | `gpg --version` |
| `git` | 2.34 | `git --version` |

Install pre-commit hooks once after cloning:
```bash
pre-commit install
```

### Azure permissions needed (for setup scripts)

- **Application Administrator** — to create app registrations and federated credentials.
- **User Access Administrator / Owner at the target RG scope** — for role assignments
  and PIM-eligible assignments.
- **Privileged Role Administrator** + **Entra ID P2** licence — for PIM
  (`manual-pim-setup.sh`, `PIM_MODE=pim`). **The lab tenant has no P2** (verified 2026-06-05),
  so the script defaults to `PIM_MODE=fallback` (permanent Contributor @ RG with compensating
  controls, ADR-014) — only Owner/UAA at the RG scope is needed for that path.

### Required accounts

- Azure subscription (any; pay-as-you-go or MSDN works for lab).
- GitHub account: `gitIgorrz`.
- HCP Terraform account with org `gitIgorrz` and project `igor-lab` created.

---

## Phase A — identity fabric (once, before first deploy)

Run the setup scripts in order. Each is in `scripts/` and is designed to be read before
running. Never run them unattended.

```
scripts/
  manual-gpg-setup.sh                 # 1. GPG signing
  manual-server-app-registration.sh   # 2. resource/audience app reg -> MCP_AUDIENCE
  manual-hcp-workspace-setup.sh       # 3. HCP TF identity (DPC) + workspace + variable set
  # --- first HCP apply creates the RG + UAMI before the next two ---
  manual-uami-rbac.sh                 # 4. Reader @ RG (needs the RG to exist)
  manual-pim-setup.sh                 # 5. Contributor @ RG for the HCP TF identity (PIM/fallback)
```

There is **no GitHub→Azure CI identity**: this is the VCS-driven model (ADR-007), so HCP runs
Terraform and authenticates to Azure via DPC. Steps 1–3 have no resource-group dependency. Steps
4–5 reference the RG scope, so run them **after** the first HCP apply creates it.
`manual-pim-setup.sh` defaults to the **permanent-Contributor fallback** because this tenant has
no Entra ID P2 (set `PIM_MODE=pim` where P2 exists). Full instructions:
[`scripts/README.md`](../scripts/README.md).

After each script:
1. Confirm the verification block at the bottom passed.
2. Record produced client IDs / object IDs in your password manager (not the repo).

---

## Phase B — GitHub repo setup

Create the repository and configure it before pushing code:

```bash
# Create the repo (once)
gh repo create gitIgorrz/azure-mcp-demo \
  --public \
  --description "Secretless MCP server on Azure Container Apps"

# Push local code (from the project root)
git remote add origin https://github.com/gitIgorrz/azure-mcp-demo.git
git push -u origin main
```

### Branch protection and Actions config

Follow [`docs/branch-protection.md`](branch-protection.md):
1. Protect `main` — require PR review, signed commits, status checks.
2. Add the one Actions **secret**: `HCP_TF_TOKEN` (app.terraform.io → User Settings → Tokens).
   **No `AZURE_*` variables** — CI never authenticates to Azure (HCP does, via DPC).
3. The apply gate is **HCP** (workspace auto-apply = off), not a GitHub Environment — see Phase C.

---

## Phase C — connect HCP + configure the workspace

In HCP (workspace `azure-mcp-demo`):

1. **Settings → Version Control** → connect to GitHub `gitIgorrz/azure-mcp-demo`,
   **Terraform Working Directory = `terraform/`**, **Auto-apply = off** (the apply gate, ADR-013).
2. **Variables (Terraform category):** `subscription_id`, `mcp_tenant_id`, `mcp_audience`,
   `budget_notification_email`, `budget_start_date` — see `terraform/terraform.tfvars.example`.
   Leave `container_image` unset; `build-push` sets it (Phase D).
3. **Variables (env category):** the DPC vars printed by `manual-hcp-workspace-setup.sh`
   (`TFC_AZURE_PROVIDER_AUTH`, `TFC_AZURE_RUN_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`).

**Contributor for the deploy identity.** The HCP TF SP needs Contributor (`manual-pim-setup.sh`,
step 5). The RG is created by the first apply, so for that **first** run grant Contributor at
**subscription** scope (or pre-create `rg-mcp-demo-lab`); later runs use the RG-scoped grant.

**UAMI Reader** (`manual-uami-rbac.sh`) is run **after** the first apply creates the RG + UAMI.
Until then the app's `/health` passes but its Azure tools return 403. Each HCP run plans and
**waits for your apply approval**. The first apply happens via Phase D (the image must exist first).

---

## Phase D — first deploy

On a push to `main` touching `app/**`, `Dockerfile`, or `pyproject.toml`, **build-push**:

1. builds + pushes the image to GHCR,
2. sets the workspace `container_image` variable to the new digest (HCP API),
3. queues an HCP run.

You then **approve the apply in HCP** (the run link is in the workflow run summary). Trigger a
build manually with:
```bash
gh workflow run build-push.yml --ref main
```

### Watch + smoke-test

```bash
gh run watch                       # follow the build-push run; it prints the HCP run link
# after you approve the apply in HCP and it finishes:
gh workflow run smoke-test.yml     # GETs /health (reads the URL from HCP state outputs)
```

### Verify the server is up

```bash
# Get the FQDN from TF output
terraform -chdir=terraform output container_app_fqdn

# Health check
curl -s https://<fqdn>/health
# Expected: {"status": "ok", ...}
```

---

## Phase E — connect a client

See [`docs/connecting-agents.md`](connecting-agents.md) for full instructions.

Quick test with the Azure CLI:
```bash
# Acquire a token (replace <audience> with your configured MCP_AUDIENCE value)
TOKEN=$(az account get-access-token --resource <audience> --query accessToken --output tsv)

# Call the health tool via MCP initialize
curl -s -X POST "https://<fqdn>/mcp" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"runbook-test","version":"0"}}}'
```

---

## Day-to-day operations

### Local development

```bash
# Install deps (run once; re-run after requirements.txt changes)
python -m venv .venv
.venv\Scripts\python -m pip install -r app/requirements.txt -r requirements-dev.txt

# Authenticate (for DefaultAzureCredential)
az login

# Run locally (stdio transport — no auth enforced)
.venv\Scripts\python -m app.server --transport stdio
```

### Run tests

```bash
.venv\Scripts\python -m pytest
```

### Format and lint

```bash
ruff format app/ tests/
ruff check app/ tests/
terraform fmt terraform/
```

### View logs

```bash
# Recent container logs (requires az login)
az containerapp logs show \
  --name ca-mcp-demo-lab \
  --resource-group rg-mcp-demo-lab \
  --follow
```

### Update the container image

1. Push a commit that touches `app/` or `Dockerfile`.
2. CI builds, pushes to GHCR, triggers `tf-apply` with the new image digest.
3. `smoke-test` verifies the new deployment.

### Updating Terraform

1. Change files under `terraform/`.
2. Open a PR — HCP posts a **speculative plan** as a PR status check; `tf-validate` runs
   `validate` + `checkov`.
3. Merge to `main` → HCP queues a run; **approve the apply in HCP**.

---

## Decommission / teardown

See [`docs/cost.md § Decommission`](cost.md#decommission) for the high-level checklist.
Teardown scripts: [`scripts/teardown/README.md`](../scripts/teardown/README.md).

Summary of order:
1. Disable CI workflows (`gh workflow disable`).
2. Terraform destroy (queue a destroy run in HCP and approve it).
3. `scripts/teardown/manual-teardown-identities.sh` — remove the HCP TF + audience app regs,
   PIM group.
4. Delete or archive the GitHub repo.
5. Delete the HCP workspace in the UI.

---

## Checklist summary

- [ ] All prerequisite tools installed
- [ ] GPG key configured and verified in GitHub
- [ ] `az login` authenticated as the operator account
- [ ] Setup scripts 1–3 run and verified (gpg, server-app-reg, hcp-workspace)
- [ ] GitHub repo created; branch protection configured; `HCP_TF_TOKEN` secret set
- [ ] HCP workspace connected to VCS; Terraform + DPC variables set; auto-apply off
- [ ] First HCP apply approved (RG + UAMI + LAW + CAE + Container App + budget)
- [ ] UAMI Reader role assignment created (`manual-uami-rbac.sh`, step 4)
- [ ] HCP TF SP added to PIM/Contributor group (`manual-pim-setup.sh`, step 5)
- [ ] `/health` returns `{"status": "ok"}`
- [ ] At least one MCP client connected and tools tested
