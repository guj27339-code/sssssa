-- 0010_access_notifications_limits.sql
-- Доступ клиента к своей брони, очередь уведомлений и счётчики лимитов.
--
-- Инвариант 5: клиент не регистрируется. Доступ к ОДНОЙ своей брони даёт
-- криптографический токен; в базе лежит только его sha256.
-- Повторная выдача того же доступа при retry обеспечивается тем, что токен
-- выводится детерминированно: HMAC(секрет сервера, tenant || ключ
-- идемпотентности). База токен не хранит и восстановить его не может.
--
-- Инвариант 10: рассылка идёт через outbox с арендой (lease), дедупликацией
-- и корректной обработкой переноса и отмены.
-- Инвариант 12: общие атомарные счётчики в БД ограничивают публичные
-- запросы и расходы на модель.

-- Чтение брони по токену. Единственный путь клиента к своим данным.
create or replace function app.booking_by_token(p_token_hash bytea)
returns table (
  booking_id     uuid,
  tenant_slug    text,
  tenant_name    text,
  tenant_timezone text,
  status         app.booking_status,
  starts_at      timestamptz,
  ends_at        timestamptz,
  service_name   text,
  resource_name  text,
  price_kopecks  bigint,
  customer_name  text,
  customer_phone text
)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select
    b.id, t.slug, t.name, t.timezone,
    b.status, b.starts_at, b.ends_at,
    s.name, r.name,
    b.price_kopecks_snapshot,
    c.name, c.phone
  from bookings b
  join tenants   t on t.id = b.tenant_id
  join services  s on s.tenant_id = b.tenant_id and s.id = b.service_id
  join resources r on r.tenant_id = b.tenant_id and r.id = b.resource_id
  join customers c on c.tenant_id = b.tenant_id and c.id = b.customer_id
  where b.access_token_hash = p_token_hash;
$$;

comment on function app.booking_by_token(bytea) is
  'Одна бронь по хэшу токена. Перебор невозможен: индекс уникален, а токен — 32 случайных байта от HMAC.';


-- ── Очередь уведомлений ──────────────────────────────────────────────────

create type app.notification_channel as enum ('push', 'ics');
create type app.notification_state   as enum ('pending', 'leased', 'sent', 'failed', 'cancelled');

create table notification_jobs (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,
  booking_id  uuid not null,

  channel     app.notification_channel not null default 'push',

  -- Тип события: reminder_24h, rescheduled, cancelled.
  event       text not null,

  -- Когда отправлять.
  send_after  timestamptz not null,

  state       app.notification_state not null default 'pending',

  -- Аренда: воркер занимает задачу до этого момента. Истекла — задача
  -- снова свободна, даже если воркер умер.
  leased_until timestamptz,
  lease_owner  uuid,

  attempts    integer not null default 0,
  last_error  text,

  -- Ключ дедупликации: одно событие на бронь отправляется один раз.
  dedupe_key  text not null,

  -- Ни одно уведомление демо-тенанта наружу не уходит (инвариант 11).
  is_demo     boolean not null default false,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  primary key (id),
  constraint notification_jobs_booking_fk
    foreign key (tenant_id, booking_id) references bookings (tenant_id, id) on delete cascade,
  constraint notification_jobs_attempts_sane check (attempts >= 0)
);

create unique index notification_jobs_dedupe_key
  on notification_jobs (tenant_id, dedupe_key);

create index notification_jobs_claimable_idx
  on notification_jobs (send_after)
  where state in ('pending', 'leased');

create trigger notification_jobs_touch
  before update on notification_jobs
  for each row execute function app.touch_updated_at();

comment on column notification_jobs.leased_until is
  'Срок аренды. Просроченная аренда освобождает задачу — упавший воркер не блокирует очередь навсегда.';


-- Взять партию задач в работу. skip locked не даёт двум воркерам
-- захватить одну задачу.
create or replace function app.claim_notification_jobs(
  p_limit      integer default 20,
  p_lease      interval default interval '2 minutes',
  p_owner      uuid default gen_random_uuid()
)
returns setof notification_jobs
language sql volatile security definer
set search_path = public, pg_temp
as $$
  with picked as (
    select j.id
    from notification_jobs j
    where j.send_after <= now()
      and (
        j.state = 'pending'
        or (j.state = 'leased' and j.leased_until < now())
      )
    order by j.send_after
    limit p_limit
    for update skip locked
  )
  update notification_jobs j
     set state = 'leased',
         leased_until = now() + p_lease,
         lease_owner = p_owner,
         attempts = j.attempts + 1
    from picked
   where j.id = picked.id
  returning j.*;
$$;


create or replace function app.finish_notification_job(
  p_id      uuid,
  p_success boolean,
  p_error   text default null
)
returns void
language sql volatile security definer
set search_path = public, pg_temp
as $$
  update notification_jobs
     set state = case when p_success then 'sent'::app.notification_state
                      else 'pending'::app.notification_state end,
         leased_until = null,
         lease_owner = null,
         last_error = p_error,
         -- Отступ растёт с числом попыток, потолок — час.
         send_after = case when p_success then send_after
                           else now() + least(interval '1 hour',
                                              make_interval(mins => attempts * 5)) end
   where id = p_id;
$$;


-- Перенос и отмена должны переписать очередь, иначе клиент получит
-- напоминание на старое время.
create or replace function app.sync_notifications_for_booking(p_booking uuid)
returns void
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_b bookings%rowtype;
begin
  select * into v_b from bookings where id = p_booking;
  if not found then
    return;
  end if;

  -- Ещё не отправленные напоминания на старое время больше не актуальны.
  update notification_jobs
     set state = 'cancelled'
   where booking_id = p_booking
     and event = 'reminder_24h'
     and state in ('pending', 'leased');

  if v_b.status <> 'confirmed' then
    return;
  end if;

  -- Напоминание за сутки. Если до брони меньше суток — не ставим.
  if v_b.starts_at - interval '24 hours' > now() then
    insert into notification_jobs
      (tenant_id, booking_id, channel, event, send_after, dedupe_key, is_demo)
    values
      (v_b.tenant_id, p_booking, 'push', 'reminder_24h',
       v_b.starts_at - interval '24 hours',
       'reminder_24h:' || p_booking::text || ':' || extract(epoch from v_b.starts_at)::bigint::text,
       v_b.is_demo)
    on conflict (tenant_id, dedupe_key) do nothing;
  end if;
end
$$;

comment on function app.sync_notifications_for_booking(uuid) is
  'Переписывает очередь под текущее состояние брони. Ключ дедупликации включает время начала, поэтому перенос создаёт новую задачу, а старая гасится.';


create table push_subscriptions (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,
  booking_id  uuid,

  endpoint    text not null,
  p256dh      text not null,
  auth        text not null,

  created_at  timestamptz not null default now(),

  primary key (id),
  constraint push_subscriptions_booking_fk
    foreign key (tenant_id, booking_id) references bookings (tenant_id, id) on delete cascade
);

create unique index push_subscriptions_endpoint_key on push_subscriptions (endpoint);


-- ── Счётчики лимитов ─────────────────────────────────────────────────────
-- Общие на всех воркеров, инкремент атомарен.

create table usage_counters (
  tenant_id  uuid not null references tenants (id) on delete cascade,

  -- Назначение: 'public_requests', 'llm_tokens', 'llm_calls'.
  bucket     text not null,

  -- Начало окна учёта: час или сутки.
  window_start timestamptz not null,

  used       bigint not null default 0,
  limit_value bigint not null,

  primary key (tenant_id, bucket, window_start)
);

comment on table usage_counters is
  'Атомарные счётчики лимитов. Инкремент и проверка — одним оператором, поэтому параллельные воркеры не пробивают предел.';


-- Возвращает true, если лимит НЕ исчерпан и расход засчитан.
create or replace function app.consume_quota(
  p_tenant uuid,
  p_bucket text,
  p_amount bigint,
  p_limit  bigint,
  p_window interval default interval '1 hour'
)
returns boolean
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_window timestamptz;
  v_used   bigint;
begin
  -- Границу окна выравниваем, чтобы все воркеры писали в одну строку.
  v_window := to_timestamp(floor(extract(epoch from now())
                                 / extract(epoch from p_window))
                           * extract(epoch from p_window));

  insert into usage_counters (tenant_id, bucket, window_start, used, limit_value)
  values (p_tenant, p_bucket, v_window, p_amount, p_limit)
  on conflict (tenant_id, bucket, window_start) do update
    set used = usage_counters.used + p_amount
  returning used into v_used;

  if v_used > p_limit then
    -- Перебор откатываем, чтобы отказанный запрос не съедал квоту.
    update usage_counters
       set used = used - p_amount
     where tenant_id = p_tenant and bucket = p_bucket and window_start = v_window;
    return false;
  end if;

  return true;
end
$$;

comment on function app.consume_quota is
  'Атомарный расход квоты. При отказе списание откатывается, поэтому отклонённый запрос не уменьшает остаток.';
