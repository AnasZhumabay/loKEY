# loKEY — памятка для продолжения (после /clear)

Дата: 2026-11-18. Язык общения с пользователем: русский.

## Что это
iOS-приложение **loKEY** (SwiftUI, iOS 17+): хранилище секретных файлов. Файлы шифруются на телефоне (AES-256-GCM), у каждого кейса свой ключ, сервер видит только шифртекст. **Делаем только фронтенд**: бэкенд пишет другой человек, стык только через `loKEY/Contract/`.

Проект: `~/Desktop/loKEY-iOS` (XcodeGen: `project.yml`, после новых файлов `xcodegen generate`).
Источник макетов: `.dc.html` в scratchpad (старый холст), требования: `~/Desktop/loKEY MVP.md`.

## Архитектура (не нарушать)
- `Contract/` — DTO + протоколы сервисов. **Версия 1.3.0**, только добавления. Меняется только по согласованию с бэкендером (`Docs/BACKEND_CONTRACT.md`, `Docs/BACKEND_INTEGRATION.md`, `Docs/CHAT.md`).
- `Domain/` — модели для UI + `VaultRepository`, `ChatRepository` (единственные интерфейсы данных для UI).
- `Core/` — реализация: `VaultRepositoryImpl`, `Chat/*`, `Crypto/*`, `Seams/*` (подменяемые швы: CryptoEngine, HistoryStore/SessionPersistence/CasesCache, CloudBackupStore), `Security/*` (duress, wipe), `Reminders/*`, `Backup/*`, `Shared/*` (общий кейс), `Backend/{MockBackend,MockBackendV13,LiveBackend,LiveBackendV13,MockChat}`. UI НЕ использует Core/Contract.
- `Features/*` — экраны. `DesignSystem/*` — токены, компоненты, `Motion.swift`, `Extras.swift`, `Localization.swift`.
- `App/` — `AppStore` (@Observable), `Router`, `RootView`.
- Переключение на живой бэкенд: `AppConfig.useMocks = false` (`App/AppStore.swift`).
- Правила: без `try!`/force-unwrap данных, расшифрованное только в памяти (никаких открытых файлов на диске/UserDefaults), доступность (подписи, ≥44pt), учёт «Уменьшить движение», тексты по-русски (ключи локализации = русский текст, переводы en/kk в `loKEY/Resources/*.lproj`).

## Запуск и подпись
- Bundle ID: `com.anasjumabay.lokey` (+ `.widgets`, `.share`). Team `Y8PGBLF73X`, App Group `group.com.anasjumabay.lokey`, keychain group `…lokey.shared`. Apple ID добавлен в Xcode; соглашение Apple принято.
- iPhone 13 «🧾» (UDID 00008110-001A08EE1ED0A01E):
  `xcodebuild -project loKEY.xcodeproj -scheme loKEY -destination 'id=00008110-001A08EE1ED0A01E' -allowProvisioningUpdates -derivedDataPath /private/tmp/lokey-dd build`, затем `xcrun devicectl device install app --device <UDID> <loKEY.app>` и `xcrun devicectl device process launch --device <UDID> com.anasjumabay.lokey` (телефон должен быть разблокирован).
- Симулятор (iPhone 18 Pro): сборка с `CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=""`. Simulator.app отсутствует, смотреть через скриншоты XCUITest.
- Мок-режим: вход с любым email и паролем от 6 символов; после перезапуска сессия и данные сбрасываются (всё в памяти).
- Демо-ключи закрытых кейсов: `Docs/DEMO_DATA.md`.

## Тесты и грабли
- Юнит-тесты: `-only-testing:loKEYTests` — **133 проходят** (BackupTests 8, ChatCryptoTests 6, ChatFeaturesTests 11, ContractTests 25, CryptoTests 13, EditorTests 12, RemindersTests 9, RepositoryTests 17, SeamsTests 9, SecurityTests 17, SharedCaseTests 6). Иногда «runner hung» — повторить, перед этим `xcrun simctl shutdown all`.
- **Известная проблема:** `ChatUITests.testChatWithDemoContact` падает на стр. 18 (кнопка «Алиса» в демо-блоке `AddContactView` не найдена после редизайна; причина не выяснена). `WalkthroughUITests` после редизайна не запускался. Поведение UI новых функций (см. ниже) на устройстве не проверялось.
- UI-тесты нестабильны под нагрузкой (рендер видео в Bloom). Отладочные аргументы (только DEBUG+моки): `-lokeyDemoLogin` (вход без набора пароля), `-lokeyOpenCase "Имя"`, плюс `-language ru -AppleLanguages (ru) -AppleLocale ru_RU`. Набор пароля в XCUI теряет символы.
- В `app.buttons.containing(...)` совпадают контейнеры-родители; для карточек искать staticTexts.
- Скриншоты тестов пишутся в `/private/tmp/lokey-shots`.
- Ошибки SourceKit «No such module UIKit» в Features/Editor — шум индексации, сборка проходит.

## Что сделано (кратко)
Онбординг (интерактивное шифрование), вход/MFA, главная, кейсы (разделы Фото/Видео/Файлы/Заметки/Пароли, миниатюры), просмотр файла (в памяти, целостность, версии), корзина, избранное, журнал (сводка, склейка событий), настройки (оценка защиты, язык ru/en/kk, устройства, тарифы), виджеты + Live Activity («Закрыть все»), встряхивание = закрыть все, защита от записи экрана, Manrope.
- **Чат** (E2EE: X25519 + симметричный ratchet + AES-GCM; ответы, реакции, правка/удаление, тема, стикеры, коды безопасности, демо-собеседница Алиса). Подробности и ограничения: `Docs/CHAT.md`.
- **Сканер документов** (VisionKit, PDF, OCR на устройстве → поле `ocrText` внутри шифртекста, поиск), **редактор фото** (обрезка/фильтры/коррекция/рисунок/текст), **подпись** (Keychain, на фото и PDF), **расширение «Поделиться в loKEY»** + экран «Входящие» (`Shared/InboxStore.swift`).
- Аудит по `/shii` (Opus подтвердил 18/22 замечаний), критичное исправлено: обход Face ID только DEBUG+моки, сессия не сбрасывается при сбое сети, ack чата после обработки, безопасное чтение Keychain, восстановление по 12 словам на новом устройстве, NFC.

### Сделано в сессии контракта 1.3.0 (юнит-тесты есть, UI на устройстве не проверен)
- **Главная переработана** (меню «+», один слот «следующий шаг», чаты вкладкой `chatsTab`) и **глобальный поиск** (`Features/Home`, `Features/Search`).
- **Персистентность:** снимок сессии, офлайн-кэш кейсов, зашифрованная история чата (`Core/Seams/HistoryStore.swift`, ключ аккаунта, AES-GCM, исключены из бэкапа). **Keychain с биометрическим ACL** для секретов кейсов (`Core/Crypto/KeyStore.swift`).
- **Чат:** исчезающие сообщения (таймер чата и сообщения, внутри шифртекста), отправка файла из кейса с флагом «не пересылать» (`nf`), сверка кода безопасности по QR (`ChatVerifyCodec`), шов `CryptoEngine` (замена `ChatCrypto` на libsignal/MLS без правки UI), шов групп (`ChatGroupRepository`, пока заглушка).
- **Редактор:** исправлены обрезка и PDF (потеря аннотаций, растягивание).
- **Безопасность:** режим «под принуждением» (ложное хранилище, `DecoyVault`), аварийное стирание после N попыток (`WipePolicy` 3–10), `SecurityEventAPI`.
- **Напоминания** о сроках документов (локальные уведомления, `Core/Reminders`).
- **Общий кейс на двоих** (обёрнутый ключ на участника, `Core/Shared`), **шифрованная резервная копия** (iCloud / сервер / файл, `Core/Backup`, формат `Docs/_backup_format.md`).
- Контракт 1.3.0: `Contract/ContractV13.swift`, `Core/Backend/{LiveBackendV13,MockBackendV13}.swift`; руководство для бэкендера `Docs/BACKEND_INTEGRATION.md`; журнал интеграции `Docs/_integration_log.md`.

## Что ещё не сделано / идеи (по приоритету)
1. Чат: замена схемы на libsignal + независимый криптоаудит (нужны prekeys → новая версия контракта); **UI групп** (шов и контракт готовы).
2. Проверить на устройстве: **Face ID ACL** секретов кейсов, работу новых экранов, камеру сканера, подпись PDF, расширение «Поделиться».
3. **iCloud entitlement** не добавлен (`loKEY.entitlements`) — без него бэкап в iCloud недоступен.
4. Бэкап **по файлам для закрытых кейсов** (сейчас пропускаются и перечисляются по имени).
5. `rotateKeyAfterRevoke` (смена ключа общего кейса после отзыва; нужен бэкенд), **endpoint отказа от приглашения** (сейчас скрывается локально).
6. **Казахские строки** нужно вычитать носителю языка.
7. **XCUITests для новых потоков**; починить `ChatUITests` (стр. 18).
8. StoreKit 2 (`TODO(StoreKit)` в `PlansView`), удаление аккаунта, privacy manifest для App Store, push (нет регистрации токена).
9. Нужно согласие бэкендера: `device_name`/`platform` при входе, SMS-MFA, перенос имён кейсов между устройствами, доступ участников общего кейса к записи кейса и файлам (пробел в 1.3.0, см. `BACKEND_INTEGRATION.md` 4.1).
10. Отложено: срок жизни пропущенных ключей чата и привязка id к шифртексту.

## Карта файлов (новое)
- `Docs/`: `BACKEND_INTEGRATION.md` (руководство бэкендеру), `BACKEND_CONTRACT.md`, `CHAT.md`, `_backup_format.md`, `_shared_case_format.md`, `_integration_log.md`, `_strings/`.
- `Contract/`: `APIModels.swift`, `Services.swift`, `ContractV13.swift`.
- `Core/Backend/`: `LiveBackend.swift`, `LiveBackendV13.swift` (заглушки `TODO(backend)`), `MockBackend*.swift`.
- `Core/Seams/`: `CryptoEngine`, `HistoryStore` (+сессия, кэш кейсов), `CloudBackupStore`, `EncryptedFileBox`.
- `Core/Chat/`: `ChatCrypto`, `ChatPayload` (+QR-коды), `ChatRepositoryImpl`. `Core/Security/`: `DecoyVault`, `AttemptTracker`. `Core/Reminders/`, `Core/Backup/`, `Core/Shared/`.
- `Features/`: `Search`, `Reminders`, `Backup`, `SharedCase`, `Privacy` (PanicSettings), `Chat/SafetyNumberView`.

## Видео для loKEY в Bloom (`~/Documents/Bloom`)
Проекты: `20261117-lokey-intro` («Что видит сервер…», готов, v4), `20261117-lokey-key-pov` («Я ключ…», готов), `20261118-lokey-thief-test` («Что найдёт вор за 10 секунд…», стиль living-screencast, голос Riley, Riley-герой; готов или в работе — смотреть `films/film-2cb6486e.json`). Фильмы в `exports/`. Перед публикацией: проверить голос, логотип (`~/Desktop/Знак из l и o — 4 варианта@1x.png`), заглушку `{{ссылка на приложение}}`, отсутствие настоящих ключей. Новый фильм запускается созданием `films/film-xxxx.json` (status queued) и перезапуском Bloom (если не идёт другой фильм).

## Рабочие соглашения с пользователем
Отвечать по-русски; делать «максимально дизайнерски» с анимациями; не обещать «100%»; честно сообщать, что не проверено; крупные задачи через `/shii` (Haiku/Sonnet делают, Opus проверяет); на «запусти на телефон» собирать и ставить на iPhone.
