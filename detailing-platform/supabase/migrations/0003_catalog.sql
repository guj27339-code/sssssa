-- 0003_catalog.sql
-- Ресурсы (посты), услуги и совместимость услуги с ресурсом.
--
-- Инвариант 3: услуга занимает конкретный подходящий ресурс на непрерывный
-- диапазон, включая буфер и возможность растянуться на несколько суток.
-- Длительность и цена живут здесь и берутся сервером; клиент их не передаёт.
--
-- Составные внешние ключи (tenant_id, id) не дают строке одного тенанта
-- сослаться на строку другого. Для этого в каждой родительской таблице
-- заведён UNIQUE (tenant_id, id) — он и служит целью ссылки.

create table resources (
  id         uuid not null default gen_random_uuid(),
  tenant_id  uuid not null references tenants (id) on delete cascade,
  name       text not null,
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (id),
  constraint resources_tenant_id_key unique (tenant_id, id),
  constraint resources_name_not_blank check (length(btrim(name)) > 0)
);

create index resources_tenant_idx on resources (tenant_id, sort_order);

create trigger resources_touch
  before update on resources
  for each row execute function app.touch_updated_at();

comment on table resources is
  'Рабочий пост студии. Бронь всегда занимает конкретный ресурс, а не абстрактный слот.';


create table services (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references tenants (id) on delete cascade,
  name             text not null,
  description      text,

  -- Чистое время работы над автомобилем.
  duration_minutes integer not null,

  -- Буферы до и после: подготовка поста и приёмка. Входят в занятость
  -- ресурса, но не в интервал самой услуги.
  buffer_before_minutes integer not null default 0,
  buffer_after_minutes  integer not null default 0,

  -- Цена в копейках. Источник истины — сервер, клиент её не задаёт.
  price_kopecks    bigint,

  sort_order       integer not null default 0,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  primary key (id),
  constraint services_tenant_id_key unique (tenant_id, id),
  constraint services_name_not_blank check (length(btrim(name)) > 0),

  -- Верхняя граница в 30 суток допускает многодневные работы
  -- (оклейка целиком, керамика с выдержкой) и при этом отсекает опечатки.
  constraint services_duration_sane
    check (duration_minutes between 5 and 60 * 24 * 30),
  constraint services_buffers_sane
    check (buffer_before_minutes between 0 and 60 * 24
       and buffer_after_minutes  between 0 and 60 * 24),
  constraint services_price_sane
    check (price_kopecks is null or price_kopecks >= 0)
);

create index services_tenant_idx on services (tenant_id, sort_order);

create trigger services_touch
  before update on services
  for each row execute function app.touch_updated_at();

comment on column services.price_kopecks is
  'NULL = цена по осмотру. Клиент никогда не передаёт цену в запросе на бронь.';
comment on column services.duration_minutes is
  'Может превышать сутки: занятость ресурса тогда переходит через полночь непрерывным диапазоном.';


-- Какие посты пригодны для услуги. Без записи здесь услуга не бронируется.
create table service_resources (
  tenant_id   uuid not null,
  service_id  uuid not null,
  resource_id uuid not null,

  primary key (tenant_id, service_id, resource_id),

  constraint service_resources_service_fk
    foreign key (tenant_id, service_id)  references services  (tenant_id, id) on delete cascade,
  constraint service_resources_resource_fk
    foreign key (tenant_id, resource_id) references resources (tenant_id, id) on delete cascade
);

create index service_resources_resource_idx
  on service_resources (tenant_id, resource_id);

comment on table service_resources is
  'Совместимость услуги и поста. Составные FK гарантируют, что обе стороны принадлежат одному тенанту.';
