import os
from typing import Iterable

import jwt
from jwt import PyJWKClient
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

# INFO: Public: landing page, OpenAPI docs/schema, health check.
DEFAULT_OPEN_PATHS: tuple[str, ...] = (
    "/",
    "/api",
    "/api.html",
    "/healthz",
    "/_mgmt/ping",
    "/info/version",
)


class JWTAuthMiddleware(BaseHTTPMiddleware):
    """Validates a Supabase-issued JWT (RS256/ES256 via JWKS) on the
       Authorization header.

       Expects: Authorization: Bearer <token>
    """

    def __init__(
        self,
        app: ASGIApp,
        *,
        jwks_url: str,
        audience: str | None = "authenticated",
        issuer: str | None = None,
        open_paths: Iterable[str] = DEFAULT_OPEN_PATHS,
        jwks_cache_ttl_seconds: int = 3600,
    ) -> None:
        super().__init__(app)
        self.audience = audience
        self.issuer = issuer
        self.open_paths = set(open_paths)
        # INFO: PyJWKClient caches fetched keys in-memory and refetches on cache miss
        # (e.g. unseen kid, expected after Supabase rotates keys).
        self._jwk_client = PyJWKClient(jwks_url, cache_keys=True, lifespan=jwks_cache_ttl_seconds)

    async def dispatch(self, request: Request, call_next):
        if request.method == "OPTIONS" or request.url.path in self.open_paths:
            return await call_next(request)

        auth_header = request.headers.get("authorization")
        if not auth_header or not auth_header.lower().startswith("bearer "):
            return JSONResponse(
                {"detail": "Missing or malformed Authorization header"},
                status_code=401,
            )

        token = auth_header.split(" ", 1)[1].strip()

        try:
            signing_key = self._jwk_client.get_signing_key_from_jwt(token)
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256", "ES256"],
                audience=self.audience,
                issuer=self.issuer,
                options={"require": ["exp", "sub"]},
            )
        except jwt.ExpiredSignatureError:
            return JSONResponse({"detail": "Token expired"}, status_code=401)
        except jwt.PyJWKClientError as exc:
            # e.g. unknown kid, JWKS endpoint unreachable
            return JSONResponse({"detail": f"Could not verify token: {exc}"}, status_code=401)
        except jwt.InvalidTokenError as exc:
            return JSONResponse({"detail": f"Invalid token: {exc}"}, status_code=401)

        request.state.user = payload
        return await call_next(request)


def get_jwt_middleware_kwargs() -> dict | None:
    """Build kwargs for the middleware from environment variables.

    Returns None if auth is disabled, so app.py can skip registration cleanly.
    """
    if os.environ.get("ENABLE_JWT_AUTH", "false").lower() not in ("true", "1", "yes"):
        return None

    jwks_url = os.environ.get("JWKS_URL", None)
    
    if not jwks_url:
        raise ValueError("Missing required JWKS url environment variable!")

    return {
        "jwks_url": jwks_url,
        "audience": os.environ.get("JWT_AUDIENCE", "authenticated"),
        "issuer": os.environ.get("JWT_ISSUER"),
    }
