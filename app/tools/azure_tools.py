"""Read-only Azure inventory MCP tools (ADR-009).

All tools use DefaultAzureCredential so the same code works with a UAMI in
Container Apps and with az-cli / env-var credentials in local dev.

Scope: the UAMI has Reader at resource-group scope (ADR-009). Azure RBAC
enforces this server-side — the tool code does not need to filter by RG;
it simply returns what the credential can see.

AZURE_SUBSCRIPTION_ID (required env var) scopes Resource Graph queries to
the correct subscription.
"""

from __future__ import annotations

import os
import re
from typing import Any

from mcp.server.fastmcp import FastMCP

# Valid Azure resource-group name characters. Used to prevent KQL injection
# before interpolating the caller-supplied name into a query string.
# Azure allows: alphanumeric, hyphens, underscores, periods, parentheses. Max 90 chars.
# Single/double quotes, backticks, and semicolons are intentionally excluded.
_RG_NAME_RE = re.compile(r"^[a-zA-Z0-9._\-()]{1,90}$")

# Lazy credential singleton — created once, reused across tool calls.
# Tests can monkeypatch `app.tools.azure_tools._credential` to avoid network calls.
_credential: Any = None


def _get_credential() -> Any:
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential

        _credential = DefaultAzureCredential()
    return _credential


def _subscription_id() -> str:
    sub_id = os.environ.get("AZURE_SUBSCRIPTION_ID", "").strip()
    if not sub_id:
        raise RuntimeError("AZURE_SUBSCRIPTION_ID environment variable is required but not set")
    return sub_id


def register(mcp: FastMCP) -> None:
    """Register Azure inventory tools against *mcp*."""

    @mcp.tool()
    def get_subscription() -> dict[str, Any]:
        """Get metadata for the configured Azure subscription.

        Returns subscription id, display name, state, and tenant id.
        Requires AZURE_SUBSCRIPTION_ID to be set.
        """
        from azure.mgmt.subscription import SubscriptionClient

        client = SubscriptionClient(_get_credential())
        sub = client.subscriptions.get(_subscription_id())
        return {
            "subscription_id": sub.subscription_id,
            "display_name": sub.display_name,
            "state": str(sub.state),
            "tenant_id": sub.tenant_id,
        }

    @mcp.tool()
    def list_resource_groups() -> list[dict[str, Any]]:
        """List resource groups visible to the server identity.

        The UAMI has Reader at a specific resource-group scope (ADR-009), so
        Azure RBAC limits the result to only that group without code-level filtering.
        Returns name, location, provisioning state, and tags for each group.
        """
        from azure.mgmt.resource import ResourceManagementClient

        client = ResourceManagementClient(_get_credential(), _subscription_id())
        return [
            {
                "name": rg.name,
                "location": rg.location,
                "provisioning_state": (rg.properties.provisioning_state if rg.properties else None),
                "tags": rg.tags or {},
            }
            for rg in client.resource_groups.list()
        ]

    @mcp.tool()
    def list_resources(resource_group: str | None = None) -> list[dict[str, Any]]:
        """List Azure resources visible to the server identity via Resource Graph.

        Args:
            resource_group: Optional. Filter results to a specific resource group.
                            If omitted, returns all resources visible to the server
                            identity (RBAC-scoped by the UAMI's Reader assignment).
                            Capped at 200 rows when unfiltered.

        Returns name, type, location, resource group, and subscription id per resource.
        Requires AZURE_SUBSCRIPTION_ID to be set.
        """
        if resource_group is not None:
            # Validate before interpolation to prevent KQL injection.
            if not _RG_NAME_RE.match(resource_group):
                raise ValueError(
                    "resource_group must contain only alphanumeric characters, "
                    "hyphens, underscores, periods, or parentheses (max 90 chars)"
                )

        from azure.mgmt.resourcegraph import ResourceGraphClient
        from azure.mgmt.resourcegraph.models import QueryRequest

        if resource_group:
            query = (
                f"Resources | where resourceGroup =~ '{resource_group}' "
                "| project name, type, location, resourceGroup, subscriptionId "
                "| order by type asc, name asc"
            )
        else:
            query = (
                "Resources "
                "| project name, type, location, resourceGroup, subscriptionId "
                "| order by type asc, name asc "
                "| take 200"
            )

        result = ResourceGraphClient(_get_credential()).resources(
            QueryRequest(subscriptions=[_subscription_id()], query=query)
        )
        return result.data or []
