-- 0006_bookings_occupancies.sql
-- Брони и занятость постов.
--
-- Инвариант 4: бронь и ручная блокировка поста живут в ОДНОЙ таблице
-- resource_occupancies с ограничением EXCLUDE. Отдельной таблицы блокировок
-- нет — иначе два источника правды разъедутся и пересечения проскочат.

create type app.booking_status as enum (
  'confirmed',   -- записан, ждём
  'completed',   -- работа выполнена
  'cancelled',   -- отменён
  'no_show'      -- не приехал
);

create type app.occupancy_kind as enum (
  'booking',     -- занято бронью клиента
  'block'        -- пост закрыт владельцем: ремонт, обслуживание, личное время
);


create table bookings (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,

  service_id  uuid not null,
  resource_id uuid not null,
  customer_id uuid not null,

  status      app.booking_status not null default 'confirmed',

  -- Интервал самой услуги, без буферов. Именно его видит клиент.
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,

  -- Снимок цены и длительности на момент записи: последующая правка
  -- прайса не должна задним числом менять уже созданную бронь.
  price_kopecks_snapshot bigint,
  duration_minutes_snapshot integer not null,

  -- sha256 от выданного клиенту токена. Сам токен в БД не хранится.
  access_token_hash bytea not null,

  -- Ключ идемпотентности запроса на создание (инвариант 4).
  idempotency_key text,

  is_demo     boolean not null default false,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  cancelled_at timestamptz,

  primary key (id),
  constraint bookings_tenant_id_key unique (tenant_id, id),

  constraint bookings_service_fk
    foreign key (tenant_id, service_id)  references services  (tenant_id, id),
  constraint bookings_resource_fk
    foreign key (tenant_id, resource_id) references resources (tenant_id, id),
  constraint bookings_customer_fk
    foreign key (tenant_id, customer_id) references customers (tenant_id, id),

  constraint bookings_range_order check (ends_at > starts_at),
  constraint bookings_cancel_shape check (
    (status = 'cancelled' and cancelled_at is not null)
    or
    (status <> 'cancelled' and cancelled_at is null)
  )
);

-- Повтор запроса с тем же ключом не создаёт вторую бронь.
create unique index bookings_idempotency_key
  on bookings (tenant_id, idempotency_key)
  where idempotency_key is not null;

-- Поиск брони по токену — точное совпадение хэша.
create unique index bookings_access_token_hash_key
  on bookings (access_token_hash);

create index bookings_tenant_time_idx  on bookings (tenant_id, starts_at);
create index bookings_customer_idx     on bookings (tenant_id, customer_id);

create trigger bookings_touch
  before update on bookings
  for each row execute function app.touch_updated_at();

comment on column bookings.access_token_hash is
  'sha256(token). Восстановить токен из базы нельзя. Повторная выдача того же токена делается пересчётом HMAC от ключа идемпотентности на сервере.';
comment on column bookings.duration_minutes_snapshot is
  'Длительность на момент записи. Клиент её не передаёт — сервер берёт из services.';


-- Единственный источник правды о занятости поста.
create table resource_occupancies (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,
  resource_id uuid not null,

  kind        app.occupancy_kind not null,

  -- Непрерывный диапазон с буферами. Полуинтервал: конец одной занятости
  -- может совпадать с началом следующей, и это не пересечение.
  during      tstzrange not null,

  -- Заполнено только для kind = 'booking'.
  booking_id  uuid,

  -- Причина закрытия поста, для kind = 'block'.
  note        text,

  created_at  timestamptz not null default now(),

  primary key (id),

  constraint resource_occupancies_resource_fk
    foreign key (tenant_id, resource_id) references resources (tenant_id, id) on delete cascade,
  constraint resource_occupancies_booking_fk
    foreign key (tenant_id, booking_id) references bookings (tenant_id, id) on delete cascade,

  constraint resource_occupancies_range_shape check (
    not isempty(during)
    and lower_inc(during) and not upper_inc(during)
    and lower(during) is not null and upper(during) is not null
  ),

  constraint resource_occupancies_kind_shape check (
    (kind = 'booking' and booking_id is not null)
    or
    (kind = 'block'   and booking_id is null)
  ),

  -- Сердце инварианта 4: на одном посту одного тенанта два диапазона
  -- пересекаться не могут, независимо от того, бронь это или блокировка.
  constraint resource_occupancies_no_overlap
    exclude using gist (
      tenant_id   with =,
      resource_id with =,
      during      with &&
    )
);

-- Одна бронь — одна строка занятости.
create unique index resource_occupancies_booking_key
  on resource_occupancies (booking_id)
  where booking_id is not null;

create index resource_occupancies_lookup_idx
  on resource_occupancies using gist (tenant_id, resource_id, during);

comment on table resource_occupancies is
  'Занятость поста. И бронь, и ручная блокировка. EXCLUDE не даёт им пересечься — проверка выполняется базой, а не приложением.';
comment on column resource_occupancies.during is
  'Интервал услуги, расширенный буферами услуги. Может пересекать полночь и длиться несколько суток.';
