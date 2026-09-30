#!/usr/bin/env bash
# Прогоняет все SQL-тесты по свежей базе.
set -euo pipefail

export PATH=/usr/lib/postgresql/16/bin:$PATH
PGHOST=${PGHOST:-/var/tmp/pgrun}; PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}; DB=${DB:-detailing}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT/scripts/db-reset.sh" > /dev/null

total=0; failed=0
for f in "$ROOT"/supabase/tests/*.sql; do
  echo ""
  echo "── $(basename "$f") ──"
  out=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
          -v ON_ERROR_STOP=1 -f "$f" 2>&1) || true

  while IFS= read -r line; do
    total=$((total + 1))
    echo "  $line"
    case "$line" in ПРОВАЛ*) failed=$((failed + 1));; esac
  done < <(echo "$out" | grep -oE "(ok|ПРОВАЛ) \|.*" || true)

  if echo "$out" | grep -q "^psql:.*ERROR"; then
    echo "  ОШИБКА SQL:"
    echo "$out" | grep "ERROR" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
done

echo ""
echo "проверок: $total, провалов: $failed"
[ "$failed" -eq 0 ] || exit 1
