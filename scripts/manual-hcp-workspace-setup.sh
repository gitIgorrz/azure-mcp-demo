#!/usr/bin/env bash
# =============================================================================
# manual-hcp-workspace-setup.sh                                  # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Establishes the HCP Terraform -> Azure trust for workspace
#        `azure-mcp-demo`, SECRETLESS (ADR-005, ADR-007). Two interchangeable paths,
#        both with NO client secret:
#          (DEFAULT)  Dynamic Provider Credentials (DPC) via HCP's OIDC issuer.
#          (TOGGLE)   A named service principal with an Azure federated credential
#                     trusting the same HCP OIDC issuer.
#        Also creates the workspace and its (non-sensitive) variable set.
#
# WHY MANUAL:  Creates an Entra app registration + federated credentials (identity
#        trust mutations) and an HCP workspace (org-level mutation). Requires
#        Application Administrator in Entra and Owner/Write on the HCP project.
#        Claude never runs these (CLAUDE.md § Destructive-command rules).
#
# WHO RUNS IT:  gitIgorrz.
#        Azure side : `az login` as Application Administrator.
#        HCP   side : export a short-lived HCP team/user API token at runtime:
#                       export TFE_TOKEN=...        # NEVER commit; not stored here
#        The TFE_TOKEN is read from the environment only; it is never written to disk.
#
# RELATED:  ADR-005 (secretless), ADR-007 (DPC default + SP toggle).
#
# NOTE:  The prior lab fell back to a client secret because DPC "failed for an
#        unknown reason". That fallback is explicitly DISALLOWED here (ADR-005):
#        if DPC misbehaves, use the SP+federated TOGGLE — still secretless. Never
#        set ARM_CLIENT_SECRET.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites arguments that look like Unix paths into
# Windows paths, corrupting them. Harmless on Linux/macOS; safe guard on Windows.
export MSYS_NO_PATHCONV=1

# ---- Configuration ----------------------------------------------------------
HCP_ORG="gitIgorrz"
HCP_PROJECT="igor-lab"
HCP_WORKSPACE="azure-mcp-demo"
APP_NAME="sp-azure-mcp-demo-hcp-tf"          # dedicated TF identity (audit separation)
TFE_HOST="app.terraform.io"
HCP_OIDC_ISSUER="https://${TFE_HOST}"
AUDIENCE="api://AzureADTokenExchange"

TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

echo "HCP:    ${HCP_ORG}/${HCP_PROJECT}/${HCP_WORKSPACE}"
echo "Tenant: ${TENANT_ID}"
echo "Sub:    ${SUBSCRIPTION_ID}"
echo

# =============================================================================
# PART A — Azure-side identity + federated credentials (az CLI; runnable now)
# =============================================================================
APP_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)"
if [[ -z "${APP_ID}" ]]; then
  echo "Creating app registration '${APP_NAME}' (no secret)..."
  APP_ID="$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)"
else
  echo "Reusing app registration '${APP_NAME}' (appId ${APP_ID})."
fi
if [[ -z "$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)" ]]; then
  az ad sp create --id "${APP_ID}" >/dev/null
fi
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id -o tsv)"
echo "  TF identity appId (= TFC_AZURE_RUN_CLIENT_ID / ARM_CLIENT_ID): ${APP_ID}"
echo "  TF identity sp objectId (add to PIM group for apply):          ${SP_OBJECT_ID}"
echo

# HCP DPC subject format:
#   organization:<org>:project:<project>:workspace:<ws>:run_phase:<plan|apply>
create_fic() {  # $1 name, $2 subject
  local name="$1" subject="$2"
  if [[ "${subject}" == *"*"* ]]; then
    echo "REFUSING wildcard subject: ${subject}" >&2; exit 1
  fi
  if az ad app federated-credential list --id "${APP_ID}" \
        --query "[?subject=='${subject}'] | [0].name" -o tsv | grep -q .; then
    echo "  [skip] FIC exists for: ${subject}"; return
  fi
  echo "  [create] ${name}  <-  ${subject}"
  az ad app federated-credential create --id "${APP_ID}" --parameters "$(cat <<JSON
{
  "name": "${name}",
  "issuer": "${HCP_OIDC_ISSUER}",
  "subject": "${subject}",
  "audiences": ["${AUDIENCE}"],
  "description": "HCP Terraform ${HCP_ORG}/${HCP_WORKSPACE} — ${name}"
}
JSON
)" >/dev/null
}

echo "Creating HCP-trusting federated credentials (plan + apply run phases)..."
SUBJ_BASE="organization:${HCP_ORG}:project:${HCP_PROJECT}:workspace:${HCP_WORKSPACE}"
create_fic "hcp-${HCP_WORKSPACE}-plan"  "${SUBJ_BASE}:run_phase:plan"
create_fic "hcp-${HCP_WORKSPACE}-apply" "${SUBJ_BASE}:run_phase:apply"
echo
echo "  RBAC: this TF identity needs Contributor to deploy resources. Do NOT assign"
echo "        it standing Contributor here — add SP ${SP_OBJECT_ID} to the PIM group"
echo "        (scripts/manual-pim-setup.sh) for time-bound elevation (ADR-014)."
echo "        It must NOT receive roleAssignments/write — RBAC grants stay manual"
echo "        (scripts/manual-uami-rbac.sh), preserving separation of duties."
echo

# =============================================================================
# PART B — HCP-side workspace + variable set
# Two ways: (B1) portal steps, or (B2) TFE API via curl using $TFE_TOKEN.
# =============================================================================
cat <<EOF
---------------------------------------------------------------------------
PART B — HCP Terraform workspace '${HCP_WORKSPACE}'
---------------------------------------------------------------------------
Execution mode: Remote, VCS-driven (ADR-007). Connect this workspace to the GitHub
repo gitIgorrz/azure-mcp-demo (working directory terraform/), auto-apply OFF, in the
HCP UI. HCP runs plan/apply on git changes and on runs queued by build-push.

Set these workspace ENVIRONMENT variables. Choose ONE path. No secret in either.

  PATH 1 — DPC / OIDC (DEFAULT):
    TFC_AZURE_PROVIDER_AUTH = true            (env)
    TFC_AZURE_RUN_CLIENT_ID = ${APP_ID}       (env)
    ARM_TENANT_ID           = ${TENANT_ID}     (env)
    ARM_SUBSCRIPTION_ID     = ${SUBSCRIPTION_ID} (env)
    # No ARM_CLIENT_ID, no ARM_CLIENT_SECRET. HCP injects the OIDC token.

  PATH 2 — SP + federated credential (TOGGLE, also secretless):
    ARM_CLIENT_ID           = ${APP_ID}        (env)
    ARM_TENANT_ID           = ${TENANT_ID}     (env)
    ARM_SUBSCRIPTION_ID     = ${SUBSCRIPTION_ID} (env)
    TFC_AZURE_PROVIDER_AUTH = true             (env)   # enables OIDC token issuance
    # ARM_CLIENT_SECRET is intentionally ABSENT. Federated trust only.

Switching paths = changing these variables, not code.
---------------------------------------------------------------------------
EOF

# ---- B2 (optional automation): create workspace + vars via the TFE API ------
# Runs only if TFE_TOKEN is exported. Token is read from env, never persisted.
if [[ -n "${TFE_TOKEN:-}" ]]; then
  echo "TFE_TOKEN detected — creating/locating workspace via API..."
  api() { curl -sS \
    --header "Authorization: Bearer ${TFE_TOKEN}" \
    --header "Content-Type: application/vnd.api+json" "$@"; }

  PROJECT_ID="$(api "https://${TFE_HOST}/api/v2/organizations/${HCP_ORG}/projects?filter%5Bnames%5D=${HCP_PROJECT}" \
    | python -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')"
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "  Project ${HCP_PROJECT} not found — create it in the UI first." >&2; exit 1
  fi

  WS_ID="$(api "https://${TFE_HOST}/api/v2/organizations/${HCP_ORG}/workspaces/${HCP_WORKSPACE}" \
    | python -c 'import sys,json;d=json.load(sys.stdin);print(d.get("data",{}).get("id",""))')"
  if [[ -z "${WS_ID}" ]]; then
    echo "  Creating workspace ${HCP_WORKSPACE}..."
    WS_ID="$(api -X POST "https://${TFE_HOST}/api/v2/organizations/${HCP_ORG}/workspaces" \
      --data "$(cat <<JSON
{"data":{"type":"workspaces","attributes":{
  "name":"${HCP_WORKSPACE}","working-directory":"terraform/","execution-mode":"remote",
  "auto-apply":false},"relationships":{"project":{"data":{"type":"projects","id":"${PROJECT_ID}"}}}}}
JSON
)" | python -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')"
  else
    echo "  Reusing workspace ${HCP_WORKSPACE} (${WS_ID})."
  fi

  set_var() {  # $1 key, $2 value, $3 category(env|terraform)
    api -X POST "https://${TFE_HOST}/api/v2/workspaces/${WS_ID}/vars" \
      --data "$(cat <<JSON
{"data":{"type":"vars","attributes":{
  "key":"$1","value":"$2","category":"$3","hcl":false,"sensitive":false}}}
JSON
)" >/dev/null && echo "    set $1"
  }
  echo "  Applying PATH 1 (DPC) variables (idempotency: ignore 'already exists' 422s)..."
  set_var TFC_AZURE_PROVIDER_AUTH true              env || true
  set_var TFC_AZURE_RUN_CLIENT_ID "${APP_ID}"       env || true
  set_var ARM_TENANT_ID           "${TENANT_ID}"    env || true
  set_var ARM_SUBSCRIPTION_ID     "${SUBSCRIPTION_ID}" env || true
else
  echo "TFE_TOKEN not set — skipping API automation. Do PART B in the HCP UI."
fi
echo

# =============================================================================
# VERIFY
# =============================================================================
echo "==== VERIFICATION ===="
echo "Azure federated credentials on ${APP_NAME}:"
az ad app federated-credential list --id "${APP_ID}" \
  --query "[].{name:name, subject:subject, issuer:issuer}" -o table

if az ad app federated-credential list --id "${APP_ID}" \
      --query "[?contains(subject,'*')] | length(@)" -o tsv | grep -qx 0; then
  echo "PASS: no wildcard subjects."
else
  echo "FAIL: wildcard subject present — remediate (ADR-008)." >&2; exit 1
fi

PW_COUNT="$(az ad app credential list --id "${APP_ID}" --query "length(@)" -o tsv)"
if [[ "${PW_COUNT}" == "0" ]]; then
  echo "PASS: HCP TF identity has zero password credentials (secretless, ADR-005)."
else
  echo "FAIL: ${PW_COUNT} password credential(s) on the TF identity — remove them." >&2
  exit 1
fi

echo
echo "Manual HCP UI check: workspace ${HCP_WORKSPACE} has NO variable named"
echo "ARM_CLIENT_SECRET. If one exists, delete it — it violates ADR-005."
