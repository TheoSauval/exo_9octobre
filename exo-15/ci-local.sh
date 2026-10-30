#!/usr/bin/env bash
# ci-local.sh : rejoue en local les étapes de .github/workflows/ci.yml, contre un registre local
#
#   ./ci-local.sh pr                     pull request : lint, étape test, build multi-arch sans push, test d'intégration
#   ./ci-local.sh main                   + push sha-<sha>, release gate (trivy bloquant + cosign), déploiement préprod
#   ./ci-local.sh tag vX.Y.Z             + tags X.Y.Z et X.Y, release gate ; la prod attend une approbation
#   PROD_APPROVED_BY=nom ./ci-local.sh deploy-prod vX.Y.Z    job "production" après approbation manuelle
#
# Variables : CI_REGISTRY (localhost:5050), CI_BUILDER (shop-ci), CI_PLATFORMS (linux/amd64,linux/arm64),
#             PREPROD_CONTEXT / PROD_CONTEXT (preprod), DEPLOY_REGISTRY (registre vu par le serveur)
set -euo pipefail
cd "$(dirname "$0")"

STAGE="${1:?usage : ./ci-local.sh pr | main | tag vX.Y.Z | deploy-prod vX.Y.Z}"
REG="${CI_REGISTRY:-localhost:5050}"
BUILDER="${CI_BUILDER:-shop-ci}"
PLATFORMS="${CI_PLATFORMS:-linux/amd64,linux/arm64}"
DEPLOY_REGISTRY="${DEPLOY_REGISTRY:-host.docker.internal:5050}"
SHA="$(git rev-parse --short HEAD)"
SERVICES="api worker"
# hadolint 2.12 signale à tort "FROM ${ARG}" (DL3006) même avec une valeur par défaut épinglée : version récente, épinglée par digest
HADOLINT_IMAGE="${HADOLINT_IMAGE:-hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d}"

ctx_of() { if [ "$1" = api ]; then echo apps/shopapi; else echo apps/shop-worker; fi; }
img_of() { if [ "$1" = api ]; then echo shopapi; else echo shop-worker; fi; }
step()   { printf '\n===== [%s] %s\n' "$STAGE" "$*"; }

mkdir -p .ci secrets
[ -f ci/pip.conf ] || cp ci/pip.conf.example ci/pip.conf
[ -f secrets/db_password.txt ] || (umask 022 && openssl rand -hex 24 > secrets/db_password.txt)

lint() {
  step "hadolint"
  for s in $SERVICES; do
    docker run --rm -i "$HADOLINT_IMAGE" < "$(ctx_of "$s")/Dockerfile"
    echo "$(ctx_of "$s")/Dockerfile : aucune sortie"
  done
  step "docker compose config"
  docker compose -f compose.yml config -q && echo "compose.yml : OK"
  REGISTRY="$REG" VERSION="sha-$SHA" docker compose -f compose.yml -f compose.prod.yml config -q \
    && echo "compose.yml + compose.prod.yml : OK"
}

test_stage() {
  step "build de l'étape test (lint + tests unitaires dans le build)"
  for s in $SERVICES; do
    args=(--builder "$BUILDER" --target test --progress quiet)
    [ "$s" = worker ] && args+=(--secret "id=pipconf,src=ci/pip.conf")
    docker buildx build "${args[@]}" "$(ctx_of "$s")" >/dev/null
    echo "$s : étape test OK"
  done
}

# build <service> <version> <push 0|1> [tags...]
build() {
  local s="$1" v="$2" push="$3"; shift 3
  local args=(--builder "$BUILDER" --platform "$PLATFORMS" --progress quiet
    --build-arg "APP_VERSION=$v" --build-arg "GIT_SHA=$SHA"
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --label "org.opencontainers.image.revision=$SHA"
    --label "org.opencontainers.image.version=$v"
    --cache-from "type=registry,ref=$REG/cache:$s")
  [ "$s" = worker ] && args+=(--secret "id=pipconf,src=ci/pip.conf")
  if [ "$push" = 1 ]; then
    local t
    for t in "$@"; do args+=(-t "$REG/$(img_of "$s"):$t"); done
    args+=(--push --provenance=mode=max --sbom=true
      --cache-to "type=registry,ref=$REG/cache:$s,mode=max"
      --metadata-file ".ci/$s.json")
  fi
  docker buildx build "${args[@]}" "$(ctx_of "$s")" >/dev/null
}

push_and_gate() {   # push_and_gate <version> <tags...>
  local v="$1"; shift
  for s in $SERVICES; do
    step "build multi-arch + push $(img_of "$s") ($*) avec provenance et SBOM"
    build "$s" "$v" 1 "$@"
    digest=$(jq -r '."containerimage.digest"' ".ci/$s.json")
    echo "$REG/$(img_of "$s") -> $digest"
    docker buildx imagetools inspect "$REG/$(img_of "$s")@$digest" | sed -n "1,20p" || true
    step "release gate $(img_of "$s")"
    ./release-gate.sh "$REG/$(img_of "$s")@$digest"
  done
}

deploy() {          # deploy <contexte> <version>
  step "déploiement de $2 sur le contexte $1"
  DEPLOY_CONTEXT="$1" VERSION="$2" REGISTRY="$DEPLOY_REGISTRY" VERIFY_REGISTRY="$REG" ./deploy/rolling-update.sh
}

semver() {
  local v="${1#v}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag invalide : $1 (attendu vX.Y.Z)"; exit 2; }
  echo "$v"
}

case "$STAGE" in
  pr)
    lint
    test_stage
    step "build multi-arch de l'image (sans push)"
    for s in $SERVICES; do build "$s" "pr-$SHA" 0; echo "$(img_of "$s") : build $PLATFORMS OK"; done
    step "test d'intégration : compose up --wait + smoke test + down -v"
    export COMPOSE="docker compose -p shop-ci -f compose.yml"
    trap '$COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true' EXIT
    $COMPOSE up -d --build --wait --quiet-pull >/dev/null
    ./smoke-test.sh
    ;;
  main)
    lint
    test_stage
    push_and_gate "sha-$SHA" "sha-$SHA"
    deploy "${PREPROD_CONTEXT:-preprod}" "sha-$SHA"
    ;;
  tag)
    v=$(semver "${2:?tag attendu : vX.Y.Z}")
    lint
    test_stage
    push_and_gate "$v" "$v" "${v%.*}"
    step "déploiement production"
    echo "en attente d'approbation manuelle (environment: production)."
    echo "Après validation : PROD_APPROVED_BY=<nom> ./ci-local.sh deploy-prod v$v"
    ;;
  deploy-prod)
    v=$(semver "${2:?tag attendu : vX.Y.Z}")
    if [ -z "${PROD_APPROVED_BY:-}" ]; then
      echo "REFUS : le déploiement production exige une approbation (PROD_APPROVED_BY)"
      exit 1
    fi
    step "approbation : $PROD_APPROVED_BY, $(date '+%Y-%m-%d %H:%M:%S')"
    deploy "${PROD_CONTEXT:-preprod}" "$v"
    ;;
  *) echo "étape inconnue : $STAGE"; exit 2 ;;
esac
echo
echo "===== [$STAGE] pipeline OK"
