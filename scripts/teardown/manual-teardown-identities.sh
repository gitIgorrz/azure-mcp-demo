#!/usr/bin/env bash
# =============================================================================
# manual-teardown-identities.sh
#
# RUN MANUALLY — removes identity fabric resources that are NOT managed by
# Terraform. Run AFTER terraform destroy has completed (scripts/teardown/README.md).
#
# Who runs this: gitIgorrz (Application Administrator + User Access Admin)
# When: after HCP TF destroy plan completes; Azure RG must already be gone.
#
# Removes:
#   - CI Entra app registration + 3 federated credentials (ADR-008)
#   - HCP Terraform identity app registration + its federated credentials (ADR-007)
#   - Server audience/resource app registration app-azure-mcp-demo-api (ADR-006)
#   - PIM group grp-mcp-demo-tf-apply + Contributor role grant (ADR-014)
#   - HCP Terraform variable set (the workspace is deleted in the portal — see README)
#   - GitHub Actions environment + secrets/variables for the 'lab' environment
#   - GPG key from GitHub profile (optional; keep the local key)
#
# Does NOT remove:
#   - Azure resources (those were already destroyed by terraform destroy)
#   - The GitHub repo itself (handled separately — see scripts/teardown/README.md)
#   - The HCP workspace (must be deleted in the portal after this script)
#   - The local GPG key (it is personal; removal from GitHub only)
# =============================================================================

set -euo pipefail

# Git Bash / MINGW on Windows rewrites args that look like Unix paths into Windows
# paths, corrupting ARM scopes. Harmless on Linux/macOS; required on Windows.
export MSYS_NO_PATHCONV=1

echo "=== azure-mcp-demo identity teardown ==="
echo ""
echo "Prerequisite: terraform destroy must have completed."
echo "Verify before proceeding:"
echo ""
echo "  az resource list --resource-group rg-mcp-demo-lab 2>&1"
echo "  # Expected: ResourceGroupNotFound"
echo ""
read -rp "Has the Terraform destroy completed successfully? (yes/no) " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted. Run terraform destroy first (scripts/teardown/README.md step 2)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Derive context
# ---------------------------------------------------------------------------

echo ""
echo "=== [1/5] Resolving tenant and subscription context ==="

TENANT_ID=$(az account show --query tenantId --output tsv)
echo "Tenant: $TENANT_ID"

# ---------------------------------------------------------------------------
# 2. Remove CI Entra app registration
# ---------------------------------------------------------------------------

echo ""
echo "=== [2/5] Removing Entra app registrations ==="
echo ""
echo "Names must match those created by the setup scripts:"
echo "  sp-azure-mcp-demo-github-oidc  (manual-github-oidc-setup.sh)"
echo "  sp-azure-mcp-demo-hcp-tf       (manual-hcp-workspace-setup.sh)"
echo "  app-azure-mcp-demo-api         (manual-server-app-registration.sh)"
echo ""

for APP_NAME in sp-azure-mcp-demo-github-oidc sp-azure-mcp-demo-hcp-tf app-azure-mcp-demo-api; do
  APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" --output tsv 2>/dev/null || true)
  if [[ -z "$APP_ID" || "$APP_ID" == "None" ]]; then
    echo "  [skip] '$APP_NAME' not found (already removed or not created)."
    continue
  fi
  echo "  Found '$APP_NAME': $APP_ID"
  # Federated credentials are removed automatically with the app registration.
  SECRET_COUNT=$(az ad app credential list --id "$APP_ID" --query "length(@)" --output tsv 2>/dev/null || echo "0")
  echo "    client secrets: $SECRET_COUNT (should be 0 — none were ever created)"
  echo "    deleting..."
  az ad app delete --id "$APP_ID"
  VERIFY=$(az ad app list --display-name "$APP_NAME" --query "length(@)" --output tsv 2>/dev/null || echo "0")
  echo "    remaining '$APP_NAME': $VERIFY (expected: 0)"
done

# ---------------------------------------------------------------------------
# 3. Remove PIM group and eligible role assignment
# ---------------------------------------------------------------------------

echo ""
echo "=== [3/5] Removing PIM group and eligible role assignment ==="
echo ""
echo "Looking for group 'grp-mcp-demo-tf-apply'..."

PIM_GROUP_ID=$(az ad group list \
  --display-name "grp-mcp-demo-tf-apply" \
  --query "[0].id" \
  --output tsv 2>/dev/null || true)

if [[ -z "$PIM_GROUP_ID" || "$PIM_GROUP_ID" == "None" ]]; then
  echo "  [skip] Group 'grp-mcp-demo-tf-apply' not found."
else
  echo "  Found group: $PIM_GROUP_ID"
  echo ""
  echo "  NOTE: Eligible PIM role assignments may not be removed automatically when the"
  echo "  resource group is deleted. If the eligible Contributor assignment was at the"
  echo "  RG scope and the RG is gone, Azure may have already cleaned it up."
  echo ""
  echo "  To verify / remove the PIM-eligible assignment manually:"
  echo "  1. Azure portal → Microsoft Entra ID → Privileged Identity Management"
  echo "  2. Azure resources → find the subscription → Resource groups"
  echo "  3. Look for rg-mcp-demo-lab in Eligible assignments (may show as orphaned)"
  echo "  4. If found, remove the eligible assignment."
  echo ""
  echo "  Deleting Entra group 'grp-mcp-demo-tf-apply'..."
  az ad group delete --group "$PIM_GROUP_ID"
  echo "  Deleted."

  VERIFY=$(az ad group list \
    --display-name "grp-mcp-demo-tf-apply" \
    --query "length(@)" \
    --output tsv 2>/dev/null || echo "0")
  echo "  Remaining 'grp-mcp-demo-tf-apply' groups: $VERIFY (expected: 0)"
fi

# ---------------------------------------------------------------------------
# 4. Remove GitHub Actions environment, secrets, and variables
# ---------------------------------------------------------------------------

echo ""
echo "=== [4/5] Removing GitHub Actions environment and configuration ==="
echo ""
echo "Requires: gh auth status (authenticated as gitIgorrz)"
echo ""

GH_AUTH_OK=$(gh auth status 2>&1 | grep -c "Logged in" || true)
if [[ "$GH_AUTH_OK" -lt 1 ]]; then
  echo "  [skip] GitHub CLI not authenticated. Run 'gh auth login' and re-run this step."
  echo "  Manual steps:"
  echo "    gh secret delete HCP_TF_TOKEN --repo gitIgorrz/azure-mcp-demo"
  echo "    gh variable delete AZURE_TENANT_ID --repo gitIgorrz/azure-mcp-demo"
  echo "    gh variable delete AZURE_SUBSCRIPTION_ID --repo gitIgorrz/azure-mcp-demo"
  echo "    gh variable delete AZURE_CLIENT_ID --repo gitIgorrz/azure-mcp-demo"
  echo "    gh api -X DELETE repos/gitIgorrz/azure-mcp-demo/environments/lab"
else
  # Remove Actions secrets
  echo "  Removing Actions secret: HCP_TF_TOKEN"
  gh secret delete HCP_TF_TOKEN \
    --repo gitIgorrz/azure-mcp-demo 2>/dev/null || echo "  (not found)"

  # Remove Actions variables
  for VAR in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_CLIENT_ID; do
    echo "  Removing Actions variable: $VAR"
    gh variable delete "$VAR" \
      --repo gitIgorrz/azure-mcp-demo 2>/dev/null || echo "  (not found)"
  done

  # Remove the 'lab' environment
  echo "  Removing GitHub Environment 'lab'..."
  gh api -X DELETE "repos/gitIgorrz/azure-mcp-demo/environments/lab" \
    2>/dev/null || echo "  (not found)"

  echo "  GitHub Actions cleanup complete."
fi

# ---------------------------------------------------------------------------
# 5. Remove GPG key from GitHub (optional)
# ---------------------------------------------------------------------------

echo ""
echo "=== [5/5] GPG key removal from GitHub (optional) ==="
echo ""
echo "  The GPG key is personal and stored locally — do NOT delete the local key."
echo "  If you want to remove it from this repo's GitHub profile:"
echo ""
echo "  1. List your signing keys:"
echo "     gpg --list-secret-keys --keyid-format LONG"
echo ""
echo "  2. Get the key fingerprint, then check which GitHub key IDs match:"
echo "     gh gpg-key list"
echo ""
echo "  3. Remove the specific key:"
echo "     gh gpg-key delete <key-id>"
echo ""
echo "  Skip this step if the same GPG key is used for other repos."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "======================================================="
echo "Identity teardown complete. Summary:"
echo ""
echo "  ✓ App registrations (github-oidc, hcp-tf, api): removed (or were absent)"
echo "  ✓ PIM group 'grp-mcp-demo-tf-apply': removed (or was absent)"
echo "  ✓ GitHub Actions lab environment + secrets/variables: removed"
echo "  ? GPG key from GitHub: manual (step 5 above)"
echo ""
echo "Remaining steps:"
echo "  - Delete the HCP workspace in the portal (app.terraform.io)"
echo "  - Delete or archive the GitHub repo (scripts/teardown/README.md step 4)"
echo "======================================================="
