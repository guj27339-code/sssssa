#!/usr/bin/env node
/**
 * tenant:verify — проверка опубликованной студии.
 *
 * Проверяет не «легли ли строки», а способна ли студия принять запись:
 * есть ли услуги, привязаны ли они к активным постам, задан ли график,
 * и находится ли хотя бы одно свободное окно на ближайшие две недели.
 *
 * Без этой проверки студия может выглядеть опубликованной и при этом
 * не отдавать клиенту ни одного времени для записи.
 *
 *   node scripts/pipeline/tenant-verify.mjs <slug>
 */

import { createHash } from 'node:crypto';
import { runSql, scalar, lit } from './db.mjs';

const slug = process.argv[2];
if (!slug) {
  console.error('Укажите slug: node scripts/pipeline/tenant-verify.mjs <slug>');
  process.exit(2);
}

const NS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
function uuid5(name) {
  const nsBytes = Buffer.from(NS.replace(/-/g, ''), 'hex');
  const hash = createHash('sha1').update(Buffer.concat([nsBytes, Buffer.from(name, 'utf8')])).digest();
  const b = Buffer.from(hash.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const tenantId = uuid5(`tenant:${slug}`);
const checks = [];
let failed = 0;

function check(name, passed, detail) {
  checks.push({ name, passed, detail });
  if (!passed) failed++;
}

// ── студия существует ────────────────────────────────────────────────────
const row = scalar(`
  select coalesce((
    select status::text || '|' || timezone || '|' || name
    from tenants where id = ${lit(tenantId)}
  ), '');
`);

if (!row) {
  console.error(`Студия "${slug}" не найдена в базе. Сначала выполните tenant:publish.`);
  process.exit(1);
}

const [status, timezone, name] = row.split('|');
check('студия опубликована', true, `${name}, состояние ${status}, зона ${timezone}`);

// ── услуги и посты ───────────────────────────────────────────────────────
const counts = scalar(`
  select (select count(*) from services  where tenant_id = ${lit(tenantId)} and is_active)
    || '|' || (select count(*) from resources where tenant_id = ${lit(tenantId)} and is_active)
    || '|' || (select count(*) from working_hours where tenant_id = ${lit(tenantId)})
    || '|' || (select count(*) from gallery_items where tenant_id = ${lit(tenantId)});
`).split('|').map(Number);

const [services, resources, hours, photos] = counts;

check('есть активные услуги', services > 0, `${services}`);
check('есть активные посты', resources > 0, `${resources}`);
check('задан график работы', hours > 0, `${hours} дней недели`);

// ── каждая услуга выполнима ──────────────────────────────────────────────
const orphans = runSql(`
  select s.name from services s
  where s.tenant_id = ${lit(tenantId)} and s.is_active
    and not exists (
      select 1 from service_resources sr
      join resources r on r.tenant_id = sr.tenant_id and r.id = sr.resource_id and r.is_active
      where sr.tenant_id = s.tenant_id and sr.service_id = s.id
    );
`).trim();

check('все услуги привязаны к активным постам',
  orphans === '',
  orphans === '' ? 'нет услуг без поста' : `без поста: ${orphans.split('\n').join(', ')}`);

// ── есть ли реально свободное окно ───────────────────────────────────────
// Берём самую длинную услугу: если помещается она, поместятся и короткие.
//
// Важно: услуга НЕ обязана укладываться в одно окно приёма. Рабочие часы
// задают только момент приёма машины и момент выдачи; между ними занятость
// идёт непрерывно, в том числе ночью и в закрытые дни. Поэтому проверяем
// два момента по отдельности, а не вмещение целиком.
const freeSlot = scalar(`
with longest as (
  select id, duration_minutes,
         buffer_before_minutes, buffer_after_minutes
  from services
  where tenant_id = ${lit(tenantId)} and is_active
  order by duration_minutes desc limit 1
),
days as (
  select generate_series(
    (now() at time zone ${lit(timezone)})::date,
    (now() at time zone ${lit(timezone)})::date + 13,
    interval '1 day'
  )::date as d
),
posts as (
  -- Только посты, на которых эта услуга действительно выполняется.
  select r.id
  from resources r
  join service_resources sr
    on sr.tenant_id = r.tenant_id and sr.resource_id = r.id
  join longest l on l.id = sr.service_id
  where r.tenant_id = ${lit(tenantId)} and r.is_active
),
starts as (
  select p.id as resource_id,
         generate_series(w.window_start, w.window_end - interval '1 minute',
                         interval '30 minutes') as ts
  from days, posts p,
       lateral app.acceptance_windows(${lit(tenantId)}, p.id, days.d) w
)
select coalesce((
  select min(s.ts)::text
  from starts s, longest l
  where s.ts > now()
    -- выдача тоже должна попадать в окно приёма, пусть и в другой день
    and app.is_acceptance_moment(${lit(tenantId)}, s.resource_id,
          s.ts + make_interval(mins => l.duration_minutes), 'end')
    -- и пост должен быть свободен на всю занятость вместе с буферами
    and not exists (
      select 1 from resource_occupancies o
      where o.tenant_id = ${lit(tenantId)}
        and o.resource_id = s.resource_id
        and o.during && tstzrange(
              s.ts - make_interval(mins => l.buffer_before_minutes),
              s.ts + make_interval(mins => l.duration_minutes + l.buffer_after_minutes),
              '[)')
    )
), '');
`).trim();

check('есть свободное окно в ближайшие 14 дней',
  freeSlot !== '',
  freeSlot ? `ближайшее: ${freeSlot}` : 'ни одного свободного времени — проверьте график и блокировки');

// ── состояние публикации ─────────────────────────────────────────────────
if (status === 'preview') {
  check('preview содержит только демо-данные',
    scalar(`select count(*) from bookings
             where tenant_id = ${lit(tenantId)} and not is_demo;`) === '0',
    'реальных записей в preview нет');
}

// ── вывод ────────────────────────────────────────────────────────────────
console.log(`\nПроверка студии "${slug}"\n`);
for (const c of checks) {
  console.log(`  ${c.passed ? 'ok    ' : 'ПРОВАЛ'}  ${c.name}${c.detail ? ' — ' + c.detail : ''}`);
}
console.log(`\n  фотографий в галерее: ${photos}`);
console.log(`  клиентский маршрут:   /s/${slug}/`);
console.log(`  кабинет владельца:    /s/${slug}/owner/`);

if (failed > 0) {
  console.error(`\nНе пройдено проверок: ${failed}`);
  process.exit(1);
}
console.log('\nСтудия готова принимать записи.');
