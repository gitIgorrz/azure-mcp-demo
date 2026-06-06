"""Auth configuration, loaded exclusively from environment variables (ADR-006).

No identifiers are hardcoded. Tenant id and audience are required; everything else has a
safe default. The derived issuer/JWKS URLs are pinned to the **tenant-specific v2.0**
endpoints — never ``common`` — so tokens from other tenants or the v1.0 issuer are rejected.

Environment variables:
    MCP_TENANT_ID              (required)  Entra tenant GUID
    MCP_AUDIENCE               (required)  expected ``aud``; comma-separated to accept more
                                           than one form (e.g. "api://<guid>,<guid>")
    MCP_ALLOWED_APP_IDS        (optional)  comma-separated allow-list of caller app ids
                                           (``azp``/``appid``); defence in depth, off by default
    MCP_JWKS_CACHE_TTL_SECONDS (optional)  JWKS key cache TTL, default 3600, min 60
    MCP_JWT_LEEWAY_SECONDS     (optional)  clock-skew leeway for exp/nbf, default 60, max 300
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field

from .errors import AuthConfigError

# Entra tenant ids and app ids are GUIDs. Validating the format defends against
# misconfiguration injecting arbitrary text into the issuer/JWKS URLs we build below.
_GUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


@dataclass(frozen=True)
class AuthSettings:
    """Immutable auth configuration for :class:`app.auth.validator.EntraTokenValidator`."""

    tenant_id: str
    audiences: tuple[str, ...]
    allowed_app_ids: frozenset[str] = field(default_factory=frozenset)
    jwks_cache_ttl_seconds: int = 3600
    leeway_seconds: int = 60

    @property
    def issuer(self) -> str:
        """The only accepted ``iss`` value (Entra v2.0, tenant-pinned)."""
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_uri(self) -> str:
        """Tenant-specific JWKS endpoint for RS256 signing-key discovery."""
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> AuthSettings:
        """Build settings from environment variables, validating eagerly (fail closed)."""
        env = os.environ if env is None else env

        tenant_id = (env.get("MCP_TENANT_ID") or "").strip()
        if not _GUID_RE.match(tenant_id):
            raise AuthConfigError("MCP_TENANT_ID is required and must be an Entra tenant GUID")

        audiences = tuple(
            a.strip() for a in (env.get("MCP_AUDIENCE") or "").split(",") if a.strip()
        )
        if not audiences:
            raise AuthConfigError("MCP_AUDIENCE is required (the server's expected token aud)")

        allowed_app_ids = frozenset(
            a.strip() for a in (env.get("MCP_ALLOWED_APP_IDS") or "").split(",") if a.strip()
        )
        for app_id in allowed_app_ids:
            if not _GUID_RE.match(app_id):
                raise AuthConfigError(
                    "MCP_ALLOWED_APP_IDS must be a comma-separated list of app-id GUIDs"
                )

        ttl = _int_env(env, "MCP_JWKS_CACHE_TTL_SECONDS", default=3600, minimum=60)
        leeway = _int_env(env, "MCP_JWT_LEEWAY_SECONDS", default=60, minimum=0, maximum=300)

        return cls(
            tenant_id=tenant_id,
            audiences=audiences,
            allowed_app_ids=allowed_app_ids,
            jwks_cache_ttl_seconds=ttl,
            leeway_seconds=leeway,
        )


def _int_env(
    env: Mapping[str, str],
    name: str,
    *,
    default: int,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    raw = env.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except ValueError as exc:
        raise AuthConfigError(f"{name} must be an integer") from exc
    if minimum is not None and value < minimum:
        raise AuthConfigError(f"{name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise AuthConfigError(f"{name} must be <= {maximum}")
    return value
