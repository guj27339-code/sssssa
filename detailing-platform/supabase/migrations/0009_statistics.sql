-- 0009_statistics.sql
-- Статистика студии.
--
-- Инвариант 8: три разные величины, которые нельзя складывать и нельзя
-- называть одним словом.
--   заезды            — сколько машин реально приехало (arrived_at)
--   выполненные работы — сколько доведено до готовности (status = completed)
--   полученные деньги  — сумма фактических платежей минус возвраты
--
-- Плановая стоимость будущих броней считается ОТДЕЛЬНО и называется
-- «ожидается», а не «выручка».
--
-- Период задаётся календарными датами в зоне студии. Одна и та же функция
-- обслуживает и кабинет, и AI-помощника — иначе цифры разъедутся.

create or replace function app.tenant_stats(
  p_tenant uuid,
  p_from   date,
  p_to     date          -- включительно
)
returns table (
  period_from        date,
  period_to          date,
  timezone           text,
  arrivals           bigint,   -- заезды
  completed          bigint,   -- выполненные работы
  cancelled          bigint,
  no_show            bigint,
  received_kopecks   bigint,   -- фактически получено за вычетом возвратов
  refunded_kopecks   bigint,
  expected_kopecks   bigint    -- ожидается по будущим броням, НЕ выручка
)
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_tz    text;
  v_start timestamptz;
  v_end   timestamptz;
begin
  select t.timezone into v_tz from tenants t where t.id = p_tenant;
  if v_tz is null then
    raise exception 'tenant_not_found' using errcode = 'P0002';
  end if;

  -- Полуинтервал [начало дня p_from, начало дня после p_to)
  -- в зоне студии, чтобы сутки не поехали на границе месяца.
  v_start := (p_from::timestamp)            at time zone v_tz;
  v_end   := ((p_to + 1)::timestamp)        at time zone v_tz;

  return query
  select
    p_from,
    p_to,
    v_tz,

    -- Заезд: машина приехала в этот период.
    (select count(*) from bookings b
      where b.tenant_id = p_tenant
        and b.arrived_at >= v_start and b.arrived_at < v_end),

    -- Выполнено: работа доведена до готовности в этот период.
    (select count(*) from bookings b
      where b.tenant_id = p_tenant
        and b.status = 'completed'
        and b.ready_at >= v_start and b.ready_at < v_end),

    (select count(*) from bookings b
      where b.tenant_id = p_tenant
        and b.status = 'cancelled'
        and b.cancelled_at >= v_start and b.cancelled_at < v_end),

    (select count(*) from bookings b
      where b.tenant_id = p_tenant
        and b.status = 'no_show'
        and b.starts_at >= v_start and b.starts_at < v_end),

    -- Получено: платежи минус возвраты, по дате фактического получения.
    (select coalesce(sum(
              case when p.kind = 'payment' then p.amount_kopecks
                   else -p.amount_kopecks end), 0)
       from payments p
      where p.tenant_id = p_tenant
        and p.received_at >= v_start and p.received_at < v_end),

    (select coalesce(sum(p.amount_kopecks), 0)
       from payments p
      where p.tenant_id = p_tenant
        and p.kind = 'refund'
        and p.received_at >= v_start and p.received_at < v_end),

    -- Ожидается: снимок цены по подтверждённым броням периода.
    -- Это не полученные деньги и не выручка.
    (select coalesce(sum(b.price_kopecks_snapshot), 0)
       from bookings b
      where b.tenant_id = p_tenant
        and b.status = 'confirmed'
        and b.starts_at >= v_start and b.starts_at < v_end);
end
$$;

comment on function app.tenant_stats(uuid, date, date) is
  'Единственный источник цифр для кабинета и AI. expected_kopecks — ожидаемая стоимость будущих броней, выручкой не является.';


-- Расписание на день для кабинета: брони и блокировки одним списком.
create or replace function app.day_schedule(
  p_tenant uuid,
  p_date   date
)
returns table (
  occupancy_id  uuid,
  kind          app.occupancy_kind,
  resource_id   uuid,
  resource_name text,
  during        tstzrange,
  booking_id    uuid,
  booking_status app.booking_status,
  service_name  text,
  customer_name text,
  customer_phone text,
  note          text
)
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_tz    text;
  v_start timestamptz;
  v_end   timestamptz;
begin
  select t.timezone into v_tz from tenants t where t.id = p_tenant;
  if v_tz is null then
    raise exception 'tenant_not_found' using errcode = 'P0002';
  end if;

  v_start := (p_date::timestamp)       at time zone v_tz;
  v_end   := ((p_date + 1)::timestamp) at time zone v_tz;

  return query
  select
    o.id, o.kind, o.resource_id, r.name,
    o.during, o.booking_id, b.status,
    s.name, c.name, c.phone, o.note
  from resource_occupancies o
  join resources r
    on r.tenant_id = o.tenant_id and r.id = o.resource_id
  left join bookings b
    on b.tenant_id = o.tenant_id and b.id = o.booking_id
  left join services s
    on s.tenant_id = b.tenant_id and s.id = b.service_id
  left join customers c
    on c.tenant_id = b.tenant_id and c.id = b.customer_id
  where o.tenant_id = p_tenant
    -- Пересечение с сутками, а не попадание целиком: многодневная работа
    -- должна показываться в каждом из своих дней.
    and o.during && tstzrange(v_start, v_end, '[)')
  order by lower(o.during), r.sort_order;
end
$$;

comment on function app.day_schedule(uuid, date) is
  'День кабинета. Многодневная занятость попадает в каждый пересекаемый день, а не только в день начала.';
