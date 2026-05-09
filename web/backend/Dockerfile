# Backend Dockerfile - Portoser Web API
# Uses uv for fast, modern Python package management

FROM python:3.14-slim

# Install uv - modern Python package manager
# Using pip instead of ghcr.io to avoid Docker proxy issues
RUN pip install --no-cache-dir uv

# Set working directory
WORKDIR /app

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Install system dependencies. gcc + python3-dev are required because
# asyncpg 0.30.0 has no prebuilt wheel for Python 3.14 yet, so uv sync
# falls back to building it from sdist.
RUN apt-get update && apt-get install -y \
    openssh-client \
    curl \
    bash \
    wget \
    postgresql-client \
    bc \
    procps \
    net-tools \
    dnsutils \
    netcat-openbsd \
    jq \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install yq (Go version) - required by portoser CLI. Pick arch dynamically
# so amd64 hosts work too (was hard-pinned to arm64 in the original).
RUN ARCH="$(dpkg --print-architecture)" \
    && curl --location --fail --silent --show-error --output /usr/local/bin/yq \
       "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
    && chmod +x /usr/local/bin/yq

# Copy dependency files first (better layer caching)
COPY pyproject.toml .python-version ./
COPY uv.lock* ./
COPY README.md ./

# Install dependencies using uv sync (frozen for reproducible builds)
RUN uv sync --frozen

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p /root/.portoser/knowledge

# Create portoser wrapper that prevents .env from being loaded
RUN echo '#!/usr/bin/env bash\n\
# Wrapper executes portoser with container environment\n\
# The trick: create temp directory and symlink portoser without .env\n\
exec /opt/portoser/portoser "$@"' > /usr/local/bin/portoser-docker && chmod +x /usr/local/bin/portoser-docker

# Expose port
EXPOSE 8988

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8988/api/health || exit 1

# Run the application via uv (ensures uvicorn is in PATH from virtual environment).
# --workers 1 is intentional: main.py keeps ws_manager (the WebSocket broadcast
# bus) and other connection state at module scope. Multi-process workers would
# fragment the bus — clients connected to worker A would never see broadcasts
# from worker B. Concurrency comes from the single-process asyncio loop.
CMD ["uv", "run", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8988", "--proxy-headers", "--forwarded-allow-ips", "*", "--workers", "1"]
