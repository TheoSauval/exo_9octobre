#!/usr/bin/env bash
# Restauration de la base de la stack Shop SAS (TP04), entièrement via des conteneurs.
#   ./restore.sh                      dernier dump logique
#   ./restore.sh backups/logical/X    dump logique donné
#   ./restore.sh --raw backups/raw/X  restauration brute du volume
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$HERE/../exo-12}"
BACKUP_DIR="${BACKUP_DIR:-$HERE/backups}"
VOLUME="${PG_VOLUME:-shop_pgdata}"
dc() { (cd "$COMPOSE_DIR" && docker compose "$@"); }
checksum() {
  dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA' <<'SQL'
SELECT count(*) || ' ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders;
SQL
}

if [ "${1:-}" = "--raw" ]; then
  file="${2:?archive .tar.gz attendue}"
  dc stop api worker db >/dev/null
  docker run --rm -v "$VOLUME":/data -v "$(cd "$(dirname "$file")" && pwd)":/backup:ro alpine:3.20 \
    sh -c "find /data -mindepth 1 -delete && tar xzf /backup/$(basename "$file") -C /data"
  dc up -d --wait db api worker >/dev/null
else
  file="${1:-$(ls -1t "$BACKUP_DIR"/logical/*.dump | head -1)}"
  echo "restauration de $file"
  dc up -d --wait db >/dev/null
  dc stop api worker >/dev/null            # plus d'écritures pendant la restauration
  # --clean --if-exists : remplace les objets créés par init.sql sur une base neuve
  dc exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --exit-on-error' < "$file"
  dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qc "ANALYZE"'
  dc up -d --wait api worker >/dev/null
fi
echo "restauré : $(checksum)   (orders count + checksum)"
