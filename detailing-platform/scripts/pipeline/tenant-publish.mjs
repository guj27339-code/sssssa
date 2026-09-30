#!/usr/bin/env node
/**
 * tenant:publish — переносит business.json в базу.
 *
 * Инвариант 2: файл — вход конвейера, база — источник для приложения.
 * Инвариант 11: переиздание конфига сохраняет записи и фотографии,
 * загруженные владельцем.
 *
 * Как это обеспечивается:
 *  - идентификаторы выводятся детерминированно из (slug, key), поэтому
 *    повторная публикация обновляет те же строки, а не плодит новые;
 *  - исчезнувшие из конфига услуги и посты деактивируются, а не удаляются:
 *    на них могут ссылаться уже созданные брони;
 *  - строки с source = 'owner' (фото и карточки, заведённые владельцем)
 *    не трогаются вовсе;
 *  - таблицы bookings, customers и payments не участвуют в публикации.
 *
 *   node scripts/pipeline/tenant-publish.mjs <slug> [--live]
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { validateBusiness } from './schema.mjs';
import { runSql, scalar, lit, jsonLit } from './db.mjs';

const slug = process.argv[2];
const goLive = process.argv.includes('--live');

if (!slug) {
  console.error('Укажите slug: node scripts/pipeline/tenant-publish.mjs <slug> [--live]');
  process.exit(2);
}

const dir = join('tenants', slug);
const file = join(dir, 'business.json');

if (!existsSync(file)) {
  console.error(`Нет файла ${file}`);
  process.exit(1);
}

const doc = JSON.parse(readFileSync(file, 'utf8'));

// Публикуем только то, что прошло проверку.
const report = validateBusiness(doc);
if (doc.slug !== slug) {
  report.err('slug', `slug в файле ("${doc.slug}") не совпадает с папкой ("${slug}")`);
}
if (!report.ok) {
  console.error('Публикация остановлена: настройки не прошли проверку.');
  for (const e of report.errors) console.error(`  ${e.path}: ${e.message}`);
  console.error('Запустите tenant:validate и исправьте ошибки.');
  process.exit(1);
}

/**
 * UUID v5: одинаковый вход даёт одинаковый идентификатор.
 * Благодаря этому публикация идемпотентна.
 */
const NS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

function uuid5(name) {
  const nsBytes = Buffer.from(NS.replace(/-/g, ''), 'hex');
  const hash = createHash('sha1').update(Buffer.concat([nsBytes, Buffer.from(name, 'utf8')])).digest();
  const b = Buffer.from(hash.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;          // версия 5
  b[8] = (b[8] & 0x3f) | 0x80;          // вариант RFC 4122
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const tenantId   = uuid5(`tenant:${slug}`);
const resourceId = (key) => uuid5(`resource:${slug}:${key}`);
const serviceId  = (key) => uuid5(`service:${slug}:${key}`);
const cardId     = (i)   => uuid5(`card:${slug}:${i}`);
const photoId    = (f)   => uuid5(`photo:${slug}:${f}`);

const publicConfig = {
  description: doc.description ?? '',
  contacts: doc.contacts ?? {},
  media: doc.media ?? {},
};

const sql = [];
sql.push('begin;');

// ── студия ───────────────────────────────────────────────────────────────
// status при переиздании не понижается: уже опубликованная студия
// не должна вернуться в preview из-за правки конфига.
sql.push(`
insert into tenants (id, slug, name, timezone, accent_color, status, public_config, is_demo)
values (${lit(tenantId)}, ${lit(slug)}, ${lit(doc.name)}, ${lit(doc.timezone)},
        ${lit(doc.accent_color || '#4690FF')},
        ${goLive ? `'live'` : `'preview'`}, ${jsonLit(publicConfig)}, ${goLive ? 'false' : 'true'})
on conflict (slug) do update set
  name = excluded.name,
  timezone = excluded.timezone,
  accent_color = excluded.accent_color,
  public_config = excluded.public_config,
  status = case when tenants.status = 'live' or excluded.status = 'live'
                then 'live'::app.tenant_status else tenants.status end,
  is_demo = case when tenants.status = 'live' or excluded.status = 'live'
                 then false else tenants.is_demo end;
`);

// ── посты ────────────────────────────────────────────────────────────────
const resourceIds = [];
doc.resources.forEach((r, i) => {
  const id = resourceId(r.key);
  resourceIds.push(id);
  sql.push(`
insert into resources (id, tenant_id, name, sort_order, is_active)
values (${lit(id)}, ${lit(tenantId)}, ${lit(r.name)}, ${i}, true)
on conflict (id) do update set
  name = excluded.name, sort_order = excluded.sort_order, is_active = true;
`);
});

// Пропавшие посты гасим, но не удаляем: на них ссылаются брони.
sql.push(`
update resources set is_active = false
where tenant_id = ${lit(tenantId)}
  and id <> all (array[${resourceIds.map(lit).join(',') || 'null::uuid'}]::uuid[]);
`);

// ── услуги ───────────────────────────────────────────────────────────────
const serviceIds = [];
doc.services.forEach((s, i) => {
  const id = serviceId(s.key);
  serviceIds.push(id);
  sql.push(`
insert into services (id, tenant_id, name, description, duration_minutes,
                      buffer_before_minutes, buffer_after_minutes,
                      price_kopecks, sort_order, is_active)
values (${lit(id)}, ${lit(tenantId)}, ${lit(s.name)}, ${lit(s.description ?? null)},
        ${lit(s.duration_minutes)},
        ${lit(s.buffer_before_minutes ?? 0)}, ${lit(s.buffer_after_minutes ?? 0)},
        ${s.price_kopecks == null ? 'null' : lit(s.price_kopecks)}, ${i}, true)
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description,
  duration_minutes = excluded.duration_minutes,
  buffer_before_minutes = excluded.buffer_before_minutes,
  buffer_after_minutes = excluded.buffer_after_minutes,
  price_kopecks = excluded.price_kopecks,
  sort_order = excluded.sort_order,
  is_active = true;
`);
});

sql.push(`
update services set is_active = false
where tenant_id = ${lit(tenantId)}
  and id <> all (array[${serviceIds.map(lit).join(',') || 'null::uuid'}]::uuid[]);
`);

// ── совместимость услуги и поста ─────────────────────────────────────────
// Полностью пересобираем: это чистое отражение конфига.
sql.push(`delete from service_resources where tenant_id = ${lit(tenantId)};`);
doc.services.forEach((s) => {
  s.resource_keys.forEach((k) => {
    sql.push(`
insert into service_resources (tenant_id, service_id, resource_id)
values (${lit(tenantId)}, ${lit(serviceId(s.key))}, ${lit(resourceId(k))});
`);
  });
});

// ── график ───────────────────────────────────────────────────────────────
sql.push(`delete from working_hours where tenant_id = ${lit(tenantId)};`);
doc.working_hours.forEach((w) => {
  sql.push(`
insert into working_hours (tenant_id, resource_id, weekday, opens_at, closes_at)
values (${lit(tenantId)}, null, ${lit(w.weekday)}, ${lit(w.opens_at)}, ${lit(w.closes_at)});
`);
});

sql.push(`delete from schedule_exceptions where tenant_id = ${lit(tenantId)};`);
(doc.schedule_exceptions || []).forEach((e) => {
  const closed = e.is_closed !== false;
  sql.push(`
insert into schedule_exceptions (tenant_id, resource_id, exception_date, is_closed, opens_at, closes_at, note)
values (${lit(tenantId)}, null, ${lit(e.date)}::date, ${closed},
        ${closed ? 'null' : lit(e.opens_at)}, ${closed ? 'null' : lit(e.closes_at)},
        ${lit(e.note ?? null)});
`);
});

// ── карточки и галерея ───────────────────────────────────────────────────
// Трогаем только source = 'config'. То, что завёл владелец, остаётся.
(doc.info_cards || []).forEach((card, i) => {
  sql.push(`
insert into info_cards (id, tenant_id, title, body, icon, sort_order, source)
values (${lit(cardId(i))}, ${lit(tenantId)}, ${lit(card.title)}, ${lit(card.body)},
        ${lit(card.icon ?? null)}, ${i}, 'config')
on conflict (id) do update set
  title = excluded.title, body = excluded.body,
  icon = excluded.icon, sort_order = excluded.sort_order
where info_cards.source = 'config';
`);
});

const photoIds = [];
(doc.gallery || []).forEach((g, i) => {
  const id = photoId(g.file);
  photoIds.push(id);
  sql.push(`
insert into gallery_items (id, tenant_id, category, caption, storage_path, source, sort_order, is_demo)
values (${lit(id)}, ${lit(tenantId)}, ${lit(g.category ?? null)}, ${lit(g.caption ?? null)},
        ${lit(`tenants/${slug}/${g.file}`)}, 'config', ${i}, ${goLive ? 'false' : 'true'})
on conflict (id) do update set
  category = excluded.category, caption = excluded.caption,
  sort_order = excluded.sort_order
where gallery_items.source = 'config';
`);
});

// Пропавшие из конфига фото удаляем — но только те, что пришли из конфига.
sql.push(`
delete from gallery_items
where tenant_id = ${lit(tenantId)}
  and source = 'config'
  and id <> all (array[${photoIds.map(lit).join(',') || 'null::uuid'}]::uuid[]);
`);

sql.push('commit;');

// ── выполнение ───────────────────────────────────────────────────────────
const before = safeCount();

try {
  runSql(sql.join('\n'));
} catch (e) {
  console.error('Публикация не удалась, изменения откачены.');
  console.error(e.message);
  process.exit(1);
}

const after = safeCount();

console.log(`Опубликована студия "${slug}"`);
console.log(`  идентификатор: ${tenantId}`);
console.log(`  маршрут:       /s/${slug}/`);
console.log(`  состояние:     ${goLive ? 'live' : 'preview (только демо-данные, реальные уведомления не отправляются)'}`);
console.log(`  услуг:         ${doc.services.length}`);
console.log(`  постов:        ${doc.resources.length}`);
console.log(`  фотографий:    ${(doc.gallery || []).length}`);

// Доказательство инварианта 11, а не обещание.
console.log('');
console.log(`  записей до публикации:  ${before.bookings}`);
console.log(`  записей после:          ${after.bookings}`);
console.log(`  фото владельца до:      ${before.ownerPhotos}`);
console.log(`  фото владельца после:   ${after.ownerPhotos}`);

if (before.bookings !== after.bookings || before.ownerPhotos !== after.ownerPhotos) {
  console.error('');
  console.error('ВНИМАНИЕ: публикация изменила данные, которые трогать не должна.');
  process.exit(1);
}

function safeCount() {
  try {
    const out = scalar(`
      select coalesce((select count(*) from bookings where tenant_id = ${lit(tenantId)}), 0)
        || ' ' ||
        coalesce((select count(*) from gallery_items
                   where tenant_id = ${lit(tenantId)} and source = 'owner'), 0);
    `);
    const [b, p] = out.split(' ');
    return { bookings: Number(b), ownerPhotos: Number(p) };
  } catch {
    return { bookings: 0, ownerPhotos: 0 };
  }
}
