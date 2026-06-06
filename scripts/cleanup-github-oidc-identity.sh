#!/usr/bin/env bash
# =============================================================================
# cleanup-github-oidc-identity.sh                               # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Removes the now-unused GitHub-OIDC CI identity. The project moved to the
#        VCS-driven HCP model (ADR-007): GitHub Actions no longer authenticates to
#        Azure (HCP does, via Dynamic Provider Credentials), so the CI app
#        registration `sp-azure-mcp-demo-github-oidc`, its federated credentials,
#        and its subscription-scope Reader role assignment are superfluous.
#
#        That identity was created by the (now-removed) manual-github-oidc-setup.sh
#        during an earlier CLI-driven attempt. Run this once to clean it up.
#
# WHY MANUAL:  Deletes an Entra app registration + an Azure role assignment —
#        identity/cloud mutations. Requires Application Administrator (delete app)
#        and User Access Administrator / Owner (remove the role assignment). Claude
#        never runs these (CLAUDE.md § Destructive-command rules).
#
# WHO RUNS IT:  gitIgorrz, `az login` as Owner + Application Administrator.
#
# SAFETY:  idempotent — skips anything already absent. Verifies removal at the end.
#          Run from a BASH shell (Git Bash / MINGW64), not PowerShell.
# =============================================================================
set -euo pipefail
# Git Bash / MINGW rewrites /subscriptions/... args into Windows paths; disable that.
export MSYS_NO_PATHCONV=1

APP_NAME="sp-azure-mcp-demo-github-oidc"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

echo "Target app: ${APP_NAME}"
echo "Subscription: ${SUBSCRIPTION_ID}"
echo

APP_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)"
if [[ -z "${APP_ID}" ]]; then
  echo "[skip] '${APP_NAME}' not found — already removed or never created. Nothing to do."
  exit 0
fi
echo "Found appId: ${APP_ID}"
echo

# -----------------------------------------------------------------------------
# 1. Remove the subscription-scope Reader role assignment (if present). Do this
#    BEFORE deleting the app so the assignee still resolves cleanly.
# -----------------------------------------------------------------------------
echo "Removing Reader @ subscription scope (if assigned)..."
ASSIGN_ID="$(az role assignment list --assignee "${APP_ID}" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" --role "Reader" \
  --query "[0].id" -o tsv 2>/dev/null || true)"
if [[ -n "${ASSIGN_ID}" ]]; then
  az role assignment delete --ids "${ASSIGN_ID}"
  echo "  [done] removed Reader assignment."
else
  echo "  [skip] no Reader assignment found."
fi
echo

# -----------------------------------------------------------------------------
# 2. Delete the app registration. This also removes its service principal and all
#    federated credentials.
# -----------------------------------------------------------------------------
echo "Deleting app registration ${APP_ID} (removes its SP + federated credentials)..."
az ad app delete --id "${APP_ID}"
echo "  [done] deleted."
echo

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
REMAIN="$(az ad app list --display-name "${APP_NAME}" --query "length(@)" -o tsv)"
if [[ "${REMAIN}" == "0" ]]; then
  echo "PASS: '${APP_NAME}' no longer exists."
else
  echo "FAIL: '${APP_NAME}' is still present (${REMAIN})." >&2
  exit 1
fi
echo
echo "Done. If you set AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID as GitHub"
echo "Actions *variables*, delete them too — they are unused in the VCS-driven model:"
echo "  gh variable delete AZURE_CLIENT_ID       --repo gitIgorrz/azure-mcp-demo"
echo "  gh variable delete AZURE_TENANT_ID       --repo gitIgorrz/azure-mcp-demo"
echo "  gh variable delete AZURE_SUBSCRIPTION_ID --repo gitIgorrz/azure-mcp-demo"
