# Cost guide — azure-mcp-demo

Expected monthly spend for the `lab` environment, optimization levers, and decommission instructions.

---

## Cost by resource

| Resource | SKU / tier | Idle cost | Light-traffic cost | Notes |
|----------|-----------|-----------|---------------------|-------|
| Container App | Consumption (0.25 vCPU / 0.5 GiB) | **~$0** | < $1 | Scale-to-zero; pay only per request at run time |
| Container App Environment | Consumption | < $0.50 | < $0.50 | Small fixed workload-profile charge |
| Log Analytics Workspace | Pay-as-you-go, 31-day retention | < $0.50 | < $1 | Diagnostics from CA + CAE; minimal at low volume |
| GHCR image storage | Free | $0 | $0 | Free for public repos; private repos have a free tier |
| Azure Budget | Governance only | $0 | $0 | No charge for the budget resource itself |
| Networking / DNS | Container Apps managed ingress | < $0.50 | < $1 | Egress to ARM / Resource Graph |

**Total expected: < $5 USD/month** at idle-to-low traffic. The budget alert threshold is set
at `$10 USD` (variable `budget_amount_usd` in `terraform/variables.tf`), which gives a
comfortable buffer.

---

## Budget alert

Terraform provisions an `azurerm_consumption_budget_resource_group` with two notifications:
- **80 % of actual spend** — early warning; no action required.
- **100 % of forecast** — investigate if triggered; consider scaling down or destroying.

Email goes to the address in `var.budget_notification_email` (set in the HCP workspace
variable set). Adjust the threshold by updating `budget_amount_usd` and running `terraform apply`.

---

## Optimization levers

| Lever | Impact | How |
|-------|--------|-----|
| Scale-to-zero | Eliminates idle CA cost | Already configured (`min_replicas = 0`) |
| Reduce log retention | Lowers LAW cost | Decrease `retention_in_days` in `terraform/main.tf` (minimum 30) |
| Disable diagnostic settings | Eliminates LAW ingestion entirely | Remove `azurerm_monitor_diagnostic_setting` resources and `terraform apply` |
| Destroy when not needed | Eliminates all cost | See [Decommission](#decommission) below |

---

## Decommission

When the lab is no longer needed, destroy all resources and clean up the identity fabric.

> **Rule:** always destroy via `terraform destroy` (HCP TF destroy plan), never with ad-hoc
> `az resource delete` commands. The Terraform state is the authoritative inventory.

### Step 1 — stop CI pipelines

Disable or delete the GitHub Actions workflows so no new deploys fire during teardown:
```bash
gh workflow disable build-push.yml
gh workflow disable tf-apply.yml
```

### Step 2 — Terraform destroy

Trigger a destroy plan in HCP Terraform:
1. Open `app.terraform.io` → org `gitIgorrz` → workspace `azure-mcp-demo`.
2. Go to **Settings → Destruction and Deletion → Queue destroy plan**.
3. Review the plan output — confirm it targets only `rg-mcp-demo-lab` resources.
4. **Approve** the destroy. Wait for completion.

Resources destroyed:
- Resource group `rg-mcp-demo-lab` (and everything inside it)
- UAMI `id-mcp-demo-lab` + its Reader role assignment (auto-removed when UAMI is deleted)
- Container App `ca-mcp-demo-lab` + Container App Environment `cae-mcp-demo-lab`
- Log Analytics Workspace `law-mcp-demo-lab`
- Budget `budget-mcp-demo-lab`
- Diagnostic settings

### Step 3 — clean up the identity fabric

Run the teardown scripts in reverse setup order. See
[`scripts/teardown/README.md`](../scripts/teardown/README.md).

### Step 4 — delete or archive the GitHub repo

```bash
gh repo delete gitIgorrz/azure-mcp-demo --yes
```

Or archive it if you want to keep the code:
```bash
gh repo archive gitIgorrz/azure-mcp-demo
```

### Step 5 — delete the HCP workspace

In `app.terraform.io` → workspace `azure-mcp-demo` → **Settings → Destruction and Deletion →
Delete from HCP Terraform**. The destroy plan in step 2 must complete first (the workspace
must have no managed resources).

---

## Cost tracking

To monitor spend against the budget:
```bash
# View current spend (Azure portal or CLI)
az consumption budget list --resource-group rg-mcp-demo-lab

# View Log Analytics ingestion
az monitor log-analytics workspace show \
  --resource-group rg-mcp-demo-lab \
  --workspace-name law-mcp-demo-lab \
  --query "sku"
```

Claude Code usage cost (subscription vs. API billing) is tracked separately —
see `CLAUDE.md § Token / cost discipline`.
