#!/usr/bin/env bash
# =============================================================================
# manual-server-app-registration.sh                             # RUN MANUALLY
# -----------------------------------------------------------------------------
# WHAT:  Registers the Entra application that REPRESENTS the MCP server as a
#        protected API — i.e. the **audience** (the "resource") that clients
#        request a token for. Its Application ID URI (api://<appId>) and its appId
#        are what an agent/user asks Entra for; the issued token's `aud` claim is
#        what the server validates against MCP_AUDIENCE (ADR-006, app/auth/).
#
#        Without this app registration there is NO valid audience, so no client
#        can ever obtain a token the server will accept. This is the missing link
#        between the identity scripts (which create the CI, Terraform, runtime and
#        elevation identities) and "connecting a client" (docs/connecting-agents.md).
#
#        Tokens are pinned to **v2.0** (api.requestedAccessTokenVersion = 2) so they
#        match the server's v2.0-only validator (tenant-pinned /v2.0 issuer).
#
#        It exposes two ways to call the API, so both client styles work:
#          * delegated scope  `access_as_user`  — interactive/user clients
#            (az CLI user, VS Code, Claude Code) request api://<appId>/access_as_user
#            or api://<appId>/.default
#          * app role         `mcp.access`      — app-only/agent clients using the
#            client-credentials flow request api://<appId>/.default (Entra requires
#            the calling app to hold an app role on the resource for .default to work)
#
# WHY MANUAL:  creates an Entra app registration and exposes an API scope + app role
#        — directory mutations requiring **Application Administrator** (or Global
#        Administrator). Claude never runs these (CLAUDE.md § Destructive-command rules).
#
#        NOTE: like every identity in this project this app holds **NO credentials**.
#        It is a resource/audience definition, not an automation identity — there is
#        no client secret and none is ever created (ADR-005). The verification block
#        asserts zero password credentials.
#
# WHO RUNS IT:  gitIgorrz, `az login` as Application Administrator / Global Admin in
#        the target tenant.
#
# RELATED:  ADR-006 (server-side JWT validation). Feeds Terraform var.mcp_audience
#        (-> container MCP_AUDIENCE) and the <audience> placeholder throughout
#        docs/connecting-agents.md.
#
# RUN ORDER:  early — before the first Terraform apply, because the apply needs
#        var.mcp_audience. It has no dependency on the resource group, so it can run
#        right after manual-gpg-setup.sh.
#
# VERIFY:  asserts identifierUris is set to api://<appId>, requestedAccessTokenVersion
#        is 2, a delegated scope and an app role exist, an SP exists, and there are
#        ZERO password credentials.
# =============================================================================
set -euo pipefail

# Git Bash / MINGW on Windows rewrites arguments that look like Unix paths into
# Windows paths, corrupting them. Harmless on Linux/macOS; safe guard on Windows.
export MSYS_NO_PATHCONV=1

# ---- Configuration (no secrets; identifiers resolved at runtime) ------------
APP_NAME="app-azure-mcp-demo-api"     # the protected-resource (audience) app
DELEGATED_SCOPE="access_as_user"      # delegated (user) permission name
APP_ROLE_VALUE="mcp.access"           # app-only (agent) permission name

TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Tenant:   ${TENANT_ID}"
echo "App name: ${APP_NAME}"
echo

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python -c 'import uuid;print(uuid.uuid4())'; }

# -----------------------------------------------------------------------------
# STEP 1 — Create (or reuse) the resource app registration. No credentials.
#          sign-in audience AzureADMyOrg = single-tenant (this tenant only).
# -----------------------------------------------------------------------------
APP_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)"
if [[ -z "${APP_ID}" ]]; then
  echo "Creating app registration '${APP_NAME}' (single-tenant, no secret)..."
  APP_ID="$(az ad app create --display-name "${APP_NAME}" \
    --sign-in-audience AzureADMyOrg --query appId -o tsv)"
else
  echo "Reusing app registration '${APP_NAME}' (appId ${APP_ID})."
fi
APP_OBJECT_ID="$(az ad app show --id "${APP_ID}" --query id -o tsv)"
echo "  appId (audience GUID): ${APP_ID}"
echo "  app objectId:          ${APP_OBJECT_ID}"
echo

# -----------------------------------------------------------------------------
# STEP 2 — Application ID URI. Idempotent: az is a no-op if already api://<appId>.
# -----------------------------------------------------------------------------
echo "Setting Application ID URI to api://${APP_ID}..."
az ad app update --id "${APP_ID}" --identifier-uris "api://${APP_ID}" >/dev/null
echo

# -----------------------------------------------------------------------------
# STEP 3 — v2.0 tokens + delegated scope + app role, via Graph PATCH.
#          Reuse existing scope/role ids when present (idempotent re-run); only
#          mint new GUIDs the first time so consent/assignments are not orphaned.
# -----------------------------------------------------------------------------
EXISTING_API="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}?\$select=api,appRoles")"

SCOPE_ID="$(echo "${EXISTING_API}" \
  | python -c "import sys,json;a=json.load(sys.stdin).get('api',{}) or {};print(next((s['id'] for s in a.get('oauth2PermissionScopes',[]) if s.get('value')=='${DELEGATED_SCOPE}'),''))")"
[[ -z "${SCOPE_ID}" ]] && SCOPE_ID="$(uuid)"

ROLE_ID="$(echo "${EXISTING_API}" \
  | python -c "import sys,json;d=json.load(sys.stdin);print(next((r['id'] for r in d.get('appRoles',[]) if r.get('value')=='${APP_ROLE_VALUE}'),''))")"
[[ -z "${ROLE_ID}" ]] && ROLE_ID="$(uuid)"

echo "Patching api (v2.0 tokens + scope '${DELEGATED_SCOPE}') and app role '${APP_ROLE_VALUE}'..."
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body "$(cat <<JSON
{
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [
      {
        "id": "${SCOPE_ID}",
        "value": "${DELEGATED_SCOPE}",
        "type": "User",
        "isEnabled": true,
        "adminConsentDisplayName": "Access the azure-mcp-demo MCP server",
        "adminConsentDescription": "Allow the signed-in user to call the azure-mcp-demo MCP server as themselves.",
        "userConsentDisplayName": "Access the MCP server on your behalf",
        "userConsentDescription": "Allow the app to call the azure-mcp-demo MCP server on your behalf."
      }
    ]
  },
  "appRoles": [
    {
      "id": "${ROLE_ID}",
      "value": "${APP_ROLE_VALUE}",
      "displayName": "Call the azure-mcp-demo MCP server (app-only)",
      "description": "Allow a daemon/agent application to call the azure-mcp-demo MCP server using its own identity (client credentials).",
      "allowedMemberTypes": ["Application"],
      "isEnabled": true
    }
  ]
}
JSON
)" >/dev/null
echo

# -----------------------------------------------------------------------------
# STEP 4 — Ensure a service principal exists for the resource app. Required so
#          tokens can be issued for it, app-role assignments can be made, and
#          delegated consent can be granted.
# -----------------------------------------------------------------------------
if [[ -z "$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)" ]]; then
  echo "Creating service principal for the resource app..."
  az ad sp create --id "${APP_ID}" >/dev/null
fi
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id -o tsv)"
echo "  resource SP objectId: ${SP_OBJECT_ID}"
echo

# -----------------------------------------------------------------------------
# GRANTING ACCESS TO CLIENTS (manual, per client — portal or CLI)
# -----------------------------------------------------------------------------
cat <<EOF
---------------------------------------------------------------------------
Set this as the server audience (Terraform var.mcp_audience / MCP_AUDIENCE).
Accept BOTH forms — v2.0 tokens may carry the appId GUID or the api:// URI:

    MCP_AUDIENCE = "api://${APP_ID},${APP_ID}"

Acquire a token (clients):
  * user / interactive:
      az account get-access-token --resource api://${APP_ID} --query accessToken -o tsv
  * app-only / agent (client credentials): first assign the '${APP_ROLE_VALUE}' app
    role to the calling app's service principal, then it requests
      api://${APP_ID}/.default

Grant the app role to an agent's SP (example):
  az rest --method POST \\
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/<AGENT_SP_OBJECT_ID>/appRoleAssignments" \\
    --body '{"principalId":"<AGENT_SP_OBJECT_ID>","resourceId":"${SP_OBJECT_ID}","appRoleId":"${ROLE_ID}"}'

Optionally restrict the server to specific callers via MCP_ALLOWED_APP_IDS
(azp/appid allow-list) — see app/auth/config.py.
---------------------------------------------------------------------------
EOF
echo

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
echo "==== VERIFICATION ===="
APP_JSON="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}?\$select=identifierUris,api,appRoles")"

# JSON is passed via env var (not stdin) because stdin carries the heredoc program.
APP_JSON="${APP_JSON}" python - "$APP_ID" "$DELEGATED_SCOPE" "$APP_ROLE_VALUE" <<'PY'
import os, sys, json
app = json.loads(os.environ["APP_JSON"])
app_id, scope, role = sys.argv[1], sys.argv[2], sys.argv[3]
uris = app.get("identifierUris", [])
api = app.get("api", {}) or {}
ver = api.get("requestedAccessTokenVersion")
scopes = [s.get("value") for s in api.get("oauth2PermissionScopes", [])]
roles = [r.get("value") for r in app.get("appRoles", [])]
ok = True
def check(cond, ok_msg, fail_msg):
    global ok
    print(("PASS: " + ok_msg) if cond else ("FAIL: " + fail_msg))
    ok = ok and cond
check(f"api://{app_id}" in uris, "Application ID URI set.", "Application ID URI missing.")
check(ver == 2, "tokens are v2.0 (requestedAccessTokenVersion=2).", f"token version is {ver}, expected 2.")
check(scope in scopes, f"delegated scope '{scope}' exposed.", f"delegated scope '{scope}' missing.")
check(role in roles, f"app role '{role}' present.", f"app role '{role}' missing.")
sys.exit(0 if ok else 1)
PY

PW_COUNT="$(az ad app credential list --id "${APP_ID}" --query "length(@)" -o tsv)"
if [[ "${PW_COUNT}" == "0" ]]; then
  echo "PASS: resource app has zero password credentials (secretless, ADR-005)."
else
  echo "FAIL: resource app has ${PW_COUNT} password credential(s). Remove them." >&2
  exit 1
fi
echo
echo "Done. Record audience api://${APP_ID} (and appId ${APP_ID}) for var.mcp_audience"
echo "in the HCP workspace — not committed to this repo."
