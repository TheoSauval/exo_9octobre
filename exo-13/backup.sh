#!/usr/bin/env bash
# Sauvegarde de la base de la stack Shop SAS (TP04), entièrement via des conteneurs.
#   ./backup.sh          dump logique pg_dump -Fc horodaté
#   ./backup.sh --raw    + sauvegarde brute du volume (arrêt de la base pendant la copie)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$HERE/../exo-12}"
BACKUP_DIR="${BACKUP_DIR:-$HERE/backups}"
VOLUME="${PG_VOLUME:-shop_pgdata}"
KEEP="${KEEP:-7}"
TS="$(date +%Y%m%d-%H%M%S)"
dc() { (cd "$COMPOSE_DIR" && docker compose "$@"); }

mkdir -p "$BACKUP_DIR/logical" "$BACKUP_DIR/raw"

# 1. Dump logique : cohérent (snapshot MVCC), base en ligne, portable entre versions
out="$BACKUP_DIR/logical/shop-$TS.dump"
dc exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$out.part"
mv "$out.part" "$out"
echo "dump logique : $out ($(du -h "$out" | cut -f1))"

# 2. Sauvegarde brute du volume (optionnelle)
if [ "${1:-}" = "--raw" ]; then
  # Copier les fichiers d'une base en cours d'écriture donne une copie incohérente
  # (pages modifiées pendant le tar, WAL non synchronisé). On arrête donc la base.
  dc stop db >/dev/null
  docker run --rm -v "$VOLUME":/data:ro -v "$BACKUP_DIR/raw":/backup alpine:3.20 \
    tar czf "/backup/pgdata-$TS.tar.gz" -C /data .
  dc start db >/dev/null
  echo "sauvegarde brute : $BACKUP_DIR/raw/pgdata-$TS.tar.gz ($(du -h "$BACKUP_DIR/raw/pgdata-$TS.tar.gz" | cut -f1))"
fi

# 3. Rétention : on garde les $KEEP plus récents de chaque type
for d in logical raw; do
  ls -1t "$BACKUP_DIR/$d" 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
    rm -f "$BACKUP_DIR/$d/$f" && echo "rétention : supprimé $d/$f"
  done
done
