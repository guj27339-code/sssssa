/**
 * Выполнение инструментов помощника.
 *
 * Каждый инструмент — вызов заранее написанной функции или выборка по
 * фиксированным полям. SQL здесь не собирается из ответа модели, и
 * tenant_id приходит из контекста запроса, а не из её аргументов.
 */

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';
import type { Intent } from '../_shared/router.ts';
import { denyReason, type ToolScope } from '../_shared/tools.ts';
import { hashToken, toByteaLiteral } from '../_shared/token.ts';

export interface ToolContext {
  tenantId: string;
  timeZone: string;
  scope: ToolScope;
  bookingToken: string | null;
}

export async function runTool(
  db: SupabaseClient,
  intent: Intent,
  ctx: ToolContext,
): Promise<unknown> {
  // Повторная проверка полномочий перед самим вызовом: роутер мог
  // ошибиться, и одна точка контроля надёжнее двух предположений.
  const deny = denyReason(intent.tool, ctx.scope);
  if (deny) throw new Error(deny);

  switch (intent.tool) {
    case 'list_services':  return listServices(db, ctx);
    case 'get_studio_info':return studioInfo(db, ctx);
    case 'find_slots':     return findSlots(db, intent, ctx);
    case 'get_my_booking': return myBooking(db, ctx);
    case 'get_day_schedule': return daySchedule(db, intent, ctx);
    case 'get_stats':      return stats(db, intent, ctx);
    default:
      throw new Error(`инструмент "${intent.tool}" не реализован`);
  }
}

async function listServices(db: SupabaseClient, ctx: ToolContext) {
  const { data, error } = await db
    .from('services')
    .select('id, name, description, duration_minutes, price_kopecks')
    .eq('tenant_id', ctx.tenantId)
    .eq('is_active', true)
    .order('sort_order');

  if (error) throw error;

  return {
    services: (data ?? []).map((s) => ({
      id: s.id,
      name: s.name,
      description: s.description,
      duration_minutes: s.duration_minutes,
      // Отсутствие цены передаём явно, чтобы модель не подставила число.
      price: s.price_kopecks == null
        ? { known: false, note: 'по осмотру' }
        : { known: true, rubles: Math.round(s.price_kopecks / 100) },
    })),
  };
}

async function studioInfo(db: SupabaseClient, ctx: ToolContext) {
  const { data: tenant, error } = await db
    .from('tenants')
    .select('name, timezone, public_config')
    .eq('id', ctx.tenantId)
    .single();

  if (error) throw error;

  const { data: hours } = await db
    .from('working_hours')
    .select('weekday, opens_at, closes_at')
    .eq('tenant_id', ctx.tenantId)
    .order('weekday');

  const cfg = (tenant.public_config ?? {}) as Record<string, any>;

  return {
    name: tenant.name,
    timezone: tenant.timezone,
    contacts: cfg.contacts ?? {},
    working_hours: hours ?? [],
  };
}

async function findSlots(db: SupabaseClient, intent: Intent, ctx: ToolContext) {
  const serviceId = String(intent.args.service_key ?? '');
  const fromDate = String(intent.args.from_date ?? new Date().toISOString().slice(0, 10));
  const days = Math.min(30, Math.max(1, Number(intent.args.days ?? 14)));

  // Расчёт свободного времени делает база: те же правила, что и у формы
  // записи, поэтому помощник и форма не могут разойтись в ответах.
  const { data, error } = await db.schema('app').rpc('find_free_slots', {
    p_tenant: ctx.tenantId,
    p_service: serviceId,
    p_from: fromDate,
    p_days: days,
    p_limit: 12,
  });

  if (error) throw error;

  return {
    service_id: serviceId,
    from_date: fromDate,
    timezone: ctx.timeZone,
    slots: data ?? [],
    // Явная отметка пустого результата: модели велено не выдумывать времена.
    empty: !data || data.length === 0,
  };
}

async function myBooking(db: SupabaseClient, ctx: ToolContext) {
  if (!ctx.bookingToken) {
    return { found: false, reason: 'нет токена доступа' };
  }

  const hash = await hashToken(ctx.bookingToken);
  const { data, error } = await db.schema('app')
    .rpc('booking_by_token', { p_token_hash: toByteaLiteral(hash) });

  if (error) throw error;
  if (!data || data.length === 0) return { found: false };

  const b = data[0];

  // Клиентскому помощнику список всех клиентов недоступен: возвращаем
  // ровно одну запись — ту, к которой у него есть токен.
  return {
    found: true,
    booking: {
      status: b.status,
      starts_at: b.starts_at,
      ends_at: b.ends_at,
      service: b.service_name,
      resource: b.resource_name,
      customer_name: b.customer_name,
    },
  };
}

async function daySchedule(db: SupabaseClient, intent: Intent, ctx: ToolContext) {
  const date = String(intent.args.date);

  const { data, error } = await db.schema('app').rpc('day_schedule', {
    p_tenant: ctx.tenantId,
    p_date: date,
  });

  if (error) throw error;

  return {
    date,
    timezone: ctx.timeZone,
    items: (data ?? []).map((r: Record<string, unknown>) => ({
      kind: r.kind,
      resource: r.resource_name,
      from: (r.during as string)?.split(',')[0]?.replace(/^\[/, ''),
      service: r.service_name,
      customer: r.customer_name,
      status: r.booking_status,
      note: r.note,
    })),
    empty: !data || data.length === 0,
  };
}

async function stats(db: SupabaseClient, intent: Intent, ctx: ToolContext) {
  const { data, error } = await db.schema('app').rpc('tenant_stats', {
    p_tenant: ctx.tenantId,
    p_from: String(intent.args.from_date),
    p_to: String(intent.args.to_date),
  });

  if (error) throw error;

  const row = Array.isArray(data) ? data[0] : data;

  // Названия величин переданы явно, чтобы модель не назвала ожидаемое
  // выручкой: инвариант 8.
  return {
    period: { from: row.period_from, to: row.period_to, timezone: row.timezone },
    arrivals: row.arrivals,
    completed: row.completed,
    cancelled: row.cancelled,
    no_show: row.no_show,
    received_rubles: Math.round(Number(row.received_kopecks) / 100),
    refunded_rubles: Math.round(Number(row.refunded_kopecks) / 100),
    expected_rubles: Math.round(Number(row.expected_kopecks) / 100),
    note: 'expected_rubles — ожидаемая стоимость будущих записей. Это не полученные деньги и не выручка.',
  };
}
