-- 0012_free_slots.sql
-- Поиск свободного времени.
--
-- Единственная реализация на всю систему: её вызывает и форма записи,
-- и AI-помощник. Иначе клиенту показали бы одно время, а помощник назвал
-- другое.
--
-- Инвариант 3: услуга занимает подходящий ресурс на непрерывный диапазон.
-- Рабочие часы ограничивают только момент приёма и момент выдачи —
-- сама работа может идти ночью и через несколько суток.

create or replace function app.find_free_slots(
  p_tenant  uuid,
  p_service uuid,
  p_from    date default null,
  p_days    integer default 14,
  p_limit   integer default 50,
  p_step    interval default interval '30 minutes'
)
returns table (
  starts_at   timestamptz,
  ends_at     timestamptz,
  resource_id uuid,
  resource_name text
)
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_tz      text;
  v_service services%rowtype;
  v_from    date;
  v_days    integer;
begin
  select timezone into v_tz from tenants where id = p_tenant;
  if v_tz is null then
    raise exception 'tenant_not_found' using errcode = 'P0002';
  end if;

  select * into v_service
  from services
  where id = p_service and tenant_id = p_tenant and is_active;

  if not found then
    raise exception 'service_not_found' using errcode = 'P0002';
  end if;

  v_from := coalesce(p_from, (now() at time zone v_tz)::date);
  v_days := least(60, greatest(1, coalesce(p_days, 14)));

  return query
  with days as (
    select generate_series(v_from, v_from + (v_days - 1), interval '1 day')::date as d
  ),
  posts as (
    -- Только посты, пригодные для этой услуги и включённые.
    select r.id, r.name, r.sort_order
    from resources r
    join service_resources sr
      on sr.tenant_id = r.tenant_id
     and sr.resource_id = r.id
     and sr.service_id = p_service
    where r.tenant_id = p_tenant and r.is_active
  ),
  -- Моменты приёма внутри окон работы, с шагом p_step.
  starts as (
    select p.id as resource_id, p.name as resource_name, p.sort_order,
           generate_series(w.window_start, w.window_end - interval '1 minute', p_step) as ts
    from days
    cross join posts p
    cross join lateral app.acceptance_windows(p_tenant, p.id, days.d) w
  )
  select s.ts,
         s.ts + make_interval(mins => v_service.duration_minutes),
         s.resource_id,
         s.resource_name
  from starts s
  where s.ts > now()
    -- Выдача тоже должна попасть в окно приёма — возможно, другого дня.
    and app.is_acceptance_moment(
          p_tenant, s.resource_id,
          s.ts + make_interval(mins => v_service.duration_minutes), 'end')
    -- Пост свободен на всю занятость, включая буферы.
    and not exists (
      select 1 from resource_occupancies o
      where o.tenant_id = p_tenant
        and o.resource_id = s.resource_id
        and o.during && tstzrange(
              s.ts - make_interval(mins => v_service.buffer_before_minutes),
              s.ts + make_interval(mins => v_service.duration_minutes
                                          + v_service.buffer_after_minutes),
              '[)')
    )
  order by s.ts, s.sort_order
  limit greatest(1, least(200, coalesce(p_limit, 50)));
end
$$;

comment on function app.find_free_slots is
  'Единственный расчёт свободного времени. Используется и формой записи, и помощником, поэтому их ответы не могут разойтись.';


-- Занятые интервалы для показа в календаре клиента.
-- Отдаёт только границы: чем занято и чья это бронь — не раскрывается.
create or replace function app.busy_intervals(
  p_tenant uuid,
  p_from   date,
  p_days   integer default 14
)
returns table (resource_id uuid, busy_from timestamptz, busy_to timestamptz)
language sql stable
set search_path = public, pg_temp
as $$
  select o.resource_id, lower(o.during), upper(o.during)
  from resource_occupancies o
  where o.tenant_id = p_tenant
    and o.during && tstzrange(
          (p_from::timestamp) at time zone (select timezone from tenants where id = p_tenant),
          ((p_from + least(60, greatest(1, p_days)))::timestamp)
            at time zone (select timezone from tenants where id = p_tenant),
          '[)')
  order by lower(o.during);
$$;

grant execute on function app.find_free_slots(uuid, uuid, date, integer, integer, interval) to service_role;
grant execute on function app.busy_intervals(uuid, date, integer) to service_role;
