/**
 * Каталог серверных инструментов помощника.
 *
 * Инвариант 7: модель не выбирает SQL и не выбирает tenant_id. Она может
 * лишь назвать инструмент из этого списка и передать его аргументы.
 * tenant_id подставляет сервер из контекста запроса, а не из ответа модели.
 *
 * Инструменты разделены по полномочиям: клиентские доступны анонимному
 * посетителю, владельческие — только после проверки членства.
 */

export type ToolScope = 'client' | 'owner';

export interface ToolParam {
  name: string;
  type: 'string' | 'number' | 'date' | 'enum';
  required: boolean;
  description: string;
  values?: readonly string[];
}

export interface ToolDef {
  name: string;
  scope: ToolScope;
  description: string;
  params: readonly ToolParam[];
}

export const TOOLS: readonly ToolDef[] = [
  // ── клиентские ─────────────────────────────────────────────────────────
  {
    name: 'list_services',
    scope: 'client',
    description: 'Список услуг студии с длительностью и ценой. Цена может отсутствовать — тогда она определяется по осмотру.',
    params: [],
  },
  {
    name: 'find_slots',
    scope: 'client',
    description: 'Свободное время для услуги начиная с указанной даты.',
    params: [
      { name: 'service_key', type: 'string', required: true,
        description: 'Ключ услуги из list_services' },
      { name: 'from_date', type: 'date', required: false,
        description: 'Дата начала поиска в формате ГГГГ-ММ-ДД; по умолчанию сегодня' },
      { name: 'days', type: 'number', required: false,
        description: 'Сколько дней просматривать, 1–30; по умолчанию 14' },
    ],
  },
  {
    name: 'get_studio_info',
    scope: 'client',
    description: 'Адрес, телефон, часы работы и маршрут до студии.',
    params: [],
  },
  {
    name: 'get_my_booking',
    scope: 'client',
    description: 'Подробности записи по токену доступа. Токен берётся из контекста запроса, а не у модели.',
    params: [],
  },

  // ── владельческие ──────────────────────────────────────────────────────
  {
    name: 'get_day_schedule',
    scope: 'owner',
    description: 'Записи и блокировки постов на конкретную дату.',
    params: [
      { name: 'date', type: 'date', required: true,
        description: 'Дата в формате ГГГГ-ММ-ДД' },
    ],
  },
  {
    name: 'get_stats',
    scope: 'owner',
    description: 'Статистика за период: заезды, выполненные работы, полученные деньги. Ожидаемая стоимость будущих записей выручкой не является.',
    params: [
      { name: 'from_date', type: 'date', required: true, description: 'Начало периода' },
      { name: 'to_date', type: 'date', required: true, description: 'Конец периода включительно' },
    ],
  },
] as const;

export const TOOLS_BY_NAME: ReadonlyMap<string, ToolDef> =
  new Map(TOOLS.map((t) => [t.name, t]));

/** Инструменты, доступные при данных полномочиях. */
export function toolsForScope(scope: ToolScope): readonly ToolDef[] {
  // Владелец видит и клиентские инструменты: ему тоже нужен список услуг.
  return scope === 'owner' ? TOOLS : TOOLS.filter((t) => t.scope === 'client');
}

/**
 * Проверяет, что инструмент разрешён при данных полномочиях.
 * Возвращает причину отказа или null, если всё в порядке.
 *
 * Эта проверка выполняется ДО вызова инструмента и не полагается
 * на то, что модель прислала корректное имя.
 */
export function denyReason(name: string, scope: ToolScope): string | null {
  const tool = TOOLS_BY_NAME.get(name);
  if (!tool) return `неизвестный инструмент "${name}"`;
  if (tool.scope === 'owner' && scope !== 'owner') {
    return `инструмент "${name}" доступен только владельцу`;
  }
  return null;
}

/** Описание инструментов в формате function calling. */
export function toOpenAiTools(scope: ToolScope) {
  return toolsForScope(scope).map((t) => ({
    type: 'function' as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: {
        type: 'object',
        properties: Object.fromEntries(
          t.params.map((p) => [
            p.name,
            {
              type: p.type === 'number' ? 'number' : 'string',
              description: p.description,
              ...(p.values ? { enum: [...p.values] } : {}),
            },
          ]),
        ),
        required: t.params.filter((p) => p.required).map((p) => p.name),
        additionalProperties: false,
      },
    },
  }));
}
