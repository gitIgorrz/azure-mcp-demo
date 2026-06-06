#!/usr/bin/env bash
# =============================================================================
# manual-pim-setup.sh                                            # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Grants the deploy identities the Contributor role at **resource-group
#        scope** for `terraform apply` (ADR-014), via an Entra group. Two modes:
#          PIM_MODE=pim       — PIM-**eligible** (time-bound, not standing). Needs
#                               Entra ID P2. The preferred posture.
#          PIM_MODE=fallback  — **permanent** Contributor @ RG (ADR-014 fallback) for
#                               tenants without P2, WITH compensating controls.
#
# CHOSEN PATH FOR THIS LAB:  **fallback** (default). The target lab tenant
#        has **no Entra ID P2 licence**
#        (verified 2026-06-05; docs/security-review.md), so PIM is not
#        available. The fallback grants permanent Contributor at **RG scope only**;
#        the standing risk is mitigated by the compensating controls below. If P2 is
#        ever added, re-run with `PIM_MODE=pim` to convert to eligible-only.
#
# COMPENSATING CONTROLS (fallback mode):  scope is the single RG, never the
#        subscription; the HCP apply approval gate (ADR-013) is an independent second
#        control before any apply; the HCP federated-credential subjects are tightly
#        scoped to the workspace + run phase (ADR-007/008); all role activity is
#        audit-logged. Schedule a quarterly access review of the group.
#
# WHY MANUAL:  Creates an Entra group and a Contributor role grant (PIM eligibility
#        or permanent assignment) — privileged identity-governance mutations.
#        Requires **Owner / User Access Administrator at the RG scope** (and, for
#        PIM mode, **Privileged Role Administrator** + Entra ID P2). Claude never
#        runs these (CLAUDE.md § Destructive-command rules).
#
# WHO RUNS IT:  gitIgorrz, `az login` as Owner / User Access Administrator at the RG.
#
# RELATED:  ADR-013 (apply gate, now in HCP), ADR-014 (PIM + fallback).
#
# RISK (accepted, lab):  single maintainer — in PIM mode this means self-activation;
#        in fallback mode it means a standing (but RG-scoped) Contributor grant.
#        Documented in ADR-014. In a team, use PIM with a separate approver.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites arguments that look like Unix paths (e.g. an
# ARM scope "/subscriptions/...") into Windows paths, corrupting them (you get a
# MissingSubscription error). Harmless on Linux/macOS; required on Windows.
export MSYS_NO_PATHCONV=1

# ---- Configuration ----------------------------------------------------------
ENVIRONMENT="lab"
RG_NAME="rg-mcp-demo-${ENVIRONMENT}"
GROUP_NAME="grp-mcp-demo-tf-apply"
GROUP_MAIL_NICK="grp-mcp-demo-tf-apply"
ROLE_NAME="Contributor"
MAX_ACTIVATION_HOURS="1"     # activation duration cap (PIM mode; set in policy, portal)
ELIGIBILITY_DURATION="P90D"  # eligibility window (PIM mode); renew via quarterly review

# Mode: 'fallback' (permanent Contributor @ RG, no P2) is the chosen path for this
# lab. Set PIM_MODE=pim to use PIM-eligible elevation where Entra ID P2 is available.
PIM_MODE="${PIM_MODE:-fallback}"
if [[ "${PIM_MODE}" != "pim" && "${PIM_MODE}" != "fallback" ]]; then
  echo "PIM_MODE must be 'pim' or 'fallback' (got '${PIM_MODE}')." >&2; exit 1
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"

echo "Mode:     ${PIM_MODE}"
echo "RG scope: ${RG_SCOPE}"
echo "Group:    ${GROUP_NAME}"
if [[ "${PIM_MODE}" == "pim" ]]; then
  echo "Role:     ${ROLE_NAME} (ELIGIBLE, not permanent — ADR-014)"
else
  echo "Role:     ${ROLE_NAME} (PERMANENT @ RG — ADR-014 fallback, no P2)"
fi
echo

# -----------------------------------------------------------------------------
# STEP 0 — Preconditions: RG must exist (Terraform owns it). PIM binds to a real
#          scope. Verify P2 licence manually (no clean CLI probe).
# -----------------------------------------------------------------------------
if ! az group show --name "${RG_NAME}" >/dev/null 2>&1; then
  echo "RG ${RG_NAME} does not exist yet. Run Terraform (Phase 5) first." >&2
  echo "PIM eligibility must target a real RG scope. Aborting." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# STEP 1 — Create (or reuse) the Entra group.
# -----------------------------------------------------------------------------
GROUP_ID="$(az ad group list --display-name "${GROUP_NAME}" --query "[0].id" -o tsv)"
if [[ -z "${GROUP_ID}" ]]; then
  echo "Creating Entra group '${GROUP_NAME}'..."
  GROUP_ID="$(az ad group create --display-name "${GROUP_NAME}" \
    --mail-nickname "${GROUP_MAIL_NICK}" --query id -o tsv)"
else
  echo "Reusing Entra group '${GROUP_NAME}' (${GROUP_ID})."
fi
echo "  group objectId: ${GROUP_ID}"
echo

# -----------------------------------------------------------------------------
# STEP 2 — Add the deploy identity as a MEMBER of the group.
#          The deploy identity is the HCP Terraform service principal (HCP runs
#          Terraform in the VCS-driven model, ADR-007). Membership + PIM eligibility
#          = it can ELEVATE, not that it holds Contributor standing.
#            HCP_TF_SP_OBJECT_ID — from manual-hcp-workspace-setup.sh
# -----------------------------------------------------------------------------
add_member() {  # $1 = sp object id (optional)
  local oid="$1"
  [[ -z "${oid}" ]] && return 0
  if az ad group member check --group "${GROUP_ID}" --member-id "${oid}" \
        --query value -o tsv 2>/dev/null | grep -qi true; then
    echo "  [skip] ${oid} already a member."
  else
    az ad group member add --group "${GROUP_ID}" --member-id "${oid}" >/dev/null
    echo "  [done] added ${oid}."
  fi
}
echo "Adding the HCP TF deploy identity to the group (skipped if env var unset)..."
add_member "${HCP_TF_SP_OBJECT_ID:-}"
echo
echo "  NOTE: PIM activation for *workload* identities (service principals) requires"
echo "        Entra ID P2. If only human operators activate, add your user instead:"
echo "          az ad group member add --group ${GROUP_ID} --member-id \\"
echo "            \$(az ad signed-in-user show --query id -o tsv)"
echo

# -----------------------------------------------------------------------------
# STEP 3 — Grant Contributor at RG scope, per mode.
#   pim      : PIM-ELIGIBLE via the ARM PIM API (roleEligibilityScheduleRequests),
#              since `az role assignment create` only makes PERMANENT assignments.
#   fallback : PERMANENT Contributor @ RG (no P2) — the chosen path for this lab.
# -----------------------------------------------------------------------------
ROLE_DEF_ID="$(az role definition list --name "${ROLE_NAME}" \
  --query "[0].id" -o tsv)"   # full /subscriptions/.../roleDefinitions/<guid>

if [[ "${PIM_MODE}" == "pim" ]]; then
  REQ_GUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python -c 'import uuid;print(uuid.uuid4())')"
  START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "Creating PIM-eligible ${ROLE_NAME} for the group at RG scope..."
  EXISTING_ELIG="$(az rest --method get \
    --url "https://management.azure.com${RG_SCOPE}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&\$filter=principalId+eq+'${GROUP_ID}'" \
    --query "value[?properties.roleDefinitionId=='${ROLE_DEF_ID}'] | length(@)" -o tsv 2>/dev/null || echo 0)"

  if [[ "${EXISTING_ELIG}" != "0" ]]; then
    echo "  [skip] eligible ${ROLE_NAME} already present for the group."
  else
    az rest --method put \
      --url "https://management.azure.com${RG_SCOPE}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/${REQ_GUID}?api-version=2020-10-01" \
      --body "$(cat <<JSON
{
  "properties": {
    "principalId": "${GROUP_ID}",
    "roleDefinitionId": "${ROLE_DEF_ID}",
    "requestType": "AdminAssign",
    "justification": "PIM-eligible Contributor for terraform apply (ADR-014)",
    "scheduleInfo": {
      "startDateTime": "${START_TIME}",
      "expiration": { "type": "AfterDuration", "duration": "${ELIGIBILITY_DURATION}" }
    }
  }
}
JSON
)" >/dev/null
    echo "  [done] eligible ${ROLE_NAME} created (expires after ${ELIGIBILITY_DURATION})."
  fi
  echo

  # Activation policy (PORTAL — no stable CLI surface).
  cat <<EOF
PORTAL — configure the activation policy (Entra ID > PIM > Azure resources >
${RG_NAME} > Roles > ${ROLE_NAME} > Role settings):
  - Maximum activation duration: ${MAX_ACTIVATION_HOURS} hour(s)
  - Require justification on activation: YES
  - Require ticket/MFA on activation: as available
  - Approval: lab = self-approval (ADR-014 risk); team = separate approver
  - Schedule a quarterly access review of '${GROUP_NAME}' membership + eligibility

Activate before each apply (operator):
  az rest --method put \\
    --url "https://management.azure.com${RG_SCOPE}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\$(uuidgen)?api-version=2020-10-01" \\
    --body '{"properties":{"principalId":"<your-or-sp-objectId>","roleDefinitionId":"${ROLE_DEF_ID}","requestType":"SelfActivate","justification":"apply <PR#>","scheduleInfo":{"startDateTime":"<now>","expiration":{"type":"AfterDuration","duration":"PT${MAX_ACTIVATION_HOURS}H"}}}}'
EOF
  echo

else
  # FALLBACK — permanent Contributor @ RG scope (no P2). RG-scoped, idempotent.
  echo "Assigning PERMANENT ${ROLE_NAME} to the group at RG scope (fallback, no P2)..."
  if az role assignment list --assignee "${GROUP_ID}" --scope "${RG_SCOPE}" \
        --role "${ROLE_NAME}" --query "[0].id" -o tsv | grep -q .; then
    echo "  [skip] ${ROLE_NAME} already assigned at ${RG_SCOPE}."
  else
    az role assignment create --assignee-object-id "${GROUP_ID}" \
      --assignee-principal-type Group --role "${ROLE_NAME}" --scope "${RG_SCOPE}" >/dev/null
    echo "  [done] permanent ${ROLE_NAME} assigned at ${RG_SCOPE}."
  fi
  echo
  echo "  COMPENSATING CONTROLS active (ADR-014): RG-scope only (never subscription);"
  echo "  the HCP apply approval gate (ADR-013) is an independent second control before any"
  echo "  apply; HCP federated subjects are workspace/run-phase scoped (ADR-007); all role"
  echo "  activity is audit-logged. Schedule a quarterly access review of the group."
  echo
fi

# -----------------------------------------------------------------------------
# VERIFY — assert the grant matches the selected mode.
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
STANDING="$(az role assignment list --assignee "${GROUP_ID}" --scope "${RG_SCOPE}" \
  --role "${ROLE_NAME}" --query "length(@)" -o tsv 2>/dev/null || echo 0)"

if [[ "${PIM_MODE}" == "pim" ]]; then
  echo "Eligible role schedules for the group at ${RG_NAME}:"
  az rest --method get \
    --url "https://management.azure.com${RG_SCOPE}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&\$filter=principalId+eq+'${GROUP_ID}'" \
    --query "value[].{role:properties.expandedProperties.roleDefinition.displayName, scope:properties.expandedProperties.scope.displayName}" -o table 2>/dev/null || true
  echo
  if [[ "${STANDING}" == "0" ]]; then
    echo "PASS: no PERMANENT ${ROLE_NAME} on the group — elevation is eligible-only (ADR-014)."
  else
    echo "FAIL: group holds ${STANDING} permanent ${ROLE_NAME} assignment(s). Convert to eligible." >&2
    exit 1
  fi
else
  # In fallback mode a permanent RG-scoped Contributor is EXPECTED; assert it exists
  # and assert there is NO broader (subscription-scope) grant.
  if [[ "${STANDING}" != "0" ]]; then
    echo "PASS: permanent ${ROLE_NAME} present at RG scope (fallback, expected)."
  else
    echo "FAIL: expected a permanent ${ROLE_NAME} grant at ${RG_SCOPE} but found none." >&2
    exit 1
  fi
  BROAD="$(az role assignment list --assignee "${GROUP_ID}" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    --role "${ROLE_NAME}" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
  if [[ "${BROAD}" == "0" ]]; then
    echo "PASS: no subscription-scope ${ROLE_NAME} — grant is RG-scoped only (least privilege)."
  else
    echo "FAIL: group holds ${BROAD} subscription-scope ${ROLE_NAME} assignment(s) — remove them." >&2
    exit 1
  fi
fi

echo
echo "Done. The HCP apply approval gate (ADR-013) remains the second, independent"
echo "control before any apply runs."
