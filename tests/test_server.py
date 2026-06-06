"""Smoke tests for the server entrypoint (app/server.py).

The hermetic auth tests never import the server module, so they cannot catch
import-time / startup failures — an invalid FastMCP constructor argument, a broken
tool registration, or mis-wired auth config. The Container App crash-loops on any
of these, so these tests exercise the real startup path:

* importing the module (builds the FastMCP instance + registers tools), and
* create_app() (validates auth config, builds the full ASGI stack), and
* a request through the middleware to the unauthenticated /health route.
"""

from __future__ import annotations

import importlib

import pytest

# Any well-formed GUID satisfies the tenant-id validation in app.auth.config.
_VALID_TENANT = "00000000-0000-0000-0000-000000000000"
_VALID_AUDIENCE = "api://00000000-0000-0000-0000-000000000000"


def test_server_module_imports():
    """Importing app.server builds the FastMCP instance and registers every tool.

    Regression guard for FastMCP being constructed with an unsupported kwarg.
    """
    server = importlib.import_module("app.server")
    assert server._mcp is not None


def test_create_app_builds_with_valid_env(monkeypatch):
    """create_app() wires the full ASGI stack when required env vars are present."""
    monkeypatch.setenv("MCP_TENANT_ID", _VALID_TENANT)
    monkeypatch.setenv("MCP_AUDIENCE", _VALID_AUDIENCE)
    server = importlib.import_module("app.server")
    app_obj = server.create_app()
    assert callable(app_obj)  # ASGI application


def test_create_app_fails_closed_without_config(monkeypatch):
    """Missing required auth config must fail fast at startup (no silent misconfig)."""
    monkeypatch.delenv("MCP_TENANT_ID", raising=False)
    monkeypatch.delenv("MCP_AUDIENCE", raising=False)
    from app.auth.errors import AuthConfigError

    server = importlib.import_module("app.server")
    with pytest.raises(AuthConfigError):
        server.create_app()


def test_health_endpoint_unauthenticated(monkeypatch):
    """GET /health passes through the auth middleware (exempt) and returns ok."""
    from starlette.testclient import TestClient

    monkeypatch.setenv("MCP_TENANT_ID", _VALID_TENANT)
    monkeypatch.setenv("MCP_AUDIENCE", _VALID_AUDIENCE)
    server = importlib.import_module("app.server")
    with TestClient(server.create_app()) as client:
        resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
