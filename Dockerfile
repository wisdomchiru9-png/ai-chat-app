# syntax=docker/dockerfile:1.6
# Root-level Dockerfile for Render deployment
# This is a wrapper around the backend Dockerfile

FROM python:3.12-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        libpq-dev \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    pip wheel --no-deps --wheel-dir /wheels -r requirements.txt \
 && pip install --prefix=/install --no-cache-dir -r requirements.txt --find-links=/wheels

# ---------- Runtime ---------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpq5 \
        curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install /usr/local

COPY backend/main.py ./
COPY backend/.env.example ./.env
COPY backend/alembic.ini ./
COPY backend/alembic ./alembic

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8000}/" || exit 1'

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1"]
