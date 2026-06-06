#!/usr/bin/env bash
# =============================================================================
# manual-register-resource-providers.sh                         # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Registers the Azure resource providers (RPs) this stack needs, on the
#        subscription. Subscriptions do NOT have these registered by default, so
#        the first Terraform apply fails with:
#          "MissingSubscriptionRegistration: The subscription is not registered to
#           use namespace 'Microsoft.App'."
#        Container Apps need Microsoft.App; diagnostic settings need
#        Microsoft.Insights; Log Analytics needs Microsoft.OperationalInsights;
#        the UAMI needs Microsoft.ManagedIdentity.
#
# WHY MANUAL:  RP registration is a **subscription-wide** prerequisite (not owned by
#        one workspace's Terraform — putting it in TF would let a `destroy` unregister
#        providers other workloads rely on). Requires Contributor on the subscription.
#
# WHO RUNS IT:  gitIgorrz, `az login` (Owner / Contributor on the subscription).
#
# SAFETY:  idempotent (skips already-Registered); registration is asynchronous, so
#          the script waits until each provider reports Registered. Run from a BASH
#          shell (Git Bash / MINGW64).
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

PROVIDERS=(
  Microsoft.App                 # Azure Container Apps (managed environment + app)
  Microsoft.OperationalInsights # Log Analytics workspace
  Microsoft.Insights            # diagnostic settings / monitoring
  Microsoft.ManagedIdentity     # user-assigned managed identity
)

echo "Subscription: $(az account show --query id -o tsv)"
echo "Providers:    ${PROVIDERS[*]}"
echo

# -----------------------------------------------------------------------------
# Kick off registration for any provider not already Registered.
# -----------------------------------------------------------------------------
for ns in "${PROVIDERS[@]}"; do
  state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
  if [[ "$state" == "Registered" ]]; then
    echo "[skip] $ns already Registered."
  else
    echo "[register] $ns (was: $state)"
    az provider register --namespace "$ns" >/dev/null
  fi
done
echo

# -----------------------------------------------------------------------------
# Wait for each to reach Registered (async; usually 1–3 minutes).
# -----------------------------------------------------------------------------
echo "Waiting for registration to complete..."
for ns in "${PROVIDERS[@]}"; do
  state=""
  for _ in $(seq 1 30); do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo unknown)"
    [[ "$state" == "Registered" ]] && break
    sleep 10
  done
  if [[ "$state" == "Registered" ]]; then
    echo "  $ns: Registered"
  else
    echo "  $ns: still '$state' after waiting — re-run this script in a minute." >&2
  fi
done
echo

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
az provider list \
  --query "[?namespace=='Microsoft.App' || namespace=='Microsoft.OperationalInsights' || namespace=='Microsoft.Insights' || namespace=='Microsoft.ManagedIdentity'].{provider:namespace, state:registrationState}" \
  -o table
echo
echo "Done. Re-run the errored apply in HCP (Actions → Start new run, or Retry). The"
echo "resources already in state (RG, UAMI, Log Analytics, budget) are kept; the run"
echo "creates the remaining ones (Container App env + app, diagnostics)."
