"""Health MCP tool — reports server liveness to MCP clients."""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP


def register(mcp: FastMCP) -> None:
    @mcp.tool()
    def health() -> dict[str, str]:
        """Return server liveness status. Use this to verify the MCP server is reachable."""
        return {"status": "ok", "service": "azure-mcp-demo"}
