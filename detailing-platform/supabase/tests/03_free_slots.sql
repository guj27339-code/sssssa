-- 03_free_slots.sql
-- Согласованность расчёта свободного времени и создания брони.
--
-- Главная проверка: то, что find_free_slots предложил, должно
-- реально бронироваться; то, чего он не предложил, — не должно.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;

insert into tenants (id, slug, name, timezone, status)
values ('33330000-0000-0000-0000-000000000001', 'slots', 'Слоты', 'Europe/Moscow', 'live');

insert into resources (id, tenant_id, name, sort_order) values
  ('33330000-0000-0000-0000-00000000000a', '33330000-0000-0000-0000-000000000001', 'Пост 1', 1);

-- Услуга ровно на 2 часа с получасовыми буферами.
insert into services (id, tenant_id, name, duration_minutes,
                      buffer_before_minutes, buffer_after_minutes)
values ('33330000-0000-0000-0000-0000000000b1', '33330000-0000-0000-0000-000000000001',
        'Двухчасовая', 120, 30, 30);

-- Двухдневная услуга: проверяем, что выдача ищется в окне другого дня.
insert into services (id, tenant_id, name, duration_minutes,
                      buffer_before_minutes, buffer_after_minutes)
values ('33330000-0000-0000-0000-0000000000b2', '33330000-0000-0000-0000-000000000001',
        'Двухдневная', 2880, 0, 0);

insert into service_resources
select '33330000-0000-0000-0000-000000000001', s.id, '33330000-0000-0000-0000-00000000000a'
from services s where s.tenant_id = '33330000-0000-0000-0000-000000000001';

-- Приём с 10:00 до 18:00 ежедневно.
insert into working_hours (tenant_id, resource_id, weekday, opens_at, closes_at)
select '33330000-0000-0000-0000-000000000001', null, d, '10:00', '18:00'
from generate_series(1,7) d;


-- ── 1. предложенное время действительно бронируется ──────────────────────
do $$
declare
  v_first timestamptz;
  v_id    uuid;
begin
  select starts_at into v_first
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1',
                           (now() at time zone 'Europe/Moscow')::date + 1, 3, 1);

  if v_first is null then
    raise exception 'ПРОВАЛ | не предложено ни одного времени';
  end if;

  select id into v_id from app.create_booking(
    '33330000-0000-0000-0000-000000000001',
    '33330000-0000-0000-0000-0000000000b1',
    v_first, 'Клиент', '+79001112200', sha256('s1'::bytea), 'slot-1');

  raise notice 'ok | предложенное время % забронировалось', v_first;
end
$$;


-- ── 2. занятое время исчезает из предложений ─────────────────────────────
do $$
declare
  v_taken timestamptz;
  v_cnt   integer;
begin
  select lower(during) + interval '30 minutes' into v_taken
  from resource_occupancies
  where tenant_id = '33330000-0000-0000-0000-000000000001';

  select count(*) into v_cnt
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1',
                           (now() at time zone 'Europe/Moscow')::date + 1, 3, 200)
  where starts_at = v_taken;

  if v_cnt = 0 then
    raise notice 'ok | занятое время больше не предлагается';
  else
    raise exception 'ПРОВАЛ | занятое время всё ещё в списке';
  end if;
end
$$;


-- ── 3. буфер тоже исключает соседние времена ─────────────────────────────
-- Бронь занимает [start-30мин, start+150мин). Время start+120мин
-- попало бы в буфер, поэтому предлагаться не должно.
do $$
declare
  v_start timestamptz;
  v_cnt   integer;
begin
  select starts_at into v_start from bookings
  where tenant_id = '33330000-0000-0000-0000-000000000001' limit 1;

  select count(*) into v_cnt
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1',
                           (now() at time zone 'Europe/Moscow')::date + 1, 3, 200)
  where starts_at > v_start - interval '150 minutes'
    and starts_at < v_start + interval '150 minutes';

  if v_cnt = 0 then
    raise notice 'ok | буфер вокруг брони исключён из предложений';
  else
    raise exception 'ПРОВАЛ | в буфер предложено % времён', v_cnt;
  end if;
end
$$;


-- ── 4. предложения не выходят за окно приёма ─────────────────────────────
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1',
                           (now() at time zone 'Europe/Moscow')::date + 1, 7, 500) s
  where (s.starts_at at time zone 'Europe/Moscow')::time < '10:00'
     or (s.starts_at at time zone 'Europe/Moscow')::time >= '18:00'
     or (s.ends_at   at time zone 'Europe/Moscow')::time > '18:00';

  if v_bad = 0 then
    raise notice 'ok | все предложения внутри часов приёма и выдачи';
  else
    raise exception 'ПРОВАЛ | % предложений вне рабочих часов', v_bad;
  end if;
end
$$;


-- ── 5. двухдневная услуга предлагается, выдача — в окне другого дня ──────
do $$
declare
  v_s timestamptz;
  v_e timestamptz;
begin
  select starts_at, ends_at into v_s, v_e
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b2',
                           (now() at time zone 'Europe/Moscow')::date + 1, 5, 1);

  if v_s is null then
    raise exception 'ПРОВАЛ | двухдневная услуга не предложена ни разу';
  end if;

  if (v_e at time zone 'Europe/Moscow')::date - (v_s at time zone 'Europe/Moscow')::date = 2
     and (v_e at time zone 'Europe/Moscow')::time between '10:00' and '18:00'
  then
    raise notice 'ok | двухдневная услуга: приём % , выдача % через двое суток в часы работы',
      (v_s at time zone 'Europe/Moscow')::time, (v_e at time zone 'Europe/Moscow')::time;
  else
    raise exception 'ПРОВАЛ | двухдневная выдача вне окна: % .. %', v_s, v_e;
  end if;
end
$$;


-- ── 6. закрытый день исключается целиком ─────────────────────────────────
do $$
declare
  v_day date := (now() at time zone 'Europe/Moscow')::date + 2;
  v_cnt integer;
begin
  insert into schedule_exceptions (tenant_id, resource_id, exception_date, is_closed)
  values ('33330000-0000-0000-0000-000000000001', null, v_day, true);

  select count(*) into v_cnt
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1',
                           v_day, 1, 200);

  if v_cnt = 0 then
    raise notice 'ok | в закрытый день ничего не предлагается';
  else
    raise exception 'ПРОВАЛ | в закрытый день предложено % времён', v_cnt;
  end if;
end
$$;


-- ── 7. сокращённый день ограничивает предложения ─────────────────────────
do $$
declare
  v_day date := (now() at time zone 'Europe/Moscow')::date + 3;
  v_bad integer;
  v_any integer;
begin
  insert into schedule_exceptions
    (tenant_id, resource_id, exception_date, is_closed, opens_at, closes_at)
  values ('33330000-0000-0000-0000-000000000001', null, v_day, false, '12:00', '15:00');

  select count(*) into v_any
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1', v_day, 1, 200);

  select count(*) into v_bad
  from app.find_free_slots('33330000-0000-0000-0000-000000000001',
                           '33330000-0000-0000-0000-0000000000b1', v_day, 1, 200) s
  where (s.starts_at at time zone 'Europe/Moscow')::time < '12:00'
     or (s.ends_at   at time zone 'Europe/Moscow')::time > '15:00';

  if v_any > 0 and v_bad = 0 then
    raise notice 'ok | сокращённый день: % предложений, все внутри 12:00–15:00', v_any;
  else
    raise exception 'ПРОВАЛ | сокращённый день: всего %, вне окна %', v_any, v_bad;
  end if;
end
$$;

rollback;
