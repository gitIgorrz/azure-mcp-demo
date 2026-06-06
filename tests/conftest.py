"""Shared fixtures for the auth tests.

All tests are hermetic: a local RSA keypair stands in for Entra's signing keys, and the
validator's signing-key resolver is injected to return that key — no network, no real tenant.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth.config import AuthSettings
from app.auth.validator import EntraTokenValidator

TENANT_ID = "11111111-1111-1111-1111-111111111111"
AUDIENCE = "api://22222222-2222-2222-2222-222222222222"
OTHER_TENANT = "99999999-9999-9999-9999-999999999999"
ISSUER = f"https://login.microsoftonline.com/{TENANT_ID}/v2.0"
KID = "test-key-1"


@pytest.fixture(scope="session")
def rsa_private_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session")
def private_pem(rsa_private_key: rsa.RSAPrivateKey) -> bytes:
    return rsa_private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


@pytest.fixture(scope="session")
def public_key(rsa_private_key: rsa.RSAPrivateKey):
    return rsa_private_key.public_key()


@pytest.fixture
def settings() -> AuthSettings:
    return AuthSettings(tenant_id=TENANT_ID, audiences=(AUDIENCE,))


@pytest.fixture
def resolver(public_key) -> Callable[[str], Any]:
    """Injected signing-key resolver: always returns the test public key."""

    def _resolve(_token: str) -> Any:
        return public_key

    return _resolve


@pytest.fixture
def validator(settings: AuthSettings, resolver) -> EntraTokenValidator:
    return EntraTokenValidator(settings, signing_key_resolver=resolver)


@pytest.fixture
def make_token(private_pem: bytes) -> Callable[..., str]:
    """Factory producing signed JWTs. Override claims/headers/algorithm/key per test."""

    def _make(
        *,
        claims: Mapping[str, Any] | None = None,
        algorithm: str = "RS256",
        key: Any = None,
        kid: str | None = KID,
        include: tuple[str, ...] = ("exp", "iss", "aud", "sub", "oid", "tid", "ver"),
    ) -> str:
        now = int(time.time())
        base: dict[str, Any] = {
            "iss": ISSUER,
            "aud": AUDIENCE,
            "sub": "subject-abc",
            "oid": "object-id-123",
            "tid": TENANT_ID,
            "ver": "2.0",
            "iat": now,
            "nbf": now,
            "exp": now + 3600,
        }
        payload = {k: v for k, v in base.items() if k in include or k in ("iat", "nbf")}
        if claims:
            payload.update(claims)
            # Allow tests to delete a claim by passing it as None.
            payload = {k: v for k, v in payload.items() if v is not None}

        signing_key: Any
        if algorithm == "none":
            signing_key = None
        elif key is not None:
            signing_key = key
        elif algorithm.startswith("HS"):
            signing_key = "shared-secret"
        else:
            signing_key = private_pem

        headers = {"kid": kid} if kid else {}
        return jwt.encode(payload, signing_key, algorithm=algorithm, headers=headers)

    return _make
