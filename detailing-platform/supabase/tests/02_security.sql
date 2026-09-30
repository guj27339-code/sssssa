-- 02_security.sql
-- Проверка инвариантов 5, 6 и 8 от лица реальных ролей.
-- Каждая проба выполняется под set role, а не от суперпользователя —
-- иначе RLS просто не применяется и тест ничего не доказывает.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;

-- ── данные ───────────────────────────────────────────────────────────────
insert into tenants (id, slug, name, timezone, status, private_config)
values ('11111111-1111-1111-1111-111111111111', 'studio-a', 'Студия А', 'Europe/Moscow', 'live',
        '{"llm_monthly_limit": 1000}'::jsonb),
       ('22222222-2222-2222-2222-222222222222', 'studio-b', 'Студия Б', 'Europe/Moscow', 'live',
        '{}'::jsonb);

insert into resources (id, tenant_id, name) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Пост А'),
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Пост Б');

insert into services (id, tenant_id, name, duration_minutes, price_kopecks) values
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Услуга А', 60, 500000),
  ('bbbb0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Услуга Б', 60, 700000);

insert into service_resources values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-000000000001'),
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000002', 'bbbb0000-0000-0000-0000-000000000001');

insert into working_hours (tenant_id, resource_id, weekday, opens_at, closes_at)
select t, null, d, '09:00', '20:00'
from (values ('11111111-1111-1111-1111-111111111111'::uuid),
             ('22222222-2222-2222-2222-222222222222'::uuid)) v(t),
     generate_series(1,7) d;

-- Владельцы: у каждого свой тенант.
insert into tenant_members (tenant_id, user_id) values
  ('11111111-1111-1111-1111-111111111111', '0000000a-0000-0000-0000-00000000000a'),
  ('22222222-2222-2222-2222-222222222222', '0000000b-0000-0000-0000-00000000000b');

select id as booking_a from app.create_booking(
  '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000002',
  '2026-11-10 10:00+03', 'Клиент А', '+79001110011',
  sha256('secret-token-a'::bytea), 'sec-a'
) \gset

insert into payments (tenant_id, booking_id, kind, amount_kopecks)
values ('11111111-1111-1111-1111-111111111111', :'booking_a', 'payment', 500000);


-- ── anon ─────────────────────────────────────────────────────────────────
set local role anon;

-- Персональные данные недостижимы.
do $$
begin
  perform 1 from customers;
  raise exception 'ПРОВАЛ | anon прочитал таблицу клиентов';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не имеет доступа к customers';
end
$$;

do $$
begin
  perform 1 from payments;
  raise exception 'ПРОВАЛ | anon прочитал платежи';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не имеет доступа к payments';
end
$$;

-- Токен доступа не читается даже поимённо.
do $$
begin
  perform access_token_hash from bookings;
  raise exception 'ПРОВАЛ | anon прочитал хэш токена';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не имеет доступа к access_token_hash';
end
$$;

do $$
begin
  perform private_config from tenants;
  raise exception 'ПРОВАЛ | anon прочитал приватную конфигурацию';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не имеет доступа к private_config';
end
$$;

do $$
begin
  perform 1 from notification_jobs;
  raise exception 'ПРОВАЛ | anon прочитал очередь уведомлений';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не имеет доступа к notification_jobs';
end
$$;

-- Нельзя вызвать создание брони в обход Edge Function.
do $$
begin
  perform app.create_booking(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000002',
    '2026-11-11 10:00+03', 'Обход', '+79009990099', sha256('x'::bytea), 'bypass');
  raise exception 'ПРОВАЛ | anon вызвал create_booking напрямую';
exception
  when insufficient_privilege then
    raise notice 'ok | anon не может вызвать create_booking напрямую';
end
$$;

-- Витрина при этом работает: услуги и занятость видны.
select case when count(*) = 2 then 'ok | anon видит публичный каталог услуг'
            else 'ПРОВАЛ | услуг видно ' || count(*)::text end
from services;

select case when count(*) = 1 then 'ok | anon видит занятые интервалы'
            else 'ПРОВАЛ | интервалов видно ' || count(*)::text end
from resource_occupancies;

-- Но без указания, чем занят интервал.
do $$
begin
  perform booking_id from resource_occupancies;
  raise exception 'ПРОВАЛ | anon увидел booking_id занятости';
exception
  when insufficient_privilege then
    raise notice 'ok | anon видит интервал, но не видит, чья это бронь';
end
$$;

reset role;


-- ── владелец студии А ────────────────────────────────────────────────────
set local role authenticated;
set local request.jwt.claim.sub = '0000000a-0000-0000-0000-00000000000a';

select case when count(*) = 1 then 'ok | владелец А видит свою бронь'
            else 'ПРОВАЛ | броней видно ' || count(*)::text end
from bookings;

select case when count(*) = 1 then 'ok | владелец А видит своего клиента'
            else 'ПРОВАЛ | клиентов видно ' || count(*)::text end
from customers;

select case when count(*) = 1 then 'ok | владелец А видит свои платежи'
            else 'ПРОВАЛ | платежей видно ' || count(*)::text end
from payments;

-- Токен клиента владельцу не выдаётся.
do $$
begin
  perform access_token_hash from bookings;
  raise exception 'ПРОВАЛ | владелец прочитал хэш токена клиента';
exception
  when insufficient_privilege then
    raise notice 'ok | владельцу не выдан доступ к токенам клиентов';
end
$$;


-- ── владелец студии Б не видит чужое ─────────────────────────────────────
set local request.jwt.claim.sub = '0000000b-0000-0000-0000-00000000000b';

select case when count(*) = 0 then 'ok | владелец Б не видит броней чужой студии'
            else 'ПРОВАЛ | видно чужих броней: ' || count(*)::text end
from bookings;

select case when count(*) = 0 then 'ok | владелец Б не видит чужих клиентов'
            else 'ПРОВАЛ | видно чужих клиентов: ' || count(*)::text end
from customers;

-- Подстановка чужого tenant_id в аргумент не даёт прав.
do $$
begin
  perform public.owner_stats('11111111-1111-1111-1111-111111111111',
                             '2026-11-01'::date, '2026-11-30'::date);
  raise exception 'ПРОВАЛ | статистика чужой студии отдана по подставленному tenant_id';
exception
  when insufficient_privilege then
    raise notice 'ok | подстановка чужого tenant_id в статистику отклонена';
end
$$;

-- Правка услуг чужой студии запрещена.
do $$
begin
  update services set price_kopecks = 1
   where tenant_id = '11111111-1111-1111-1111-111111111111';
  if found then
    raise exception 'ПРОВАЛ | владелец Б изменил услугу чужой студии';
  end if;
  raise notice 'ok | правка чужих услуг не прошла';
end
$$;

reset role;
rollback;
