"""MCP server entrypoint — Phase 4.

Startup wires the ASGI stack in this order (outermost → innermost):

    EntraAuthMiddleware          ← validates every request except /health
        Starlette router
            GET /health          ← unauthenticated probe endpoint (container liveness)
            Mount /              ← FastMCP Streamable-HTTP ASGI app

Auth config is validated eagerly at startup via AuthSettings.from_env() so the
container fails fast if required env vars (MCP_TENANT_ID, MCP_AUDIENCE) are absent.

Transports
----------
HTTP (production): uvicorn app.server:create_app --factory
stdio (local dev): python -m app.server --stdio   (or MCP_TRANSPORT=stdio)
"""

from __future__ import annotations

import logging
import os

from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from app.auth.config import AuthSettings
from app.auth.middleware import EntraAuthMiddleware
from app.auth.validator import EntraTokenValidator
from app.tools import register_all

logger = logging.getLogger("azure_mcp_demo.server")

# ---------------------------------------------------------------------------
# Shared FastMCP instance — created once, tools registered at import time.
# ---------------------------------------------------------------------------
_mcp = FastMCP(
    "azure-mcp-demo",
    instructions=(
        "Read-only Azure inventory MCP server. "
        "Requires a valid Entra-issued v2.0 JWT on every request."
    ),
)

register_all(_mcp)

# ---------------------------------------------------------------------------
# Health probe path — exempt from JWT auth so the container runtime can probe.
# ---------------------------------------------------------------------------
_HEALTH_PATH = "/health"


async def _health_handler(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok", "service": "azure-mcp-demo"})


# ---------------------------------------------------------------------------
# ASGI app factory (called by uvicorn --factory and in tests).
# ---------------------------------------------------------------------------
def create_app():
    """Build and return the fully-wired ASGI application.

    Validates auth config eagerly — the process exits if env vars are missing.
    """
    settings = AuthSettings.from_env()
    validator = EntraTokenValidator(settings)
    logger.info(
        "auth configured: tenant=%s audiences=%s",
        settings.tenant_id,
        settings.audiences,
    )

    inner = Starlette(
        routes=[
            Route(_HEALTH_PATH, _health_handler, methods=["GET"]),
            Mount("/", app=_mcp.streamable_http_app()),
        ]
    )

    return EntraAuthMiddleware(inner, validator, exempt_paths={_HEALTH_PATH})


# ---------------------------------------------------------------------------
# Direct invocation — stdio (local dev) or HTTP via uvicorn.
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys

    transport = os.environ.get("MCP_TRANSPORT", "").lower()
    if transport == "stdio" or "--stdio" in sys.argv:
        # stdio transport: no auth middleware; never expose this remotely.
        logger.info("starting in stdio mode (local dev only — no auth enforced)")
        _mcp.run(transport="stdio")
    else:
        import uvicorn

        port = int(os.environ.get("PORT", "8080"))
        logger.info("starting HTTP server on port %d", port)
        uvicorn.run(create_app(), host="0.0.0.0", port=port, log_level="info")
