# loKEY iOS — общий бриф для агентов (читать целиком)

Приложение: iOS-хранилище секретных файлов. Файлы шифруются на телефоне (AES-256-GCM), у каждого кейса свой ключ, сервер видит только шифртекст. Делаем ТОЛЬКО фронтенд (SwiftUI, iOS 17+, Swift 5 mode, без сторонних библиотек). Бэкенд пишет другой человек — он работает только через контракт.

## Где лежит всё
- Проект: `/Users/anas/Desktop/loKEY-iOS` (XcodeGen, `project.yml`). Исходники: `loKEY/`.
- **Макеты (источник правды по виду и тексту):** `/private/tmp/claude-501/-Users-anas/c2d593fa-b807-4637-af1a-bb08de7a36a3/scratchpad/lokey/project/*.dc.html` — HTML с inline-стилями (размеры в px = pt). Открой нужный файл и воспроизведи: структуру, отступы, радиусы, цвета, тексты (русские — копируй дословно), состояния и анимации. Данные в макетах выдуманные.
- Спека продукта: `/Users/anas/Desktop/loKEY MVP.md`.

## Уже готово (НЕ менять, только использовать)
- `Contract/` — DTO и протоколы бэкенда. **Не трогать.** UI про них не знает.
- `Domain/Models.swift` — модели для UI (`VaultCase`, `VaultFile`, `VaultError`, …). `Domain/VaultRepository.swift` — ЕДИНСТВЕННЫЙ интерфейс данных для UI (в комментариях описана семантика).
- `App/AppStore.swift` — `@Observable` состояние. Во View: `@Environment(AppStore.self) private var store`. Есть: `store.cases`, `store.unlockedCases`, `store.vaultCase(id)`, `store.storage`, `store.account`, `store.secondsUntilAutoLock`, `store.autoLockMinutes`, `store.faceIDEnabled`, `store.hideNamesInWidgets`, `store.unlock(caseID:method:)`, `store.lock(caseID:)`, `store.lockAll()`, `store.refreshCases()`, `store.noteActivity()`, `store.showToast(_:isError:)`, `store.showError(_:)`, `store.signOut()`, `store.login/verifyMFA/register`, `store.finishOnboarding()`, `store.repo`.
  **После любого изменения кейсов/файлов через `store.repo` обязательно `await store.refreshCases()`.**
- `App/Router.swift` — `@Environment(Router.self) private var router`: `router.push(.unlock(caseID:))`, `.vaultCase(caseID:)`, `.file(fileID:caseID:)`, `.trash`, `router.pop()`, `router.popToRoot()`, `router.replaceTop(with:)`, `router.tab`, `router.cover = .newCase`, `router.sheet = .deleteCase(caseID:)`, `router.pendingIntent` (`.camera`/`.upload`, ставит Home, выполняет и сбрасывает CaseView).
- `App/RootView.swift` — оболочка и плавающая панель вкладок; pushed-экраны её не показывают.
- `DesignSystem/` — `Color.lk*`, `Font.lk(_:_:)`, `Font.lkMono`, `BrandMark`, `BrandWordmark`, `GlowBackground`, `.lkScreen()`, `.lkCard()`, `LKPrimaryButtonStyle`/`.lkPrimary`, `.lkSecondary`, `LKIconButton`, `LKChip`, `LevelTag`, `AutoLockPill`, `LKField`, `LKTopBar`, `ToastView`, `Haptics`, `LKFormat`, расширения `SecurityLevel/CaseIcon/FileKind` (`tint`, `title`, `systemName`, `label`). Если нужного компонента нет — делай приватный внутри своего файла, общие файлы не правь.
- Заглушки экранов в `Features/*/` — каждый агент ЗАМЕНЯЕТ свои файлы (имя struct и init-параметры менять нельзя — на них ссылается RootView).

## Правила (жёсткие)
1. **Один файл — один владелец.** Правь и создавай файлы ТОЛЬКО в своей зоне (указана в задании). Чужие, `Contract/`, `Domain/`, `DesignSystem/`, `App/` — не трогай. Нужна правка в чужом месте — напиши в отчёте, не делай.
2. UI не импортирует и не использует ничего из `Core/` и `Contract/`. Данные — только через `store`/`store.repo`.
3. Никакого открытого текста файлов на диске: расшифрованные данные живут в памяти (`Data`/`UIImage`), без временных файлов и без `UserDefaults`.
4. Все ошибки репозитория ловить и показывать: `store.showError(error)` или встроенное состояние экрана. Никаких `try!`, `fatalError`, force-unwrap опциональных данных.
5. Доступность: у иконок-кнопок `accessibilityLabel`, зоны нажатия ≥ 44 pt, Dynamic Type не ломает вёрстку (`lineLimit`, `minimumScaleFactor` где нужно), уважать `accessibilityReduceMotion` для анимаций.
6. Каждый экран: состояния loading / empty / error, предпросмотры `#Preview` не нужны (нет данных).
7. Компиляция: НЕ запускай `xcodebuild` и `xcodegen` (общий проект). Проверка типов только своих файлов вместе с фундаментом:
   ```
   cd /Users/anas/Desktop/loKEY-iOS && SDK=$(xcrun --sdk iphonesimulator --show-sdk-path) && xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.0-simulator -swift-version 5 loKEY/Contract/*.swift loKEY/Domain/*.swift loKEY/DesignSystem/*.swift loKEY/App/AppStore.swift loKEY/App/Router.swift loKEY/App/WidgetSync.swift <ТВОИ ФАЙЛЫ>
   ```
   (Файлы с `NewCase/`, `Features/` других агентов в команду не включай.) Исправь все `error`.
8. Тексты на русском, как в макетах. Дополнительные (не нарисованные) состояния оформляй в том же стиле.
9. Не добавляй зависимости, не меняй `project.yml` (кроме агента D для виджетов).
