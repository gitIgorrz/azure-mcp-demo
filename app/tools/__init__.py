"""MCP tool registration.

Call :func:`register_all` once during server startup to register every tool
against the shared :class:`~mcp.server.fastmcp.FastMCP` instance.
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from app.tools.azure_tools import register as _register_azure
from app.tools.health import register as _register_health


def register_all(mcp: FastMCP) -> None:
    """Register all MCP tools against *mcp*."""
    _register_health(mcp)
    _register_azure(mcp)


__all__ = ["register_all"]
