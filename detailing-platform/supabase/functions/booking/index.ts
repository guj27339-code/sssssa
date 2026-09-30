/**
 * Edge Function: запись клиента.
 *
 * POST /booking            — создать запись
 * POST /booking/reschedule — перенести
 * POST /booking/cancel     — отменить
 * GET  /booking?token=…    — посмотреть свою запись
 *
 * Инвариант 4: клиент передаёт только услугу, момент начала и контакты.
 * Цену, длительность и tenant_id сервер берёт из базы по slug из пути
 * и по service_id. Значения из тела запроса для них игнорируются.
 *
 * Инвариант 12: публичные запросы ограничены общим счётчиком в БД.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'https://deno.land/x/zod@v3.23.8/mod.ts';
import { deriveToken, hashToken, toByteaLiteral } from '../_shared/token.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TOKEN_SECRET = Deno.env.get('BOOKING_TOKEN_SECRET')!;
const PUBLIC_RATE_LIMIT = Number(Deno.env.get('PUBLIC_RATE_LIMIT') ?? '120');

// service_role остаётся на сервере. Во фронтенд уходит только anon-ключ.
const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

/* ── схемы входа ──────────────────────────────────────────────────────── */

// Обратите внимание: ни tenant_id, ни цены, ни длительности здесь нет.
// Их присутствие в теле запроса ничего не изменит — они просто не читаются.
const CreateInput = z.object({
  slug: z.string().min(3).max(40).regex(/^[a-z0-9-]+$/),
  service_id: z.string().uuid(),
  starts_at: z.string().datetime({ offset: true }),
  name: z.string().min(1).max(120),
  phone: z.string().min(8).max(20),
  car: z.string().max(120).optional(),
  resource_id: z.string().uuid().optional(),
  idempotency_key: z.string().min(8).max(100),
});

const RescheduleInput = z.object({
  token: z.string().min(20).max(100),
  new_start: z.string().datetime({ offset: true }),
});

const CancelInput = z.object({
  token: z.string().min(20).max(100),
});

/* ── ответы ───────────────────────────────────────────────────────────── */

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'content-type, authorization',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
      'cache-control': 'no-store',
    },
  });
}

/** Сообщения базы переводим в понятные клиенту, не раскрывая внутренностей. */
const ERROR_TEXT: Record<string, { status: number; message: string }> = {
  no_free_resource:        { status: 409, message: 'На это время уже нет свободного поста. Выберите другое.' },
  slot_taken:              { status: 409, message: 'Время только что заняли. Выберите другое.' },
  outside_acceptance_window:{ status: 422, message: 'В это время студия не принимает или не сможет отдать машину.' },
  starts_in_past:          { status: 422, message: 'Это время уже прошло.' },
  service_not_found:       { status: 404, message: 'Услуга не найдена.' },
  tenant_not_found:        { status: 404, message: 'Студия не найдена.' },
  tenant_suspended:        { status: 423, message: 'Запись в эту студию сейчас закрыта.' },
  booking_not_found:       { status: 404, message: 'Запись не найдена.' },
  booking_not_active:      { status: 409, message: 'Эту запись уже нельзя изменить.' },
  resource_not_compatible: { status: 422, message: 'Выбранный пост не выполняет эту услугу.' },
  invalid_phone:           { status: 422, message: 'Проверьте номер телефона.' },
};

function mapError(e: unknown): Response {
  const raw = (e as { message?: string })?.message ?? '';
  for (const [code, info] of Object.entries(ERROR_TEXT)) {
    if (raw.includes(code)) return json({ error: code, message: info.message }, info.status);
  }
  console.error('booking: непредвиденная ошибка', raw);
  return json({ error: 'internal', message: 'Не удалось выполнить запрос. Попробуйте ещё раз.' }, 500);
}

/* ── вспомогательное ──────────────────────────────────────────────────── */

async function tenantBySlug(slug: string) {
  const { data, error } = await db
    .from('tenants')
    .select('id, slug, name, timezone, status')
    .eq('slug', slug)
    .maybeSingle();

  if (error) throw error;
  if (!data) throw new Error('tenant_not_found');
  return data;
}

async function checkQuota(tenantId: string): Promise<boolean> {
  const { data, error } = await db.schema('app').rpc('consume_quota', {
    p_tenant: tenantId,
    p_bucket: 'public_requests',
    p_amount: 1,
    p_limit: PUBLIC_RATE_LIMIT,
    p_window: '01:00:00',
  });
  if (error) throw error;
  return data === true;
}

/* ── обработчики ──────────────────────────────────────────────────────── */

async function handleCreate(body: unknown): Promise<Response> {
  const parsed = CreateInput.safeParse(body);
  if (!parsed.success) {
    return json({ error: 'invalid_input', issues: parsed.error.issues }, 422);
  }
  const input = parsed.data;

  const tenant = await tenantBySlug(input.slug);

  if (!(await checkQuota(tenant.id))) {
    return json({ error: 'rate_limited', message: 'Слишком много запросов. Попробуйте через минуту.' }, 429);
  }

  // Токен выводится из ключа идемпотентности: повтор даст тот же токен.
  const token = await deriveToken(TOKEN_SECRET, tenant.id, input.idempotency_key);
  const hash = await hashToken(token);

  const { data, error } = await db.schema('app').rpc('create_booking', {
    p_tenant: tenant.id,
    p_service_id: input.service_id,
    p_starts_at: input.starts_at,
    p_customer_name: input.name,
    p_customer_phone: input.phone,
    p_token_hash: toByteaLiteral(hash),
    p_idempotency_key: input.idempotency_key,
    p_resource_id: input.resource_id ?? null,
  });

  if (error) return mapError(error);

  // Очередь напоминаний приводится в соответствие с состоянием брони.
  await db.schema('app').rpc('sync_notifications_for_booking', { p_booking: data.id });

  return json({
    booking_id: data.id,
    starts_at: data.starts_at,
    ends_at: data.ends_at,
    status: data.status,
    // Токен возвращается один раз в ответе и живёт в ссылке у клиента.
    access_token: token,
    manage_url: `/s/${tenant.slug}/booking?token=${encodeURIComponent(token)}`,
  }, 201);
}

async function handleReschedule(body: unknown): Promise<Response> {
  const parsed = RescheduleInput.safeParse(body);
  if (!parsed.success) {
    return json({ error: 'invalid_input', issues: parsed.error.issues }, 422);
  }

  const hash = await hashToken(parsed.data.token);
  const { data: found, error: findErr } = await db.schema('app')
    .rpc('booking_by_token', { p_token_hash: toByteaLiteral(hash) });

  if (findErr) return mapError(findErr);
  if (!found || found.length === 0) {
    return json({ error: 'booking_not_found', message: 'Запись не найдена.' }, 404);
  }

  const booking = found[0];

  // Перенос атомарен внутри SQL: при конфликте исходная бронь остаётся.
  const { data, error } = await db.schema('app').rpc('reschedule_booking', {
    p_tenant: booking.tenant_id ?? null,
    p_booking_id: booking.booking_id,
    p_new_start: parsed.data.new_start,
    p_new_resource: null,
  });

  if (error) return mapError(error);

  await db.schema('app').rpc('sync_notifications_for_booking', { p_booking: data.id });

  return json({ booking_id: data.id, starts_at: data.starts_at, ends_at: data.ends_at, status: data.status });
}

async function handleCancel(body: unknown): Promise<Response> {
  const parsed = CancelInput.safeParse(body);
  if (!parsed.success) {
    return json({ error: 'invalid_input', issues: parsed.error.issues }, 422);
  }

  const hash = await hashToken(parsed.data.token);
  const { data: found } = await db.schema('app')
    .rpc('booking_by_token', { p_token_hash: toByteaLiteral(hash) });

  if (!found || found.length === 0) {
    return json({ error: 'booking_not_found', message: 'Запись не найдена.' }, 404);
  }

  const booking = found[0];
  const { data, error } = await db.schema('app').rpc('cancel_booking', {
    p_tenant: booking.tenant_id,
    p_booking_id: booking.booking_id,
  });

  if (error) return mapError(error);

  await db.schema('app').rpc('sync_notifications_for_booking', { p_booking: booking.booking_id });

  return json({ booking_id: data.id, status: data.status });
}

async function handleGet(url: URL): Promise<Response> {
  const token = url.searchParams.get('token');
  if (!token) {
    return json({ error: 'token_required' }, 400);
  }

  const hash = await hashToken(token);
  const { data, error } = await db.schema('app')
    .rpc('booking_by_token', { p_token_hash: toByteaLiteral(hash) });

  if (error) return mapError(error);
  if (!data || data.length === 0) {
    return json({ error: 'booking_not_found', message: 'Запись не найдена.' }, 404);
  }

  return json(data[0]);
}

/* ── точка входа ──────────────────────────────────────────────────────── */

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return json({}, 204);
  }

  const url = new URL(req.url);
  const action = url.pathname.split('/').filter(Boolean).pop() ?? '';

  try {
    if (req.method === 'GET') {
      return await handleGet(url);
    }
    if (req.method !== 'POST') {
      return json({ error: 'method_not_allowed' }, 405);
    }

    const body = await req.json().catch(() => null);

    switch (action) {
      case 'reschedule': return await handleReschedule(body);
      case 'cancel':     return await handleCancel(body);
      default:           return await handleCreate(body);
    }
  } catch (e) {
    return mapError(e);
  }
});
