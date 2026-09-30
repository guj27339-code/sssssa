#!/usr/bin/env bash
# Гонка за один слот: N параллельных попыток забронировать одно и то же время
# на единственном посту. Пройти должна ровно одна.
set -euo pipefail

export PATH=/usr/lib/postgresql/16/bin:$PATH
PGHOST=${PGHOST:-/var/tmp/pgrun}; PGPORT=${PGPORT:-5433}
PGUSER=${PGUSER:-postgres}; DB=${DB:-detailing}
N=${N:-12}

q() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -qtA -c "$1"; }

# Чистая площадка: один пост, одна услуга, круглосуточный приём.
q "delete from tenants where slug = 'race-test';" >/dev/null
q "
insert into tenants (id, slug, name, timezone, status)
values ('aaaaaaaa-0000-0000-0000-000000000001','race-test','Гонка','UTC','live');
insert into resources (id, tenant_id, name)
values ('aaaaaaaa-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','Единственный пост');
insert into services (id, tenant_id, name, duration_minutes)
values ('aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','Услуга',60);
insert into service_resources values
 ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002');
insert into working_hours (tenant_id, resource_id, weekday, opens_at, closes_at)
select 'aaaaaaaa-0000-0000-0000-000000000001', null, d, '00:00','23:59' from generate_series(1,7) d;
" >/dev/null

SLOT=$(date -u -d '+30 days 12:00' +%Y-%m-%dT12:00:00+00)

tmp=$(mktemp -d)
for i in $(seq 1 "$N"); do
  (
    # Каждый клиент — свой телефон и свой ключ идемпотентности,
    # то есть это разные люди, а не повтор одного запроса.
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -qtA -c "
      select (app.create_booking(
        'aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000003',
        '$SLOT'::timestamptz,
        'Клиент $i', '+7900000${i}0${i}0',
        sha256('tok-$i'::bytea), 'race-$i'
      )).id;" > "$tmp/$i.out" 2> "$tmp/$i.err"
  ) &
done
wait

ok=$(grep -l -E '^[0-9a-f-]{36}$' "$tmp"/*.out 2>/dev/null | wc -l)
fail=$(grep -l 'no_free_resource' "$tmp"/*.err 2>/dev/null | wc -l)

# Непустые .err, в которых НЕ штатный отказ, — это настоящие сбои.
# Считаем циклом: xargs вернул бы 123 и уронил скрипт под set -e.
other=0
for e in "$tmp"/*.err; do
  if [ -s "$e" ] && ! grep -q 'no_free_resource' "$e"; then
    other=$((other + 1))
    echo "  неожиданная ошибка в $(basename "$e"):"
    sed 's/^/    /' "$e"
  fi
done

rows=$(q "select count(*) from resource_occupancies where tenant_id='aaaaaaaa-0000-0000-0000-000000000001';")

echo "параллельных попыток: $N"
echo "успешных броней:      $ok"
echo "отказов no_free_resource: $fail"
echo "иных ошибок:          $other"
echo "строк занятости в БД: $rows"

q "delete from tenants where slug = 'race-test';" >/dev/null
rm -rf "$tmp"

if [ "$ok" -eq 1 ] && [ "$rows" -eq 1 ] && [ "$other" -eq 0 ]; then
  echo "ok | ровно одна бронь прошла, пересечений нет"
else
  echo "ПРОВАЛ | ожидалась ровно одна бронь"
  exit 1
fi
