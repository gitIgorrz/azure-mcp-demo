# scripts/teardown/ — RUN-MANUALLY decommission scripts

> **These scripts are never executed automatically.** They mutate cloud and identity state.
> Read each script before running. Run in the order below.
> Per `CLAUDE.md § Destructive-command rules` and memory: always use `terraform destroy`
> for TF-managed resources — never ad-hoc `az resource delete`.

---

## Teardown order

Run **after** confirming with `docs/cost.md § Decommission`.

| # | Step | Script / Action | What it removes |
|---|------|----------------|-----------------|
| 1 | Disable CI | `gh workflow disable` (see below) | Prevents new deploys during teardown |
| 2 | Terraform destroy | HCP TF destroy plan (portal) | RG + all resources inside it (UAMI, LAW, CAE, CA, budget, diagnostics) |
| 3 | Identity cleanup | [`manual-teardown-identities.sh`](manual-teardown-identities.sh) | CI app reg + fed creds, PIM group + role, HCP workspace |
| 4 | GitHub cleanup | `gh repo delete` / archive | Actions environment, secrets/variables, repo |
| 5 | HCP workspace delete | HCP TF portal | Workspace (must have no managed resources after step 2) |

---

## Step 1 — disable CI

```bash
gh workflow disable build-push.yml
gh workflow disable tf-apply.yml
gh workflow disable smoke-test.yml
```

---

## Step 2 — Terraform destroy (REQUIRED FIRST)

The Terraform state owns the Azure resources. Always destroy through HCP TF, not with
raw `az` commands, to keep state consistent.

### Option A — HCP TF portal (recommended)

1. Open `app.terraform.io` → org `gitIgorrz` → workspace `az-mcp-demo`.
2. **Settings → Destruction and Deletion → Queue destroy plan**.
3. Review: confirm the plan lists only `rg-mcp-demo-lab` and its child resources.
4. Type the workspace name to confirm, then **Apply destroy plan**.
5. Wait for completion; all resources show as destroyed.

### Option B — local Terraform (fallback)

If you cannot access HCP TF UI, override to local state and run destroy:
```bash
# WARNING: this migrates state locally. Only if HCP TF is unavailable.
cd terraform
terraform init -migrate-state   # follow prompts to copy state locally
terraform destroy               # review plan, type 'yes' to confirm
```

### What gets destroyed

- `azurerm_resource_group.rg` (`rg-mcp-demo-lab`) — and everything inside it:
  - `azurerm_user_assigned_identity.uami` (`id-mcp-demo-lab`)
    - Reader role assignment at RG scope (auto-removed when UAMI is deleted)
  - `azurerm_log_analytics_workspace.law` (`law-mcp-demo-lab`)
  - `azurerm_container_app_environment.cae` (`cae-mcp-demo-lab`)
  - `azurerm_container_app.ca` (`ca-mcp-demo-lab`)
  - `azurerm_monitor_diagnostic_setting` ×2
  - `azurerm_consumption_budget_resource_group.budget`

### What is NOT destroyed by Terraform

These were created by the Phase 2 setup scripts and require manual removal (step 3):
- CI Entra app registration + 3 federated credentials
- PIM group `grp-mcp-demo-tf-apply` + PIM-eligible role assignment
- HCP Terraform workspace `az-mcp-demo` and its variable sets

---

## Step 3 — identity cleanup

```bash
bash scripts/teardown/manual-teardown-identities.sh
```

See the script for details. Run after step 2 completes.

---

## Step 4 — GitHub repo cleanup

```bash
# Delete permanently
gh repo delete gitIgorrz/azure-mcp-demo --yes

# OR archive (keep code, disable pushes/issues/CI)
gh repo archive gitIgorrz/azure-mcp-demo
```

---

## Step 5 — delete HCP workspace

After the Terraform destroy (step 2) has cleared all managed resources:
1. `app.terraform.io` → workspace `az-mcp-demo` → **Settings → Destruction and Deletion**.
2. **Delete from HCP Terraform** → confirm by typing workspace name.

---

## Verify teardown is complete

```bash
# Verify no Azure resources remain
az resource list --resource-group rg-mcp-demo-lab 2>&1
# Expected: "ResourceGroupNotFound" error

# Verify CI app reg is gone
az ad app list --display-name "sp-mcp-demo-ci-lab" 2>&1
# Expected: empty list []

# Verify PIM group is gone
az ad group list --display-name "grp-mcp-demo-tf-apply" 2>&1
# Expected: empty list []
```
