"""Tests for EntraAuthMiddleware — the ASGI gate in front of the MCP HTTP transport.

Starlette is used purely as a test harness; the middleware itself is framework-free pure ASGI.
"""

from __future__ import annotations

import pytest

from app.auth.errors import SigningKeyUnavailableError
from app.auth.middleware import EntraAuthMiddleware
from app.auth.validator import EntraTokenValidator

starlette = pytest.importorskip("starlette")
from starlette.applications import Starlette  # noqa: E402
from starlette.requests import Request  # noqa: E402
from starlette.responses import JSONResponse  # noqa: E402
from starlette.routing import Route  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402


def _build_app(validator: EntraTokenValidator, exempt_paths=()) -> TestClient:
    async def whoami(request: Request) -> JSONResponse:
        claims = request.scope["state"]["auth"]
        return JSONResponse({"sub": claims.subject, "oid": claims.object_id})

    async def health(_request: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    app = Starlette(routes=[Route("/whoami", whoami), Route("/healthz", health)])
    app.add_middleware(
        EntraAuthMiddleware, validator=validator, exempt_paths=exempt_paths
    )
    return TestClient(app)


def test_valid_token_reaches_downstream(validator, make_token):
    client = _build_app(validator)
    resp = client.get("/whoami", headers={"Authorization": f"Bearer {make_token()}"})
    assert resp.status_code == 200
    assert resp.json() == {"sub": "subject-abc", "oid": "object-id-123"}


def test_missing_header_returns_401_with_challenge(validator):
    client = _build_app(validator)
    resp = client.get("/whoami")
    assert resp.status_code == 401
    assert resp.headers["www-authenticate"].startswith("Bearer")
    assert resp.json()["error"] == "invalid_request"


def test_non_bearer_scheme_returns_401(validator):
    client = _build_app(validator)
    resp = client.get("/whoami", headers={"Authorization": "Basic abc123"})
    assert resp.status_code == 401


def test_invalid_token_returns_401(validator):
    client = _build_app(validator)
    resp = client.get("/whoami", headers={"Authorization": "Bearer not-a-jwt"})
    assert resp.status_code == 401
    assert resp.headers["www-authenticate"].startswith("Bearer")


def test_exempt_path_skips_auth(validator):
    client = _build_app(validator, exempt_paths=("/healthz",))
    resp = client.get("/healthz")  # no Authorization header
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_signing_key_outage_returns_503(settings):
    def failing_resolver(_token):
        raise SigningKeyUnavailableError("jwks down")

    validator = EntraTokenValidator(settings, signing_key_resolver=failing_resolver)
    client = _build_app(validator)
    # Any syntactically present bearer triggers validation, which hits the resolver.
    resp = client.get("/whoami", headers={"Authorization": "Bearer something"})
    assert resp.status_code == 503
    assert "www-authenticate" not in resp.headers  # only 401 carries the challenge
