-- 0001_extensions.sql
-- Расширения и общие утилиты.
--
-- btree_gist обязателен: без него нельзя построить EXCLUDE, в котором
-- равенство по tenant_id/resource_id сочетается с пересечением диапазона.

create extension if not exists "pgcrypto";
create extension if not exists "btree_gist";

-- Схема для внутренних функций, недоступная клиентским ролям.
create schema if not exists app;

comment on schema app is
  'Внутренние функции и типы платформы. GRANT на неё клиентским ролям не выдаётся.';

-- Роли Supabase в локальной среде отсутствуют — создаём их, чтобы миграции
-- накатывались одинаково и локально, и в облаке.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

-- Заглушка auth.uid() для локальных прогонов. В облаке Supabase её
-- определяет сам GoTrue, и create schema if not exists ничего не ломает.
create schema if not exists auth;

do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'uid'
  ) then
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable
      as 'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
    $fn$;
  end if;
end
$$;

-- Общий триггер обновления updated_at.
create or replace function app.touch_updated_at() returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;
