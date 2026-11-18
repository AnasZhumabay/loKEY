# loKEY — интеграция бэкенда (для разработчика, который не видел приложение)

Контракт: **1.3.0** (только добавления к 1.0.0). Этот документ — практическое руководство. Формальные источники правды: `loKEY/Contract/{APIModels,Services,ContractV13}.swift`, `Docs/BACKEND_CONTRACT.md`, `Docs/CHAT.md`, `Docs/_shared_case_format.md`, `Docs/_backup_format.md`. Эталонные JSON: `loKEYTests/Fixtures/*.json`.

Что такое loKEY: iOS-хранилище секретных файлов + E2E-чат. Всё шифруется на телефоне; сервер — «тупое» хранилище шифртекста и «почтовое отделение» для чата. Ключей, имён файлов, текста сообщений у сервера нет и быть не должно.

Метки в документе: **факт** = проверено по коду; «предложение» = путь/правило не зафиксирован в коде, придумано для удобства (согласовать с фронтендом); «не проверено» = в коде не нашёл.

---

## 1. Быстрый старт

### 1.1 Переключение Mock → Live
1. `loKEY/App/AppStore.swift`, `enum AppConfig`: `static let useMocks = true` → `false`.
2. Там же: `static let apiBaseURL = URL(string: "https://api.lokey.example")!` — подставить свой адрес (только HTTPS; ATS-исключений в проекте нет; пиннинга сертификата в клиенте нет — **не проверено/не реализовано**).
3. Сборка выбирается в одном месте — `AppEnvironment.makeServices()` (`loKEY/App/LoKEYApp.swift`, стр. 46): `useMocks ? MockBackend.makeServices() : LiveBackend.makeServices(baseURL:)`.
4. `LiveBackend.makeServices(baseURL:)` (`loKEY/Core/Backend/LiveBackend.swift`, стр. 6) создаёт один `LiveHTTP` (actor: токены, refresh, заголовки) и 11 клиентов: `LiveAuthAPI, LiveAccountAPI, LiveCasesAPI, LiveFilesAPI, LiveAuditAPI, LiveBillingAPI, LiveChatAPI` (1.0–1.2, **уже написаны** по таблице путей контракта) и `LiveSharedCaseAPI, LiveBackupAPI, LiveChatGroupAPI, LiveSecurityEventAPI` (1.3.0, **заглушки** в `Core/Backend/LiveBackendV13.swift`: каждый метод бросает `.server("not_implemented")`, над ним комментарий `// TODO(backend): <метод путь → ответ>`).
5. В режиме Live также меняется: iCloud-бэкап (`ICloudDriveBackupStore` вместо локальной папки), общий кейс использует настоящий X25519 с контактом, персистентность включена (`persist = !useMocks`), обход Face ID выключен.

**Что реализовать на сервере (рекомендуемый порядок):**
1. Auth (register/login/refresh/logout) + единый конверт ошибок.
2. Account (me, storage), cases, files + blob (с SHA-256 и квотой), trash.
3. Audit, sessions, versions.
4. Chat 1.2.0 (identity, send/fetch/ack) + push.
5. Billing (может остаться заглушкой; StoreKit на клиенте не подключён).
6. 1.3.0: security-events (самое простое), backup, shared case, groups (группы в UI не подключены).
Пока метод 1.3.0 не готов — отвечайте `501` с телом `{"code":"not_implemented","message":"…"}`. **Важно (факт):** `LiveHTTP.raw` разбирает конверт и делает `APIError.from(env)`; неизвестный `code` → `.server(env.message)`. Чтобы сработало сравнение `e == .server("not_implemented")` в `SharedCaseServiceImpl.mapped`, **поле `message` должно быть ровно `"not_implemented"`**. Голый 501 без тела даст `.server("")` и UI покажет общую ошибку.

Если вам нужно поправить путь/заголовок, правится только `LiveBackend*.swift`, UI не трогается.

### 1.2 Авторизация, токены, refresh (факт, `LiveHTTP`)
- Заголовок `Authorization: Bearer <access_token>` на всех запросах, кроме `/v1/auth/{register,login,mfa/verify,refresh,password-reset}`.
- `SessionDTO{access_token, refresh_token, expires_at, account}` хранится в Keychain (сервис `com.lokey.tokens`, ключ `session`).
- `401` на запрос с авторизацией (кроме тела с `code=mfa_invalid`) → клиент **один раз** вызывает `POST /v1/auth/refresh {"refresh_token":"…"}` → `SessionDTO` → повторяет исходный запрос. Параллельные refresh склеиваются в один.
- Сессия стирается **только** если refresh вернул 401/403/`mfa_invalid`; сеть/5xx разлогинить не должны. Поэтому refresh при невалидном токене обязан отвечать именно 401, а при сбоях — 5xx.
- Рекомендация (предложение): ротация refresh-токена при каждом refresh, обнаружение повторного использования старого → отзыв всей цепочки. Access ~1 ч (мок — 3600 с), refresh — дольше.
- `restoreSession`: если `expires_at` в будущем — используется без сети; иначе refresh.
- Вход: `POST /v1/auth/login {"identifier","password"}` → `{"session":…}` ИЛИ `{"mfa_challenge_id":"ch-1"}`; затем `POST /v1/auth/mfa/verify {"challenge_id","code"}` → `SessionDTO`. Мок-код MFA — `123456`.
- Устройство (`device_name`, `platform`) клиент при входе **не передаёт** (факт: `LoginRequest` — только `identifier`, `password`). Для `SessionInfoDTO.deviceName/platform` нужно либо взять из `User-Agent`, либо согласовать добавочные поля (открытый вопрос из HANDOFF).

### 1.3 Модель ошибок (факт, `APIErrorEnvelope`, `APIError.from`)
Любой 4xx/5xx — JSON `{"code","message","retry_after_seconds"?,"limit_bytes"?}`.

| HTTP | `code` | `APIError` | Заметки |
|---|---|---|---|
| 400 | `validation` | `.validation(message)` | `message` по-русски, показывается пользователю |
| 401 | `unauthorized` | `.unauthorized` | запускает refresh |
| 401 | `mfa_invalid` | `.mfaInvalid` | refresh НЕ делается |
| 403 | `forbidden` | `.forbidden` | |
| 404 | `not_found` | `.notFound` | |
| 409 | `conflict` | `.conflict` | `If-Match` ≠ revision |
| 413 | `quota_exceeded` | `.quotaExceeded(limit_bytes)` | **`limit_bytes` обязателен**, иначе клиент увидит 0 |
| 422 | `integrity_failed` | `.integrityFailed` | sha256/размер |
| 429 | `rate_limited` | `.rateLimited(retry_after_seconds)` | без поля — 60 с; без конверта — заголовок `Retry-After` |
| 5xx / иное | любой | `.server(message)` | `not_implemented` для 1.3.0 |

Если тела-конверта нет, клиент маппит по статусу (401/403/404/409/413/422/429/400), остальное → `.server("")`. Сетевые сбои/таймаут (30 с) → `.network` (клиентская).

### 1.4 Идемпотентность
- id (кейс, файл, конверт чата, бэкап, группа) генерирует клиент (UUID v4, строчные). Повторный `POST` с тем же id возвращает существующую запись (кейсы/файлы/группы), `send` чата — игнорируется (дедуп по `(sender_id, id)`).
- Клиент **повторяет** отправку конверта чата с тем же `id` после сбоя (факт: `pending[id] = env`) — дубликаты должны быть безвредны.
- `DELETE`/`purge`/`ack` — повтор безопасен (404 на повторный DELETE клиент обрабатывает как ошибку; рекомендуется отвечать 204, предложение).

### 1.5 Пагинации нет (факт)
Все списки — «голые» массивы без курсора. Исключения-параметры: `GET /v1/audit?limit=N`, `GET /v1/chat/messages?limit=N` (клиент просит 100, старые первыми). Если сделаете пагинацию — только как добавочные необязательные параметры; без параметров ответ должен остаться полным списком.

### 1.6 Revision / 409
- `revision`: создание = 1, +1 на каждое изменение (включая trash/restore/replaceContent/restoreVersion). Значение в теле создания игнорируется.
- `PUT /v1/cases/{id}` и `PUT /v1/files/{id}` требуют `If-Match: <число>`; не совпало → `409 conflict`. Меняются только `sealed_header`/`recovery_wrapped_key` (кейс) и `sealed_metadata` (файл); остальные поля сервер игнорирует.
- Формат JSON: snake_case, даты `2025-01-15T10:30:00Z` (без долей секунды!), `Data` — base64 со стандартным алфавитом и padding, enum — как в Swift (`caseUnlocked`, `authenticator`). `null`-поля можно опускать; исключение: `PATCH /v1/account {"backup_email": null}` — ключ присутствует.

---

## 2. Функция приложения → что делает бэкенд

Условные обозначения: **С** — обязанность сервера, **К** — клиента. «Не видит» — то, что сервер никогда не должен получать/логировать.

### 2.1 Существующие функции (1.0–1.2)

| Функция | Протокол / файл шва | Live (заменять не надо, готово) | Эндпоинты | Кто что проверяет / лимиты |
|---|---|---|---|---|
| **Auth** | `AuthAPI` в `Contract/Services.swift` | `LiveBackend.swift` стр. 155 `LiveAuthAPI` | `POST /v1/auth/register` (`{email,username,password}`→`SessionDTO`); `/login`; `/mfa/verify`; `/refresh`; `/logout` (Bearer, 204); `/password-reset` (`{email}`, всегда 204) | С: хэш пароля (argon2/bcrypt), уникальность email/username (400 `validation`), rate-limit входа (429), анти-перебор. К: сила пароля. Не видит: ключи кейсов (пароль сервер получает — это пароль аккаунта, не ключ хранилища). Пароль-reset не раскрывает наличие аккаунта. |
| **MFA** | `AccountAPI.setMFA` | `LiveAccountAPI` стр. 194 | `PUT /v1/account/mfa {"enabled":true,"method":"authenticator"\|"sms"}` → `MFASetupDTO{method,otpauth_uri?}`; при выключении 204/пустое тело | С: TOTP (otpauth URI), хранить секрет; `mfa_invalid` при неверном коде; SMS-подтверждение — не согласовано (HANDOFF). |
| **Account** | `AccountAPI` | там же | `GET /v1/account`→`AccountDTO{id,email,username,backup_email?,mfa_enabled,created_at}`; `PATCH /v1/account`; `GET /v1/account/storage`→`StorageUsageDTO{used_bytes,limit_bytes,per_case[{case_id,bytes}]}` | С: корзина и версии входят в `used_bytes`; `limit_bytes` = 1 ГБ (1 073 741 824) по умолчанию, выше по подписке. |
| **Кейсы** | `CasesAPI` | `LiveCasesAPI` стр. 210 | `GET/POST /v1/cases`; `PUT /v1/cases/{id}` (+`If-Match`); `DELETE /v1/cases/{id}` | С: идемпотентность по id, revision, `file_count`/`storage_bytes` пересчитывает сам, каскад при DELETE. Не видит: `sealed_header` (AES-GCM ключом хранилища), `recovery_wrapped_key` (PBKDF2+GCM фразой). К: все ключи, 12 слов, 20-байтный секрет. |
| **Файлы + blob** | `FilesAPI` | `LiveFilesAPI` стр. 220 | `GET /v1/cases/{caseId}/files`; `GET /v1/trash/files`; `POST /v1/files`; `PUT /v1/files/{id}` (+`If-Match`); `PUT /v1/files/{id}/blob` (octet-stream + `X-Content-SHA256`); `GET /v1/files/{id}/blob` | С: при PUT blob сверить SHA-256(тела)==`X-Content-SHA256`==`ciphertext_sha256` записи и длину==`ciphertext_size`, иначе 422; квота при `POST /v1/files` (413 + `limit_bytes`); чистить записи без blob старше суток. Макс. размер blob в контракте **не задан** (не проверено; клиент грузит данные целиком в память — разумный лимит выбрать с фронтендом). Не видит: имя, тип, заметку, OCR-текст (всё внутри `sealed_metadata`/blob). |
| **Версии** | `FilesAPI` (1.1.0) | `LiveFilesAPI` | `GET /v1/files/{id}/versions`; `POST /v1/files/{id}/versions` (`ReplaceFileRequest{sealed_metadata,ciphertext_size,ciphertext_sha256,expected_revision}`→`FileRecordDTO`, затем клиент `PUT …/blob`); `GET /v1/file-versions/{id}/blob`; `POST /v1/files/{id}/versions/{vid}/restore` | С: атомарно старое состояние→версия, revision+1; 409 при `expected_revision`; версии считаются в `used_bytes`. |
| **Корзина** | `FilesAPI` | то же | `POST /v1/files/{id}/trash` (204); `POST /v1/files/{id}/restore`→`FileRecordDTO`; `DELETE /v1/files/{id}` | С: `deleted_at`, через **30 дней** удалить запись+blob+версии; в `GET /cases/{id}/files` удалённые не отдавать. |
| **Сеансы** | `AccountAPI` (1.1.0) | `LiveAccountAPI` | `GET /v1/account/sessions`→`[SessionInfoDTO{id,device_name,platform,app_version?,approx_location?,created_at,last_active_at,is_current}]`; `DELETE /v1/account/sessions/{id}`; `POST …/revoke-others` | С: отзыв = инвалидировать refresh+access сеанса. |
| **Биллинг** | `BillingAPI` (1.1.0) | `LiveBillingAPI` стр. 248 | `GET /v1/billing/plans`; `GET /v1/billing/subscription`; `POST /v1/billing/purchase {plan_id, apple_transaction?}`; `POST /v1/billing/cancel` | С: проверка подписанной транзакции StoreKit 2 (JWS) у Apple, подъём `limit_bytes`. К: StoreKit не подключён, `PlansView.buy` шлёт `apple_transaction = nil` (`TODO(StoreKit)`) — Live-сервер должен отклонять `nil` вне тестового режима. |
| **Журнал (audit)** | `AuditAPI` | `LiveAuditAPI` стр. 256 | `GET /v1/audit?limit=N` (новые первыми, `AuditEventDTO{id,kind,case_id?,device_name,ip_hint?,at}`); `POST /v1/audit {"kind","case_id"?}`→204 | С сам пишет: `login, logout, loginFailed, fileAdded, fileTrashed, fileRestored, mfaChanged`. К присылает: `caseCreated, caseDeleted, caseUnlocked, caseLocked, unlockFailed, keyRecovered`. Неизвестные `kind` клиент пропускает. Хранить `case_id` допустимо (это UUID), имён нет. |
| **Чат 1.2.0** | `ChatAPI` | `LiveChatAPI` стр. 270 | см. раздел 3 | см. раздел 3 |

### 2.2 Функции сессии (1.3.0 и клиентские)

Колонка «нужен бэкенд»: **Да** / **Нет** (чисто клиентская).

| Функция | Нужен бэкенд | Шов (Swift + файл) | Live-заглушка | Что ожидается |
|---|---|---|---|---|
| **Общий кейс на двоих** | Да | `SharedCaseAPI` — `Contract/ContractV13.swift`; клиент: `SharedCaseService` (`Domain/SharedCase.swift`) → `Core/Shared/SharedCaseServiceImpl.swift` | `Core/Backend/LiveBackendV13.swift` стр. 7–21 | раздел 4.1 |
| **Резервная копия на сервер** | Да (для назначения «сервер») | `BackupAPI` — `ContractV13.swift`; клиент: `BackupServiceImpl` | `LiveBackendV13.swift` стр. 23–33 | раздел 4.2. Назначения «iCloud» и «файл» бэкенд не используют |
| **SecurityEventAPI** | Да (необязательно для работы приложения) | `SecurityEventAPI` — `ContractV13.swift` | `LiveBackendV13.swift` стр. 49–52 | раздел 4.3. Клиент отправляет «выстрелил и забыл» (`try?`) — отказ сервера ничего не ломает |
| **Группы чата** | Да, но в UI **не подключено** | `ChatGroupAPI` — `ContractV13.swift`; клиент: `ChatGroupRepository` (`Domain/Chat.swift` стр. ~205), сейчас `ChatGroupRepositoryStub` бросает `notImplemented` | `LiveBackendV13.swift` стр. 35–47 | раздел 3.5. Можно реализовать позже |
| **Исчезающие сообщения** | Нет | `ChatPayload.ttl`/`k="ttl"` (`Core/Chat/ChatPayload.swift`), `ChatDisappearPreset` (`Domain/Chat.swift`) | — | Всё внутри шифртекста. Сервер может лишь применять общий максимум TTL 30 дней. Ничего не ожидается |
| **Отправка файла из кейса / «не пересылать»** | Нет | `ChatSendOptions.noForward`, `ChatPayload.nf` | — | Флаг внутри шифртекста; вежливая метка, не защита. Размер вложения влияет на лимит конверта (раздел 3.1) |
| **Сверка QR кода безопасности** | Нет | `ChatVerifyCodec` (`Core/Chat/ChatPayload.swift`), `Features/Chat/SafetyNumberView.swift` | — | Ничего (QR `lokey://verify?a=&b=&h=` не касается сервера). Единственная зависимость: `findUser`/`identity_key` должны быть правдивы |
| **CryptoEngine (замена E2EE)** | Нет | `CryptoEngine` — `Core/Seams/CryptoEngine.swift`; `BuiltinCryptoEngine` | — | Меняется только тело `ciphertext`; `version` конверта поднять (раздел 3.6) |
| **Персистентность (сессия, кэш кейсов, история чата)** | Нет | `SessionPersistence`, `CasesCache`, `HistoryStore` — `Core/Seams/HistoryStore.swift` | — | Локально, AES-GCM, ключ 32 байта; сервер ничего не хранит. Кэш кейсов = копия `GET /v1/cases` (офлайн-старт) |
| **Biometric ACL в Keychain** | Нет | `KeyStoreAccessPolicy`, `KeychainKeyStore` — `Core/Crypto/KeyStore.swift` | — | Ничего |
| **Duress (ложное хранилище)** | Нет | `VaultRepository.setDuressPIN/unlockAppWithDuress` — `Core/Repository/VaultRepositoryImpl.swift`, приманка `Core/Security/DecoyVault.swift` | — | Сервер ничего не знает о PIN. **Единственный след:** событие `duressUnlock` через `SecurityEventAPI` (если сервер его принимает). В режиме приманки данные не берутся с сервера |
| **Аварийное стирание после N попыток** | Нет (+событие) | `WipePolicy{enabled,maxAttempts 3…10}`, `AttemptTracker` — `Core/Security/AttemptTracker.swift`; `wipeLocal` в `VaultRepositoryImpl` | — | Стирает **локальный** секрет кейса; запись кейса и blob'ы на сервере остаются (кейс можно открыть 12 словами). Отправляет `caseWiped` (`tooManyAttempts` в коде репозитория не найден — **не проверено**, где используется) |
| **Напоминания о сроках документов** | Нет | `ReminderService` — `Domain/Reminders.swift`; `ReminderServiceImpl` (локальные `UNUserNotificationCenter`), срок берётся из OCR/заметок локально | — | Ничего; push-сервер не нужен. Текст уведомления формируется локально (`ReminderPlanner.title`; что в `body` — не проверено) |
| **Поиск (глобальный)** | Нет | `Features/Search/GlobalSearchView.swift` | — | Ищет по расшифрованным в памяти данным открытых кейсов; запросов на сервер нет |
| **Главный экран / редизайн, редактор, PDF** | Нет | `Features/Home`, `Features/Editor` | — | — |

---

## 3. Чат

Подробности клиента и криптографии: `Docs/CHAT.md`.

### 3.1 Конверт и правила
`ChatEnvelopeDTO` JSON: `{"id":"uuid","sender_id":"…","recipient_id":"…","version":1,"ciphertext":"<base64>","sent_at":"2025-01-15T10:30:00Z","expires_at":"2025-02-14T10:30:00Z"}`.
- `ciphertext` = `[счётчик UInt32 BE][AES-GCM combined]`; сервер его не разбирает.
- Правила (контракт): `sender_id` == пользователь токена, иначе 403; неизвестный получатель — 404; дедуп по `(sender_id, id)`; `public_key` при регистрации ровно 32 байта, иначе 400; `PUT /v1/chat/identity` не должен молча менять уже зарегистрированный ключ (иначе подмена личности); `ack` чужих id игнорируется; `fetch` не удаляет до `ack`, старые первыми.
- `PUT /v1/chat/identity` тело `{"public_key":"<base64 32 байта>"}` → `ChatUserDTO{id,username,identity_key}`. `GET /v1/chat/users/{id}` → то же, 404 если нет.
- Размер: рекомендация CHAT.md — ~7 МБ на конверт (вложение до 5 МБ + base64/накладные); в контракте жёсткого лимита нет — выбрать и вернуть 413/400 (предложение).
- Rate limit на `send` (предложение: десятки/мин на отправителя); 429 с `retry_after_seconds`.

### 3.2 TTL и очередь
Клиент ставит `expires_at = sent_at + 30 дней` (факт). Сервер вправе удалить конверт после `expires_at`; доставленный, но неподтверждённый — тоже через 30 дней. После `ack` — удалить сразу.

### 3.3 Push (политика)
**Факт: в контракте и клиенте НЕТ эндпоинта регистрации push-токена, в приложении нет `registerForRemoteNotifications`/`aps-environment` (не проверено на устройстве).** Клиент сейчас получает сообщения опросом `fetch`. Если делаете push: предложение — `PUT /v1/account/push-token {apns_token}` (нужно согласовать, это изменение контракта MINOR); тело push **без текста и без имени отправителя** («Новое сообщение», `content-available`); сервер не кладёт в push ничего из конверта.

### 3.4 Исчезающие сообщения и «не пересылать» (всё внутри шифртекста)
- Таймер чата и таймер сообщения передаются как `ChatPayload.ttl` (секунды, пресеты 30 с / 5 мин / 1 ч / 1 день / 1 неделя, максимум клиента 31 день); смена таймера чата — служебное сообщение `k="ttl"`. У получателя отсчёт стартует при первом показе.
- Сервер **не должен** на это полагаться и не может это видеть. Он вправе (MAY) применять свой максимум TTL очереди (30 дней). Исчезновение — вежливая клиентская функция: модифицированный клиент или скриншот его обходят.
- Флаг `nf` (no-forward) — тоже внутри шифртекста, приёмник скрывает «Переслать»/«Сохранить в галерею». Сервер его не видит и не может влиять.
- Серверу не передаются имена вложений (`an`) и сами вложения (`ad`) — они в шифртексте.

### 3.5 Группы (шов, UI пока нет)
`ChatGroupAPI`, fan-out на сервере:
- `POST /v1/chat/groups` body `GroupDTO{id,name_ciphertext,member_ids[],created_at}` → `GroupDTO`, идемпотентно по `id`.
- `GET /v1/chat/groups` → `[GroupDTO]` (только где пользователь член).
- `POST /v1/chat/groups/{id}/members {"user_id"}` / `DELETE …/members/{user_id}` → `GroupDTO`.
- `POST /v1/chat/groups/{id}/messages` body `GroupEnvelopeDTO{id,group_id,sender_id,sent_at,ciphertext,recipient_ids[]}` → 204: сервер кладёт **копию** каждому из `recipient_ids` в обычную очередь получателя (`fetch`). Проверки сервера (предложение): `sender_id` == токен и состоит в группе; `recipient_ids` ⊆ `member_ids` группы; отправителю копию не класть.
- Встроенный `BuiltinCryptoEngine.supportsGroups == false`: парные сессии, группового протокола нет. Для реальных групп нужен MLS/Sender Keys через `CryptoEngine`. Состояние: «не проверено ни на каком сервере».
- Права: добавлять/удалять участников может создатель (предложение; в контракте явно не сказано).

### 3.6 Замена `ChatCrypto` на libsignal/MLS без правок UI (шаги)
1. Создать `struct SignalCryptoEngine: CryptoEngine` в `loKEY/Core/Seams/` (протокол: `name`, `supportsGroups`, `generateIdentity`, `establishSession`, `seal`, `open`, `safetyNumber`). Состояние сессии — непрозрачные `Data` (движок сам сериализует).
2. Для X3DH/PreKeys понадобится публикация prekey-бандлов — **в контракте 1.3.0 этого нет**; это будет новая MINOR-версия (напр. `PUT/GET /v1/chat/prekeys`, предложение). С текущим `registerIdentity(publicKey)` (один 32-байтный ключ) достаточно только для схемы без prekeys.
3. Подставить движок там, где `ChatRepositoryImpl` получает `engine` (по умолчанию `BuiltinCryptoEngine()`; точка сборки — `AppEnvironment.makeAll`, `LoKEYApp.swift`).
4. Поднять `ChatEnvelopeDTO.version` (сейчас `ChatCrypto.version = 1`), чтобы старые сессии мигрировали; `name` движка попадает в метаданные сессии.
5. Прогнать `ChatCryptoTests`/`ChatFeaturesTests`, добавить тесты движка (круг, вне порядка, повтор, подмена).
6. Критически: независимый криптоаудит.
Серверу в 1–5 ничего не нужно, кроме принятия большего `ciphertext` и нового `version`.

---

## 4. Общий кейс, резервная копия, события безопасности

### 4.1 Общий кейс (Contract 1.3.0)
Формат обёртки ключа: `Docs/_shared_case_format.md` (blob = `0x01 ‖ AES-GCM.combined`, ключ обёртки = HKDF(X25519(личности), salt=SHA256(caseId), info="lokey.sharedcase.wrap.v1"), AAD = `"caseId|inviterId|inviteeId"`). Сервер видит только blob и ничего расшифровать не может.

| Метод | HTTP | Тело → ответ | Проверки сервера |
|---|---|---|---|
| `invite` | `POST /v1/cases/{caseId}/invites` | `{"invitee_user_id","wrapped_key_for_invitee":"<base64>","role":"editor"\|"viewer"}` → 204 | 403 если вызывающий не владелец кейса; 404 если получателя нет; клиент выдаёт только `editor`/`viewer` (`SharedRolePolicy.assignable`), `owner` не присваивается — отклонять 400; не приглашать себя; повторное приглашение — идемпотентно (предложение) |
| `listMembers` | `GET /v1/cases/{caseId}/members` | → `[CaseMemberDTO{user_id,display_name,role,status,joined_at?}]` | доступно владельцу и участникам |
| `accept` | `POST /v1/invites/{id}/accept` | → `CaseMemberDTO` | 403/404 если приглашение не этого пользователя |
| `revoke` | `DELETE /v1/cases/{caseId}/members/{user_id}` | → 204 | **только владелец** отзывает других; участник может удалить **сам себя** («выйти»); владельца удалить нельзя (предложение) |
| `fetchWrappedKey` | `GET /v1/cases/{caseId}/wrapped-key` | → `{"wrapped_key":"<base64>"}`; **404 = нет доступа или ещё не принято** | отдавать только вызывающему его собственную копию, и только после `accept` |
| `listInvites` | `GET /v1/invites` | → `[CaseInviteDTO{id,case_id,case_name_ciphertext?,from_user_id,created_at}]` | только входящие и ещё не принятые; отказа (`decline`) в контракте нет — клиент скрывает приглашение локально |

Идемпотентность: повторный `accept` уже принятого — вернуть текущего члена; повторный `revoke` — 204 (предложение).

**Пробел в контракте (важно, факт по коду `SharedCaseServiceImpl.accept`):** после `accept` клиент зовёт `repo.unlockCase(id, keyString)`, т.е. ожидает, что приглашённый может прочитать **запись кейса** (`GET /v1/cases`) и его **файлы и blob'ы** (`GET /v1/cases/{id}/files`, `GET /v1/files/{id}/blob`). Контракт 1.3.0 это не описывает; код комментирует: «запись кейса ещё не доступна этому устройству (нужен бэкенд)» и откладывает секрет в Keychain. Серверу нужно (предложение, согласовать): для активного участника отдавать кейс в `GET /v1/cases` и файлы кейса; запись/загрузку — только роли `owner`/`editor` (клиент соблюдает `viewer` как «только чтение», криптографически это не обеспечено — сервер **должен** запрещать запись viewer'у: 403). Расшифровать `sealed_header` приглашённый не сможет (он запечатан ключом хранилища владельца) — имя кейса приходит в `case_name_ciphertext` (шифр ключом кейса). Не проверено ни на каком сервере.

Ограничения, которые сервер должен знать: после отзыва доступа ключ кейса у бывшего участника остаётся; смена ключа (`rotateKeyAfterRevoke`) не реализована (бросает `notImplemented`) и потребует атомарной смены версии ключа и перезаписи blob'ов на сервере — отдельное расширение контракта.

### 4.2 Резервная копия
Формат файла `.lokeybackup` v1: `Docs/_backup_format.md` (заголовок 27 байт `LKBK`, PBKDF2-HMAC-SHA256 ≥ 600 000 раундов, записи AES-GCM). Сервер хранит **один непрозрачный файл**.
- `GET /v1/backups` → `[BackupInfoDTO{id,created_at,size_bytes,sha256,device_name,app_version,format_version}]`.
- `PUT /v1/backups/{id}`: `Content-Type: application/octet-stream`, заголовки `X-LK-Info` (JSON `BackupInfoDTO`, snake_case, `created_at` как `…Z`) и `X-LK-SHA256` (hex). Сервер: SHA-256(тела) == `X-LK-SHA256` == `info.sha256`, длина == `info.size_bytes`, иначе 422 `integrity_failed`; `id` из пути == `info.id`; идемпотентно по id; квота (предложение: считать в общий лимит или отдельный, 413 + `limit_bytes`).
- `GET /v1/backups/{id}/blob`, `DELETE /v1/backups/{id}` → 204. Доступ только владельцу (404 для чужого).
- Не парсить, не пытаться «проверять» содержимое. Клиент максимальную запись ограничивает 512 МБ (`BackupArchive.maxRecord`); размер всего архива лимитом контракта не задан.
- Что не попадает в архив: ключи кейсов; закрытые (locked) кейсы пропускаются (ограничение, в списке «не сделано»). Восстановление создаёт НОВЫЕ кейсы (новые id и ключи) — сервер видит это как обычные `POST /v1/cases`/`/v1/files`.
- Хранение/ретеншен (предложение): ограничить число копий на пользователя (напр. 5–10), старые вытеснять.
- Назначения iCloud и «файл» работают без бэкенда.

### 4.3 События безопасности
`POST /v1/security-events` body `SecurityEventDTO{kind,case_id?,at,device_name?}` → 204. `kind`: `caseWiped | duressUnlock | tooManyAttempts | backupCreated | backupRestored`.
- Факт: отправляются `caseWiped` (стирание локального ключа после N попыток), `duressUnlock` (вход по PIN принуждения), `backupCreated`, `backupRestored`. `tooManyAttempts` в Swift-коде как отправляемое событие **не найден** — не проверено.
- **Осторожно с `duressUnlock`:** это сигнал «пользователя, возможно, принуждают». Не показывать его в обычном журнале/письмах в ту же секунду так, чтобы принуждающий увидел; хранить и использовать осознанно (предложение: только во внутренней/доверенной цепочке уведомлений).
- Валидация: `kind` из списка (неизвестный → 400), `case_id` — если задан, должен принадлежать пользователю (иначе игнорировать/403), `at` не из далёкого будущего. Только запись, ответа с данными нет. Идемпотентность: дубликаты допустимы (клиент не повторяет).
- Rate limit (предложение): не давать превратить в канал утечки/спам, но и не блокировать события дольше нескольких секунд.

---

## 5. Безопасность

### 5.1 Модель угроз (кратко)
1. Злоумышленник на сервере/БД (утечка, инсайдер): видит только шифртекст, id, размеры, время, граф общения.
2. Сетевой злоумышленник: TLS; клиент не пиннит сертификат (риск MITM при установленном вредоносном корне).
3. Потерянный/украденный телефон: Face ID/PIN, ключи в Keychain (`WhenUnlockedThisDeviceOnly`, ACL биометрии для секретов кейсов), стирание после N попыток.
4. Принуждение: ложное хранилище (duress), «закрыть все», встряска.
5. Подмена ключа собеседника (MITM в чате): очная передача QR и сверка кода безопасности.
6. Компрометация долговременного ключа личности: будущие сообщения под угрозой (нет DH-ratchet).
7. Вредоносный/модифицированный клиент собеседника: обходит «не пересылать» и «исчезающие».
8. Потеря 12 слов/секрета кейса: восстановить нельзя (сервер ключей не знает).
9. Подбор паролей аккаунта и токенов: rate-limit, MFA.
10. Метаданные: сервер видит кто/кому/когда/сколько.

### 5.2 Сервер ОБЯЗАН
TLS 1.2+/HSTS; хэш паролей (argon2id/bcrypt); rate limit на login/mfa/password-reset/chat send/ blob upload (429 + `retry_after_seconds`); сравнение токенов/MAC/хэшей — в постоянное время; изоляция аккаунтов (проверка владения на **каждом** id в пути); строгая валидация размеров и sha256; квоты; корзина 30 дней; журналирование только событий без содержимого; шифрование диска и бэкапов самого сервера; отзыв сеансов; удалять доставленные и подтверждённые конверты.

### 5.3 Сервер НЕ ДОЛЖЕН
Расшифровывать/разбирать/логировать содержимое `sealed_*`, blob'ов, `ciphertext`, `recovery_wrapped_key`, `wrapped_key`, `name_ciphertext`, бэкапов; принимать ключи/фразы; генерировать id; молча «чинить» хэш; менять формат JSON/enum; логировать заголовки `Authorization`, `X-LK-Info` целиком в открытые логи; писать в push текст; менять зарегистрированный `identity_key` без явного процесса.
Логировать ограниченно: id, размер, время, код ответа — **не** длину отдельных сообщений вместе с адресатами дольше, чем нужно для работы очереди.

### 5.4 Пиннинг и сертификаты
В клиенте TLS-пиннинга **нет**. Если нужен: pin публичного ключа листа/промежуточного в `URLSessionDelegate` внутри `LiveHTTP` (единственная сессия `urlSession`) — запланировать вместе с ротацией сертификатов.

### 5.5 Честные ограничения
- Метаданные (кто с кем, когда, размеры, IP, число файлов в кейсе, `file_count`, `storage_bytes`) видны серверу.
- Нет двойного храповика (Double Ratchet): утечка долговременного ключа компрометирует будущие сообщения.
- Скриншоты ОС заблокировать нельзя (запись экрана приложение закрывает, скриншот — нет); «не пересылать» и исчезающие сообщения — вежливые, не защита.
- Duress: ложное хранилище правдоподобно, но не «неотличимо» для эксперта (содержимое фиксировано демонстрационное, живёт в памяти; сервер не вызывается; единственный след — событие `duressUnlock`, если сервер его принимает; Face ID/обычный вход остаются, у принуждающего может быть доступ к устройству).
- Wipe: стирает локальный ключ кейса, но не данные на сервере и не копии в бэкапе/iCloud; не защищает от копирования шифртекста заранее; фраза восстановления из 12 слов открывает кейс снова.
- Отзыв общего кейса не «забирает» уже виденное.
- Биометрический ACL Keychain и iCloud — не проверены на устройстве (раздел 7).

---

## 6. Чек-лист приёмки

Тесты (факт): **133 юнит-теста** в `loKEYTests` — `ContractTests` (25, формат DTO по фикстурам), `RepositoryTests` (17), `SecurityTests` (17), `CryptoTests` (13), `EditorTests` (12), `ChatFeaturesTests` (11), `RemindersTests` (9), `SeamsTests` (9), `BackupTests` (8), `ChatCryptoTests` (6), `SharedCaseTests` (6). UI: `loKEYUITests` — `ChatUITests` (**сейчас падает на стр. 18**, см. раздел 7), `CaseSectionsUITests`, `WalkthroughUITests`, `LocalizationUITests`, `LanguageSwitchUITests`. Юнит-тесты идут на моках — против живого API их надо повторять вручную/curl. Запуск: `xcodebuild … -only-testing:loKEYTests test`.

Как проверять в Live: `useMocks=false`, свой `apiBaseURL`, сборка на устройство/симулятор, зарегистрироваться (email + пароль ≥ 6 символов), смотреть вкладки.

### Чек-листы по функциям
**Auth/MFA/сеансы**
- [ ] register → `SessionDTO` (даты `…Z`, `account` полный); дубликат email → 400 `validation`
- [ ] login с неверным паролем → 401; серия попыток → 429 + `retry_after_seconds`
- [ ] login при включённой MFA → `mfa_challenge_id`; неверный код → 401 `mfa_invalid` (клиент не делает refresh)
- [ ] протухший access → 401 → refresh → запрос повторён; refresh 5xx не разлогинивает
- [ ] logout требует Bearer; `password-reset` всегда 204
- [ ] экран устройств (`Features/Settings/SessionsView.swift`) показывает текущее; revoke-others работает
**Кейсы/файлы/версии/корзина**
- [ ] POST /v1/cases идемпотентен (повтор → тот же, revision=1); PUT без/с неверным `If-Match` → 409
- [ ] загрузка файла: sha256 не совпал → 422; квота → 413 с `limit_bytes`; скачанный blob побайтно равен загруженному
- [ ] корзина: trash → не в списке файлов, есть в `/v1/trash/files`; restore; purge; через 30 дней удаляется
- [ ] версии: replaceContent → +1 revision, старое в `/versions`, `restoreVersion` меняет местами; версии в `used_bytes`
- [ ] DELETE кейса каскадно удаляет blob'ы
- [ ] чужие id → 403/404 (проверить двумя аккаунтами)
**Audit**: [ ] серверные события пишутся автоматически; `POST /v1/audit` с неизвестным `kind` — не 5xx
**Биллинг**: [ ] plans/subscription; purchase с `apple_transaction=null` отклоняется (вне тест-режима)
**Чат**
- [ ] registerIdentity (32 байта; иной размер → 400; повтор с тем же ключом — ок; другой ключ → отказ)
- [ ] два аккаунта: добавить контакт по QR, отправить, получить, `ack` удаляет конверт; повтор `send` с тем же id не создаёт дубликат
- [ ] `sender_id` ≠ токена → 403; неизвестный получатель → 404
- [ ] конверт старше 30 дней удаляется; push не содержит текста
- [ ] исчезающие/«не пересылать»/QR-сверка работают без участия сервера (проверить на двух устройствах)
**Общий кейс**: [ ] invite чужим не владельцем → 403; accept чужого приглашения → 403/404; fetchWrappedKey до accept → 404; приглашённый видит кейс/файлы после accept (пробел 4.1); viewer не может писать (403); revoke владельцем/самим участником; revoke чужого не владельцем → 403
**Бэкап**: [ ] PUT с неверным sha256 → 422; list/download/delete; чужой id → 404; скачанный файл восстанавливается приложением (`Features/Backup/BackupSettingsView.swift`, «Восстановить»)
**Security events**: [ ] 204 на каждый `kind`; неизвестный → 400
**Клиентские (бэкенд не нужен)**: [ ] напоминания, поиск, duress, wipe, персистентность, смена CryptoEngine — проверяются только в приложении

### Smoke-тест curl
```bash
B=https://api.example   # свой адрес
J='Content-Type: application/json'
# 1. регистрация и вход
curl -s -X POST $B/v1/auth/register -H "$J" -d '{"email":"a@x.io","username":"anna","password":"correct-horse"}'
TOKEN=$(curl -s -X POST $B/v1/auth/login -H "$J" -d '{"identifier":"anna","password":"correct-horse"}' | jq -r .session.access_token)
A="Authorization: Bearer $TOKEN"
# 2. кейс (id генерирует клиент)
CID=$(uuidgen | tr A-Z a-z)
curl -s -X POST $B/v1/cases -H "$A" -H "$J" -d "{\"id\":\"$CID\",\"sealed_header\":\"3q2+7w==\",\"recovery_wrapped_key\":\"AAECAwQFBgc=\",\"file_count\":0,\"storage_bytes\":0,\"revision\":0,\"created_at\":\"2025-01-15T10:30:00Z\",\"updated_at\":\"2025-01-15T10:30:00Z\"}"
# 3. файл: метаданные + blob + sha256
FID=$(uuidgen | tr A-Z a-z); head -c 2048 /dev/urandom > /tmp/blob.bin
SHA=$(shasum -a 256 /tmp/blob.bin | cut -d' ' -f1)
curl -s -X POST $B/v1/files -H "$A" -H "$J" -d "{\"id\":\"$FID\",\"case_id\":\"$CID\",\"sealed_metadata\":\"3q2+7w==\",\"ciphertext_size\":2048,\"ciphertext_sha256\":\"$SHA\",\"revision\":0,\"created_at\":\"2025-01-15T10:31:00Z\",\"updated_at\":\"2025-01-15T10:31:00Z\"}"
curl -s -X PUT $B/v1/files/$FID/blob -H "$A" -H 'Content-Type: application/octet-stream' -H "X-Content-SHA256: $SHA" --data-binary @/tmp/blob.bin -w '%{http_code}\n'   # 204
curl -s $B/v1/files/$FID/blob -H "$A" -H 'Accept: application/octet-stream' | shasum -a 256            # == $SHA
# неверный хэш → 422
curl -s -X PUT $B/v1/files/$FID/blob -H "$A" -H 'Content-Type: application/octet-stream' -H 'X-Content-SHA256: 00' --data-binary @/tmp/blob.bin -w '%{http_code}\n'
# конфликт revision → 409
curl -s -X PUT $B/v1/cases/$CID -H "$A" -H "$J" -H 'If-Match: 99' -d "{\"id\":\"$CID\",\"sealed_header\":\"3q2+7w==\",\"file_count\":0,\"storage_bytes\":0,\"revision\":99,\"created_at\":\"2025-01-15T10:30:00Z\",\"updated_at\":\"2025-01-15T10:30:00Z\"}" -w '%{http_code}\n'
# 4. чат (после регистрации второго пользователя bob и его TOKEN_B/ID_B)
KEY=$(head -c 32 /dev/urandom | base64)
curl -s -X PUT $B/v1/chat/identity -H "$A" -H "$J" -d "{\"public_key\":\"$KEY\"}"
MID=$(uuidgen | tr A-Z a-z)
curl -s -X POST $B/v1/chat/messages -H "$A" -H "$J" -d "{\"id\":\"$MID\",\"sender_id\":\"$ID_A\",\"recipient_id\":\"$ID_B\",\"version\":1,\"ciphertext\":\"AAAAAA==\",\"sent_at\":\"2025-01-15T10:32:00Z\",\"expires_at\":\"2025-02-14T10:32:00Z\"}" -w '%{http_code}\n'   # 204 (повтор тоже 204)
curl -s "$B/v1/chat/messages?limit=100" -H "Authorization: Bearer $TOKEN_B"
curl -s -X POST $B/v1/chat/messages/ack -H "Authorization: Bearer $TOKEN_B" -H "$J" -d "{\"ids\":[\"$MID\"]}" -w '%{http_code}\n'
# 5. 1.3.0 пока не готово → 501
curl -s -X POST $B/v1/security-events -H "$A" -H "$J" -d '{"kind":"duressUnlock","at":"2025-01-15T10:33:00Z"}' -w '%{http_code}\n'
```
(Тело `ciphertext` `AAAAAA==` — просто байты для проверки очереди; сервер не расшифровывает.)

---

## 7. Ошибки и неизвестное (честно)

**Не проверено / не сделано:**
- Реальный сервер: ни один Live-клиент не запускался против настоящего API (проверено только на `MockBackend` и по фикстурам).
- Face ID / биометрический ACL секретов кейсов — на реальном устройстве не проверено (юнит-тесты на выбор политики есть).
- Push: нет регистрации токена и `aps-environment`, не проверено вообще.
- iCloud-бэкап: entitlement iCloud **не добавлен** в `loKEY.entitlements` (только app group и keychain group); `ICloudDriveBackupStore` вернёт `.unavailable`.
- Поведение UI новых функций (главная, поиск, исчезающие, «не пересылать», QR-сверка, duress, wipe, напоминания, общий кейс, бэкап) на устройстве не проверялось.
- `ChatUITests` падает на стр. 18: не найдена кнопка «Алиса» в демо-блоке `AddContactView` после редизайна (причина не выяснена); `WalkthroughUITests` не запускался.
- Группы в UI не подключены; `rotateKeyAfterRevoke` не реализован; отказа от приглашения нет; бэкап не включает закрытые кейсы; казахские строки не вычитаны носителем.
- Доступ участников общего кейса к записи кейса и файлам в контракте не описан (раздел 4.1).
- Жёсткие лимиты размера blob/конверта/бэкапа в контракте не заданы.
- Где используется `SecurityEventKind.tooManyAttempts` — не найдено.
- Передача `device_name`/`platform` при входе, SMS-MFA, перенос имён кейсов между устройствами — ждут согласования.
