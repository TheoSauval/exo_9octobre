#!/usr/bin/env bash
# Smoke test de la stack Shop SAS (dev ou prod) via le reverse proxy.
set -euo pipefail
BASE="${BASE_URL:-http://api.localhost}"
COMPOSE="${COMPOSE:-docker compose}"
pass=0; fail=0
ok()  { echo "  OK   $*"; pass=$((pass+1)); }
ko()  { echo "  FAIL $*"; fail=$((fail+1)); }

echo "== Smoke test sur $BASE"

# 1. /ready : API joignable via Traefik, base et Redis OK
#    (après un redémarrage, Traefik ajoute la route quand le conteneur est healthy : on attend jusqu'à 30 s)
ready=""
for _ in $(seq 1 30); do
  ready=$(curl -fsS "$BASE/ready" 2>/dev/null || true)
  echo "$ready" | grep -q '"redis":"ok"' && break
  sleep 1
done
if echo "$ready" | grep -q '"db":"ok"' && echo "$ready" | grep -q '"redis":"ok"'; then ok "/ready -> $ready"; else ko "/ready -> $ready"; fi

# 2. /products : 1er appel MISS (ou HIT si déjà en cache), 2e appel HIT
curl -fsS -o /dev/null "$BASE/products"
cache=$(curl -fsS -D - -o /dev/null "$BASE/products" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')
nb=$(curl -fsS "$BASE/products" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$cache" = "HIT" ] && [ "$nb" -ge 1 ]; then ok "/products -> $nb produits, X-Cache: $cache"; else ko "/products -> X-Cache: ${cache:-absent}, $nb produits"; fi

# 3. Création d'une commande
code=$(curl -sS -o /tmp/smoke-order.json -w '%{http_code}' -X POST "$BASE/orders" \
  -H 'Content-Type: application/json' -d '{"productId": 1, "quantity": 2}')
if [ "$code" = "201" ]; then ok "POST /orders -> 201 $(cat /tmp/smoke-order.json)"; else ko "POST /orders -> $code"; fi

# 4. Le worker passe la commande en "confirmed"
status=""
for _ in $(seq 1 15); do
  status=$($COMPOSE exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT status FROM orders WHERE product_id = 1 ORDER BY id DESC LIMIT 1"')
  [ "$status" = "confirmed" ] && break
  sleep 1
done
if [ "$status" = "confirmed" ]; then ok "commande traitée par le worker -> $status"; else ko "commande -> ${status:-introuvable}"; fi

echo "== $pass OK, $fail FAIL"
[ "$fail" -eq 0 ]
