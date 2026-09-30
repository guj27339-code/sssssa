# Платформа записи для детейлинг-студий

Один общий билд, один проект Supabase, разделение по `tenant_id`.
Каждая студия — на своих маршрутах `/s/{slug}/` и `/s/{slug}/owner/`.

## Быстрый старт

```bash
cp .env.example .env          # заполнить ключи
npm run db:reset              # накатить миграции
npm run db:test               # 39 проверок
npm run db:test:concurrency   # гонка за слот
```

## Новая студия за несколько минут

```bash
npm run tenant:new -- myslug --name "Название студии"
# заполнить tenants/myslug/business.json, положить фото в tenants/myslug/photos/
npm run tenant:validate -- myslug
npm run tenant:publish -- myslug        # в режиме preview
npm run tenant:verify -- myslug
npm run tenant:publish -- myslug --live # после проверки настроек
```

Переиздание конфига не трогает уже созданные записи и фотографии,
загруженные владельцем. Удалённая из конфига услуга выключается,
а не удаляется: на неё могут ссылаться брони.

## Документы

- `AGENTS.md` — правила работы над репозиторием
- `docs/plan.md` — восемь этапов и их состояние
- `docs/verification.md` — **что проверено прогоном, а что только написано**

## Состояние

Слой базы данных и конвейер студий работают и проверены на живом Postgres.
Серверные функции написаны, но не исполнялись. Фронтенд не начат.
Причины и подробности — в `docs/verification.md`.
