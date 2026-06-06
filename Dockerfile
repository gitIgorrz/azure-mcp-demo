# azure-mcp-demo — multi-stage, non-root container image.
#
# Digest pinning (ADR guardrail 8)
# ---------------------------------
# Pass --build-arg PYTHON_IMAGE=python:3.12-slim@sha256:<digest> at build time.
# Phase 6 CI resolves the digest automatically on each build:
#   digest=$(docker buildx imagetools inspect python:3.12-slim --format '{{.Manifest.Digest}}')
#   docker build --build-arg PYTHON_IMAGE=python:3.12-slim@${digest} .
#
# For local development, the default (undigested tag) is intentionally allowed.
ARG PYTHON_IMAGE=python:3.12-slim

# ---------------------------------------------------------------------------
# Stage 1 — builder: install Python dependencies into an isolated prefix.
# ---------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

# Upgrade pip before installing any packages.
RUN pip install --no-cache-dir --upgrade pip

WORKDIR /build

# Copy only the requirements file first — maximises Docker layer cache hits.
COPY app/requirements.txt ./

# Install into /install so the final stage can COPY only the package tree.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2 — final: minimal runtime image, non-root user.
# ---------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS final

# Create a dedicated non-root user/group (uid/gid 65532).
# addgroup/adduser are available on Debian-based slim images.
RUN addgroup --gid 65532 appgroup \
 && adduser --uid 65532 --gid 65532 \
            --no-create-home --disabled-password --gecos "" appuser

WORKDIR /app

# Copy the pre-installed dependency tree from the builder stage.
COPY --from=builder /install /usr/local

# Copy the application package.  Tests, scripts, and Terraform are excluded
# via .dockerignore to keep the image lean.
COPY app/ ./app/
COPY pyproject.toml ./

# Install the package metadata only (deps are already present; no re-download).
RUN pip install --no-cache-dir --no-deps .

# Switch to non-root for all subsequent instructions and at runtime.
USER appuser

EXPOSE 8080

# Container health check — probes the unauthenticated /health endpoint.
# start-period gives uvicorn time to load the auth config and open the JWKS cache.
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:8080/health').read()" \
        || exit 1

# Run via uvicorn using the create_app factory so auth config is validated at startup.
# --workers 1: Container Apps scales horizontally; vertical scaling is not needed.
CMD ["uvicorn", "app.server:create_app", \
     "--factory", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "1", \
     "--log-level", "info"]
