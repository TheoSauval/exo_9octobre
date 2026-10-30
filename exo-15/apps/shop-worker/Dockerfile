# syntax=docker/dockerfile:1.7
# shop-worker : image de production (multi-stage)
# Le pip.conf du registre interne (avec identifiants) est un secret de build : il n'est jamais écrit dans une couche.
#   docker buildx build --secret id=pipconf,src=pip.conf .

ARG PY_IMAGE=python:3.12.7-slim-bookworm

# ---- builder : dépendances de prod dans un virtualenv
FROM ${PY_IMAGE} AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt ./
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# ---- test : dépendances de dev + lint + tests
FROM builder AS test
COPY requirements-dev.txt ./
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
RUN ruff check . && python -m pytest -q -p no:cacheprovider

# ---- runtime
FROM ${PY_IMAGE} AS runtime
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.description="Worker de commandes Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/christopheutp/docker_ynov_10_26"
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    METRICS_PORT=9100 \
    APP_VERSION=${APP_VERSION}
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin worker
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --from=test /app/worker ./worker
USER 10001:10001
EXPOSE 9100
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
