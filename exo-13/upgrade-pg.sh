#!/usr/bin/env bash
# Montée de version PostgreSQL 14 -> 16 de la base legacy (compose.yml du TP05), sans perte.
# Le volume PG14 n'est jamais modifié : il sert de retour arrière.
set -euo pipefail
cd "$(dirname "$0")"
DC14="docker compose -f compose.yml"
DC16="docker compose -f compose.yml -f compose.pg16.yml"
NET="shopdata_default"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="backups/upgrade-$TS"
PG16_IMAGE="postgres:16.4-alpine"
mkdir -p "$OUT"
q() { $1 exec -T db psql -U shop -d shop -tA -c "$2"; }
CHECK="SELECT count(*) || ' ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"
# client PostgreSQL 16 lancé dans un conteneur sur le réseau du projet (pas de psql sur l'hôte)
pg16() { docker run --rm -i --network "$NET" -e PGPASSWORD=shop "$PG16_IMAGE" "$@"; }

echo "== 1. État avant"
$DC14 up -d --wait db >/dev/null
echo "version  : $(q "$DC14" 'SHOW server_version')"
BEFORE="$(q "$DC14" "$CHECK")"
echo "checksum : $BEFORE"

echo "== 2. Sauvegardes (pg_dump/pg_dumpall en version 16 : le client doit être >= au serveur cible)"
pg16 pg_dumpall -h db -U shop --globals-only > "$OUT/globals.sql"
pg16 pg_dumpall -h db -U shop > "$OUT/dumpall.sql"
pg16 pg_dump -h db -U shop -d shop -Fc > "$OUT/shop.dump"
ls -lh "$OUT"

echo "== 3. Arrêt de PG14 (volume shopdata_pgdata conservé)"
T0=$(date +%s)
$DC14 stop db >/dev/null
$DC14 rm -f db >/dev/null

echo "== 4. PG16 sur un NOUVEAU volume (shopdata_pgdata16)"
$DC16 up -d --wait db >/dev/null
echo "version  : $(q "$DC16" 'SHOW server_version')"

echo "== 5. Restauration"
$DC16 exec -T db pg_restore -U shop -d shop --exit-on-error < "$OUT/shop.dump"
$DC16 exec -T db vacuumdb -U shop -d shop --analyze-in-stages -q
T1=$(date +%s)

echo "== 6. Vérification"
AFTER="$(q "$DC16" "$CHECK")"
echo "checksum avant : $BEFORE"
echo "checksum après : $AFTER"
echo "indisponibilité (arrêt PG14 -> PG16 restauré) : $((T1 - T0)) s"
if [ "$BEFORE" = "$AFTER" ]; then
  echo "VERDICT : OK, aucune perte de données"
else
  echo "VERDICT : ECHEC, checksums différents. Retour arrière :"
  echo "  $DC16 down && $DC14 up -d --wait db"
  exit 1
fi
