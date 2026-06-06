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
  manual-github-oidc-setup.sh         # 3. CI app registration + federated credentials
  manual-hcp-workspace-setup.sh       # 4. HCP workspace + DPC/OIDC variable set
  # --- first `terraform apply` creates the RG + UAMI before the next two ---
  manual-uami-rbac.sh                 # 5. Reader @ RG (needs the RG to exist)
  manual-pim-setup.sh                 # 6. Contributor @ RG (PIM-eligible, or permanent fallback)
```

Steps 1–4 have no resource-group dependency. Steps 5–6 reference the RG scope, so run them
**after** the first `terraform apply` creates it. `manual-pim-setup.sh` defaults to the
**permanent-Contributor fallback** because this tenant has no Entra ID P2 (set `PIM_MODE=pim`
where P2 exists). Full instructions: [`scripts/README.md`](../scripts/README.md).

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
2. Create GitHub Environment `lab` with manual approval gate.
3. Add Actions **variables** (not secrets — these are non-sensitive IDs):
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
   - `AZURE_CLIENT_ID`
4. Add Actions **secret**:
   - `HCP_TF_TOKEN` (from `app.terraform.io → User settings → Tokens`)

---

## Phase C — Terraform: first apply

The first apply is a two-step process due to the UAMI role assignment needing a
separate User Access Admin permission (see `terraform/main.tf` header comment).

### Step 1 — apply without the Container App

```bash
cd terraform
terraform init    # connects to HCP TF; requires HCP_TOKEN env var or browser auth
terraform plan    # review; should show ~5 resources (RG, UAMI, LAW, CAE, budget)
```

Push to `main` (or trigger via workflow) to run `tf-apply` through the CI pipeline.
The `lab` environment gate pauses for your approval before applying.

### Step 2 — assign UAMI Reader role

After the first apply creates the UAMI, run:
```bash
bash scripts/manual-uami-rbac.sh
```

Verify:
```bash
az role assignment list --assignee <uami-principal-id> --scope <rg-id>
```

### Step 3 — apply again to create the Container App

The Container App `terraform` resources are conditioned on the UAMI existing. Re-run
`tf-apply` (push a commit or trigger `workflow_dispatch`) to complete the deployment.

---

## Phase D — first deploy

CI handles the full build → apply → smoke-test pipeline automatically on pushes to `main`.

Manual trigger if needed:
```bash
# Trigger build + push
gh workflow run build-push.yml --ref main

# After build completes, trigger apply (or wait for workflow_run trigger)
gh workflow run tf-apply.yml --ref main
```

### Watch the pipeline

```bash
# Follow logs live
gh run watch

# Check smoke test result
gh run list --workflow=smoke-test.yml --limit 1
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
2. Open a PR — `tf-plan` posts the plan as a PR comment.
3. Merge to `main` → `tf-apply` runs (requires `lab` environment approval).

---

## Decommission / teardown

See [`docs/cost.md § Decommission`](cost.md#decommission) for the high-level checklist.
Teardown scripts: [`scripts/teardown/README.md`](../scripts/teardown/README.md).

Summary of order:
1. Disable CI workflows (`gh workflow disable`).
2. Terraform destroy (via HCP TF destroy plan).
3. `scripts/teardown/manual-teardown-identities.sh` — remove CI app reg, PIM group, HCP workspace.
4. Delete or archive the GitHub repo.
5. Delete the HCP workspace in the UI.

---

## Checklist summary

- [ ] All prerequisite tools installed
- [ ] GPG key configured and verified in GitHub
- [ ] `az login` authenticated as the operator account
- [ ] Setup scripts 1–5 run and verified
- [ ] GitHub repo created; branch protection configured
- [ ] GitHub Environment `lab` created; Actions variables + `HCP_TF_TOKEN` set
- [ ] First `terraform apply` completed (step 1)
- [ ] UAMI Reader role assignment created (`manual-uami-rbac.sh`)
- [ ] Second `terraform apply` completed (Container App created)
- [ ] `/health` returns `{"status": "ok"}`
- [ ] At least one MCP client connected and tools tested
