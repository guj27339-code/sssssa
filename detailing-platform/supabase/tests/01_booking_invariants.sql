-- 01_booking_invariants.sql
-- Проверка инвариантов 3 и 4 на живых данных.
-- Каждая проверка печатает строку вида "ok | ..." или падает с ошибкой.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;

-- ── подготовка ───────────────────────────────────────────────────────────
insert into tenants (id, slug, name, timezone, status, is_demo)
values ('11111111-1111-1111-1111-111111111111', 'darkside', 'Dark Side', 'Europe/Moscow', 'live', false);

insert into resources (id, tenant_id, name, sort_order) values
  ('22222222-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Пост 1', 1),
  ('22222222-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Пост 2', 2);

-- Тонировка: 2 часа, буфер 15 минут с каждой стороны.
insert into services (id, tenant_id, name, duration_minutes, buffer_before_minutes, buffer_after_minutes, price_kopecks)
values ('33333333-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Тонировка', 120, 15, 15, 350000);

-- Оклейка: трое суток — многодневная занятость.
insert into services (id, tenant_id, name, duration_minutes, buffer_before_minutes, buffer_after_minutes, price_kopecks)
values ('33333333-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
        'Оклейка кузова', 60 * 24 * 3, 30, 60, 15000000);

insert into service_resources (tenant_id, service_id, resource_id)
select '11111111-1111-1111-1111-111111111111', s.id, r.id
from services s cross join resources r
where s.tenant_id = '11111111-1111-1111-1111-111111111111'
  and r.tenant_id = '11111111-1111-1111-1111-111111111111';

-- Принимаем и отдаём с 9:00 до 20:00 все семь дней.
insert into working_hours (tenant_id, resource_id, weekday, opens_at, closes_at)
select '11111111-1111-1111-1111-111111111111', null, d, '09:00', '20:00'
from generate_series(1, 7) d;


-- ── 1. базовая бронь ─────────────────────────────────────────────────────
select 'ok | бронь создана, пост подобран: ' || b.resource_id::text
from app.create_booking(
  '11111111-1111-1111-1111-111111111111',
  '33333333-0000-0000-0000-000000000001',
  '2026-10-05 10:00+03',
  'Иван', '+7 937 558-33-48',
  sha256('token-a'::bytea),
  'idem-a'
) b;

-- Занятость шире услуги ровно на буферы: 09:45 .. 12:15.
select case
  when lower(during) = '2026-10-05 09:45+03'::timestamptz
   and upper(during) = '2026-10-05 12:15+03'::timestamptz
  then 'ok | буферы вошли в занятость: ' || during::text
  else 'ПРОВАЛ | занятость ' || during::text
end
from resource_occupancies
where tenant_id = '11111111-1111-1111-1111-111111111111';


-- ── 2. идемпотентность ───────────────────────────────────────────────────
select case
  when (select count(*) from bookings) = 1
  then 'ok | повтор с тем же ключом не создал вторую бронь'
  else 'ПРОВАЛ | броней: ' || (select count(*) from bookings)::text
end
from app.create_booking(
  '11111111-1111-1111-1111-111111111111',
  '33333333-0000-0000-0000-000000000001',
  '2026-10-05 10:00+03',
  'Иван', '+7 937 558-33-48',
  sha256('token-a'::bytea),
  'idem-a'
);


-- ── 3. пересечение по буферу уходит на второй пост ───────────────────────
-- 12:00 попадает в буфер первой брони (до 12:15), поэтому первый пост занят.
select case
  when b.resource_id = '22222222-0000-0000-0000-000000000002'
  then 'ok | пересечение по буферу увело на свободный пост'
  else 'ПРОВАЛ | выбран пост ' || b.resource_id::text
end
from app.create_booking(
  '11111111-1111-1111-1111-111111111111',
  '33333333-0000-0000-0000-000000000001',
  '2026-10-05 12:00+03',
  'Пётр', '+79001234567',
  sha256('token-b'::bytea),
  'idem-b'
) b;


-- ── 4. оба поста заняты — отказ ──────────────────────────────────────────
do $$
begin
  perform app.create_booking(
    '11111111-1111-1111-1111-111111111111',
    '33333333-0000-0000-0000-000000000001',
    '2026-10-05 12:05+03',
    'Третий', '+79007654321',
    sha256('token-c'::bytea), 'idem-c'
  );
  raise exception 'ПРОВАЛ | бронь прошла, хотя оба поста заняты';
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'no_free_resource' then
      raise notice 'ok | оба поста заняты — отказ, как и ожидалось';
    else
      raise exception 'ПРОВАЛ | неожиданная ошибка: %', sqlerrm;
    end if;
end
$$;


-- ── 5. выдача вне рабочих часов не проходит ──────────────────────────────
-- Начало в 19:00 укладывается в приём, но конец в 21:00 — уже закрыто.
do $$
begin
  perform app.create_booking(
    '11111111-1111-1111-1111-111111111111',
    '33333333-0000-0000-0000-000000000001',
    '2026-10-06 19:00+03',
    'Поздний', '+79005550000',
    sha256('token-d'::bytea), 'idem-d'
  );
  raise exception 'ПРОВАЛ | принята бронь с выдачей после закрытия';
exception
  when sqlstate 'P0001' then
    raise notice 'ok | выдача после закрытия отклонена';
end
$$;


-- ── 6. многодневная услуга ───────────────────────────────────────────────
-- Трое суток: занятость идёт и ночью, когда студия закрыта, — это допустимо.
-- Вставка и чтение разнесены по операторам: строку, добавленную функцией,
-- в том же операторе не видно — снимок данных берётся до её выполнения.
do $$
declare
  v_id   uuid;
  v_span interval;
begin
  select id into v_id from app.create_booking(
    '11111111-1111-1111-1111-111111111111',
    '33333333-0000-0000-0000-000000000002',
    '2026-10-12 10:00+03',
    'Многодневный', '+79001112233',
    sha256('token-e'::bytea), 'idem-e'
  );

  select upper(during) - lower(during) into v_span
  from resource_occupancies where booking_id = v_id;

  if v_span = interval '3 days 1 hour 30 minutes' then
    raise notice 'ok | многодневная занятость непрерывна: %', v_span;
  else
    raise exception 'ПРОВАЛ | длительность %', v_span;
  end if;
end
$$;


-- ── 7. исключение расписания закрывает день ──────────────────────────────
insert into schedule_exceptions (tenant_id, resource_id, exception_date, is_closed, note)
values ('11111111-1111-1111-1111-111111111111', null, '2026-10-07', true, 'Санитарный день');

do $$
begin
  perform app.create_booking(
    '11111111-1111-1111-1111-111111111111',
    '33333333-0000-0000-0000-000000000001',
    '2026-10-07 11:00+03',
    'В выходной', '+79002223344',
    sha256('token-f'::bytea), 'idem-f'
  );
  raise exception 'ПРОВАЛ | бронь прошла в закрытый день';
exception
  when sqlstate 'P0001' then
    raise notice 'ok | закрытый день отклонён';
end
$$;


-- ── 8. неудачный перенос не теряет исходную бронь ────────────────────────
-- Переносим бронь Петра на время, занятое бронью Ивана на том же посту.
do $$
declare
  v_pet  uuid;
  v_before record;
  v_after  record;
begin
  select id into v_pet from bookings where idempotency_key = 'idem-b';

  select starts_at, resource_id into v_before from bookings where id = v_pet;

  begin
    perform app.reschedule_booking(
      '11111111-1111-1111-1111-111111111111',
      v_pet,
      '2026-10-05 10:30+03',
      '22222222-0000-0000-0000-000000000001'
    );
    raise exception 'ПРОВАЛ | перенос прошёл на занятый пост';
  exception
    when exclusion_violation then
      null;  -- ожидаемо
  end;

  select starts_at, resource_id into v_after from bookings where id = v_pet;

  if v_before.starts_at = v_after.starts_at
     and v_before.resource_id = v_after.resource_id
     and exists (select 1 from resource_occupancies where booking_id = v_pet)
  then
    raise notice 'ok | неудачный перенос откатился, исходная бронь цела';
  else
    raise exception 'ПРОВАЛ | бронь повреждена после неудачного переноса';
  end if;
end
$$;


-- ── 9. удачный перенос ───────────────────────────────────────────────────
do $$
declare
  v_pet uuid;
  v_new timestamptz;
begin
  select id into v_pet from bookings where idempotency_key = 'idem-b';

  select starts_at into v_new
  from app.reschedule_booking(
    '11111111-1111-1111-1111-111111111111', v_pet, '2026-10-06 09:00+03', null
  );

  if v_new = '2026-10-06 09:00+03'::timestamptz
     and (select lower(during) from resource_occupancies where booking_id = v_pet)
         = '2026-10-06 08:45+03'::timestamptz
  then
    raise notice 'ok | перенос выполнен, занятость сдвинулась вместе с буфером';
  else
    raise exception 'ПРОВАЛ | перенос не сдвинул занятость';
  end if;
end
$$;


-- ── 10. блокировка поста и бронь в одной таблице не пересекаются ─────────
do $$
begin
  perform app.block_resource(
    '11111111-1111-1111-1111-111111111111',
    '22222222-0000-0000-0000-000000000001',
    '2026-10-05 10:30+03', '2026-10-05 11:00+03', 'Ремонт'
  );
  raise exception 'ПРОВАЛ | блокировка легла поверх брони';
exception
  when sqlstate 'P0001' then
    raise notice 'ok | блокировка не смогла пересечь бронь';
end
$$;

-- Проверяем поле составного типа, а не сам тип: composite IS NOT NULL
-- ложно, когда хоть одно поле пусто, а у блокировки booking_id всегда пуст.
do $$
declare
  v_id uuid;
begin
  select id into v_id from app.block_resource(
    '11111111-1111-1111-1111-111111111111',
    '22222222-0000-0000-0000-000000000001',
    '2026-10-08 10:00+03', '2026-10-08 14:00+03', 'Обслуживание'
  );

  if v_id is not null then
    raise notice 'ok | блокировка на свободное время создана';
  else
    raise exception 'ПРОВАЛ | блокировка не создалась';
  end if;
end
$$;


-- ── 11. отмена освобождает занятость ─────────────────────────────────────
do $$
declare
  v_ivan uuid;
begin
  select id into v_ivan from bookings where idempotency_key = 'idem-a';
  perform app.cancel_booking('11111111-1111-1111-1111-111111111111', v_ivan);

  if not exists (select 1 from resource_occupancies where booking_id = v_ivan)
     and (select status from bookings where id = v_ivan) = 'cancelled'
  then
    raise notice 'ok | отмена освободила занятость, бронь осталась в истории';
  else
    raise exception 'ПРОВАЛ | отмена отработала неверно';
  end if;

  -- Повторная отмена не должна падать.
  perform app.cancel_booking('11111111-1111-1111-1111-111111111111', v_ivan);
  raise notice 'ok | повторная отмена идемпотентна';
end
$$;


-- ── 12. составной FK не даёт сослаться на чужой тенант ───────────────────
insert into tenants (id, slug, name) values
  ('99999999-9999-9999-9999-999999999999', 'other', 'Другая студия');
insert into resources (id, tenant_id, name) values
  ('88888888-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999', 'Чужой пост');

do $$
begin
  insert into service_resources (tenant_id, service_id, resource_id)
  values ('11111111-1111-1111-1111-111111111111',
          '33333333-0000-0000-0000-000000000001',
          '88888888-0000-0000-0000-000000000001');
  raise exception 'ПРОВАЛ | получилось сослаться на пост чужого тенанта';
exception
  when foreign_key_violation then
    raise notice 'ok | составной FK заблокировал ссылку на чужой тенант';
end
$$;

rollback;
