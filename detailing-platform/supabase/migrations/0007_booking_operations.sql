-- 0007_booking_operations.sql
-- Атомарные операции над бронью: создание, перенос, отмена.
--
-- Инвариант 4: каждая операция — одна SQL-транзакция. Повторный запрос
-- идемпотентен. Неудачный перенос не теряет исходную бронь: вся функция
-- откатывается, и старая занятость остаётся на месте.
--
-- Инвариант 3: длительность и буферы берутся из services по service_id.
-- Клиент передаёт только услугу, момент начала и свои контакты.

-- Диапазон занятости поста для услуги, начинающейся в p_starts_at.
-- Включает буферы; сама услуга занимает более узкий интервал.
create or replace function app.occupancy_range(
  p_service_id uuid,
  p_tenant     uuid,
  p_starts_at  timestamptz
) returns tstzrange
language sql stable
set search_path = public, pg_temp
as $$
  select tstzrange(
           p_starts_at - make_interval(mins => s.buffer_before_minutes),
           p_starts_at + make_interval(mins => s.duration_minutes + s.buffer_after_minutes),
           '[)'
         )
  from services s
  where s.id = p_service_id and s.tenant_id = p_tenant;
$$;


-- Попадает ли момент в окно приёма поста.
-- p_edge = 'start' — принимаем машину: open <= ts < close.
-- p_edge = 'end'   — отдаём машину:    open <  ts <= close.
create or replace function app.is_acceptance_moment(
  p_tenant   uuid,
  p_resource uuid,
  p_ts       timestamptz,
  p_edge     text
) returns boolean
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_tz        text;
  v_local_day date;
  w           record;
begin
  select timezone into v_tz from tenants where id = p_tenant;
  if v_tz is null then
    return false;
  end if;

  -- Календарный день в зоне студии, а не в зоне сессии.
  v_local_day := (p_ts at time zone v_tz)::date;

  for w in
    select * from app.acceptance_windows(p_tenant, p_resource, v_local_day)
  loop
    if p_edge = 'start' then
      if p_ts >= w.window_start and p_ts < w.window_end then
        return true;
      end if;
    else
      if p_ts > w.window_start and p_ts <= w.window_end then
        return true;
      end if;
    end if;
  end loop;

  return false;
end
$$;

comment on function app.is_acceptance_moment(uuid, uuid, timestamptz, text) is
  'Проверяет момент приёма или выдачи. Занятость между этими моментами может идти и в закрытые часы — многодневная работа это нормально.';


-- Нормализация телефона к E.164. Всё, кроме цифр, отбрасывается;
-- ведущая 8 российского формата заменяется на 7.
create or replace function app.normalize_phone(p_raw text) returns text
language plpgsql immutable
as $$
declare
  v_digits text;
begin
  v_digits := regexp_replace(coalesce(p_raw, ''), '[^0-9]', '', 'g');

  if length(v_digits) = 11 and left(v_digits, 1) = '8' then
    v_digits := '7' || substr(v_digits, 2);
  end if;

  if length(v_digits) between 8 and 15 then
    return '+' || v_digits;
  end if;

  raise exception 'invalid_phone' using errcode = '22023';
end
$$;


-- Создание брони.
--
-- p_resource_id = NULL — сервер сам подбирает первый подходящий свободный пост.
-- p_token_hash — sha256 токена, посчитанный вызывающей Edge Function.
--                Сам токен в базу не попадает.
create or replace function app.create_booking(
  p_tenant          uuid,
  p_service_id      uuid,
  p_starts_at       timestamptz,
  p_customer_name   text,
  p_customer_phone  text,
  p_token_hash      bytea,
  p_idempotency_key text default null,
  p_resource_id     uuid  default null
)
returns bookings
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_service   services%rowtype;
  v_tenant    tenants%rowtype;
  v_existing  bookings%rowtype;
  v_customer  customers%rowtype;
  v_booking   bookings%rowtype;
  v_phone     text;
  v_range     tstzrange;
  v_ends_at   timestamptz;
  v_candidate uuid;
  v_placed    boolean := false;
begin
  -- Повтор того же запроса возвращает ту же бронь, ничего не создавая.
  if p_idempotency_key is not null then
    select * into v_existing
    from bookings
    where tenant_id = p_tenant and idempotency_key = p_idempotency_key;

    if found then
      return v_existing;
    end if;
  end if;

  select * into v_tenant from tenants where id = p_tenant;
  if not found then
    raise exception 'tenant_not_found' using errcode = 'P0002';
  end if;
  if v_tenant.status = 'suspended' then
    raise exception 'tenant_suspended' using errcode = 'P0001';
  end if;

  -- Длительность, буферы и цена — только из базы.
  select * into v_service
  from services
  where id = p_service_id and tenant_id = p_tenant and is_active;

  if not found then
    raise exception 'service_not_found' using errcode = 'P0002';
  end if;

  v_range   := app.occupancy_range(p_service_id, p_tenant, p_starts_at);
  v_ends_at := p_starts_at + make_interval(mins => v_service.duration_minutes);

  if p_starts_at < now() then
    raise exception 'starts_in_past' using errcode = 'P0001';
  end if;

  v_phone := app.normalize_phone(p_customer_phone);

  -- Клиент без регистрации: строка заводится или переиспользуется по телефону.
  insert into customers (tenant_id, name, phone, is_demo)
  values (p_tenant, btrim(p_customer_name), v_phone, v_tenant.is_demo)
  on conflict (tenant_id, phone) do update
    set name = excluded.name
  returning * into v_customer;

  -- Кандидаты: подходящие активные посты. Если пост задан явно — только он.
  for v_candidate in
    select r.id
    from resources r
    join service_resources sr
      on sr.tenant_id = r.tenant_id
     and sr.resource_id = r.id
     and sr.service_id = p_service_id
    where r.tenant_id = p_tenant
      and r.is_active
      and (p_resource_id is null or r.id = p_resource_id)
    order by r.sort_order, r.id
  loop
    -- Окна приёма проверяются для конкретного поста: у постов
    -- могут быть свои часы и свои исключения.
    if not app.is_acceptance_moment(p_tenant, v_candidate, p_starts_at, 'start') then
      continue;
    end if;
    if not app.is_acceptance_moment(p_tenant, v_candidate, v_ends_at, 'end') then
      continue;
    end if;

    begin
      insert into bookings (
        tenant_id, service_id, resource_id, customer_id,
        starts_at, ends_at,
        price_kopecks_snapshot, duration_minutes_snapshot,
        access_token_hash, idempotency_key, is_demo
      )
      values (
        p_tenant, p_service_id, v_candidate, v_customer.id,
        p_starts_at, v_ends_at,
        v_service.price_kopecks, v_service.duration_minutes,
        p_token_hash, p_idempotency_key, v_tenant.is_demo
      )
      returning * into v_booking;

      insert into resource_occupancies (tenant_id, resource_id, kind, during, booking_id)
      values (p_tenant, v_candidate, 'booking', v_range, v_booking.id);

      v_placed := true;
      exit;

    exception
      -- Пост занят: пробуем следующий. Блок EXCEPTION ставит savepoint,
      -- поэтому откатывается только неудачная попытка.
      when exclusion_violation then
        continue;
    end;
  end loop;

  if not v_placed then
    raise exception 'no_free_resource' using errcode = 'P0001';
  end if;

  return v_booking;
end
$$;

comment on function app.create_booking is
  'Создание брони одной транзакцией. Цену, длительность и tenant берёт из базы. Повтор с тем же ключом идемпотентности возвращает исходную бронь.';


-- Перенос брони на другой момент и, возможно, другой пост.
-- При неудаче вся функция откатывается и исходная бронь остаётся.
create or replace function app.reschedule_booking(
  p_tenant       uuid,
  p_booking_id   uuid,
  p_new_start    timestamptz,
  p_new_resource uuid default null
)
returns bookings
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_booking  bookings%rowtype;
  v_service  services%rowtype;
  v_target   uuid;
  v_range    tstzrange;
  v_ends_at  timestamptz;
begin
  select * into v_booking
  from bookings
  where id = p_booking_id and tenant_id = p_tenant
  for update;

  if not found then
    raise exception 'booking_not_found' using errcode = 'P0002';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'booking_not_active' using errcode = 'P0001';
  end if;

  select * into v_service
  from services
  where id = v_booking.service_id and tenant_id = p_tenant;

  v_target  := coalesce(p_new_resource, v_booking.resource_id);
  v_range   := app.occupancy_range(v_booking.service_id, p_tenant, p_new_start);
  v_ends_at := p_new_start + make_interval(mins => v_booking.duration_minutes_snapshot);

  -- Новый пост обязан уметь эту услугу.
  if not exists (
    select 1 from service_resources
    where tenant_id = p_tenant
      and service_id = v_booking.service_id
      and resource_id = v_target
  ) then
    raise exception 'resource_not_compatible' using errcode = 'P0001';
  end if;

  if not app.is_acceptance_moment(p_tenant, v_target, p_new_start, 'start') then
    raise exception 'outside_acceptance_window' using errcode = 'P0001';
  end if;
  if not app.is_acceptance_moment(p_tenant, v_target, v_ends_at, 'end') then
    raise exception 'outside_acceptance_window' using errcode = 'P0001';
  end if;

  -- Снимаем старую занятость и ставим новую в одной транзакции.
  -- Если новая пересечётся с чужой бронью, EXCLUDE поднимет исключение,
  -- транзакция откатится целиком и старая занятость вернётся.
  delete from resource_occupancies where booking_id = p_booking_id;

  insert into resource_occupancies (tenant_id, resource_id, kind, during, booking_id)
  values (p_tenant, v_target, 'booking', v_range, p_booking_id);

  update bookings
     set starts_at = p_new_start,
         ends_at = v_ends_at,
         resource_id = v_target
   where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end
$$;

comment on function app.reschedule_booking is
  'Перенос одной транзакцией. При конфликте EXCLUDE вся операция откатывается — исходная бронь и её занятость остаются нетронутыми.';


-- Отмена: бронь остаётся в истории, занятость освобождается.
create or replace function app.cancel_booking(
  p_tenant     uuid,
  p_booking_id uuid
)
returns bookings
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_booking bookings%rowtype;
begin
  select * into v_booking
  from bookings
  where id = p_booking_id and tenant_id = p_tenant
  for update;

  if not found then
    raise exception 'booking_not_found' using errcode = 'P0002';
  end if;

  -- Повторная отмена не считается ошибкой: запрос идемпотентен.
  if v_booking.status = 'cancelled' then
    return v_booking;
  end if;

  delete from resource_occupancies where booking_id = p_booking_id;

  update bookings
     set status = 'cancelled',
         cancelled_at = now()
   where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end
$$;


-- Ручная блокировка поста владельцем. Пишется в ту же таблицу занятости,
-- поэтому не может пересечься с бронью.
create or replace function app.block_resource(
  p_tenant     uuid,
  p_resource   uuid,
  p_from       timestamptz,
  p_to         timestamptz,
  p_note       text default null
)
returns resource_occupancies
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row resource_occupancies%rowtype;
begin
  if p_to <= p_from then
    raise exception 'invalid_range' using errcode = '22023';
  end if;

  insert into resource_occupancies (tenant_id, resource_id, kind, during, note)
  values (p_tenant, p_resource, 'block', tstzrange(p_from, p_to, '[)'), p_note)
  returning * into v_row;

  return v_row;
exception
  when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'P0001';
end
$$;

comment on function app.block_resource is
  'Закрытие поста владельцем. Та же таблица, что и брони, — пересечение невозможно по построению.';
