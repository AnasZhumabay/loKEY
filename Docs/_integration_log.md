# Интеграция 1.3.0 — журнал

## Исправления
- Features/Editor/CropView.swift: enum CropMath переименован в CropRectMath (конфликт с struct CropMath).
- Features/Backup/BackupSettingsView.swift: неявный `catch { error = ... }` ронял компилятор (краш Swift 6.4, тень @State error); заменён на `catch let other`.
- Core/Chat/ChatRepositoryImpl.swift: реализован ChatKeyAgreement.sharedSecret(withContact:) (X25519 + HKDF с меткой lokey.shared-case.dh.v1).
- App/LoKEYApp.swift: в мок-режиме DemoSharedCaseAPI(MockSharedCaseAPI) + LazyDemoKeyAgreement; в живом — SharedCaseServiceImpl с агентом = ChatRepositoryImpl.
- Core/Backend/MockBackendV13.swift, Core/Shared/DemoSharedCaseAPI.swift: `me` читается лениво (meProvider), т.к. id аккаунта известен после входа; старые init сохранены.
- Core/Shared/SharedCaseWrap.swift: LazyDemoKeyAgreement.
- Domain/Reminders.swift, Core/Reminders/ReminderServiceImpl.swift: clearAll() и setSuspended(_:) (по умолчанию no-op в extension); в приманке list/scan/add/remove пусты, уведомления сняты.
- App/AppStore.swift: signOut -> reminders.clearAll; enterDuress -> setSuspended(true); didSignIn -> setSuspended(false).
- Features/Chat/ChatListView.swift: кнопка «Назад» только если router.path не пуст.
- Resources/{en,kk}.lproj/Localizable.strings: добавлено 219 (en) / 221 (kk) ключей из Docs/_strings; plutil OK.

## Тесты изменены
- loKEYTests/SharedCaseTests.swift: `await` внутри XCTAssertEqual автозамыкания не компилируется; значение вынесено в let (логика не изменена).

## Замечания
- a11y-id отдельно не добавлялись (новых экранов без id не выявлено; не проверялось построчно).

## UI-тесты
- loKEYUITests/ChatUITests.swift: вход в чаты теперь через вкладку `chatsTab` (на главной кнопки «Сообщения» больше нет). После правки тест доходит до экрана добавления контакта, но FAIL на строке 18: кнопка с label «Алиса» (демо-блок AddContactView) не найдена. Причина не выяснена (возможно, демо-блок скрыт/название контакта в label иное после редизайна). WalkthroughUITests не запускался.

## Исправления по проверке Opus
1. Приманка: флаг `decoy.state` в Keychain (VaultRepositoryImpl). Перезапуск при «active» сразу поднимает приманку (restoreSession возвращает аккаунт-заглушку, offlineSnapshot/кэш/чаты не читаются; AppStore.bootstrap). Выход из приманки ставит «exited»: настоящая сессия и данные не стираются, но тихо не восстанавливаются, пока не будет настоящего входа (login/register/verifyMFA снимают флаг).
2. AppStore.signOut в приманке не вызывает reminders.clearAll и clearLocalPersistence.
3. VaultRepository.isDecoy (additive, default false); BackupServiceImpl в приманке: list = [], lastBackupDate = nil, create/restore/delete = BackupError.unavailable, setAutoBackup no-op.
4. SharedCaseServiceImpl в приманке: pendingInvites/members/joinedCaseIds = [], invite/accept/revoke/leave = notReady.
5. Тексты PanicSettings/Unlock и блок ограничений переписаны честно (перезапуск, PIN на экране со списком, код-пароль устройства); en/kk обновлены.
6. accept: кейс с таким id уже свой (не присоединённый) = отказ без попытки; новая `unlockSharedCase(id:secret:)` не считает попытки/не стирает ключ.
7. FileHistoryStore.load пропускает битый/чужой файл вместо throw; остальные грузятся, пропущенные не перезаписываются.
8. expireDue вызывается из таймера AppStore (вместе с sync) и при уходе в фон.
9. Ключ-файл другого кейса или невалидный = invalidKeyFormat без попытки.
10. demoBlock получил accessibilityIdentifier("demoContactButton"), ChatUITests ищет по id. Причина прежнего падения: поиск по label зависит от языка. Фактически при `-language ru` приложение показывало русский (скриншот); отдельной ошибки выбора языка не найдено. ChatUITests: PASS (47 с).
11. Убраны force-unwrap (AddContactView, ChatRepositoryImpl x3, ChatView, ChatCrypto); UI не использует DuressPIN/BackupArchive: новый Domain/SecurityRules; ChatError в Label через tr().
12. KeyStore.write(policy:): новая запись сначала под временным именем, старая удаляется только после успеха. Подпись про снятие код-пароля в Settings (Face ID) и в PanicSettings.
13. Комментарий в Domain/Chat.swift исправлен (vault.key.device).

Тесты: loKEYTests/OpusFixesTests.swift (7 новых), SeamsTests.testHistoryTamperAndWrongKey обновлён (теперь ожидается пропуск битого файла, а не throw: пункт 7). Итого 140 тестов, 0 упали.
Примечание: xcodebuild часто виснет («runner hung»); помогло `simctl shutdown all` + `simctl erase` симулятора.

## Финальный прогон
- Юнит-тесты: 144/144 зелёные (первый запуск завис «runner hung», после `simctl shutdown/erase` прошёл).
- ChatUITests: PASS (вход через карточку «Сообщения», id `chatStripButton` добавлен в HomeView).
- WalkthroughUITests: PASS (запуск с `-lokeyShowOnboarding`, id онбординга, прокрутка к карточке кейса; если ввод в SecureField не сработал, перезапуск с `-lokeyDemoLogin`).
- OnboardingUITests: PASS (2/2).
- Замечание: UI-тесты надёжны только на чистом симуляторе (`simctl erase`): сохранённая демо-сессия и язык в Prefs ломают сценарии.
- Красного не осталось.
