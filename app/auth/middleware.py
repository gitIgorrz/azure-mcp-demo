"""Pure-ASGI middleware that enforces Entra JWT auth on the HTTP transport (ADR-006).

Why pure ASGI (no Starlette ``BaseHTTPMiddleware``): the official MCP SDK exposes a Streamable-
HTTP ASGI app; wrapping it directly keeps this layer framework-light and avoids
``BaseHTTPMiddleware``'s streaming pitfalls. Phase 4 wires it as the outermost layer of the
HTTP app so **no tool logic can run before validation**.

On success the verified :class:`ValidatedClaims` are placed on ``scope["state"]["auth"]``
(readable downstream as ``request.state.auth``). On failure the request is short-circuited
with a 401 (or 503) bearer-error response and a ``WWW-Authenticate`` challenge; failures are
logged at WARNING **without the token**.

The stdio transport (local dev only, ADR-010) does not use this middleware and must never be
exposed remotely.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Awaitable, Callable, Iterable

from .errors import AuthError, MissingTokenError
from .validator import EntraTokenValidator

logger = logging.getLogger("azure_mcp_demo.auth")

Scope = dict
Receive = Callable[[], Awaitable[dict]]
Send = Callable[[dict], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]


class EntraAuthMiddleware:
    """Gate every HTTP request behind :class:`EntraTokenValidator`.

    ``exempt_paths`` lets the operator leave unauthenticated paths open (e.g. a container
    liveness/readiness probe). It defaults to empty so auth is mandatory unless explicitly
    relaxed; Phase 4 sets the probe path here.
    """

    def __init__(
        self,
        app: ASGIApp,
        validator: EntraTokenValidator,
        exempt_paths: Iterable[str] = (),
    ) -> None:
        self.app = app
        self.validator = validator
        self.exempt_paths = frozenset(exempt_paths)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            # Lifespan / websocket pass through unchanged.
            await self.app(scope, receive, send)
            return

        if scope.get("path") in self.exempt_paths:
            await self.app(scope, receive, send)
            return

        try:
            token = _bearer_token(scope.get("headers") or [])
            if token is None:
                raise MissingTokenError("missing or malformed Authorization header")
            claims = self.validator.validate(token)
        except AuthError as exc:
            _log_failure(scope, exc)
            await _send_challenge(send, exc)
            return

        scope.setdefault("state", {})["auth"] = claims
        logger.debug("auth accepted: %s", claims.safe_log_context())
        await self.app(scope, receive, send)


def _bearer_token(headers: Iterable[tuple[bytes, bytes]]) -> str | None:
    """Extract the bearer token from raw ASGI headers, scheme matched case-insensitively."""
    for name, value in headers:
        if name.lower() == b"authorization":
            try:
                scheme, _, credentials = value.decode("latin-1").partition(" ")
            except UnicodeDecodeError:
                return None
            if scheme.lower() == "bearer" and credentials.strip():
                return credentials.strip()
            return None
    return None


async def _send_challenge(send: Send, exc: AuthError) -> None:
    body = json.dumps({"error": exc.error_code, "error_description": exc.reason}).encode()
    headers = [
        (b"content-type", b"application/json"),
        (b"content-length", str(len(body)).encode()),
    ]
    if exc.status_code == 401:
        # RFC 6750 bearer challenge. reason text is a fixed, quote-free constant.
        challenge = f'Bearer error="{exc.error_code}", error_description="{exc.reason}"'
        headers.append((b"www-authenticate", challenge.encode("latin-1")))
    await send({"type": "http.response.start", "status": exc.status_code, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def _log_failure(scope: Scope, exc: AuthError) -> None:
    client = scope.get("client")
    client_host = client[0] if client else "unknown"
    # Never log the token or Authorization header — only the reason and request context.
    logger.warning(
        "auth rejected (%s): %s [path=%s client=%s]",
        exc.error_code,
        exc.reason,
        scope.get("path", "?"),
        client_host,
    )
