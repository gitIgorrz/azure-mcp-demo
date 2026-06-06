"""Auth error hierarchy.

Two distinct failure classes, kept separate on purpose:

* :class:`AuthConfigError` — the *server* is misconfigured (e.g. no tenant id). This is a
  startup/programming error, never the caller's fault, and must surface loudly (fail to
  start) rather than be reported as a 401.
* :class:`AuthError` — a *request* could not be authenticated. These map to HTTP 401 (or
  503 when the server temporarily cannot reach the signing keys). Their ``reason`` text is
  deliberately generic and **never contains the token or any secret**, so it is safe to log
  and to return to the caller.
"""

from __future__ import annotations


class AuthConfigError(Exception):
    """The auth subsystem is misconfigured. Raised at startup; never per-request."""


class AuthError(Exception):
    """Base class for inbound-request authentication failures (fail closed).

    ``reason`` is a short, non-sensitive description safe to log and to return to the
    caller. ``status_code`` and ``error_code`` drive the HTTP response (RFC 6750 bearer
    error semantics).
    """

    status_code: int = 401
    error_code: str = "invalid_token"

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class MissingTokenError(AuthError):
    """No bearer token was presented (missing/!malformed Authorization header)."""

    error_code = "invalid_request"


class MalformedTokenError(AuthError):
    """The token is not a well-formed JWT and could not be decoded."""


class InvalidSignatureError(AuthError):
    """Signature verification failed, the algorithm was not RS256, or no key matched."""


class TokenExpiredError(AuthError):
    """The token is expired (``exp`` in the past, beyond the configured leeway)."""


class InvalidClaimError(AuthError):
    """A required claim is missing or has an unexpected value (aud/iss/tid/oid/...)."""

    def __init__(self, claim: str, reason: str | None = None) -> None:
        super().__init__(reason or f"invalid or missing claim: {claim}")
        self.claim = claim


class SigningKeyUnavailableError(AuthError):
    """The JWKS endpoint could not be reached, so the token cannot be validated now.

    Distinct from a bad token: this is a transient server-side condition. We still fail
    closed (no tool runs), but signal 503 so callers retry rather than assuming their token
    is invalid.
    """

    status_code = 503
    error_code = "temporarily_unavailable"
