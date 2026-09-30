-- 0008_payments_and_gallery.sql
-- Платежи, отметки приёмки и фотографии работ.
--
-- Инвариант 8: заезды, выполненные работы и полученные деньги — три разные
-- величины. Будущая стоимость брони выручкой не является и в подсчёт
-- полученного не входит.
-- Инвариант 11: переиздание конфига не трогает фотографии, загруженные
-- владельцем, и не трогает записи.

-- Отметки движения машины по студии. Нужны для «заездов» в статистике.
alter table bookings
  add column arrived_at timestamptz,
  add column ready_at   timestamptz;

comment on column bookings.arrived_at is
  'Машина принята. Заезд считается по этой отметке, а не по факту создания брони.';
comment on column bookings.ready_at is
  'Работа завершена, машину можно отдавать.';


create type app.payment_kind as enum ('payment', 'refund');

create table payments (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,
  booking_id  uuid not null,

  kind        app.payment_kind not null default 'payment',

  -- Всегда положительная величина; знак задаёт kind.
  amount_kopecks bigint not null,

  -- Момент фактического получения денег. Именно он попадает в статистику.
  received_at timestamptz not null default now(),

  note        text,
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now(),

  primary key (id),
  constraint payments_tenant_id_key unique (tenant_id, id),
  constraint payments_booking_fk
    foreign key (tenant_id, booking_id) references bookings (tenant_id, id) on delete cascade,
  constraint payments_amount_positive check (amount_kopecks > 0)
);

create index payments_tenant_received_idx on payments (tenant_id, received_at);
create index payments_booking_idx on payments (tenant_id, booking_id);

comment on table payments is
  'Фактически полученные и возвращённые деньги. Плановая стоимость брони здесь не отражается.';


-- Фотографии работ. Загруженные владельцем помечаются source = 'owner'
-- и переживают переиздание конфига студии.
create type app.photo_source as enum ('config', 'owner');

create table gallery_items (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references tenants (id) on delete cascade,

  -- Категория для фильтров в портфолио.
  category    text,
  caption     text,

  -- Путь в Supabase Storage.
  storage_path text not null,

  source      app.photo_source not null default 'config',
  sort_order  integer not null default 0,
  is_demo     boolean not null default false,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  primary key (id),
  constraint gallery_items_tenant_id_key unique (tenant_id, id),
  constraint gallery_items_path_not_blank check (length(btrim(storage_path)) > 0)
);

create index gallery_items_tenant_idx on gallery_items (tenant_id, sort_order);

create trigger gallery_items_touch
  before update on gallery_items
  for each row execute function app.touch_updated_at();

comment on column gallery_items.source is
  'config = пришло из business.json и заменяется при переиздании; owner = загружено владельцем и переиздание его не трогает.';


-- Три информационные карточки на главной. Владелец правит их из кабинета.
create table info_cards (
  id         uuid not null default gen_random_uuid(),
  tenant_id  uuid not null references tenants (id) on delete cascade,
  title      text not null,
  body       text not null,
  icon       text,
  sort_order integer not null default 0,
  source     app.photo_source not null default 'config',
  updated_at timestamptz not null default now(),

  primary key (id),
  constraint info_cards_tenant_id_key unique (tenant_id, id)
);

create index info_cards_tenant_idx on info_cards (tenant_id, sort_order);

create trigger info_cards_touch
  before update on info_cards
  for each row execute function app.touch_updated_at();


-- Отметка приёмки и готовности. Отдельная функция, чтобы владелец
-- не правил статусы напрямую и подсчёт заездов оставался достоверным.
create or replace function app.mark_booking(
  p_tenant     uuid,
  p_booking_id uuid,
  p_event      text          -- 'arrived' | 'ready'
)
returns bookings
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_booking bookings%rowtype;
begin
  select * into v_booking
  from bookings where id = p_booking_id and tenant_id = p_tenant
  for update;

  if not found then
    raise exception 'booking_not_found' using errcode = 'P0002';
  end if;
  if v_booking.status = 'cancelled' then
    raise exception 'booking_cancelled' using errcode = 'P0001';
  end if;

  if p_event = 'arrived' then
    update bookings set arrived_at = coalesce(arrived_at, now())
     where id = p_booking_id returning * into v_booking;

  elsif p_event = 'ready' then
    update bookings
       set ready_at = coalesce(ready_at, now()),
           arrived_at = coalesce(arrived_at, now()),
           status = 'completed'
     where id = p_booking_id returning * into v_booking;

  else
    raise exception 'unknown_event' using errcode = '22023';
  end if;

  return v_booking;
end
$$;

comment on function app.mark_booking is
  'Отметка приёмки или готовности. Идемпотентна: повторный вызов не сдвигает уже проставленное время.';


-- Внесение оплаты или возврата.
create or replace function app.record_payment(
  p_tenant     uuid,
  p_booking_id uuid,
  p_kind       app.payment_kind,
  p_amount     bigint,
  p_note       text default null
)
returns payments
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_row     payments%rowtype;
  v_is_demo boolean;
begin
  select is_demo into v_is_demo
  from bookings where id = p_booking_id and tenant_id = p_tenant;

  if not found then
    raise exception 'booking_not_found' using errcode = 'P0002';
  end if;
  if p_amount <= 0 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;

  insert into payments (tenant_id, booking_id, kind, amount_kopecks, note, is_demo)
  values (p_tenant, p_booking_id, p_kind, p_amount, p_note, v_is_demo)
  returning * into v_row;

  return v_row;
end
$$;
