/**
 * Проверка роутера намерений (инвариант 7).
 *
 * Запуск:  node --experimental-strip-types --test supabase/functions/_shared/router.test.ts
 *
 * Роутер проверяется отдельно от модели и от сети: он чистый, поэтому
 * его поведение можно зафиксировать полностью.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { routeByRules, parseModelCall, type FallbackContext } from './router.ts';

const SERVICES = [
  { key: 'tinting', name: 'Тонировка стёкол' },
  { key: 'polishing', name: 'Полировка кузова' },
  { key: 'ceramic', name: 'Керамическое покрытие' },
  { key: 'interior-cleaning', name: 'Химчистка салона' },
];

const TODAY = new Date('2026-10-01T09:00:00+03:00');

function ctx(over: Partial<FallbackContext> = {}): FallbackContext {
  return {
    scope: 'client',
    services: SERVICES,
    today: TODAY,
    timeZone: 'Europe/Moscow',
    hasBookingToken: false,
    ...over,
  };
}

/* ── запасной разбор: клиент ──────────────────────────────────────────── */

test('вопрос про цену ведёт к списку услуг', () => {
  const r = routeByRules('Сколько стоит полировка?', ctx());
  assert.equal(r.intent?.tool, 'list_services');
  assert.equal(r.intent?.origin, 'fallback');
});

test('вопрос про адрес ведёт к сведениям о студии', () => {
  const r = routeByRules('Как найти студию?', ctx());
  assert.equal(r.intent?.tool, 'get_studio_info');
});

test('поиск окна распознаёт услугу по названию', () => {
  const r = routeByRules('Когда ближайшее свободное окно на полировку?', ctx());
  assert.equal(r.intent?.tool, 'find_slots');
  assert.equal(r.intent?.args.service_key, 'polishing');
});

test('поиск окна без названия услуги задаёт уточняющий вопрос', () => {
  const r = routeByRules('Когда ближайшее окно?', ctx());
  assert.equal(r.intent, null);
  assert.match(r.clarify ?? '', /услуг/i);
});

test('относительная дата переводится в дату зоны студии', () => {
  const r = routeByRules('Можно записаться на химчистку завтра?', ctx());
  assert.equal(r.intent?.tool, 'find_slots');
  assert.equal(r.intent?.args.service_key, 'interior-cleaning');
  assert.equal(r.intent?.args.from_date, '2026-10-02');
});

test('запрос своей записи без токена просит открыть ссылку', () => {
  const r = routeByRules('Когда я записан?', ctx());
  assert.equal(r.intent, null);
  assert.match(r.clarify ?? '', /ссылк/i);
});

test('запрос своей записи с токеном проходит', () => {
  const r = routeByRules('Когда я записан?', ctx({ hasBookingToken: true }));
  assert.equal(r.intent?.tool, 'get_my_booking');
});

/* ── разделение полномочий ────────────────────────────────────────────── */

test('клиент не получает доступ к расписанию владельца', () => {
  const r = routeByRules('Что у меня завтра?', ctx({ scope: 'client' }));
  assert.equal(r.intent, null);
  assert.match(r.refusal ?? '', /только владельцу/);
});

test('клиент не получает доступ к статистике', () => {
  const r = routeByRules('Сколько денег получено за неделю?', ctx({ scope: 'client' }));
  assert.equal(r.intent, null);
  assert.match(r.refusal ?? '', /только владельцу/);
});

test('владелец получает расписание на день', () => {
  const r = routeByRules('Что у меня завтра?', ctx({ scope: 'owner' }));
  assert.equal(r.intent?.tool, 'get_day_schedule');
  assert.equal(r.intent?.args.date, '2026-10-02');
});

test('владелец получает статистику за неделю', () => {
  const r = routeByRules('Сколько машин было на неделе?', ctx({ scope: 'owner' }));
  assert.equal(r.intent?.tool, 'get_stats');
  assert.equal(r.intent?.args.from_date, '2026-09-25');
  assert.equal(r.intent?.args.to_date, '2026-10-01');
});

test('непонятный вопрос не выбирает инструмент наугад', () => {
  const r = routeByRules('А вы котиков любите?', ctx());
  assert.equal(r.intent, null);
  assert.equal(r.refusal, null);
  assert.equal(r.clarify, null);
});

/* ── разбор ответа модели ─────────────────────────────────────────────── */

test('function call от модели разбирается', () => {
  const r = parseModelCall(
    { name: 'find_slots', arguments: '{"service_key":"tinting","from_date":"2026-10-05"}' },
    'client',
  );
  assert.equal(r.intent?.tool, 'find_slots');
  assert.equal(r.intent?.args.service_key, 'tinting');
  assert.equal(r.intent?.origin, 'model');
});

test('JSON в прозе модели тоже разбирается', () => {
  const r = parseModelCall(
    'Сейчас посмотрю.\n```json\n{"tool":"list_services","args":{}}\n```\nМинуту.',
    'client',
  );
  assert.equal(r.intent?.tool, 'list_services');
});

test('модель не может выбрать tenant_id', () => {
  const r = parseModelCall(
    { name: 'find_slots',
      arguments: { service_key: 'tinting', tenant_id: '00000000-0000-0000-0000-000000000000' } },
    'client',
  );
  assert.equal(r.intent?.tool, 'find_slots');
  assert.equal(r.intent?.args.tenant_id, undefined);
  assert.deepEqual(Object.keys(r.intent!.args), ['service_key']);
});

test('модель не может подсунуть SQL', () => {
  const r = parseModelCall(
    { name: 'list_services', arguments: { sql: 'drop table bookings' } },
    'client',
  );
  assert.equal(r.intent?.tool, 'list_services');
  assert.deepEqual(r.intent?.args, {});
});

test('модель не может вызвать владельческий инструмент от клиента', () => {
  const r = parseModelCall(
    { name: 'get_stats', arguments: { from_date: '2026-01-01', to_date: '2026-12-31' } },
    'client',
  );
  assert.equal(r.intent, null);
  assert.match(r.refusal ?? '', /только владельцу/);
});

test('несуществующий инструмент отклоняется', () => {
  const r = parseModelCall({ name: 'delete_everything', arguments: {} }, 'owner');
  assert.equal(r.intent, null);
  assert.match(r.refusal ?? '', /неизвестный инструмент/);
});

test('пропущенный обязательный аргумент превращается в уточнение', () => {
  const r = parseModelCall({ name: 'find_slots', arguments: {} }, 'client');
  assert.equal(r.intent, null);
  assert.match(r.clarify ?? '', /Уточните/);
});

test('дата в неверном формате не проходит', () => {
  const r = parseModelCall(
    { name: 'get_day_schedule', arguments: { date: '5 октября' } },
    'owner',
  );
  assert.equal(r.intent, null);
  assert.match(r.clarify ?? '', /Уточните/);
});

test('мусор вместо ответа модели не роняет разбор', () => {
  for (const junk of ['', 'просто текст', '{{{', null, 42, [], { foo: 'bar' }]) {
    const r = parseModelCall(junk, 'client');
    assert.equal(r.intent, null);
  }
});
