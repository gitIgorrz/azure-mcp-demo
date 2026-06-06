# Connecting MCP clients to azure-mcp-demo

The MCP server runs on public HTTPS with Entra JWT authentication (ADR-003, ADR-006).
Any spec-compliant MCP client can connect. This page covers four client types.

Full auth contract: [`docs/auth-contract.md`](auth-contract.md).
Server endpoint: `https://<container-app-fqdn>/mcp` (get the FQDN from `terraform output container_app_fqdn`).

---

## Before you connect — get a token

Every client needs a **v2.0 Entra access token** scoped to this server's audience.
The audience is the value of `MCP_AUDIENCE` set in the container (configured via
`var.mcp_audience` in Terraform → HCP workspace variable).

The token must be acquired for **this server's audience**, not Microsoft Graph. Typical scope:
`api://<server-app-id>/.default`

### Authorize the client (one-time)

A token request for a custom API only succeeds once the **calling client** is allowed to obtain
the scope. Two paths:

- **Delegated** (a user signs in — Azure CLI, VS Code, Claude Code): the client app must be
  authorized for the API's `access_as_user` scope. Either **pre-authorize** it (no consent prompt)
  with [`scripts/manual-preauthorize-client.sh`](../scripts/manual-preauthorize-client.sh) — it
  defaults to the Azure CLI public client; set `CLIENT_APP_ID=<appId>` for a different client — or
  let the user **consent** interactively on first sign-in.
- **App-only** (an agent uses its own identity — client credentials): assign the API's
  **`mcp.access` app role** to the agent's service principal, then the agent requests
  `api://<server-app-id>/.default`. No user and no consent prompt.

> **Tenant gotcha (Azure CLI):** sign in to the tenant that **owns the API**, or the request fails
> with `AADSTS500011 … resource principal … was not found`:
>
> ```bash
> az login --tenant <your-tenant-id> --scope "api://<server-app-id>/.default"
> ```
>
> A bare `az login` can land in a different home tenant (common with personal/MSA accounts).

Verify the server is up first:
```bash
curl https://<fqdn>/health
# expected: {"status": "ok", ...}
```

---

## 1. SRE Agent / Azure AI Foundry

Azure AI Foundry's **SRE Agent** (preview) connects to external MCP servers over Streamable-HTTP
using the agent's own managed identity as the caller credential. No client secret is needed.

> **Preview note:** the SRE Agent MCP connector configuration UI and SDK APIs are subject to
> change. Check the current Azure AI Foundry documentation for the latest format.

### Prerequisites

- An Azure AI Foundry project in the same (or a trusted) Entra tenant.
- The SRE Agent's managed identity (or service principal) must be granted the **allow-list
  entry** if `MCP_ALLOWED_APP_IDS` is configured on the server.

### Steps (portal)

1. Open your **Azure AI Foundry project → Agents → [your SRE agent] → Tools**.
2. Add an **MCP server** tool connector.
3. Set **Endpoint URL**: `https://<fqdn>/mcp`
4. Set **Authentication**: Managed Identity (the agent's UAMI or SAMI).
5. The agent runtime acquires a token for the configured audience and passes it as `Authorization: Bearer <token>`.

### Steps (SDK)

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    endpoint="https://<foundry-project>.api.azureml.ms",
    credential=DefaultAzureCredential(),
)

# Add MCP server to agent (preview API — verify current parameter names in SDK docs)
agent = client.agents.create_agent(
    model="gpt-4o",
    name="sre-agent",
    tools=[
        {
            "type": "mcp",
            "mcp": {
                "server_label": "azure-inventory",
                "server_url": "https://<fqdn>/mcp",
                "require_approval": "never",
            },
        }
    ],
)
```

---

## 2. Claude Code (CLI)

Claude Code supports MCP servers via `.claude/mcp.json` (project-scoped) or
`~/.claude.json` (user-scoped).

### Get a token

For interactive use, acquire a token via the Azure CLI:
```bash
# Replace <audience> with your server's configured MCP_AUDIENCE value
az account get-access-token \
  --resource <audience> \
  --query accessToken \
  --output tsv
```

Store it in an environment variable (never in a file):
```bash
export MCP_TOKEN="$(az account get-access-token --resource <audience> --query accessToken --output tsv)"
```

### Project-scoped MCP config

Create `.claude/mcp.json` in your project root (gitignore this if it contains
tenant-specific values):

```json
{
  "mcpServers": {
    "azure-inventory": {
      "type": "http",
      "url": "https://<fqdn>/mcp",
      "headers": {
        "Authorization": "Bearer ${MCP_TOKEN}"
      }
    }
  }
}
```

Claude Code reads `$MCP_TOKEN` from the environment at startup. Set it before launching:
```bash
export MCP_TOKEN="$(az account get-access-token --resource <audience> --query accessToken --output tsv)"
claude
```

### Verify in Claude Code

```
/mcp
```
Should list `azure-inventory` as connected. Then try:
```
What Azure resource groups do I have?
```

---

## 3. VS Code / GitHub Copilot Chat

VS Code supports MCP servers via the Copilot Chat MCP integration (preview).

> **Preview note:** VS Code MCP configuration is an evolving feature. Check the current
> VS Code documentation (`mcp.json` spec) for the latest format and any built-in auth flows.

### Steps

1. Install the [GitHub Copilot](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot-chat) extension (includes MCP support in recent versions).
2. Create or update `.vscode/mcp.json` in your project:

```json
{
  "servers": {
    "azure-inventory": {
      "type": "http",
      "url": "https://<fqdn>/mcp",
      "headers": {
        "Authorization": "Bearer ${input:mcpToken}"
      }
    }
  },
  "inputs": [
    {
      "id": "mcpToken",
      "type": "promptString",
      "description": "Entra access token for the MCP server (az account get-access-token --resource <audience> --query accessToken --output tsv)",
      "password": true
    }
  ]
}
```

3. Open **GitHub Copilot Chat → Agent mode** and select the `azure-inventory` server.
4. VS Code prompts for the token on first use (the `input` block above).

---

## 4. Custom MCP client

Any HTTP client that can send `Authorization: Bearer` headers works with Streamable-HTTP transport.

### Minimal Python example

```python
import asyncio
import os

from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamablehttp_client

SERVER_URL = "https://<fqdn>/mcp"


async def main():
    # Token for the server audience — see "Authorize the client" above. e.g.:
    #   export MCP_TOKEN="$(az account get-access-token \
    #       --resource api://<server-app-id> --query accessToken -o tsv)"
    token = os.environ["MCP_TOKEN"]  # never hardcode
    headers = {"Authorization": f"Bearer {token}"}

    async with streamablehttp_client(SERVER_URL, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("tools:", [t.name for t in tools.tools])
            result = await session.call_tool("list_resource_groups", {})
            print(result.content)


asyncio.run(main())
```

The `streamablehttp_client` handles the Streamable-HTTP session (the `mcp-session-id` exchange and
`Accept` negotiation) for you — which is why a proper client succeeds where a raw `curl` tool call
does not.

### Raw HTTP (curl — for debugging)

```bash
TOKEN="$(az account get-access-token --resource <audience> --query accessToken --output tsv)"

# Initialize. The Accept header MUST include both types (Streamable-HTTP requires it).
# This confirms auth (no token -> 401; valid token -> the MCP layer responds); a full
# tool call needs the SDK's session handling, so use the Python client above for that.
curl -s -X POST "https://<fqdn>/mcp" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-test","version":"0"}}}'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `401 Unauthorized` | Token missing, expired, or wrong audience | Re-acquire token for the correct `--resource` value |
| `401` with `invalid_token` | Wrong tenant, or token is an ID token not an access token | Use `get-access-token`, not `id-token`; confirm tenant matches server's `MCP_TENANT_ID` |
| `AADSTS65001 … consent_required` acquiring the token | The calling client isn't authorized for the API's scope | Pre-authorize it — `scripts/manual-preauthorize-client.sh` (`CLIENT_APP_ID=<id>` for non-CLI) — or consent interactively |
| `AADSTS500011 … resource principal … not found` | Signed into the wrong tenant | `az login --tenant <tenant-id> --scope "api://<server-app-id>/.default"` |
| `503 Service Unavailable` | Server couldn't reach Entra JWKS to validate your token | Transient; retry after a few seconds |
| `curl: (60) SSL certificate problem` | Local dev with self-signed cert | Not applicable — Container Apps provides a trusted cert |
| Connection refused / timeout | Container App scaled to zero (cold start) | Health probe should wake it; wait 5–15 seconds and retry |
| `{"status": "error"}` from `/health` | UAMI or identity not assigned | Verify `AZURE_CLIENT_ID` env var is set and UAMI Reader role assignment exists |

### Check server health

```bash
curl -s https://<fqdn>/health | python -m json.tool
```

Expected:
```json
{
  "status": "ok",
  "identity": {
    "subscription_id": "<guid>",
    "client_id": "<uami-client-id>"
  }
}
```

### Check token claims

Decode without a library:
```bash
TOKEN="..."
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python -m json.tool
```

Verify: `aud` matches `MCP_AUDIENCE`, `iss` contains your tenant ID, `exp` is in the future.
