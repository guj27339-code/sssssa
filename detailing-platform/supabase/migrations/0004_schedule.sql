-- 0004_schedule.sql
-- Рабочие часы и исключения.
--
-- Инвариант 3: рабочие часы задают моменты приёма — то есть когда клиента
-- можно ПРИНЯТЬ (начало услуги) и когда можно ОТДАТЬ машину (конец услуги).
-- Они не обязаны покрывать всю занятость: многодневная работа идёт и ночью,
-- пока студия закрыта, и это нормально.

create table working_hours (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,

  -- NULL = правило действует на все посты тенанта.
  resource_id uuid,

  -- ISO-8601: 1 = понедельник, 7 = воскресенье.
  weekday     smallint not null,

  -- Локальное время студии, без даты и без зоны.
  opens_at    time not null,
  closes_at   time not null,

  created_at  timestamptz not null default now(),

  constraint working_hours_resource_fk
    foreign key (tenant_id, resource_id) references resources (tenant_id, id) on delete cascade,
  constraint working_hours_weekday_range check (weekday between 1 and 7),
  constraint working_hours_order check (closes_at > opens_at)
);

-- Одно правило на пару (пост, день). Отдельные индексы, потому что NULL
-- в resource_id не участвует в обычном UNIQUE.
create unique index working_hours_resource_unique
  on working_hours (tenant_id, resource_id, weekday)
  where resource_id is not null;

create unique index working_hours_tenant_wide_unique
  on working_hours (tenant_id, weekday)
  where resource_id is null;

comment on table working_hours is
  'Окна приёма и выдачи. Закрытая студия не мешает уже идущей многодневной работе.';
comment on column working_hours.closes_at is
  'Строго больше opens_at. Смена через полночь задаётся двумя строками на соседние дни.';


-- Исключения: праздники, переносы, укороченные дни.
create table schedule_exceptions (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants (id) on delete cascade,
  resource_id   uuid,

  -- Конкретная календарная дата в зоне тенанта.
  exception_date date not null,

  -- true = в этот день не принимаем вовсе; тогда opens_at/closes_at пусты.
  is_closed     boolean not null default true,
  opens_at      time,
  closes_at     time,

  note          text,
  created_at    timestamptz not null default now(),

  constraint schedule_exceptions_resource_fk
    foreign key (tenant_id, resource_id) references resources (tenant_id, id) on delete cascade,

  constraint schedule_exceptions_shape check (
    (is_closed and opens_at is null and closes_at is null)
    or
    (not is_closed and opens_at is not null and closes_at is not null and closes_at > opens_at)
  )
);

create unique index schedule_exceptions_resource_unique
  on schedule_exceptions (tenant_id, resource_id, exception_date)
  where resource_id is not null;

create unique index schedule_exceptions_tenant_wide_unique
  on schedule_exceptions (tenant_id, exception_date)
  where resource_id is null;

comment on table schedule_exceptions is
  'Перекрывает working_hours на конкретную дату. Правило для поста важнее общего правила тенанта.';


-- Окна приёма для поста на дату, с учётом исключений и зоны тенанта.
-- Возвращает моменты в timestamptz, чтобы вызывающий код не занимался
-- преобразованием зон самостоятельно.
create or replace function app.acceptance_windows(
  p_tenant   uuid,
  p_resource uuid,
  p_date     date
)
returns table (window_start timestamptz, window_end timestamptz)
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_tz      text;
  v_weekday smallint;
  v_opens   time;
  v_closes  time;
  v_found   boolean := false;
begin
  select timezone into v_tz from tenants where id = p_tenant;
  if v_tz is null then
    return;
  end if;

  v_weekday := extract(isodow from p_date)::smallint;

  -- Приоритет: исключение для поста → исключение тенанта →
  -- рабочие часы поста → рабочие часы тенанта.
  select e.is_closed, e.opens_at, e.closes_at
    into v_found, v_opens, v_closes
  from schedule_exceptions e
  where e.tenant_id = p_tenant
    and e.exception_date = p_date
    and (e.resource_id = p_resource or e.resource_id is null)
  order by (e.resource_id is not null) desc
  limit 1;

  if found then
    if v_found then
      return;                         -- в этот день не принимаем
    end if;
  else
    select w.opens_at, w.closes_at
      into v_opens, v_closes
    from working_hours w
    where w.tenant_id = p_tenant
      and w.weekday = v_weekday
      and (w.resource_id = p_resource or w.resource_id is null)
    order by (w.resource_id is not null) desc
    limit 1;

    if not found then
      return;                         -- расписания на этот день нет
    end if;
  end if;

  return query
  select (p_date + v_opens)  at time zone v_tz,
         (p_date + v_closes) at time zone v_tz;
end
$$;

comment on function app.acceptance_windows(uuid, uuid, date) is
  'Окно приёма на дату с учётом исключений. Границы возвращаются в UTC-моментах, пересчёт из локального времени тенанта сделан внутри.';
