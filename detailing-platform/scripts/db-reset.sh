#!/usr/bin/env bash
# Пересоздаёт локальную БД и накатывает все миграции по порядку.
# Останавливается на первой ошибке и печатает её.
set -euo pipefail

export PATH=/usr/lib/postgresql/16/bin:$PATH
PGHOST=${PGHOST:-/var/tmp/pgrun}
PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}
DB=${DB:-detailing}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -qtAc \
  "drop database if exists $DB;" postgres
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -qtAc \
  "create database $DB;" postgres

for f in "$ROOT"/supabase/migrations/*.sql; do
  printf '%-44s' "$(basename "$f")"
  if out=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
            -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "ok"
  else
    echo "ОШИБКА"
    echo "$out" | sed 's/^/    /'
    exit 1
  fi
done

echo "все миграции накатились"
