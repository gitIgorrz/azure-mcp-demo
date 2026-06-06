#!/usr/bin/env bash
# =============================================================================
# manual-github-oidc-setup.sh                                    # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Creates the GitHub Actions CI identity in Entra and the *tightly scoped*
#        federated credentials that let GitHub Actions obtain Azure tokens WITHOUT
#        any client secret (secretless CI per ADR-005 / ADR-008).
#
# WHY MANUAL:  Creates an Entra app registration + service principal and federated
#        credentials. These are identity/trust mutations that require elevated
#        directory permissions and must be reviewed by a human before running.
#        Claude never runs these (CLAUDE.md § Destructive-command rules).
#
# WHO RUNS IT:  gitIgorrz, from `az login` as a user holding **Application
#        Administrator** (or Owner of the app reg) in the target tenant.
#
# RELATED:  ADR-005 (secretless), ADR-008 (subject scoping), ADR-013 (env gate).
#
# VERIFY:  The verification block at the end lists the federated credentials and
#        asserts there is no wildcard subject and no password credential.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites arguments that look like Unix paths (e.g. an
# ARM scope "/subscriptions/...") into Windows paths, corrupting them (you get a
# MissingSubscription error). Harmless on Linux/macOS; required on Windows.
export MSYS_NO_PATHCONV=1

# ---- Configuration (no secrets; identifiers resolved at runtime) ------------
GH_OWNER="gitIgorrz"
GH_REPO="azure-mcp-demo"
APP_NAME="sp-${GH_REPO}-github-oidc"   # CI service principal display name
GH_ENVIRONMENT="lab"                   # GitHub Environment gating apply (ADR-013)

# Resolved from the logged-in context — nothing sensitive is hardcoded.
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

echo "Tenant:       ${TENANT_ID}"
echo "Subscription: ${SUBSCRIPTION_ID}"
echo "Repo:         ${GH_OWNER}/${GH_REPO}"
echo

# -----------------------------------------------------------------------------
# STEP 1 — Create (or reuse) the app registration + service principal.
#          NO password/secret is ever created. Federated credentials only.
# -----------------------------------------------------------------------------
APP_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)"
if [[ -z "${APP_ID}" ]]; then
  echo "Creating app registration '${APP_NAME}'..."
  APP_ID="$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)"
else
  echo "Reusing existing app registration '${APP_NAME}' (appId ${APP_ID})."
fi

# Ensure a service principal exists for the app (needed for RBAC role assignment).
if [[ -z "$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)" ]]; then
  echo "Creating service principal for appId ${APP_ID}..."
  az ad sp create --id "${APP_ID}" >/dev/null
fi
APP_OBJECT_ID="$(az ad app show --id "${APP_ID}" --query id -o tsv)"
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id -o tsv)"

echo "  appId (client ID):  ${APP_ID}"
echo "  app objectId:       ${APP_OBJECT_ID}"
echo "  sp  objectId:       ${SP_OBJECT_ID}"
echo

# -----------------------------------------------------------------------------
# STEP 2 — Federated credentials. ONE per scope. NEVER a wildcard (ADR-008).
#          GitHub's OIDC issuer is https://token.actions.githubusercontent.com
#          Audience for Azure is "api://AzureADTokenExchange".
#
#   Subject reference (ADR-008):
#     repo:{owner}/{repo}:ref:refs/heads/{branch}   -> specific branch
#     repo:{owner}/{repo}:environment:{env}          -> GitHub Environment (gated)
#     repo:{owner}/{repo}:pull_request               -> any PR (use sparingly)
# -----------------------------------------------------------------------------
ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"

create_fic() {
  # $1 = credential name, $2 = subject claim
  local name="$1" subject="$2"
  # Defence-in-depth: refuse to create a wildcard subject (ADR-008).
  if [[ "${subject}" == *"*"* ]]; then
    echo "REFUSING to create wildcard federated subject: ${subject}" >&2
    exit 1
  fi
  if az ad app federated-credential list --id "${APP_ID}" \
        --query "[?subject=='${subject}'] | [0].name" -o tsv | grep -q .; then
    echo "  [skip] federated credential already exists for subject: ${subject}"
    return
  fi
  echo "  [create] ${name}  <-  ${subject}"
  az ad app federated-credential create --id "${APP_ID}" --parameters "$(cat <<JSON
{
  "name": "${name}",
  "issuer": "${ISSUER}",
  "subject": "${subject}",
  "audiences": ["${AUDIENCE}"],
  "description": "GitHub OIDC for ${GH_OWNER}/${GH_REPO} — ${name}"
}
JSON
)" >/dev/null
}

echo "Creating tightly-scoped federated credentials (ADR-008)..."
# (a) Terraform PLAN on PRs targeting main + image build on main.
create_fic "tf-plan-main"  "repo:${GH_OWNER}/${GH_REPO}:ref:refs/heads/main"
# (b) Terraform APPLY — gated by the GitHub Environment 'lab' (ADR-013).
#     This subject can only be presented after the Environment approval is granted.
create_fic "tf-apply-env"  "repo:${GH_OWNER}/${GH_REPO}:environment:${GH_ENVIRONMENT}"
# (c) OPTIONAL — plan-on-PR for feature branches (fork PRs). Commented by default;
#     uncomment only if you accept the broader 'pull_request' subject (ADR-008 note).
# create_fic "tf-plan-pr"  "repo:${GH_OWNER}/${GH_REPO}:pull_request"
echo

# -----------------------------------------------------------------------------
# STEP 3 — RBAC for the CI identity.
#   - GHCR push uses GitHub's own token, NOT Azure — no Azure role needed for push.
#   - Terraform plan needs READ on the subscription/RG. Apply needs elevated rights,
#     which are granted time-bound via PIM to a group the SP joins (ADR-014) — NOT a
#     standing Contributor assignment here.
#
#   Assign Reader at subscription scope for plan (read state of existing resources).
#   The RG may not exist yet (Terraform creates it in Phase 5); subscription-scope
#   Reader is the minimum that lets `plan` refresh. Apply elevation = PIM only.
# -----------------------------------------------------------------------------
echo "Assigning Reader (subscription scope) to the CI service principal for 'plan'..."
if az role assignment list --assignee "${APP_ID}" \
      --scope "/subscriptions/${SUBSCRIPTION_ID}" \
      --role "Reader" --query "[0].id" -o tsv | grep -q .; then
  echo "  [skip] Reader already assigned."
else
  az role assignment create \
    --assignee "${APP_ID}" \
    --role "Reader" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
  echo "  [done] Reader assigned at subscription scope."
fi
echo
echo "  NOTE: apply-time elevation (Contributor) is NOT assigned here. It is granted"
echo "        time-bound via PIM — run scripts/manual-pim-setup.sh and add this SP"
echo "        (objectId ${SP_OBJECT_ID}) to group grp-mcp-demo-tf-apply."
echo

# -----------------------------------------------------------------------------
# STEP 4 — Surface the values GitHub Actions needs as repo/environment variables.
#          These are IDs, NOT secrets — OIDC means no client secret is stored.
#          Set them via `gh` (requires `gh auth login`) or in the GitHub UI.
# -----------------------------------------------------------------------------
cat <<EOF
Set the following GitHub Actions *variables* (not secrets — these are non-sensitive IDs):

  gh variable set AZURE_CLIENT_ID       --repo ${GH_OWNER}/${GH_REPO} --body "${APP_ID}"
  gh variable set AZURE_TENANT_ID       --repo ${GH_OWNER}/${GH_REPO} --body "${TENANT_ID}"
  gh variable set AZURE_SUBSCRIPTION_ID --repo ${GH_OWNER}/${GH_REPO} --body "${SUBSCRIPTION_ID}"

The apply workflow must reference  environment: ${GH_ENVIRONMENT}  so the
environment-scoped federated credential (b) can be used (ADR-013).
EOF
echo

# -----------------------------------------------------------------------------
# VERIFY — list federated credentials, assert no wildcard, assert no password cred.
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
echo "Federated credentials on ${APP_NAME}:"
az ad app federated-credential list --id "${APP_ID}" \
  --query "[].{name:name, subject:subject, issuer:issuer}" -o table

echo
if az ad app federated-credential list --id "${APP_ID}" \
      --query "[?contains(subject, '*')] | length(@)" -o tsv | grep -qx 0; then
  echo "PASS: no wildcard federated subjects."
else
  echo "FAIL: a wildcard federated subject exists — remediate (ADR-008)." >&2
  exit 1
fi

PW_COUNT="$(az ad app credential list --id "${APP_ID}" --query "length(@)" -o tsv)"
if [[ "${PW_COUNT}" == "0" ]]; then
  echo "PASS: app registration has zero password credentials (secretless, ADR-005)."
else
  echo "FAIL: app registration has ${PW_COUNT} password credential(s). Remove them." >&2
  exit 1
fi
echo "Done. Record appId ${APP_ID} in your secret manager / HCP — not in this repo."
