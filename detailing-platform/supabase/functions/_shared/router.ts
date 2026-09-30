/**
 * Роутер намерений.
 *
 * Инвариант 7: помощник обязан выполнить разрешённый серверный инструмент
 * ДО того, как отвечать про записи и свободное время. Если модель недоступна
 * или вернула мусор, запрос всё равно должен привести к вызову инструмента —
 * для этого здесь есть запасной разбор без модели.
 *
 * Модуль намеренно чистый: никаких сетевых вызовов и никакого состояния.
 * Благодаря этому он тестируется отдельно, как того требует инвариант 7.
 */

import { TOOLS_BY_NAME, denyReason, type ToolScope } from './tools.ts';

export interface Intent {
  tool: string;
  args: Record<string, string | number>;
  /** 'model' — выбрала модель, 'fallback' — разобрано правилами. */
  origin: 'model' | 'fallback';
  confidence: number;
}

export interface RouteResult {
  intent: Intent | null;
  /** Причина, по которой инструмент не выбран или запрещён. */
  refusal: string | null;
  /** Уточняющий вопрос, если данных не хватает. */
  clarify: string | null;
}

/* ── нормализация ─────────────────────────────────────────────────────── */

function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/ё/g, 'е')
    .replace(/[^\p{L}\p{N}\s:.-]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Слова, по которым узнаётся намерение. Порядок важен: раньше — точнее. */
const RULES: ReadonlyArray<{ tool: string; any: readonly string[]; weight: number }> = [
  { tool: 'get_stats',        any: ['сколько денег', 'выручк', 'получено', 'заработал', 'сколько машин', 'статистик', 'за неделю', 'за месяц'], weight: 0.8 },
  { tool: 'get_day_schedule', any: ['что у меня', 'какие записи', 'расписание', 'на завтра', 'на сегодня', 'кто записан'], weight: 0.8 },
  { tool: 'get_my_booking',   any: ['моя запись', 'мою запись', 'когда я записан', 'моя бронь', 'отменить запись', 'перенести запись'], weight: 0.85 },
  { tool: 'find_slots',       any: ['ближайшее окно', 'свободн', 'когда можно', 'записаться', 'запись на', 'есть места', 'во сколько'], weight: 0.75 },
  { tool: 'list_services',    any: ['сколько стоит', 'цен', 'прайс', 'услуг', 'что делаете', 'стоимость'], weight: 0.7 },
  { tool: 'get_studio_info',  any: ['как найти', 'где вы', 'адрес', 'как проехать', 'телефон', 'во сколько открыв', 'график работы', 'маршрут'], weight: 0.75 },
];

/** Названия услуг → ключ. Заполняется из каталога студии. */
export type ServiceIndex = ReadonlyArray<{ key: string; name: string }>;

/**
 * Усечённая основа слова. Полноценная лемматизация здесь избыточна:
 * русские окончания короткие, и отбрасывания двух последних букв хватает,
 * чтобы «полировку» совпало с «полировка», а «химчистку» с «химчистка».
 * Нижняя граница в 4 символа не даёт основам стать слишком общими.
 */
function stem(word: string): string {
  return word.slice(0, Math.max(4, word.length - 2));
}

function matchService(text: string, services: ServiceIndex): string | null {
  const n = normalize(text);
  let best: { key: string; score: number } | null = null;

  for (const s of services) {
    const words = normalize(s.name).split(' ').filter((w) => w.length >= 4);
    if (words.length === 0) continue;

    const hits = words.filter((w) => n.includes(stem(w))).length;
    const score = hits / words.length;

    if (score > 0 && (!best || score > best.score)) {
      best = { key: s.key, score };
    }
  }

  return best && best.score >= 0.5 ? best.key : null;
}

/** Относительные даты: сегодня, завтра, послезавтра. */
function matchDate(text: string, today: Date, timeZone: string): string | null {
  const n = normalize(text);

  const iso = n.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return iso[0];

  const shift =
    /послезавтра/.test(n) ? 2 :
    /завтра/.test(n) ? 1 :
    /сегодня/.test(n) ? 0 :
    null;

  if (shift === null) return null;

  const d = new Date(today.getTime() + shift * 86400000);
  // Дата в зоне студии, а не в зоне сервера.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(d);
}

/* ── запасной разбор без модели ───────────────────────────────────────── */

export interface FallbackContext {
  scope: ToolScope;
  services: ServiceIndex;
  today: Date;
  timeZone: string;
  hasBookingToken: boolean;
}

export function routeByRules(text: string, ctx: FallbackContext): RouteResult {
  const n = normalize(text);

  let picked: { tool: string; weight: number } | null = null;
  for (const rule of RULES) {
    if (rule.any.some((k) => n.includes(k))) {
      if (!picked || rule.weight > picked.weight) {
        picked = { tool: rule.tool, weight: rule.weight };
      }
    }
  }

  if (!picked) {
    return { intent: null, refusal: null, clarify: null };
  }

  const deny = denyReason(picked.tool, ctx.scope);
  if (deny) {
    return { intent: null, refusal: deny, clarify: null };
  }

  const args: Record<string, string | number> = {};

  if (picked.tool === 'find_slots') {
    const key = matchService(text, ctx.services);
    if (!key) {
      // Данных не хватает — задаём уточняющий вопрос вместо догадки.
      return {
        intent: null, refusal: null,
        clarify: 'На какую услугу подобрать время?',
      };
    }
    args.service_key = key;
    const d = matchDate(text, ctx.today, ctx.timeZone);
    if (d) args.from_date = d;
  }

  if (picked.tool === 'get_day_schedule') {
    const d = matchDate(text, ctx.today, ctx.timeZone);
    if (!d) {
      return { intent: null, refusal: null, clarify: 'За какой день показать записи?' };
    }
    args.date = d;
  }

  if (picked.tool === 'get_stats') {
    const range = matchStatsRange(n, ctx.today, ctx.timeZone);
    if (!range) {
      return { intent: null, refusal: null, clarify: 'За какой период посчитать?' };
    }
    args.from_date = range.from;
    args.to_date = range.to;
  }

  if (picked.tool === 'get_my_booking' && !ctx.hasBookingToken) {
    return {
      intent: null, refusal: null,
      clarify: 'Не вижу вашей записи в этом устройстве. Откройте ссылку из подтверждения записи.',
    };
  }

  return {
    intent: { tool: picked.tool, args, origin: 'fallback', confidence: picked.weight },
    refusal: null,
    clarify: null,
  };
}

function fmt(d: Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(d);
}

function matchStatsRange(n: string, today: Date, timeZone: string) {
  if (/за неделю|на неделе|за 7 дней/.test(n)) {
    return { from: fmt(new Date(today.getTime() - 6 * 86400000), timeZone), to: fmt(today, timeZone) };
  }
  if (/за месяц|за 30 дней/.test(n)) {
    return { from: fmt(new Date(today.getTime() - 29 * 86400000), timeZone), to: fmt(today, timeZone) };
  }
  if (/сегодня|за день/.test(n)) {
    return { from: fmt(today, timeZone), to: fmt(today, timeZone) };
  }
  if (/вчера/.test(n)) {
    const y = new Date(today.getTime() - 86400000);
    return { from: fmt(y, timeZone), to: fmt(y, timeZone) };
  }
  return null;
}

/* ── разбор ответа модели ─────────────────────────────────────────────── */

/**
 * Принимает то, что вернула модель, и превращает в намерение.
 * Ничему из ответа не доверяет: имя инструмента сверяется с каталогом,
 * лишние аргументы отбрасываются, tenant_id игнорируется, даже если
 * модель его прислала.
 */
export function parseModelCall(
  raw: unknown,
  scope: ToolScope,
): RouteResult {
  let name: unknown;
  let rawArgs: unknown;

  if (typeof raw === 'string') {
    // Запасной путь: модель без function calling отвечает JSON-объектом.
    const json = extractJson(raw);
    if (!json) return { intent: null, refusal: null, clarify: null };
    name = json.tool ?? json.name ?? json.intent;
    rawArgs = json.args ?? json.arguments ?? json.parameters ?? {};
  } else if (raw && typeof raw === 'object') {
    const o = raw as Record<string, unknown>;
    name = o.name ?? o.tool;
    rawArgs = o.arguments ?? o.args ?? {};
    if (typeof rawArgs === 'string') {
      rawArgs = extractJson(rawArgs) ?? {};
    }
  } else {
    return { intent: null, refusal: null, clarify: null };
  }

  if (typeof name !== 'string') {
    return { intent: null, refusal: null, clarify: null };
  }

  const deny = denyReason(name, scope);
  if (deny) {
    return { intent: null, refusal: deny, clarify: null };
  }

  const def = TOOLS_BY_NAME.get(name)!;
  const src = (rawArgs && typeof rawArgs === 'object' ? rawArgs : {}) as Record<string, unknown>;
  const args: Record<string, string | number> = {};

  // Берём только объявленные параметры. Всё остальное — включая tenant_id,
  // sql и любые попытки расширить доступ — отбрасывается молча.
  for (const p of def.params) {
    const v = src[p.name];
    if (v === undefined || v === null) continue;

    if (p.type === 'number') {
      const num = typeof v === 'number' ? v : Number(v);
      if (Number.isFinite(num)) args[p.name] = num;
    } else if (p.type === 'date') {
      if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) args[p.name] = v;
    } else if (typeof v === 'string' && v.length <= 200) {
      args[p.name] = v;
    }
  }

  const missing = def.params.filter((p) => p.required && args[p.name] === undefined);
  if (missing.length > 0) {
    return {
      intent: null, refusal: null,
      clarify: `Уточните: ${missing.map((m) => m.description).join('; ')}`,
    };
  }

  return {
    intent: { tool: name, args, origin: 'model', confidence: 1 },
    refusal: null, clarify: null,
  };
}

/** Достаёт первый JSON-объект из текста: модели любят обрамлять его прозой. */
function extractJson(text: string): Record<string, any> | null {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidate = fenced ? fenced[1] : text;

  const start = candidate.indexOf('{');
  if (start < 0) return null;

  // Ищем парную закрывающую скобку, уважая строки.
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < candidate.length; i++) {
    const ch = candidate[i];
    if (esc) { esc = false; continue; }
    if (ch === '\\') { esc = true; continue; }
    if (ch === '"') { inStr = !inStr; continue; }
    if (inStr) continue;
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        try {
          const parsed = JSON.parse(candidate.slice(start, i + 1));
          return parsed && typeof parsed === 'object' ? parsed : null;
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}
