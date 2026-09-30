-- 0002_tenants.sql
-- Тенанты и членство владельцев.
--
-- Инвариант 1: новая студия не заменяет предыдущую — slug уникален,
-- строки независимы, удаление одной не трогает остальные.
-- Инвариант 5: публичной регистрации владельца нет. Членство заводит
-- только service_role, поэтому политик INSERT для authenticated тут нет.

create type app.tenant_status as enum ('preview', 'live', 'suspended');
create type app.member_role   as enum ('owner', 'staff');

create table tenants (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null,
  name          text not null,
  timezone      text not null default 'Europe/Moscow',
  status        app.tenant_status not null default 'preview',

  -- Оформление: один акцентный цвет, из него собирается тема.
  accent_color  text not null default '#4690FF',

  -- Публичная часть конфигурации: контакты, тексты, адреса.
  -- Сюда не кладутся секреты — таблицу читает anon.
  public_config jsonb not null default '{}'::jsonb,

  -- Служебная часть: пороги, лимиты, флаги. anon не читает (см. 0011_rls).
  private_config jsonb not null default '{}'::jsonb,

  -- Отметка, что данные демонстрационные (инвариант 11).
  is_demo       boolean not null default true,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint tenants_slug_format
    check (slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$'),
  constraint tenants_accent_format
    check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  -- Часовой пояс должен существовать в базе, иначе расчёты окон поедут.
  constraint tenants_timezone_known
    check (now() at time zone timezone is not null)
);

create unique index tenants_slug_key on tenants (slug);

create trigger tenants_touch
  before update on tenants
  for each row execute function app.touch_updated_at();

comment on column tenants.private_config is
  'Непубличные настройки. anon не имеет SELECT на эту колонку — доступ только через представление tenant_public.';
comment on column tenants.is_demo is
  'true = в тенанте только помеченные демо-данные, реальные уведомления не отправляются.';


-- Членство владельца. Подтверждается на сервере, а не заявляется клиентом.
create table tenant_members (
  tenant_id  uuid not null references tenants (id) on delete cascade,
  user_id    uuid not null,
  role       app.member_role not null default 'owner',
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

create index tenant_members_user_idx on tenant_members (user_id);

comment on table tenant_members is
  'Связь пользователя Supabase Auth с тенантом. Публичной регистрации владельца нет: строки заводит только service_role.';


-- Принадлежность текущего пользователя тенанту. Используется в политиках RLS.
-- stable, а не volatile — планировщик вызовет один раз на запрос.
create or replace function app.is_member(p_tenant uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from tenant_members m
    where m.tenant_id = p_tenant
      and m.user_id = auth.uid()
  );
$$;

comment on function app.is_member(uuid) is
  'Подтверждение членства на сервере. Клиент не передаёт tenant_id как доказательство прав.';
