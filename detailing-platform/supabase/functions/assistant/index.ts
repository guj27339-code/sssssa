/**
 * Edge Function: помощник студии.
 *
 * Инвариант 7:
 *  - до ответа про записи выполняется разрешённый серверный инструмент,
 *    и его результат передаётся модели;
 *  - SQL и tenant_id модель не выбирает: tenant берётся из slug в запросе,
 *    инструмент — из закрытого каталога;
 *  - клиентские и владельческие инструменты разделены проверкой полномочий;
 *  - цикл инструментов ограничен;
 *  - при недоступной модели работает запасной разбор без неё.
 *
 * Инвариант 12: расход на модель ограничен общим счётчиком в БД.
 * При исчерпании лимита или отказе модели обычная запись продолжает работать —
 * помощник лишь сообщает, что сейчас отвечает упрощённо.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { toOpenAiTools, type ToolScope } from '../_shared/tools.ts';
import { routeByRules, parseModelCall, type Intent } from '../_shared/router.ts';
import { runTool } from './run-tool.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Модель настраивается снаружи: базовый адрес, ключ и имя модели.
const LLM_BASE_URL = Deno.env.get('LLM_BASE_URL') ?? 'https://api.openai.com/v1';
const LLM_API_KEY  = Deno.env.get('LLM_API_KEY') ?? '';
const LLM_MODEL    = Deno.env.get('LLM_MODEL') ?? 'gpt-4o-mini';

const LLM_CALL_LIMIT   = Number(Deno.env.get('LLM_CALL_LIMIT') ?? '60');
const MAX_TOOL_ROUNDS  = 2;   // потолок цикла инструментов
const LLM_TIMEOUT_MS   = 12000;

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'content-type, authorization',
      'cache-control': 'no-store',
    },
  });
}

/**
 * Полномочия определяются на сервере.
 * Заголовок Authorization проверяется через Supabase Auth, затем членство
 * подтверждается по tenant_members. Заявление клиента «я владелец» не значит
 * ничего: при неудачной проверке роль остаётся клиентской.
 */
async function resolveScope(req: Request, tenantId: string): Promise<ToolScope> {
  const auth = req.headers.get('authorization');
  if (!auth?.startsWith('Bearer ')) return 'client';

  const { data: userData, error } = await db.auth.getUser(auth.slice(7));
  if (error || !userData?.user) return 'client';

  const { data: member } = await db
    .from('tenant_members')
    .select('role')
    .eq('tenant_id', tenantId)
    .eq('user_id', userData.user.id)
    .maybeSingle();

  return member ? 'owner' : 'client';
}

interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  tool_call_id?: string;
  tool_calls?: unknown[];
}

async function callModel(
  messages: ChatMessage[],
  scope: ToolScope,
): Promise<{ text: string; toolCall: unknown | null } | null> {
  if (!LLM_API_KEY) return null;

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), LLM_TIMEOUT_MS);

  try {
    const res = await fetch(`${LLM_BASE_URL}/chat/completions`, {
      method: 'POST',
      signal: ctrl.signal,
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${LLM_API_KEY}`,
      },
      body: JSON.stringify({
        model: LLM_MODEL,
        messages,
        tools: toOpenAiTools(scope),
        tool_choice: 'auto',
        temperature: 0.2,
        max_tokens: 500,
      }),
    });

    if (!res.ok) {
      console.error('llm: ответ', res.status, await res.text().catch(() => ''));
      return null;
    }

    const body = await res.json();
    const choice = body?.choices?.[0]?.message;
    if (!choice) return null;

    return {
      text: typeof choice.content === 'string' ? choice.content : '',
      toolCall: choice.tool_calls?.[0]?.function ?? null,
    };
  } catch (e) {
    console.error('llm: вызов не удался', (e as Error).message);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

const SYSTEM_PROMPT = `Ты — помощник студии детейлинга. Отвечай коротко и по-русски.

Жёсткие правила:
- Никогда не называй свободное время, цену или подробности записи по памяти.
  Сначала вызови подходящий инструмент и отвечай только по его результату.
- Если инструмент вернул пустой список, так и скажи. Не придумывай времена.
- Если не хватает данных для вызова инструмента, задай один уточняющий вопрос.
- Цену, у которой нет значения, называй «по осмотру», а не числом.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return json({}, 204);
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as
    | { slug?: string; message?: string; booking_token?: string }
    | null;

  const slug = body?.slug;
  const message = body?.message;

  if (!slug || !message || message.length > 1000) {
    return json({ error: 'invalid_input' }, 422);
  }

  // Студия — из slug, а не из ответа модели.
  const { data: tenant } = await db
    .from('tenants')
    .select('id, slug, name, timezone, status')
    .eq('slug', slug)
    .maybeSingle();

  if (!tenant) return json({ error: 'tenant_not_found' }, 404);

  const scope = await resolveScope(req, tenant.id);

  const { data: services } = await db
    .from('services')
    .select('id, name')
    .eq('tenant_id', tenant.id)
    .eq('is_active', true);

  const serviceIndex = (services ?? []).map((s) => ({ key: s.id, name: s.name }));

  const fallbackCtx = {
    scope,
    services: serviceIndex,
    today: new Date(),
    timeZone: tenant.timezone,
    hasBookingToken: Boolean(body?.booking_token),
  };

  // Бюджет модели. Исчерпан — идём запасным путём, а не отказываем.
  const { data: hasBudget } = await db.schema('app').rpc('consume_quota', {
    p_tenant: tenant.id, p_bucket: 'llm_calls',
    p_amount: 1, p_limit: LLM_CALL_LIMIT, p_window: '01:00:00',
  });

  const messages: ChatMessage[] = [
    { role: 'system', content: SYSTEM_PROMPT },
    { role: 'user', content: message },
  ];

  let intent: Intent | null = null;
  let refusal: string | null = null;
  let clarify: string | null = null;
  let degraded = false;

  if (hasBudget === true) {
    const first = await callModel(messages, scope);

    if (first) {
      const routed = first.toolCall
        ? parseModelCall(first.toolCall, scope)
        : parseModelCall(first.text, scope);

      intent = routed.intent;
      refusal = routed.refusal;
      clarify = routed.clarify;

      // Модель не выбрала инструмент, но вопрос явно про данные —
      // пробуем разобрать правилами, чтобы не ответить по памяти.
      if (!intent && !refusal && !clarify) {
        const byRules = routeByRules(message, fallbackCtx);
        intent = byRules.intent;
        clarify = byRules.clarify;
        refusal = byRules.refusal;

        // Инструмент не нужен — это разговорный вопрос, отвечает модель.
        if (!intent && !clarify && !refusal && first.text) {
          return json({ answer: first.text, used_tool: null, degraded: false });
        }
      }
    } else {
      degraded = true;
    }
  } else {
    degraded = true;
  }

  // Модель недоступна или бюджет исчерпан — разбираем сами.
  if (degraded && !intent) {
    const byRules = routeByRules(message, fallbackCtx);
    intent = byRules.intent;
    clarify = byRules.clarify;
    refusal = byRules.refusal;
  }

  if (refusal) {
    return json({
      answer: 'Этот вопрос доступен только владельцу студии.',
      used_tool: null, degraded,
    });
  }

  if (!intent) {
    return json({
      answer: clarify ?? 'Уточните, пожалуйста, вопрос: могу рассказать про услуги, свободное время или как нас найти.',
      used_tool: null, degraded,
    });
  }

  // ── выполнение инструмента ─────────────────────────────────────────────
  // tenant_id подставляет сервер. Модель на него не влияет.
  let toolResult: unknown;
  try {
    toolResult = await runTool(db, intent, {
      tenantId: tenant.id,
      timeZone: tenant.timezone,
      scope,
      bookingToken: body?.booking_token ?? null,
    });
  } catch (e) {
    console.error('tool: ошибка', (e as Error).message);
    return json({
      answer: 'Не удалось получить данные. Попробуйте ещё раз или запишитесь обычным способом.',
      used_tool: intent.tool, degraded: true,
    }, 200);
  }

  // ── второй заход: модель формулирует ответ по результату ───────────────
  if (!degraded && hasBudget === true) {
    messages.push({
      role: 'assistant',
      content: `Вызван инструмент ${intent.tool}.`,
    });
    messages.push({
      role: 'user',
      content: `Результат инструмента ${intent.tool} (отвечай только по нему, ничего не добавляй от себя):\n${JSON.stringify(toolResult)}`,
    });

    // Второй заход без инструментов: цикл ограничен MAX_TOOL_ROUNDS.
    const second = await callModel(messages, scope);
    if (second?.text) {
      return json({
        answer: second.text,
        used_tool: intent.tool,
        tool_result: toolResult,
        degraded: false,
        rounds: MAX_TOOL_ROUNDS,
      });
    }
  }

  // Модель не ответила — отдаём результат инструмента как есть.
  // Фронтенд умеет его показать: это не заглушка, а структурированные данные.
  return json({
    answer: null,
    used_tool: intent.tool,
    tool_result: toolResult,
    degraded: true,
  });
});
