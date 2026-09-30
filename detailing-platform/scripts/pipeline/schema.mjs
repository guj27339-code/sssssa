/**
 * Схема business.json и её проверка.
 *
 * Валидатор написан без зависимостей намеренно: конвейер должен работать
 * до установки чего-либо, в том числе в чистом CI. Zod в этом проекте
 * отвечает за другое — за проверку данных, которые вводят люди в формах
 * приложения. Пересечения нет: business.json человек не вводит, его
 * готовит оператор конвейера.
 *
 * Правило источника истины (инвариант 2): business.json — вход конвейера.
 * После публикации источником для приложения становится база.
 */

const RE_SLUG  = /^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$/;
const RE_HEX   = /^#[0-9A-Fa-f]{6}$/;
const RE_PHONE = /^\+[1-9][0-9]{7,14}$/;
const RE_TIME  = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
const RE_DATE  = /^\d{4}-\d{2}-\d{2}$/;

/** Накопитель ошибок: собирает все проблемы, а не падает на первой. */
class Report {
  constructor() { this.errors = []; this.warnings = []; }
  err(path, message) { this.errors.push({ path, message }); }
  warn(path, message) { this.warnings.push({ path, message }); }
  get ok() { return this.errors.length === 0; }
}

function isPlainObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function checkString(r, path, value, { required = true, pattern = null, max = 500, min = 1 } = {}) {
  if (value === undefined || value === null || value === '') {
    if (required) r.err(path, 'обязательное поле не заполнено');
    return false;
  }
  if (typeof value !== 'string') {
    r.err(path, `ожидалась строка, пришло ${typeof value}`);
    return false;
  }
  if (value.length < min || value.length > max) {
    r.err(path, `длина ${value.length} вне диапазона ${min}..${max}`);
    return false;
  }
  if (pattern && !pattern.test(value)) {
    r.err(path, `не соответствует формату ${pattern}`);
    return false;
  }
  return true;
}

function checkInt(r, path, value, { required = true, min = 0, max = 1e9 } = {}) {
  if (value === undefined || value === null) {
    if (required) r.err(path, 'обязательное поле не заполнено');
    return false;
  }
  if (!Number.isInteger(value)) {
    r.err(path, `ожидалось целое число, пришло ${JSON.stringify(value)}`);
    return false;
  }
  if (value < min || value > max) {
    r.err(path, `значение ${value} вне диапазона ${min}..${max}`);
    return false;
  }
  return true;
}

/**
 * Проверяет разобранный business.json.
 * Возвращает Report: ошибки блокируют публикацию, предупреждения — нет.
 */
export function validateBusiness(doc) {
  const r = new Report();

  if (!isPlainObject(doc)) {
    r.err('', 'корень файла должен быть объектом');
    return r;
  }

  // ── студия ─────────────────────────────────────────────────────────────
  checkString(r, 'slug', doc.slug, { pattern: RE_SLUG, max: 40 });
  checkString(r, 'name', doc.name, { max: 120 });
  checkString(r, 'timezone', doc.timezone, { max: 60 });
  checkString(r, 'accent_color', doc.accent_color, { pattern: RE_HEX, required: false });
  checkString(r, 'description', doc.description, { required: false, max: 600 });

  if (doc.timezone && !isKnownTimezone(doc.timezone)) {
    r.err('timezone', `часовой пояс "${doc.timezone}" не распознан средой выполнения`);
  }

  // ── контакты ───────────────────────────────────────────────────────────
  const c = doc.contacts;
  if (!isPlainObject(c)) {
    r.err('contacts', 'блок контактов обязателен');
  } else {
    checkString(r, 'contacts.phone', c.phone, { pattern: RE_PHONE });
    checkString(r, 'contacts.address', c.address, { max: 300 });
    checkString(r, 'contacts.whatsapp', c.whatsapp, { required: false, pattern: RE_PHONE });
    checkString(r, 'contacts.telegram', c.telegram, { required: false, max: 200 });
    checkString(r, 'contacts.map_url', c.map_url, { required: false, max: 500 });
    if (!c.whatsapp && !c.telegram) {
      r.warn('contacts', 'не указан ни один мессенджер — кнопка «Написать» будет скрыта');
    }
  }

  // ── посты ──────────────────────────────────────────────────────────────
  if (!Array.isArray(doc.resources) || doc.resources.length === 0) {
    r.err('resources', 'нужен хотя бы один пост');
  } else {
    const keys = new Set();
    doc.resources.forEach((res, i) => {
      const p = `resources[${i}]`;
      checkString(r, `${p}.key`, res?.key, { pattern: /^[a-z0-9_-]{1,40}$/ });
      checkString(r, `${p}.name`, res?.name, { max: 120 });
      if (res?.key) {
        if (keys.has(res.key)) r.err(`${p}.key`, `ключ "${res.key}" уже использован`);
        keys.add(res.key);
      }
    });
  }

  // ── услуги ─────────────────────────────────────────────────────────────
  const resourceKeys = new Set((doc.resources || []).map((x) => x?.key).filter(Boolean));

  if (!Array.isArray(doc.services) || doc.services.length === 0) {
    r.err('services', 'нужна хотя бы одна услуга');
  } else {
    const keys = new Set();
    doc.services.forEach((s, i) => {
      const p = `services[${i}]`;
      checkString(r, `${p}.key`, s?.key, { pattern: /^[a-z0-9_-]{1,40}$/ });
      checkString(r, `${p}.name`, s?.name, { max: 160 });
      checkInt(r, `${p}.duration_minutes`, s?.duration_minutes, { min: 5, max: 60 * 24 * 30 });
      checkInt(r, `${p}.buffer_before_minutes`, s?.buffer_before_minutes, { required: false, min: 0, max: 1440 });
      checkInt(r, `${p}.buffer_after_minutes`, s?.buffer_after_minutes, { required: false, min: 0, max: 1440 });

      // Цена необязательна: «по осмотру» — законное состояние.
      if (s?.price_kopecks !== undefined && s.price_kopecks !== null) {
        checkInt(r, `${p}.price_kopecks`, s.price_kopecks, { min: 0, max: 1e11 });
      }

      if (s?.key) {
        if (keys.has(s.key)) r.err(`${p}.key`, `ключ "${s.key}" уже использован`);
        keys.add(s.key);
      }

      // Услуга обязана быть привязана к существующим постам.
      if (!Array.isArray(s?.resource_keys) || s.resource_keys.length === 0) {
        r.err(`${p}.resource_keys`, 'не указано, на каких постах выполняется услуга');
      } else {
        s.resource_keys.forEach((k, j) => {
          if (!resourceKeys.has(k)) {
            r.err(`${p}.resource_keys[${j}]`, `пост "${k}" не описан в resources`);
          }
        });
      }
    });
  }

  // ── график ─────────────────────────────────────────────────────────────
  if (!Array.isArray(doc.working_hours) || doc.working_hours.length === 0) {
    r.err('working_hours', 'график работы обязателен: без него нельзя вычислить свободное время');
  } else {
    const seen = new Set();
    doc.working_hours.forEach((w, i) => {
      const p = `working_hours[${i}]`;
      if (!checkInt(r, `${p}.weekday`, w?.weekday, { min: 1, max: 7 })) return;
      if (seen.has(w.weekday)) r.err(`${p}.weekday`, `день ${w.weekday} описан дважды`);
      seen.add(w.weekday);

      const okOpen  = checkString(r, `${p}.opens_at`, w?.opens_at, { pattern: RE_TIME });
      const okClose = checkString(r, `${p}.closes_at`, w?.closes_at, { pattern: RE_TIME });

      if (okOpen && okClose && w.closes_at <= w.opens_at) {
        r.err(p, `закрытие ${w.closes_at} не позже открытия ${w.opens_at}; смену через полночь задайте двумя днями`);
      }
    });
  }

  if (doc.schedule_exceptions !== undefined) {
    if (!Array.isArray(doc.schedule_exceptions)) {
      r.err('schedule_exceptions', 'ожидался массив');
    } else {
      doc.schedule_exceptions.forEach((e, i) => {
        const p = `schedule_exceptions[${i}]`;
        checkString(r, `${p}.date`, e?.date, { pattern: RE_DATE });
        if (e?.date && Number.isNaN(Date.parse(e.date))) {
          r.err(`${p}.date`, `несуществующая дата "${e.date}"`);
        }
        if (e?.is_closed === false) {
          checkString(r, `${p}.opens_at`, e?.opens_at, { pattern: RE_TIME });
          checkString(r, `${p}.closes_at`, e?.closes_at, { pattern: RE_TIME });
        }
      });
    }
  }

  // ── карточки на главной ────────────────────────────────────────────────
  if (doc.info_cards !== undefined) {
    if (!Array.isArray(doc.info_cards)) {
      r.err('info_cards', 'ожидался массив');
    } else {
      if (doc.info_cards.length !== 3) {
        r.warn('info_cards', `на главной рассчитано три карточки, описано ${doc.info_cards.length}`);
      }
      doc.info_cards.forEach((card, i) => {
        checkString(r, `info_cards[${i}].title`, card?.title, { max: 80 });
        checkString(r, `info_cards[${i}].body`, card?.body, { max: 300 });
      });
    }
  }

  // ── медиа ──────────────────────────────────────────────────────────────
  checkString(r, 'media.hero', doc.media?.hero, { required: false, max: 300 });
  checkString(r, 'media.logo', doc.media?.logo, { required: false, max: 300 });

  if (doc.gallery !== undefined) {
    if (!Array.isArray(doc.gallery)) {
      r.err('gallery', 'ожидался массив');
    } else {
      doc.gallery.forEach((g, i) => {
        checkString(r, `gallery[${i}].file`, g?.file, { max: 300 });
        checkString(r, `gallery[${i}].caption`, g?.caption, { required: false, max: 200 });
        checkString(r, `gallery[${i}].category`, g?.category, { required: false, max: 60 });
      });
    }
  }

  if (!doc.media?.hero) {
    r.warn('media.hero', 'нет главного фото — на первом экране будет пустое место');
  }

  return r;
}

/** Проверяет, что среда знает такой часовой пояс. */
function isKnownTimezone(tz) {
  try {
    new Intl.DateTimeFormat('ru-RU', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

export { Report };
