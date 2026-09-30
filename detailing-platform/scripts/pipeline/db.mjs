/**
 * Тонкая обёртка над psql. Без зависимостей: конвейер должен работать
 * в чистой среде, где npm install ещё не выполнялся.
 *
 * Подключение берётся из DATABASE_URL, а при его отсутствии — из
 * переменных локального Postgres. Секреты в код не попадают.
 */

import { spawnSync } from 'node:child_process';

export function dbTarget() {
  if (process.env.DATABASE_URL) {
    return { kind: 'url', value: process.env.DATABASE_URL };
  }
  return {
    kind: 'local',
    host: process.env.PGHOST || '/var/tmp/pgrun',
    port: process.env.PGPORT || '5433',
    user: process.env.PGUSER || 'postgres',
    db: process.env.PGDATABASE || 'detailing',
  };
}

function psqlArgs(t, extra) {
  return t.kind === 'url'
    ? [t.value, ...extra]
    : ['-h', t.host, '-p', String(t.port), '-U', t.user, '-d', t.db, ...extra];
}

/** Выполняет SQL и возвращает stdout. Бросает при ошибке. */
export function runSql(sql, { quiet = true } = {}) {
  const t = dbTarget();
  const args = psqlArgs(t, [
    '-v', 'ON_ERROR_STOP=1',
    ...(quiet ? ['-qtA'] : []),
    '-f', '-',
  ]);

  const res = spawnSync('psql', args, {
    input: sql,
    encoding: 'utf8',
    env: { ...process.env, PATH: `/usr/lib/postgresql/16/bin:${process.env.PATH}` },
  });

  if (res.error) {
    throw new Error(`psql не запустился: ${res.error.message}`);
  }
  if (res.status !== 0) {
    throw new Error(`psql завершился с кодом ${res.status}:\n${res.stderr || res.stdout}`);
  }
  return res.stdout;
}

/** Одно скалярное значение. */
export function scalar(sql) {
  return runSql(sql).trim();
}

/** Экранирует строку как SQL-литерал. */
export function lit(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`не число: ${value}`);
    return String(value);
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return `'${String(value).replace(/'/g, "''")}'`;
}

/** Экранирует объект как jsonb-литерал. */
export function jsonLit(value) {
  return `${lit(JSON.stringify(value ?? {}))}::jsonb`;
}
