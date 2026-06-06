"""Entra ID JWT validator — the security core of the MCP server (ADR-006).

Validation performed, all fail-closed:

* **signature** — RS256 only, against the tenant JWKS. Pinning ``algorithms=["RS256"]``
  blocks ``alg: none`` and HS256 algorithm-confusion attacks (a token can never be verified
  with a symmetric key derived from the public key).
* **iss** — must equal ``https://login.microsoftonline.com/{tenant}/v2.0`` (v1.0 issuer and
  other tenants are rejected).
* **aud** — must be one of the configured audiences (blocks token-confusion / replay of a
  token minted for a different Azure resource).
* **exp / nbf** — not expired / not before, with a small leeway for clock skew.
* **tid** — must equal the configured tenant (blocks cross-tenant replay).
* **oid, sub** — must be present.
* **azp / appid** — optional caller allow-list (defence in depth, off by default).

Library: PyJWT[crypto]. ADR-006 names ``python-jose``/``msal`` only as examples ("e.g.");
PyJWT is the de-facto, actively maintained standard and ships :class:`PyJWKClient` with
built-in JWKS key caching. JWT verification is never hand-rolled.

The validator is transport-agnostic and hermetically testable: inject ``signing_key_resolver``
to supply keys from a local keypair instead of the network.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

import jwt
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientConnectionError, PyJWKClientError

from .config import AuthSettings
from .errors import (
    InvalidClaimError,
    InvalidSignatureError,
    MalformedTokenError,
    MissingTokenError,
    SigningKeyUnavailableError,
    TokenExpiredError,
)

# Resolver: given the raw JWT, return the public key material accepted by ``jwt.decode``.
# Mirrors ``PyJWKClient.get_signing_key_from_jwt(token).key``.
SigningKeyResolver = Callable[[str], Any]

# Required-presence claims enforced by PyJWT itself (value checks for iss/aud done too).
_REQUIRED_CLAIMS = ["exp", "iss", "aud", "sub"]


@dataclass(frozen=True)
class ValidatedClaims:
    """The trusted subset of a verified token. Never holds the raw token string."""

    subject: str
    object_id: str
    tenant_id: str
    audience: str
    app_id: str | None
    claims: Mapping[str, Any]

    @classmethod
    def from_mapping(cls, claims: Mapping[str, Any]) -> ValidatedClaims:
        aud = claims.get("aud")
        if isinstance(aud, list):
            aud = aud[0] if aud else ""
        return cls(
            subject=str(claims.get("sub", "")),
            object_id=str(claims.get("oid", "")),
            tenant_id=str(claims.get("tid", "")),
            audience=str(aud or ""),
            app_id=claims.get("azp") or claims.get("appid"),
            claims=dict(claims),
        )

    def safe_log_context(self) -> dict[str, Any]:
        """Identifiers safe to log (caller identity, not credentials/token)."""
        return {"oid": self.object_id, "appid": self.app_id, "tid": self.tenant_id}


class EntraTokenValidator:
    """Validates Entra v2.0 JWTs. Construct once and reuse (the JWKS cache is shared)."""

    def __init__(
        self,
        settings: AuthSettings,
        signing_key_resolver: SigningKeyResolver | None = None,
    ) -> None:
        self._settings = settings
        self._resolve_key = signing_key_resolver or self._build_default_resolver(settings)

    @staticmethod
    def _build_default_resolver(settings: AuthSettings) -> SigningKeyResolver:
        client = PyJWKClient(
            settings.jwks_uri,
            cache_keys=True,
            lifespan=settings.jwks_cache_ttl_seconds,
            max_cached_keys=16,
        )

        def resolver(token: str) -> Any:
            try:
                return client.get_signing_key_from_jwt(token).key
            except PyJWKClientConnectionError as exc:
                # Transient: JWKS endpoint unreachable -> 503, fail closed.
                raise SigningKeyUnavailableError(
                    "signing keys are temporarily unavailable"
                ) from exc
            except PyJWKClientError as exc:
                # No key matches the token's kid -> treat as a bad/forged token.
                raise InvalidSignatureError("no signing key matches the token") from exc

        return resolver

    def validate(self, token: str) -> ValidatedClaims:
        """Validate ``token`` end-to-end. Raises :class:`AuthError` on any failure."""
        if not token or not token.strip():
            raise MissingTokenError("no bearer token presented")
        token = token.strip()

        key = self._resolve_key(token)

        try:
            claims = jwt.decode(
                token,
                key=key,
                algorithms=["RS256"],
                audience=list(self._settings.audiences),
                issuer=self._settings.issuer,
                leeway=self._settings.leeway_seconds,
                options={"require": _REQUIRED_CLAIMS},
            )
        except jwt.ExpiredSignatureError as exc:
            raise TokenExpiredError("token has expired") from exc
        except jwt.ImmatureSignatureError as exc:
            raise InvalidClaimError("nbf", "token is not yet valid") from exc
        except jwt.InvalidAudienceError as exc:
            raise InvalidClaimError("aud", "token audience is not accepted") from exc
        except jwt.InvalidIssuerError as exc:
            raise InvalidClaimError("iss", "token issuer is not accepted") from exc
        except jwt.MissingRequiredClaimError as exc:
            raise InvalidClaimError(exc.claim, f"missing required claim: {exc.claim}") from exc
        except jwt.InvalidAlgorithmError as exc:
            # alg: none, HS256, etc. — only RS256 is allowed.
            raise InvalidSignatureError("token algorithm is not allowed") from exc
        except jwt.InvalidSignatureError as exc:
            raise InvalidSignatureError("token signature is invalid") from exc
        except jwt.DecodeError as exc:
            raise MalformedTokenError("token could not be decoded") from exc
        except jwt.InvalidTokenError as exc:
            raise MalformedTokenError("token failed validation") from exc

        self._verify_custom_claims(claims)
        return ValidatedClaims.from_mapping(claims)

    def _verify_custom_claims(self, claims: Mapping[str, Any]) -> None:
        """Checks PyJWT cannot express: v2.0 marker, tenant pin, oid, caller allow-list."""
        version = claims.get("ver")
        if version is not None and version != "2.0":
            raise InvalidClaimError("ver", "only Entra v2.0 tokens are accepted")

        tenant_id = claims.get("tid")
        if not tenant_id:
            raise InvalidClaimError("tid", "missing tenant id claim")
        if tenant_id != self._settings.tenant_id:
            raise InvalidClaimError("tid", "token was issued for a different tenant")

        if not claims.get("oid"):
            raise InvalidClaimError("oid", "missing object id claim")

        allowed = self._settings.allowed_app_ids
        if allowed:
            app_id = claims.get("azp") or claims.get("appid")
            if app_id not in allowed:
                raise InvalidClaimError("azp", "calling application is not allow-listed")
