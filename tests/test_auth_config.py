"""Tests for AuthSettings.from_env — fail-closed configuration loading."""

from __future__ import annotations

import pytest

from app.auth.config import AuthSettings
from app.auth.errors import AuthConfigError

from .conftest import TENANT_ID

AUD = "api://22222222-2222-2222-2222-222222222222"


def test_minimal_valid_env():
    s = AuthSettings.from_env({"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD})
    assert s.tenant_id == TENANT_ID
    assert s.audiences == (AUD,)
    assert s.issuer == f"https://login.microsoftonline.com/{TENANT_ID}/v2.0"
    assert s.jwks_uri.endswith("/discovery/v2.0/keys")
    assert s.jwks_cache_ttl_seconds == 3600
    assert s.leeway_seconds == 60
    assert s.allowed_app_ids == frozenset()


def test_missing_tenant_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env({"MCP_AUDIENCE": AUD})


def test_non_guid_tenant_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env({"MCP_TENANT_ID": "contoso.onmicrosoft.com", "MCP_AUDIENCE": AUD})


def test_missing_audience_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env({"MCP_TENANT_ID": TENANT_ID})


def test_multiple_audiences_parsed():
    s = AuthSettings.from_env(
        {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": f"{AUD}, 22222222-2222-2222-2222-222222222222"}
    )
    assert s.audiences == (AUD, "22222222-2222-2222-2222-222222222222")


def test_allowed_app_ids_parsed():
    app_id = "33333333-3333-3333-3333-333333333333"
    s = AuthSettings.from_env(
        {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD, "MCP_ALLOWED_APP_IDS": app_id}
    )
    assert s.allowed_app_ids == frozenset({app_id})


def test_non_guid_allowed_app_id_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env(
            {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD, "MCP_ALLOWED_APP_IDS": "some-app"}
        )


def test_ttl_below_minimum_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env(
            {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD, "MCP_JWKS_CACHE_TTL_SECONDS": "10"}
        )


def test_leeway_above_maximum_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env(
            {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD, "MCP_JWT_LEEWAY_SECONDS": "9999"}
        )


def test_non_integer_ttl_raises():
    with pytest.raises(AuthConfigError):
        AuthSettings.from_env(
            {"MCP_TENANT_ID": TENANT_ID, "MCP_AUDIENCE": AUD, "MCP_JWKS_CACHE_TTL_SECONDS": "soon"}
        )
