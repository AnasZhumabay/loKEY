# Виджеты и Live Activity

1. App Group `group.com.anasjumabay.lokey` включён у приложения и расширения `loKEYWidgets` (entitlements генерирует XcodeGen из `project.yml`).
2. `loKEY/Shared/LoKEYShared.swift` компилируется в оба таргета: `WidgetSnapshot` (Codable) и `LoKEYTimerAttributes` (ActivityKit).
3. `AppStore.refreshCases()` и `tick()` вызывают `WidgetSync.publish(...)`: снимок (открыто/всего, названия, если не скрыты, уровни, занятое место, секунды до автоблокировки) пишется в `UserDefaults(suiteName:)`.
4. `reloadAllTimelines()` вызывается не чаще раза в 5 с (при частых вызовах работает один отложенный «хвостовой» вызов).
5. Названия кейсов в снимок не попадают, если включено «Скрывать названия в виджетах». Файлов и превью в снимке нет вообще.
6. Виджеты (`loKEYWidgets/LoKEYWidgets.swift`): малый «N / M кейса открыты», малый «Закрыть все» (только вид), средний «кейсы» (две плитки с цветной полосой уровня и объёмом).
7. `LiveActivityController.sync` запускает `Activity<LoKEYTimerAttributes>`, только если открыт ≥1 кейс и есть таймер; обновляет не чаще раза в 10 с; завершает, когда всё закрыто. Ошибки глушатся.
8. Обратный отсчёт в Live Activity и виджете рисует система (`Text(timerInterval:)`), поэтому секундных обновлений не нужно; цвет меняется на оранжевый при ≤30 с на ближайшем обновлении.
9. Нужны: `NSSupportsLiveActivities = YES` (уже в project.yml), включённые Live Activities в настройках iOS.
10. Проверка: запустить на симуляторе, открыть кейс, добавить виджет на главный экран; после `xcodegen generate` проверить, что entitlements подцепились обоими таргетами.
