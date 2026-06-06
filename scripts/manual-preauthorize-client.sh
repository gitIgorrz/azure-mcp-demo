#!/usr/bin/env bash
# =============================================================================
# manual-preauthorize-client.sh                                 # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Pre-authorizes a CLIENT application on the MCP server's API app
#        (`app-azure-mcp-demo-api`) for the `access_as_user` delegated scope, so the
#        client can obtain **delegated** tokens for the API WITHOUT an interactive
#        consent prompt. Default client = the **Azure CLI** public client (handy for
#        testing: `az account get-access-token --resource api://<appId>`). Override
#        with `CLIENT_APP_ID=<appId>` for a specific user-facing client (e.g. a custom
#        agent or VS Code's client id).
#
#        App-only agents (daemon / client-credentials) do NOT need this — they use the
#        `mcp.access` **app role** + an appRoleAssignment, not delegated consent.
#
# WHY MANUAL:  modifies an Entra app registration (Application.ReadWrite). Requires
#        **Application Administrator**. Claude never runs these
#        (CLAUDE.md § Destructive-command rules).
#
# SAFETY:  GETs the current `api` object and only ADDS the client, preserving the
#        exposed scopes, the v2.0 token-version setting, and any existing
#        pre-authorized apps. Idempotent; verifies. Run from a BASH shell.
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

API_APP_NAME="app-azure-mcp-demo-api"
SCOPE_VALUE="access_as_user"
# Default client: Microsoft Azure CLI (well-known public-client appId).
CLIENT_APP_ID="${CLIENT_APP_ID:-04b07795-8ddb-461a-bbee-02f9e1bf7b46}"

API_APP_ID="$(az ad app list --display-name "${API_APP_NAME}" --query "[0].appId" -o tsv)"
if [[ -z "${API_APP_ID}" ]]; then
  echo "API app '${API_APP_NAME}' not found. Run manual-server-app-registration.sh first." >&2
  exit 1
fi
API_OBJ="$(az ad app show --id "${API_APP_ID}" --query id -o tsv)"
echo "API app: ${API_APP_NAME} (${API_APP_ID})"
echo "Client:  ${CLIENT_APP_ID}"
echo "Scope:   ${SCOPE_VALUE}"
echo

# Build the updated api object: keep everything, add the client to
# preAuthorizedApplications with the access_as_user scope id (idempotent).
NEW_API="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/applications/${API_OBJ}?\$select=api" \
  | CLIENT_APP_ID="${CLIENT_APP_ID}" SCOPE_VALUE="${SCOPE_VALUE}" python -c '
import sys, json, os
api = json.load(sys.stdin)["api"]
client = os.environ["CLIENT_APP_ID"]
want = os.environ["SCOPE_VALUE"]
scope_id = next((s["id"] for s in api.get("oauth2PermissionScopes", []) if s["value"] == want), None)
if not scope_id:
    sys.stderr.write("scope %r not found on the API\n" % want)
    sys.exit(1)
pa = api.get("preAuthorizedApplications") or []
entry = next((p for p in pa if p.get("appId") == client), None)
if entry is None:
    pa.append({"appId": client, "delegatedPermissionIds": [scope_id]})
elif scope_id not in (entry.get("delegatedPermissionIds") or []):
    entry.setdefault("delegatedPermissionIds", []).append(scope_id)
api["preAuthorizedApplications"] = pa
json.dump({"api": api}, sys.stdout)
')"

az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/${API_OBJ}" \
  --headers "Content-Type=application/json" \
  --body "${NEW_API}" >/dev/null
echo "[done] pre-authorization applied."
echo

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/applications/${API_OBJ}?\$select=api" \
  --query "api.preAuthorizedApplications" -o json
echo
echo "Client ${CLIENT_APP_ID} can now get delegated '${SCOPE_VALUE}' tokens for the API."
echo "Test:  az account get-access-token --resource api://${API_APP_ID} --query accessToken -o tsv"
