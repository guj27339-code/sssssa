#!/usr/bin/env node
/**
 * tenant:validate — проверка настроек студии до публикации.
 *
 * Проверяет и сам файл, и наличие на диске всех упомянутых фотографий:
 * ссылка на несуществующий файл выявляется здесь, а не пустым местом
 * на странице у владельца.
 *
 *   node scripts/pipeline/tenant-validate.mjs <slug>
 *   node scripts/pipeline/tenant-validate.mjs --all
 */

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { validateBusiness } from './schema.mjs';

const arg = process.argv[2];

if (!arg) {
  console.error('Укажите slug или --all');
  process.exit(2);
}

const slugs = arg === '--all'
  ? (existsSync('tenants') ? readdirSync('tenants', { withFileTypes: true })
      .filter((d) => d.isDirectory()).map((d) => d.name) : [])
  : [arg];

if (slugs.length === 0) {
  console.error('Не найдено ни одной студии в tenants/');
  process.exit(1);
}

let failed = 0;

for (const slug of slugs) {
  const dir = join('tenants', slug);
  const file = join(dir, 'business.json');

  console.log(`\n── ${slug} ──`);

  if (!existsSync(file)) {
    console.error(`  ОШИБКА  нет файла ${file}`);
    failed++;
    continue;
  }

  let doc;
  try {
    doc = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    console.error(`  ОШИБКА  файл не разбирается как JSON: ${e.message}`);
    failed++;
    continue;
  }

  const report = validateBusiness(doc);

  // Имя папки и slug внутри файла должны совпадать, иначе публикация
  // уедет не в ту студию.
  if (doc.slug && doc.slug !== slug) {
    report.err('slug', `slug в файле ("${doc.slug}") не совпадает с именем папки ("${slug}")`);
  }

  // Фотографии обязаны лежать на диске.
  const photoRefs = [];
  if (doc.media?.hero) photoRefs.push(['media.hero', doc.media.hero]);
  if (doc.media?.logo) photoRefs.push(['media.logo', doc.media.logo]);
  (doc.gallery || []).forEach((g, i) => {
    if (g?.file) photoRefs.push([`gallery[${i}].file`, g.file]);
  });

  for (const [path, rel] of photoRefs) {
    const full = join(dir, 'photos', rel);
    if (!existsSync(full)) {
      report.err(path, `файл не найден: ${full}`);
    }
  }

  // Неиспользуемые снимки — не ошибка, но о них стоит знать.
  const photosDir = join(dir, 'photos');
  if (existsSync(photosDir)) {
    const used = new Set(photoRefs.map(([, rel]) => rel));
    for (const f of readdirSync(photosDir)) {
      if (!used.has(f) && /\.(jpe?g|png|webp|avif)$/i.test(f)) {
        report.warn('photos', `файл ${f} лежит в папке, но нигде не используется`);
      }
    }
  }

  for (const w of report.warnings) {
    console.log(`  внимание  ${w.path ? w.path + ': ' : ''}${w.message}`);
  }
  for (const e of report.errors) {
    console.error(`  ОШИБКА    ${e.path ? e.path + ': ' : ''}${e.message}`);
  }

  if (report.ok) {
    const services = (doc.services || []).length;
    const resources = (doc.resources || []).length;
    console.log(`  проверено: услуг ${services}, постов ${resources}, фотографий ${photoRefs.length}`);
    console.log('  готово к публикации');
  } else {
    failed++;
  }
}

console.log('');
if (failed > 0) {
  console.error(`Не прошли проверку: ${failed} из ${slugs.length}`);
  process.exit(1);
}
console.log(`Проверено студий: ${slugs.length}, все в порядке`);
