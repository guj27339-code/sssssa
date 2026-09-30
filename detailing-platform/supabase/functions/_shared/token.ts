/**
 * Выдача и проверка токена доступа к брони.
 *
 * Инвариант 5: клиент не регистрируется. Ссылка на его запись содержит
 * токен; в базе лежит только sha256 от него.
 *
 * Повторная выдача того же доступа при retry решается тем, что токен
 * ВЫВОДИТСЯ, а не генерируется случайно:
 *
 *     token = base64url( HMAC-SHA256(secret, tenant_id + ':' + idempotency_key) )
 *
 * Повтор запроса с тем же ключом идемпотентности даёт тот же токен —
 * не потому, что он где-то сохранён, а потому что вычисление детерминировано.
 * База по-прежнему не может его восстановить: она хранит только хэш.
 *
 * Секрет живёт в переменных окружения Edge Function и во фронтенд не попадает.
 */

const enc = new TextEncoder();

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw', enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign'],
  );
}

function base64url(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Токен для пары (студия, ключ идемпотентности). Детерминирован. */
export async function deriveToken(
  secret: string,
  tenantId: string,
  idempotencyKey: string,
): Promise<string> {
  if (!secret || secret.length < 32) {
    throw new Error('BOOKING_TOKEN_SECRET не задан или короче 32 символов');
  }
  const key = await hmacKey(secret);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(`${tenantId}:${idempotencyKey}`));
  return base64url(sig);
}

/** sha256 токена — то, что попадает в базу. */
export async function hashToken(token: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest('SHA-256', enc.encode(token));
  return new Uint8Array(digest);
}

/** Представление для передачи в SQL в виде bytea-литерала. */
export function toByteaLiteral(bytes: Uint8Array): string {
  return '\\x' + [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Сравнение токенов за постоянное время.
 * Обычное === выдаёт длину общего префикса через время выполнения.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
