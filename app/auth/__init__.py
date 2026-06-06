"""Inbound Entra ID (Azure AD) JWT authentication for the MCP server.

Security-critical (Phase 3, Opus). Implements ADR-006: every request to the public HTTPS
MCP endpoint must carry a valid Entra-issued **v2.0** JWT, validated *before* any tool logic
runs. See ``docs/auth-contract.md`` for the caller-facing contract.

Public surface:
    AuthSettings              configuration loaded from environment variables
    EntraTokenValidator       fail-closed JWT validator (signature + claims)
    ValidatedClaims           the trusted subset of a verified token
    EntraAuthMiddleware       pure-ASGI middleware that gates the HTTP transport
    AuthError (+ subclasses)  validation failures (map to HTTP 401 / 503)
    AuthConfigError           startup misconfiguration (not a request failure)
"""

from .config import AuthSettings
from .errors import (
    AuthConfigError,
    AuthError,
    InvalidClaimError,
    InvalidSignatureError,
    MalformedTokenError,
    MissingTokenError,
    SigningKeyUnavailableError,
    TokenExpiredError,
)
from .middleware import EntraAuthMiddleware
from .validator import EntraTokenValidator, ValidatedClaims

__all__ = [
    "AuthConfigError",
    "AuthError",
    "AuthSettings",
    "EntraAuthMiddleware",
    "EntraTokenValidator",
    "InvalidClaimError",
    "InvalidSignatureError",
    "MalformedTokenError",
    "MissingTokenError",
    "SigningKeyUnavailableError",
    "TokenExpiredError",
    "ValidatedClaims",
]
