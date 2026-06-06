#!/usr/bin/env bash
# =============================================================================
# manual-hcp-tf-bootstrap-rbac.sh                               # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Grants the HCP Terraform deploy identity (`sp-azure-mcp-demo-hcp-tf`) the
#        built-in **Contributor** role at **subscription** scope so the FIRST
#        Terraform apply can create the resource group `rg-mcp-demo-lab`.
#
# WHY SUBSCRIPTION SCOPE (broader than ADR-014's RG scope):  creating a resource
#        group is a subscription-level operation, so the RG-scoped Contributor grant
#        (`manual-pim-setup.sh`) cannot exist before the RG does — a bootstrap
#        chicken-and-egg. For the lab the deploy identity holds subscription
#        Contributor so Terraform manages the RG's full lifecycle (create + destroy).
#
#        To tighten later (optional): after the first apply, run `manual-pim-setup.sh`
#        (RG scope) and remove this assignment (command printed at the end). Note a
#        future from-scratch rebuild would then need the RG pre-created/imported.
#
# WHY MANUAL:  creates an Azure role assignment
#        (`Microsoft.Authorization/roleAssignments/write`) — requires
#        **Owner / User Access Administrator**. Claude never runs these
#        (CLAUDE.md § Destructive-command rules).
#
# WHO RUNS IT:  gitIgorrz, `az login` as Owner / User Access Administrator.
#
# SAFETY:  idempotent (skips if already assigned); verifies at the end. Run from a
#          BASH shell (Git Bash / MINGW64), not PowerShell.
# =============================================================================
set -euo pipefail
# Git Bash / MINGW rewrites /subscriptions/... args into Windows paths; disable that.
export MSYS_NO_PATHCONV=1

APP_NAME="sp-azure-mcp-demo-hcp-tf"
ROLE="Contributor"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Resolve the deploy identity's SP object id from its display name (no hardcoded ids).
SP_OBJECT_ID="$(az ad sp list --display-name "${APP_NAME}" --query "[0].id" -o tsv)"
if [[ -z "${SP_OBJECT_ID}" ]]; then
  echo "Deploy identity '${APP_NAME}' not found." >&2
  echo "Run manual-hcp-workspace-setup.sh first (it creates that app registration)." >&2
  exit 1
fi

echo "Deploy identity: ${APP_NAME} (objectId ${SP_OBJECT_ID})"
echo "Role:            ${ROLE} @ subscription scope (bootstrap for the first apply)"
echo "Scope:           ${SUB_SCOPE}"
echo

# -----------------------------------------------------------------------------
# Assign Contributor at subscription scope. Idempotent.
# -----------------------------------------------------------------------------
if az role assignment list --assignee "${SP_OBJECT_ID}" --scope "${SUB_SCOPE}" \
      --role "${ROLE}" --query "[0].id" -o tsv | grep -q .; then
  echo "[skip] ${ROLE} already assigned at subscription scope."
else
  az role assignment create \
    --assignee-object-id "${SP_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE}" \
    --scope "${SUB_SCOPE}" >/dev/null
  echo "[done] ${ROLE} assigned at subscription scope."
fi
echo

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
if az role assignment list --assignee "${SP_OBJECT_ID}" --scope "${SUB_SCOPE}" \
      --role "${ROLE}" --query "[0].id" -o tsv | grep -q .; then
  echo "PASS: ${APP_NAME} holds ${ROLE} at subscription scope — the first apply can create the RG."
else
  echo "FAIL: assignment not found." >&2
  exit 1
fi
echo
echo "To tighten later (after the first apply creates the RG): run manual-pim-setup.sh for"
echo "RG-scope Contributor, then remove this subscription-scope grant with:"
echo "  MSYS_NO_PATHCONV=1 az role assignment delete \\"
echo "    --assignee-object-id ${SP_OBJECT_ID} --role ${ROLE} --scope ${SUB_SCOPE}"
