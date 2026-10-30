#!/usr/bin/env bash
# rolling-update.sh : déploiement sans interruption de la stack Shop SAS sur un hôte Docker distant
#
#   VERSION=sha-abc1234 REGISTRY=registre.vu.par.le.serveur ./deploy/rolling-update.sh
#
# Étapes :
#   1. vérifie la signature cosign des deux images (refus si non signées)
#   2. tire les images sur le serveur
#   3. premier déploiement : up --wait ; sinon, pour chaque réplica de l'API, un à la fois :
#        - démarre UN nouveau réplica avec la nouvelle image et attend qu'il soit healthy
#          (Traefik ne lui envoie du trafic qu'à partir de là)
#        - arrête proprement UN ancien réplica (SIGTERM, l'API termine ses requêtes, 15 s max)
#      la capacité ne descend jamais sous le nombre de réplicas
#   4. recrée le worker (hors du chemin des requêtes : la file Redis absorbe la coupure)
#
# Variables :
#   VERSION          tag immuable à déployer (sha-xxxxxxx ou X.Y.Z)           obligatoire
#   REGISTRY         registre tel que le SERVEUR le voit                     obligatoire
#   VERIFY_REGISTRY  registre tel que la machine qui déploie le voit          défaut : REGISTRY
#   DEPLOY_CONTEXT   contexte Docker de l'hôte cible                          défaut : preprod
#   SHOP_CONF_DIR    dossier du serveur contenant secrets/ et db/             défaut : /srv/shop
#   COSIGN_KEY       clé publique cosign (mode clé)                           défaut : ci/keys/cosign.pub
#   COSIGN_IDENTITY_REGEXP / COSIGN_OIDC_ISSUER   mode keyless (pipeline GitHub)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION requis (ex : sha-abc1234 ou 1.5.0)}"
: "${REGISTRY:?REGISTRY requis (registre vu par le serveur)}"
VERIFY_REGISTRY="${VERIFY_REGISTRY:-$REGISTRY}"
DEPLOY_CONTEXT="${DEPLOY_CONTEXT:-preprod}"
STOP_TIMEOUT="${STOP_TIMEOUT:-15}"
COSIGN_IMAGE="${COSIGN_IMAGE:-ghcr.io/sigstore/cosign/cosign:v2.4.1}"
LOCAL_CTX="${LOCAL_CTX:-$(docker context show)}"
export VERSION REGISTRY SHOP_CONF_DIR="${SHOP_CONF_DIR:-/srv/shop}"

REMOTE=(docker --context "$DEPLOY_CONTEXT")
DC=(docker --context "$DEPLOY_CONTEXT" compose -f compose.yml -f compose.prod.yml)
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
T0=$(date +%s)

# ---- 1. signature
verify() {
  local ref="$1"
  if [ -n "${COSIGN_IDENTITY_REGEXP:-}" ]; then
    cosign verify --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
      --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}" \
      "$ref" >/dev/null
  else
    local key="${COSIGN_KEY:-ci/keys/cosign.pub}"
    [ -f "$key" ] || { echo "clé publique $key introuvable"; return 1; }
    docker --context "$LOCAL_CTX" run --rm --network host -v "$PWD/$(dirname "$key")":/keys:ro "$COSIGN_IMAGE" \
      verify --key "/keys/$(basename "$key")" --insecure-ignore-tlog=true \
      --allow-insecure-registry --allow-http-registry "$ref" >/dev/null
  fi
}
for img in shopapi shop-worker; do
  log "vérification de la signature de $VERIFY_REGISTRY/$img:$VERSION"
  if ! verify "$VERIFY_REGISTRY/$img:$VERSION"; then
    log "REFUS : $img:$VERSION n'est pas signée par la CI, rien n'a été modifié sur $DEPLOY_CONTEXT"
    exit 1
  fi
done

# ---- 2. images
running=$("${DC[@]}" ps -q api 2>/dev/null || true)
if [ -z "$running" ]; then
  log "premier déploiement sur $DEPLOY_CONTEXT : tirage de toutes les images"
  "${DC[@]}" pull --quiet
  "${DC[@]}" up -d --wait
  log "stack démarrée en version $VERSION en $(( $(date +%s) - T0 )) s"
  exit 0
fi
log "tirage des images $VERSION sur $DEPLOY_CONTEXT"
"${DC[@]}" pull --quiet api worker

# ---- 3. API, un réplica à la fois
# shellcheck disable=SC2206  # identifiants de conteneurs : pas d'espace (compatible bash 3.2 de macOS)
old=($running)
n=${#old[@]}
log "$n réplica(s) de l'API à remplacer"
for c in "${old[@]}"; do
  name=$("${REMOTE[@]}" inspect -f '{{.Name}}' "$c" | tr -d /)
  log "démarrage d'un réplica $VERSION (attente du statut healthy)"
  "${DC[@]}" up -d --no-deps --no-recreate --scale "api=$((n + 1))" --wait api
  log "arrêt propre de $name (SIGTERM, ${STOP_TIMEOUT} s max)"
  "${REMOTE[@]}" stop -t "$STOP_TIMEOUT" "$c" >/dev/null
  "${REMOTE[@]}" rm "$c" >/dev/null
done

# ---- 4. worker
log "recréation du worker"
"${DC[@]}" up -d --no-deps --wait worker

"${DC[@]}" ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
log "version $VERSION déployée sur $DEPLOY_CONTEXT en $(( $(date +%s) - T0 )) s"
