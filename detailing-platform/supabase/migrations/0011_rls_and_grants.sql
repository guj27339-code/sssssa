-- 0011_rls_and_grants.sql
-- Построчная безопасность и права.
--
-- Инвариант 6: anon не видит персональные данные, платежи и токены.
-- Владелец видит только свой тенант, и принадлежность подтверждается
-- на сервере через tenant_members, а не заявляется клиентом.
--
-- Порядок действий: сначала отозвать всё, потом выдать точечно.
-- Обратный порядок оставляет дыры в момент миграции.

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on schema app from anon, authenticated;

-- Новые таблицы не должны автоматически становиться доступными.
alter default privileges in schema public revoke all on tables from anon, authenticated;

grant usage on schema public to anon, authenticated;

alter table tenants              enable row level security;
alter table tenant_members       enable row level security;
alter table resources            enable row level security;
alter table services             enable row level security;
alter table service_resources    enable row level security;
alter table working_hours        enable row level security;
alter table schedule_exceptions  enable row level security;
alter table customers            enable row level security;
alter table bookings             enable row level security;
alter table resource_occupancies enable row level security;
alter table payments             enable row level security;
alter table gallery_items        enable row level security;
alter table info_cards           enable row level security;
alter table notification_jobs    enable row level security;
alter table push_subscriptions   enable row level security;
alter table usage_counters       enable row level security;

-- Таблицы без единой политики закрыты для всех, кроме service_role
-- (у него bypassrls). Персональные данные, платежи, очередь и счётчики
-- политик не получают вовсе — к ним нет пути ни у anon, ни у authenticated.


-- ── Публичная витрина ────────────────────────────────────────────────────
-- anon читает только то, что нужно для показа страницы и выбора времени.
-- Колонка private_config в выборку не входит: доступ выдаётся
-- на конкретные колонки, а не на таблицу целиком.

grant select (id, slug, name, timezone, status, accent_color, public_config, is_demo)
  on tenants to anon, authenticated;

create policy tenants_public_read on tenants
  for select to anon, authenticated
  using (status in ('preview', 'live'));

grant select on resources, services, service_resources,
                working_hours, schedule_exceptions,
                gallery_items, info_cards
  to anon, authenticated;

create policy resources_public_read on resources
  for select to anon, authenticated using (true);
create policy services_public_read on services
  for select to anon, authenticated using (true);
create policy service_resources_public_read on service_resources
  for select to anon, authenticated using (true);
create policy working_hours_public_read on working_hours
  for select to anon, authenticated using (true);
create policy schedule_exceptions_public_read on schedule_exceptions
  for select to anon, authenticated using (true);
create policy gallery_public_read on gallery_items
  for select to anon, authenticated using (true);
create policy info_cards_public_read on info_cards
  for select to anon, authenticated using (true);


-- Занятость нужна клиенту, чтобы показать занятые интервалы. Отдаём
-- только диапазон и пост — без booking_id, без заметок владельца.
grant select (id, tenant_id, resource_id, during) on resource_occupancies
  to anon, authenticated;

create policy occupancies_public_read on resource_occupancies
  for select to anon, authenticated using (true);

comment on policy occupancies_public_read on resource_occupancies is
  'Клиент видит, что интервал занят, но не чем и не кем: booking_id и note в GRANT не входят.';


-- ── Кабинет владельца ────────────────────────────────────────────────────
-- Членство проверяется функцией на сервере. Клиент не может объявить
-- себя членом чужого тенанта, передав другой tenant_id.

grant select on tenant_members to authenticated;
create policy members_see_own on tenant_members
  for select to authenticated
  using (user_id = auth.uid());

-- Публичной регистрации владельца нет: политики INSERT нет ни у кого,
-- кроме service_role.

create policy tenants_owner_manage on tenants
  for update to authenticated
  using (app.is_member(id)) with check (app.is_member(id));
grant update (name, timezone, accent_color, public_config) on tenants to authenticated;

grant select, insert, update, delete on resources, services, service_resources,
                                        working_hours, schedule_exceptions,
                                        gallery_items, info_cards
  to authenticated;

create policy resources_owner on resources
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy services_owner on services
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy service_resources_owner on service_resources
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy working_hours_owner on working_hours
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy schedule_exceptions_owner on schedule_exceptions
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy gallery_owner on gallery_items
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
create policy info_cards_owner on info_cards
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));

-- Владелец читает брони, клиентов и платежи своего тенанта.
-- Токен доступа ему не нужен и не выдаётся.
grant select (id, tenant_id, service_id, resource_id, customer_id, status,
              starts_at, ends_at, price_kopecks_snapshot,
              duration_minutes_snapshot, arrived_at, ready_at,
              is_demo, created_at, cancelled_at)
  on bookings to authenticated;

create policy bookings_owner_read on bookings
  for select to authenticated using (app.is_member(tenant_id));

grant select on customers, payments to authenticated;

create policy customers_owner_read on customers
  for select to authenticated using (app.is_member(tenant_id));
create policy payments_owner_read on payments
  for select to authenticated using (app.is_member(tenant_id));

create policy occupancies_owner_all on resource_occupancies
  for all to authenticated
  using (app.is_member(tenant_id)) with check (app.is_member(tenant_id));
grant select, insert, update, delete on resource_occupancies to authenticated;


-- ── Функции ──────────────────────────────────────────────────────────────
-- Изменяющие операции идут только через Edge Functions с service_role.
-- Прямого EXECUTE у anon и authenticated на них нет: клиент не должен
-- уметь вызвать create_booking напрямую, минуя проверку квот и выдачу токена.

grant usage on schema app to service_role;
grant execute on all functions in schema app to service_role;

-- Кабинету нужна статистика и расписание — их отдаём напрямую,
-- членство проверяется внутри вызова.
create or replace function public.owner_stats(
  p_tenant uuid, p_from date, p_to date
)
returns setof record
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not app.is_member(p_tenant) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query select * from app.tenant_stats(p_tenant, p_from, p_to);
end
$$;

revoke all on function public.owner_stats(uuid, date, date) from public;
grant execute on function public.owner_stats(uuid, date, date) to authenticated;

comment on function public.owner_stats is
  'Обёртка над app.tenant_stats с проверкой членства. tenant_id из аргумента не даёт прав сам по себе.';
