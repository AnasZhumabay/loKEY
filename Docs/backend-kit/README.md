# loKEY backend-kit

Набор для бэкендера, у которого **нет Mac**: собрать приложение и запустить Swift-тесты он не может, зато может проверить свой сервер на соответствие контракту 1.3.0 на Linux/Windows.

Источник правды (всё в репозитории): `Docs/BACKEND_CONTRACT.md`, `Docs/BACKEND_INTEGRATION.md`, `Docs/CHAT.md`, `loKEY/Contract/*.swift`, `loKEY/Core/Backend/LiveBackend*.swift`. Файлы этого набора выведены из них; если что-то расходится, прав Swift-код.

## Что внутри

| Файл | Зачем |
|---|---|
| `openapi.yaml` | OpenAPI 3.1: 57 операций (все вызовы клиента), схемы DTO в snake_case, enum, конверт ошибок, Bearer, правила 409/If-Match, идемпотентность |
| `postman_collection.json` | Postman v2.1: папка `00 Smoke` + папка на каждую область, тесты на статусы и ключевые поля |
| `contract_check.py` | Самодостаточный Python 3 (только stdlib): smoke-сценарий + проверки схем, ошибок, 409/404/401, идемпотентности; режим `--mock` |
| `fixtures/*.json` | Эталонные JSON из `loKEYTests/Fixtures` (на них построены проверки формата) |

## Главные правила формата (из `LKCoding`)
- Ключи `snake_case`; даты ISO-8601 UTC **без долей секунды**: `2025-01-15T10:30:00Z` (Swift `.iso8601` долей не принимает).
- `Data` = base64 (стандартный, с `=`). Enum не переводятся в snake_case: `unlockFailed`, `caseWiped`, `authenticator`.
- Ошибка = HTTP 4xx/5xx + `{"code","message","retry_after_seconds"?,"limit_bytes"?}`. Таблица код -> `APIError` в `openapi.yaml` (схема `ErrorEnvelope`). `quota_exceeded` обязан нести `limit_bytes`.
- `PUT /v1/cases/{id}`, `PUT /v1/files/{id}`: заголовок `If-Match: <revision>`; не совпал -> `409 conflict`. Создание даёт `revision=1`.
- id создаёт клиент; повторный POST того же id возвращает существующую запись; повтор `POST /v1/chat/messages` с тем же `(sender_id, id)` -> 204 без дубля.
- Для 1.3.0 пока не реализованного: `501` + `{"code":"not_implemented","message":"not_implemented"}` (message ровно такой).

## Как пользоваться без Mac

### 1. Быстрая проверка скриптом
```bash
python3 contract_check.py --mock                                    # самопроверка скрипта, сервер не нужен
python3 contract_check.py --base-url http://localhost:8080          # против вашего сервера
python3 contract_check.py --base-url https://api.example --token <access_token>   # токен пользователя A
```
Скрипт сам регистрирует двух пользователей (`chk…@example.com`), создаёт кейс/файл, гоняет чат A->B и убирает за собой. Код выхода 0 = нет провалов, 1 = есть. `WARN` = эндпоинт 1.3.0 отвечает `501 not_implemented` (допустимо). `--token` подменяет токен пользователя A; пользователь B всё равно регистрируется.

### 2. Postman / newman
```bash
npm i -g newman
newman run postman_collection.json --env-var baseUrl=http://localhost:8080 --folder "00 Smoke (по порядку)"
```
В Postman: Import -> файл, задайте переменную `baseUrl`, запустите Runner на папке `00 Smoke`: она создаёт пользователей и заполняет `token`, `tokenB`, `userAId`, `caseId`, `fileId`, `msgId` и т.д. Остальные папки используют эти переменные.

### 3. Документация и заглушки сервера
```bash
docker run -p 8081:8080 -e SWAGGER_JSON=/k/openapi.yaml -v "$PWD":/k swaggerapi/swagger-ui      # Swagger UI на :8081
docker run -p 8082:80 -e SPEC_URL=openapi.yaml -v "$PWD/openapi.yaml":/usr/share/nginx/html/openapi.yaml redocly/redoc   # Redoc на :8082
```
Без docker: вставьте `openapi.yaml` в https://editor.swagger.io. Заглушки сервера:
```bash
docker run --rm -v "$PWD":/local openapitools/openapi-generator-cli generate -i /local/openapi.yaml -g spring -o /local/out/spring
# другие генераторы: -g python-fastapi, -g go-server, -g typescript-nestjs, -g aspnetcore
```
Генераторам иногда мешают OpenAPI 3.1 (`type: [string, 'null']`); при ошибке используйте свежий openapi-generator или откройте в редакторе и экспортируйте как 3.0.

## Как проверить конверты чата
Сервер не расшифровывает `ciphertext` (формат `[счётчик UInt32 BE][AES-GCM combined]`, см. `Docs/CHAT.md`), поэтому достаточно проверить «почтовое отделение»:
1. `PUT /v1/chat/identity` принимает ровно 32 байта (base64), иначе 400; повтор того же ключа идемпотентен, подмену ключа не допускает.
2. `POST /v1/chat/messages`: `sender_id` == пользователь токена (иначе 403), неизвестный получатель -> 404, повтор того же `id` -> 204 и в очереди один конверт.
3. `GET /v1/chat/messages?limit=` у получателя: старые первыми, поля и байты `ciphertext` без искажений, до `ack` не удаляются; чужие `ack` игнорируются.
4. `expires_at`: клиент ставит `sent_at + 30 дней`; сервер вправе удалить после.
Все пункты уже покрыты `contract_check.py` (раздел 6) и Smoke-папкой Postman (шаги 15-24).
Групповые конверты (`POST /v1/chat/groups/{id}/messages`): сервер раздаёт копию каждому из `recipient_ids` в обычную очередь получателя (проверьте `GET /v1/chat/messages` получателя).

## Чего без приложения проверить нельзя
- Поведение интерфейса (экраны, ошибки на экране, «недоступно» при 501, текст `validation`-сообщений).
- Face ID / биометрия и хранение секретов в Keychain.
- Push-уведомления: в контракте и клиенте нет эндпоинта регистрации push-токена (`aps-environment` не настроен).
- Реальное шифрование: валидность `sealed_*`, обёрнутых ключей, `ciphertext` и бэкап-файла сервер проверить не может (и не должен); скрипт шлёт случайные байты.
- Refresh-токены в реальных сроках жизни (клиент делает один refresh и повтор запроса на 401) и таймауты 30 с.
- Общий кейс: как приглашённый получает доступ к записи кейса и файлам, в контракте не описано (см. `BACKEND_INTEGRATION.md`, 4.1) - решать вместе с владельцем приложения.
- Ни один Live-клиент ещё не запускался против настоящего сервера; клиентские 1.3.0-вызовы (`LiveBackendV13.swift`) пока заглушки.

## Как владелец приложения (Mac) запускает настоящее приложение против сервера
1. В `loKEY/App/AppStore.swift`, `enum AppConfig`: `static let useMocks = false`; `static let apiBaseURL = URL(string: "https://<ваш адрес>")!` (только HTTPS, ATS-исключений нет, пиннинга нет).
2. Для 1.3.0: реализовать тела методов в `loKEY/Core/Backend/LiveBackendV13.swift` по комментариям `// TODO(backend)`; UI менять не нужно.
3. Сборка и запуск в симуляторе, например:
```bash
cd ~/Desktop/loKEY-iOS
xcodebuild -scheme loKEY -destination 'platform=iOS Simulator,name=iPhone 15' build     # имя схемы/симулятора уточните через xcodebuild -list
xcodebuild test -scheme loKEY -only-testing:loKEYTests/ContractTests                    # формат DTO по фикстурам
```
4. Сначала прогоните `python3 contract_check.py --base-url <адрес>`; зелёный отчёт = контракт соблюдён, дальше ручная проверка в приложении: регистрация -> кейс -> файл -> скачивание -> корзина -> чат между двумя аккаунтами.

## Эндпоинт -> реализован? (отметьте ✓)
Источник: `openapi.yaml`, ровно столько же вызовов делает клиент (`LiveBackend.swift` + `LiveBackendV13.swift`).

| Реализовано (✗/✓) | Метод | Путь | Что делает | Примечание |
|---|---|---|---|---|
| ✗ | POST | `/v1/auth/register` | Регистрация |  |
| ✗ | POST | `/v1/auth/login` | Вход |  |
| ✗ | POST | `/v1/auth/mfa/verify` | Второй фактор |  |
| ✗ | POST | `/v1/auth/refresh` | Обновление токенов |  |
| ✗ | POST | `/v1/auth/logout` | Выход |  |
| ✗ | POST | `/v1/auth/password-reset` | Сброс пароля |  |
| ✗ | GET | `/v1/account` | Текущий аккаунт |  |
| ✗ | PATCH | `/v1/account` | Запасной email |  |
| ✗ | PUT | `/v1/account/mfa` | Включить/выключить MFA |  |
| ✗ | GET | `/v1/account/storage` | Использование хранилища |  |
| ✗ | GET | `/v1/account/sessions` | Активные сеансы |  |
| ✗ | DELETE | `/v1/account/sessions/{id}` | Завершить сеанс |  |
| ✗ | POST | `/v1/account/sessions/revoke-others` | Завершить все сеансы, кроме текущего |  |
| ✗ | GET | `/v1/cases` | Не удалённые кейсы пользователя |  |
| ✗ | POST | `/v1/cases` | Создать кейс |  |
| ✗ | PUT | `/v1/cases/{id}` | Обновить кейс |  |
| ✗ | DELETE | `/v1/cases/{id}` | Навсегда удалить кейс, файлы и blob'ы |  |
| ✗ | GET | `/v1/cases/{caseId}/files` | Файлы кейса |  |
| ✗ | GET | `/v1/trash/files` | Файлы в корзине всех кейсов |  |
| ✗ | POST | `/v1/files` | Создать запись файла |  |
| ✗ | PUT | `/v1/files/{id}` | Обновить метаданные файла |  |
| ✗ | DELETE | `/v1/files/{id}` | Удалить файл навсегда |  |
| ✗ | PUT | `/v1/files/{id}/blob` | Загрузка шифртекста |  |
| ✗ | GET | `/v1/files/{id}/blob` | Скачать шифртекст |  |
| ✗ | POST | `/v1/files/{id}/trash` | В корзину |  |
| ✗ | POST | `/v1/files/{id}/restore` | Достать из корзины |  |
| ✗ | GET | `/v1/files/{id}/versions` | Предыдущие версии |  |
| ✗ | POST | `/v1/files/{id}/versions` | Заменить содержимое новой версией |  |
| ✗ | GET | `/v1/file-versions/{id}/blob` | Шифртекст версии |  |
| ✗ | POST | `/v1/files/{id}/versions/{versionId}/restore` | Поменять местами текущее состояние и выбранную версию |  |
| ✗ | GET | `/v1/billing/plans` | Тарифы |  |
| ✗ | GET | `/v1/billing/subscription` | Текущая подписка |  |
| ✗ | POST | `/v1/billing/purchase` | Подтвердить покупку StoreKit |  |
| ✗ | POST | `/v1/billing/cancel` | Отменить подписку |  |
| ✗ | GET | `/v1/audit` | Журнал событий, новые первыми |  |
| ✗ | POST | `/v1/audit` | Клиент сообщает событие, которого сервер не видит |  |
| ✗ | PUT | `/v1/chat/identity` | Опубликовать публичный ключ X25519 |  |
| ✗ | GET | `/v1/chat/users/{id}` | Профиль и публичный ключ пользователя |  |
| ✗ | POST | `/v1/chat/messages` | Положить конверт в очередь получателя |  |
| ✗ | GET | `/v1/chat/messages` | Входящие конверты, старые первыми; не удаляются до ack |  |
| ✗ | POST | `/v1/chat/messages/ack` | Подтвердить получение - сервер удаляет конверты из очереди |  |
| ✗ | POST | `/v1/cases/{caseId}/invites` | Пригласить в общий кейс | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/cases/{caseId}/members` | Участники общего кейса | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | DELETE | `/v1/cases/{caseId}/members/{userId}` | Отозвать доступ / выйти | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/cases/{caseId}/wrapped-key` | Ключ кейса, обёрнутый для текущего пользователя | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/invites` | Входящие непринятые приглашения | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | POST | `/v1/invites/{id}/accept` | Принять приглашение | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/backups` | Список бэкапов | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | PUT | `/v1/backups/{id}` | Загрузить бэкап | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | DELETE | `/v1/backups/{id}` | Удалить бэкап | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/backups/{id}/blob` | Скачать бэкап | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | GET | `/v1/chat/groups` | Группы пользователя | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | POST | `/v1/chat/groups` | Создать группу | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | POST | `/v1/chat/groups/{groupId}/members` | Добавить участника | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | DELETE | `/v1/chat/groups/{groupId}/members/{userId}` | Убрать участника | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | POST | `/v1/chat/groups/{groupId}/messages` | Групповое сообщение | 1.3.0 (клиент пока заглушка; 501 допустим) |
| ✗ | POST | `/v1/security-events` | Событие безопасности | 1.3.0 (клиент пока заглушка; 501 допустим) |

Допустимые коды сверх таблицы: 401 на любой защищённый путь без/с плохим токеном; 429 `rate_limited`; 5xx `server`. Полные ответы - в `openapi.yaml`.
