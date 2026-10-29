# shop-worker : image de production (multi-stage)
# Les dépendances viennent de pypi.org : aucun identifiant de registre dans l'image.

ARG PY_IMAGE=python:3.12.7-slim-bookworm

# ---- builder : dépendances de prod dans un virtualenv
FROM ${PY_IMAGE} AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt ./
RUN pip install -r requirements.txt

# ---- test : dépendances de dev + lint + tests
FROM builder AS test
COPY requirements-dev.txt ./
RUN pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
RUN ruff check . && python -m pytest -q -p no:cacheprovider

# ---- runtime
FROM ${PY_IMAGE} AS runtime
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    METRICS_PORT=9100
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin worker
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
# le code est copié depuis l'étape test : pas d'image si les tests échouent
COPY --from=test /app/worker ./worker
USER 10001:10001
EXPOSE 9100
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
