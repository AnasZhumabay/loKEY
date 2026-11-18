# loKEY — контракт бэкенда (версия 1.3.0)

Источник правды: `loKEY/Contract/APIModels.swift` и `Services.swift`. Этот документ — их описание для бэкендера. Клиентская реализация REST: `loKEY/Core/Backend/LiveBackend.swift`.

## 1. Назначение и золотые правила
Бэкенд — «тупое» зашифрованное хранилище. Всё шифрование делает приложение.

1. **Сервер видит только шифртекст.** `sealed_header`, `sealed_metadata`, `recovery_wrapped_key` и blob'ы файлов — непрозрачные байты. Сервер не знает имён, типов, заметок, ключей.
2. **Id генерирует клиент** (UUID v4, строчные буквы). Создание идемпотентно: повторный POST с тем же id возвращает существующую запись.
3. **Optimistic revision.** `revision` растёт на 1 при каждом изменении (создание = 1). PUT требует заголовок `If-Match: <ожидаемая revision>`; не совпало — `409 conflict`. Клиентское значение `revision` в теле при создании игнорируется.
4. **Формат JSON:** ключи `snake_case`, даты ISO-8601 UTC **без долей секунды** (`2025-01-15T10:30:00Z`), `Data` — base64 (стандартный, с padding). Значения enum — как в Swift-коде (`"unlockFailed"`, `"authenticator"`, `"critical"`): **enum не переводятся в snake_case**. Поля `null` можно опускать.
5. Все списки — «голые» JSON-массивы. Все тела ошибок — единый конверт (раздел 3).
6. Авторизация: `Authorization: Bearer <access_token>` везде, кроме `/v1/auth/*`.
7. Размер хранилища: 5 ГБ на бесплатном тарифе (`limit_bytes`), платные: 10 ГБ ($4.99), 25 ГБ ($9.99), 120 ГБ ($49.99) в месяц; корзина считается в использование.

## 2. Таблица эндпоинтов

| Метод протокола | HTTP | Путь | Тело запроса → ответ | Ошибки |
|---|---|---|---|---|
| `AuthAPI.register` | POST | `/v1/auth/register` | `RegisterRequest` → `SessionDTO` | 400 validation |
| `AuthAPI.login` | POST | `/v1/auth/login` | `LoginRequest` → `LoginResponse` (сессия ИЛИ `mfa_challenge_id`) | 400, 401, 429 |
| `AuthAPI.verifyMFA` | POST | `/v1/auth/mfa/verify` | `MFAVerifyRequest` → `SessionDTO` | 401 `mfa_invalid` |
| (refresh, клиент) | POST | `/v1/auth/refresh` | `{"refresh_token"}` → `SessionDTO` | 401 |
| `AuthAPI.restoreSession` | — | локально (Keychain) + refresh при истечении | — | — |
| `AuthAPI.logout` | POST | `/v1/auth/logout` | — → 204 | 401 |
| `AuthAPI.requestPasswordReset` | POST | `/v1/auth/password-reset` | `{"email"}` → 204 (всегда 204, не раскрывать наличие аккаунта) | 400, 429 |
| `AccountAPI.me` | GET | `/v1/account` | → `AccountDTO` | 401 |
| `AccountAPI.updateBackupEmail` | PATCH | `/v1/account` | `{"backup_email": "a@b.c"\|null}` → `AccountDTO` | 400 |
| `AccountAPI.setMFA` | PUT | `/v1/account/mfa` | `{"enabled":true,"method":"authenticator"}` → `MFASetupDTO` (или 204 при выключении) | 400 |
| `AccountAPI.storageUsage` | GET | `/v1/account/storage` | → `StorageUsageDTO` | 401 |
| `CasesAPI.list` | GET | `/v1/cases` | → `[CaseRecordDTO]` | 401 |
| `CasesAPI.create` | POST | `/v1/cases` | `CaseRecordDTO` → `CaseRecordDTO` (200/201, идемпотентно) | 400 |
| `CasesAPI.update` | PUT | `/v1/cases/{id}` + `If-Match` | `CaseRecordDTO` → `CaseRecordDTO` (меняются только `sealed_header`, `recovery_wrapped_key`) | 404, 409 |
| `CasesAPI.purge` | DELETE | `/v1/cases/{id}` | → 204 (кейс, файлы и blob'ы навсегда) | 404 |
| `FilesAPI.list` | GET | `/v1/cases/{caseId}/files` | → `[FileRecordDTO]` (без удалённых) | 404 |
| `FilesAPI.listTrash` | GET | `/v1/trash/files` | → `[FileRecordDTO]` (`deleted_at != null`, все кейсы) | 401 |
| `FilesAPI.create` | POST | `/v1/files` | `FileRecordDTO` → `FileRecordDTO` | 404 кейс, 413 квота |
| `FilesAPI.update` | PUT | `/v1/files/{id}` + `If-Match` | `FileRecordDTO` → `FileRecordDTO` (меняется только `sealed_metadata`) | 404, 409 |
| `FilesAPI.uploadCiphertext` | PUT | `/v1/files/{id}/blob` | `application/octet-stream` + заголовок `X-Content-SHA256` → 204 | 404, 422 `integrity_failed` |
| `FilesAPI.downloadCiphertext` | GET | `/v1/files/{id}/blob` | → `application/octet-stream` | 404 |
| `FilesAPI.softDelete` | POST | `/v1/files/{id}/trash` | → 204 (ставит `deleted_at`, revision+1) | 404 |
| `FilesAPI.restore` | POST | `/v1/files/{id}/restore` | → `FileRecordDTO` (`deleted_at` снимается) | 404 |
| `FilesAPI.purge` | DELETE | `/v1/files/{id}` | → 204 | 404 |
| `AuditAPI.list` | GET | `/v1/audit?limit=N` | → `[AuditEventDTO]`, новые первыми | 401 |
| `AuditAPI.record` | POST | `/v1/audit` | `{"kind":"caseUnlocked","case_id":"…"}` → 204 | 400 |

Сервер сам пишет в журнал: `login`, `logout`, `loginFailed`, `fileAdded` (при `POST /v1/files`), `fileTrashed`, `fileRestored`, `mfaChanged`. Клиент через `POST /v1/audit` сообщает: `caseCreated`, `caseDeleted`, `caseUnlocked`, `caseLocked`, `unlockFailed`, `keyRecovered`.

Сервер заполняет/пересчитывает сам: `revision`, `created_at`, `updated_at`, `deleted_at`, у кейса `file_count` (без удалённых) и `storage_bytes` (с корзиной). При загрузке blob'а сервер проверяет: SHA-256 тела == `X-Content-SHA256` == `ciphertext_sha256` записи, длина == `ciphertext_size`; иначе 422.

### Примеры
```json
// POST /v1/auth/login
{"identifier":"anna","password":"correct-horse"}
// → 200
{"mfa_challenge_id":"ch-1"}
```
```json
// POST /v1/cases
{"id":"c0000000-0000-4000-8000-000000000001","sealed_header":"3q2+7w==","recovery_wrapped_key":"AAECAwQFBgc=",
 "file_count":0,"storage_bytes":0,"revision":0,"created_at":"2025-01-15T10:30:00Z","updated_at":"2025-01-15T10:30:00Z"}
// → 200, revision=1
```
```json
// POST /v1/files
{"id":"f0000000-…","case_id":"c0000000-…","sealed_metadata":"3q2+7w==","ciphertext_size":2048,
 "ciphertext_sha256":"e3b0c442…b855","revision":0,"created_at":"2025-01-15T10:31:00Z","updated_at":"2025-01-15T10:31:00Z"}
```
Полные эталонные документы для каждого DTO: `loKEYTests/Fixtures/*.json`.

## 3. Конверт ошибок
Любой ответ 4xx/5xx — JSON `{"code":"…","message":"…","retry_after_seconds":null,"limit_bytes":null}` (последние два поля — по необходимости).

| HTTP | `code` | `APIError` | Когда |
|---|---|---|---|
| 400 | `validation` | `.validation(message)` | неверные поля; `message` показывается пользователю (по-русски) |
| 401 | `unauthorized` | `.unauthorized` | нет/истёк токен (клиент один раз делает refresh) |
| 401 | `mfa_invalid` | `.mfaInvalid` | неверный код второго фактора (refresh НЕ делается) |
| 403 | `forbidden` | `.forbidden` | чужой ресурс |
| 404 | `not_found` | `.notFound` | нет записи |
| 409 | `conflict` | `.conflict` | `If-Match` ≠ текущей revision |
| 413 | `quota_exceeded` | `.quotaExceeded` | превышен лимит; обязательно `limit_bytes` |
| 422 | `integrity_failed` | `.integrityFailed` | SHA-256/размер blob'а не совпал |
| 429 | `rate_limited` | `.rateLimited` | `retry_after_seconds` (и/или заголовок `Retry-After`) |
| 5xx | `server` (любой другой) | `.server(message)` | прочее |

## 4. Потоки
- **Регистрация/вход/MFA.** register → `SessionDTO`. login → либо сессия, либо `mfa_challenge_id`; затем verify с кодом → сессия. Access-токен живёт ~1 ч, refresh — дольше; клиент хранит их в Keychain.
- **Создание кейса.** Клиент генерирует id, 20-байтный секрет, 12 слов; `sealed_header` (AES-GCM ключом хранилища аккаунта), `recovery_wrapped_key` (PBKDF2 от фразы + AES-GCM секрета) → `POST /v1/cases`. Секрет сервер не получает.
- **Загрузка файла.** `POST /v1/files` (метаданные + `ciphertext_sha256`) → `PUT /v1/files/{id}/blob`. Если blob не пришёл — запись-сирота; клиент при ошибке сам вызывает `DELETE /v1/files/{id}`; сервер может чистить записи без blob'а старше суток.
- **Скачивание.** `GET /v1/files/{id}/blob`; клиент сверяет SHA-256 и тег GCM — любое расхождение = «файл изменён».
- **Перенос.** Сервера это не касается: клиент скачивает, перешифровывает ключом другого кейса, создаёт НОВУЮ запись (новый id) + blob, старую отправляет в корзину.
- **Корзина.** `trash` ставит `deleted_at`; через 30 дней сервер удаляет запись и blob навсегда. `restore` снимает метку. `purge` — сразу.
- **Удаление кейса.** `DELETE /v1/cases/{id}` каскадно удаляет файлы и blob'ы.
- **Восстановление.** Ключ потерян → пользователь вводит 12 слов, клиент берёт `recovery_wrapped_key` из `GET /v1/cases`, разворачивает локально. Сервер ничего не делает (кроме приёма события `keyRecovered`).

## 5. Чего сервер НЕ ДОЛЖЕН делать никогда
- Пытаться расшифровать/разбирать `sealed_*`, blob'ы, `recovery_wrapped_key`; логировать их содержимое.
- Принимать/хранить ключи, секреты кейсов, фразы восстановления, ключ хранилища.
- Генерировать id кейсов/файлов, менять `ciphertext_sha256`, молча «чинить» несовпадение хэша.
- Менять формат JSON (snake_case, ISO-8601 без долей, base64) и значения enum.
- Отдавать удалённые (`deleted_at != null`) файлы в `GET /cases/{id}/files` и чужие данные между аккаунтами.
- Игнорировать `If-Match` (потеря обновлений) и квоту.

## 6. Известные ограничения v1.0.0
- Ключ хранилища аккаунта (`sealed_header`) лежит только в Keychain устройства и между устройствами не синхронизируется; на новом устройстве кейс виден как «Кейс с другого устройства». Для мультиустройств нужна MINOR-версия контракта (обёртка ключа хранилища паролем/фразой).
- Тип `AuditKind` в JSON — camelCase-строки.

## 7. Версионирование
`LKContract.version` (сейчас `1.3.0`) — semver. Любое изменение DTO, протоколов, путей, ошибок: MINOR — обратно совместимое добавление (новые необязательные поля), MAJOR — ломающее. Менять `Contract/` можно только по согласованию, обновляя этот документ и фикстуры.

## 8. Чек-лист бэкендера
1. Реализовать все эндпоинты из раздела 2, формат JSON и ошибки из разделов 1 и 3.
2. В `LiveBackend.swift` при необходимости поправить пути/заголовки (единственное место; UI не трогать).
3. Поставить `AppConfig.useMocks = false` (и `apiBaseURL`).
4. Прогнать Contract-тесты: `ContractTests` (формат DTO по фикстурам) и `RepositoryTests` (поведение; в них подставляется мок — повторить сценарии вручную против живого API: регистрация → кейс → файл → скачивание → перенос → корзина → квота → искажённый blob).


## 1.1.0 — добавления (обратно совместимо)

Только новые методы, существующие не менялись. Мок: `MockBackend`, клиент: `LiveBackend`.

| Протокол | Метод | HTTP |
|---|---|---|
| AccountAPI | listSessions | GET /v1/account/sessions → [SessionInfoDTO] |
| AccountAPI | revokeSession(id) | DELETE /v1/account/sessions/{id} |
| AccountAPI | revokeOtherSessions | POST /v1/account/sessions/revoke-others |
| FilesAPI | listVersions(fileId) | GET /v1/files/{id}/versions → [FileVersionDTO] (новые первыми, без текущей) |
| FilesAPI | replaceContent(fileId, ReplaceFileRequest) | POST /v1/files/{id}/versions → FileRecordDTO. Атомарно: старое состояние → версия, revision+1, затем клиент делает PUT /v1/files/{id}/blob. `409` при несовпадении expectedRevision |
| FilesAPI | downloadVersionCiphertext(versionId) | GET /v1/file-versions/{id}/blob |
| FilesAPI | restoreVersion(fileId, versionId) | POST /v1/files/{id}/versions/{vid}/restore → FileRecordDTO (меняет местами текущее и выбранное) |
| BillingAPI | plans | GET /v1/billing/plans → [PlanDTO] |
| BillingAPI | subscription | GET /v1/billing/subscription → SubscriptionDTO |
| BillingAPI | purchase(PurchaseRequest) | POST /v1/billing/purchase (appleTransaction = JWS StoreKit 2); сервер поднимает лимит StorageUsageDTO.limitBytes |
| BillingAPI | cancelSubscription | POST /v1/billing/cancel |

Версии занимают место в хранилище (считать в usedBytes). Метаданные и шифртекст версий запечатаны ключом кейса, как у файла.
StoreKit на клиенте пока не подключён: `PlansView.buy` вызывает `purchase(transaction: nil)` (TODO в коде).


## 1.2.0 — защищённый чат
Подробно: `Docs/CHAT.md`. Новый протокол `ChatAPI` (`registerIdentity`, `findUser`, `send`, `fetch`, `acknowledge`), DTO `ChatUserDTO`, `ChatEnvelopeDTO` (`Contract/APIModels.swift`). Только добавления, существующее не менялось.

## Уточнения (по итогам аудита)
- `POST /v1/auth/logout` требует Bearer; без Bearer работают только `register`, `login`, `mfa/verify`, `refresh`, `password-reset`.
- Очистка запасного email: клиент шлёт `{"backup_email": null}` (ключ присутствует, значение null).
- Даты только в формате `...Z` без дробных секунд. Значения enum (`AuditKind` и др.) в camelCase. Неизвестные значения `AuditKind` клиент пропускает, но другие enum сервер расширять не должен без релиза клиента.
- Для GET `/blob` клиент шлёт `Accept: application/octet-stream`.
- Версии файлов входят в `usedBytes`.
- Чат (1.2.0): на проводе поля `sender_id`, `recipient_id`, `sent_at`, `expires_at`, `public_key`. `public_key` ровно 32 байта (иначе 400); `sender_id` должен совпадать с пользователем токена (иначе 403); неизвестный получатель даёт 404; дедуп `send` по `(sender_id, id)`; `PUT /v1/chat/identity` не должен молча менять ключ уже зарегистрированной личности; `ack` с чужими id игнорируется.
| Протокол | Метод | HTTP |
|---|---|---|
| ChatAPI | registerIdentity | `PUT /v1/chat/identity` |
| ChatAPI | findUser | `GET /v1/chat/users/{id}` |
| ChatAPI | send | `POST /v1/chat/messages` |
| ChatAPI | fetch | `GET /v1/chat/messages?limit=` |
| ChatAPI | acknowledge | `POST /v1/chat/messages/ack` |

## 1.3.0 — добавления
Только добавления (новые протоколы/DTO, старое не менялось). Код: `Contract/ContractV13.swift`. В `APIServices` новые поля `sharedCases`, `backup`, `chatGroups`, `securityEvents` (по умолчанию «не реализовано»). Пока метод не готов, сервер отвечает `501` с конвертом `{"code":"not_implemented","message":"not_implemented"}` (поле `message` должно быть ровно таким: клиент делает `APIError.server(message)` и сравнивает с `"not_implemented"`; голый 501 даст `.server("")`); UI показывает «недоступно». Заглушки со `// TODO(backend):` — `Core/Backend/LiveBackendV13.swift`.

### Требуют работы бэкенда
| Протокол | Метод | HTTP |
|---|---|---|
| SharedCaseAPI | invite | `POST /v1/cases/{id}/invites` body `{invitee_user_id, wrapped_key_for_invitee, role}` → 204 |
| SharedCaseAPI | listMembers | `GET /v1/cases/{id}/members` → `[CaseMemberDTO]` |
| SharedCaseAPI | accept | `POST /v1/invites/{id}/accept` → `CaseMemberDTO` |
| SharedCaseAPI | revoke | `DELETE /v1/cases/{id}/members/{user_id}` → 204 |
| SharedCaseAPI | fetchWrappedKey | `GET /v1/cases/{id}/wrapped-key` → `{wrapped_key}`; 404 = нет доступа |
| SharedCaseAPI | listInvites | `GET /v1/invites` → `[CaseInviteDTO]` |
| BackupAPI | listBackups | `GET /v1/backups` → `[BackupInfoDTO]` |
| BackupAPI | upload | `PUT /v1/backups/{id}` (octet-stream; заголовки `X-LK-Info` = JSON `BackupInfoDTO`, `X-LK-SHA256`) |
| BackupAPI | download | `GET /v1/backups/{id}/blob` |
| BackupAPI | delete | `DELETE /v1/backups/{id}` → 204 |
| ChatGroupAPI | createGroup | `POST /v1/chat/groups` (идемпотентно по id) |
| ChatGroupAPI | listGroups | `GET /v1/chat/groups` |
| ChatGroupAPI | addMember / removeMember | `POST /v1/chat/groups/{id}/members` body `{user_id}` / `DELETE /v1/chat/groups/{id}/members/{user_id}` → `GroupDTO` |
| ChatGroupAPI | send | `POST /v1/chat/groups/{id}/messages` body `GroupEnvelopeDTO` → 204; сервер раздаёт копию каждому из `recipient_ids` в обычную очередь получателя |
| SecurityEventAPI | report | `POST /v1/security-events` body `SecurityEventDTO` → 204 |

### DTO (JSON snake_case, даты `...Z`, Data = base64)
- `SharedRole`: `owner|editor|viewer`; `SharedMemberStatus`: `invited|active|revoked`.
- `CaseMemberDTO{user_id, display_name, role, status, joined_at?}`; `CaseInviteDTO{id, case_id, case_name_ciphertext?, from_user_id, created_at}`.
- `BackupInfoDTO{id, created_at, size_bytes, sha256, device_name, app_version, format_version}`.
- `GroupDTO{id, name_ciphertext, member_ids, created_at}`; `GroupEnvelopeDTO{id, group_id, sender_id, sent_at, ciphertext, recipient_ids}`.
- `SecurityEventKind`: `caseWiped|duressUnlock|tooManyAttempts|backupCreated|backupRestored`; `SecurityEventDTO{kind, case_id?, at, device_name?}`.
- Фикстуры: `loKEYTests/Fixtures/*.json`, тесты `ContractTests`.

### Ошибки
Прежняя таблица. Для 1.3.0: `invite` чужого кейса — 403; неизвестный получатель — 404; `upload` с неверным sha256 — 422 `integrity_failed`; `accept` не своего приглашения — 403/404; `revoke` — только владелец или сам участник. Сервер НЕ видит ключи кейсов: `wrapped_key_for_invitee` и `name_ciphertext` — непрозрачные байты.

### Только клиент (работы бэкенда НЕТ)
`Core/Seams/`: `CryptoEngine` (+`BuiltinCryptoEngine`), `HistoryStore`/`FileHistoryStore`, `SessionPersistence`/`FileSessionPersistence`, `CasesCache`/`FileCasesCache` (AES-GCM, ключ аккаунта 32 байта, исключены из бэкапа), `CloudBackupStore` (`LocalFolderBackupStore`, `ICloudDriveBackupStore`; iCloud-entitlement не добавлялся).
