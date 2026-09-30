#!/usr/bin/env node
/**
 * tenant:new — заготовка новой студии.
 *
 * Создаёт tenants/<slug>/business.json и папку photos/.
 * Существующую студию не трогает: в этом смысл инварианта 1 —
 * новая студия не заменяет предыдущую.
 *
 *   node scripts/pipeline/tenant-new.mjs <slug> [--name "Название"]
 */

import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
const slug = args[0];

if (!slug) {
  console.error('Укажите slug: node scripts/pipeline/tenant-new.mjs <slug> [--name "Название"]');
  process.exit(2);
}
if (!/^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$/.test(slug)) {
  console.error(`Недопустимый slug "${slug}". Разрешены строчные латинские буквы, цифры и дефис, 3–40 символов.`);
  process.exit(2);
}

const nameIdx = args.indexOf('--name');
const name = nameIdx >= 0 ? args[nameIdx + 1] : slug;

const dir = join('tenants', slug);
const file = join(dir, 'business.json');

if (existsSync(file)) {
  console.error(`Студия "${slug}" уже заведена: ${file}`);
  console.error('Существующие настройки не перезаписываются — правьте файл вручную.');
  process.exit(1);
}

const template = {
  slug,
  name,
  timezone: 'Europe/Moscow',
  accent_color: '#4690FF',
  description: '',

  contacts: {
    phone: '+70000000000',
    whatsapp: null,
    telegram: null,
    address: '',
    map_url: null,
  },

  resources: [
    { key: 'box-1', name: 'Пост 1' },
  ],

  services: [
    {
      key: 'example',
      name: 'Название услуги',
      description: '',
      duration_minutes: 120,
      buffer_before_minutes: 15,
      buffer_after_minutes: 15,
      // null = цена по осмотру. Не выдумывайте прайс.
      price_kopecks: null,
      resource_keys: ['box-1'],
    },
  ],

  working_hours: [1, 2, 3, 4, 5, 6, 7].map((weekday) => ({
    weekday,
    opens_at: '09:00',
    closes_at: '20:00',
  })),

  schedule_exceptions: [],

  info_cards: [
    { title: 'Карточка 1', body: 'Короткий текст' },
    { title: 'Карточка 2', body: 'Короткий текст' },
    { title: 'Карточка 3', body: 'Короткий текст' },
  ],

  media: {
    hero: null,
    logo: null,
  },

  gallery: [],
};

mkdirSync(join(dir, 'photos'), { recursive: true });
writeFileSync(file, JSON.stringify(template, null, 2) + '\n', 'utf8');

console.log(`Заведена студия "${slug}"`);
console.log(`  настройки: ${file}`);
console.log(`  фотографии: ${join(dir, 'photos')}/`);
console.log('');
console.log('Дальше: заполните business.json и выполните');
console.log(`  npm run tenant:validate -- ${slug}`);
