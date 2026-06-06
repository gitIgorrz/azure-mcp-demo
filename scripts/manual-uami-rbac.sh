#!/usr/bin/env bash
# =============================================================================
# manual-uami-rbac.sh                                            # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Ensures the MCP server's runtime identity — a User-Assigned Managed
#        Identity (UAMI) — exists and holds the built-in **Reader** role at
#        **resource-group scope** only (ADR-009). This is the server-to-Azure
#        leg of the secretless chain (ADR-005).
#
# WHY MANUAL:  Creating a role assignment requires
#        `Microsoft.Authorization/roleAssignments/write`, which the Terraform
#        apply identity does NOT have (it runs as Contributor via PIM, and
#        Contributor cannot grant roles). Per the same pattern proven in the
#        prior lab, the role assignment is a one-time manual step done by an
#        operator holding **Owner / User Access Administrator** at the RG scope.
#        Separation of duties: the identity that deploys resources is not the
#        identity that grants RBAC.
#
# WHO RUNS IT:  gitIgorrz, `az login` as Owner / User Access Administrator on the
#        target resource group.
#
# RELATED:  ADR-005 (secretless), ADR-009 (Reader @ RG scope).
#
# ORDER NOTE (chicken-and-egg):
#        The resource group and (optionally) the UAMI are created by Terraform in
#        Phase 5. Run this AFTER the first `terraform apply` creates the RG + UAMI,
#        so the role assignment binds to a real principal and scope. If you are
#        bootstrapping before Terraform exists, this script can create the RG and
#        UAMI itself (guarded below) — but the canonical owner of those resources
#        is Terraform.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites arguments that look like Unix paths (e.g. an
# ARM scope "/subscriptions/...") into Windows paths, corrupting them (you get a
# MissingSubscription error). Harmless on Linux/macOS; required on Windows.
export MSYS_NO_PATHCONV=1

# ---- Configuration (identifiers resolved at runtime; nothing sensitive) -----
ENVIRONMENT="lab"
RG_NAME="rg-mcp-demo-${ENVIRONMENT}"
UAMI_NAME="id-mcp-demo-${ENVIRONMENT}"
ROLE="Reader"
# Region only used if this script must bootstrap the RG/UAMI before Terraform.
# Set to your lab region; left unset on purpose to avoid a wrong-region default.
LOCATION="${LOCATION:-}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"

echo "Subscription: ${SUBSCRIPTION_ID}"
echo "RG scope:     ${RG_SCOPE}"
echo "UAMI:         ${UAMI_NAME}"
echo "Role:         ${ROLE} (resource-group scope only — ADR-009)"
echo

# -----------------------------------------------------------------------------
# STEP 1 — Confirm the resource group exists (Terraform owns it).
# -----------------------------------------------------------------------------
if ! az group show --name "${RG_NAME}" >/dev/null 2>&1; then
  echo "Resource group ${RG_NAME} does not exist yet."
  if [[ -n "${LOCATION}" ]]; then
    echo "Bootstrapping: creating ${RG_NAME} in ${LOCATION} (Terraform should own this)."
    az group create --name "${RG_NAME}" --location "${LOCATION}" \
      --tags environment="${ENVIRONMENT}" project="azure-mcp-demo" \
             managed-by="manual-bootstrap" repo="gitIgorrz/azure-mcp-demo" \
             cost-centre="lab" >/dev/null
  else
    echo "Run Terraform (Phase 5) first, or set LOCATION=<region> to bootstrap." >&2
    echo "Aborting — refusing to assign a role to a non-existent scope." >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# STEP 2 — Ensure the UAMI exists. Reuse if Terraform already created it.
# -----------------------------------------------------------------------------
if az identity show --name "${UAMI_NAME}" --resource-group "${RG_NAME}" >/dev/null 2>&1; then
  echo "Reusing existing UAMI ${UAMI_NAME} (owned by Terraform if present in state)."
else
  echo "Creating UAMI ${UAMI_NAME} (bootstrap — Terraform is the canonical owner)..."
  az identity create --name "${UAMI_NAME}" --resource-group "${RG_NAME}" \
    ${LOCATION:+--location "${LOCATION}"} \
    --tags environment="${ENVIRONMENT}" project="azure-mcp-demo" \
           managed-by="manual-bootstrap" repo="gitIgorrz/azure-mcp-demo" \
           cost-centre="lab" >/dev/null
fi

UAMI_PRINCIPAL_ID="$(az identity show --name "${UAMI_NAME}" --resource-group "${RG_NAME}" --query principalId -o tsv)"
UAMI_CLIENT_ID="$(az identity show --name "${UAMI_NAME}" --resource-group "${RG_NAME}" --query clientId -o tsv)"
echo "  UAMI principalId (for RBAC): ${UAMI_PRINCIPAL_ID}"
echo "  UAMI clientId    (for app):  ${UAMI_CLIENT_ID}"
echo

# -----------------------------------------------------------------------------
# STEP 3 — Assign Reader at RG scope. Idempotent. Scope is the RG, never broader.
#          --assignee-object-id + --assignee-principal-type avoids an extra Graph
#          lookup and the propagation race on freshly-created identities.
# -----------------------------------------------------------------------------
echo "Assigning ${ROLE} to UAMI at RG scope..."
if az role assignment list --assignee "${UAMI_PRINCIPAL_ID}" --scope "${RG_SCOPE}" \
      --role "${ROLE}" --query "[0].id" -o tsv | grep -q .; then
  echo "  [skip] ${ROLE} already assigned at ${RG_SCOPE}."
else
  az role assignment create \
    --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE}" \
    --scope "${RG_SCOPE}" >/dev/null
  echo "  [done] ${ROLE} assigned at ${RG_SCOPE}."
fi
echo

# -----------------------------------------------------------------------------
# VERIFY — assert exactly the intended grant; assert no broader (sub-scope) grant.
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
echo "Role assignments for the UAMI:"
az role assignment list --assignee "${UAMI_PRINCIPAL_ID}" --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table

echo
# Fail if the UAMI holds any assignment at subscription (or broader) scope.
BROAD="$(az role assignment list --assignee "${UAMI_PRINCIPAL_ID}" --all \
  --query "[?scope=='/subscriptions/${SUBSCRIPTION_ID}'] | length(@)" -o tsv)"
if [[ "${BROAD}" == "0" ]]; then
  echo "PASS: UAMI has no subscription-scope assignment (least privilege, ADR-009)."
else
  echo "FAIL: UAMI holds ${BROAD} subscription-scope assignment(s) — remove them." >&2
  exit 1
fi

echo
echo "Record the UAMI clientId ${UAMI_CLIENT_ID} for the Container App / app config"
echo "(via Terraform output or HCP variable) — not committed to this repo."
