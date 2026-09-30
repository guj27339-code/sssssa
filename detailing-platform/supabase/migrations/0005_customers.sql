-- 0005_customers.sql
-- Клиенты. Персональные данные: anon не читает эту таблицу ни при каких
-- условиях (инвариант 6). Регистрация клиенту не нужна — строка заводится
-- сервером в момент записи.

create table customers (
  id         uuid not null default gen_random_uuid(),
  tenant_id  uuid not null references tenants (id) on delete cascade,

  name       text not null,

  -- Нормализованный вид: только цифры с ведущим плюсом.
  phone      text not null,

  -- Помечает записи, созданные наполнением preview (инвариант 11).
  is_demo    boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (id),
  constraint customers_tenant_id_key unique (tenant_id, id),
  constraint customers_name_not_blank check (length(btrim(name)) > 0),
  constraint customers_phone_format check (phone ~ '^\+[1-9][0-9]{7,14}$')
);

-- Повторный визит того же телефона не плодит дубли внутри тенанта.
create unique index customers_tenant_phone_key on customers (tenant_id, phone);

create trigger customers_touch
  before update on customers
  for each row execute function app.touch_updated_at();

comment on table customers is
  'Персональные данные. GRANT для anon не выдаётся; клиент видит только свою бронь через токен.';
comment on column customers.phone is
  'E.164 без пробелов и скобок. Нормализация выполняется на сервере до вставки.';
