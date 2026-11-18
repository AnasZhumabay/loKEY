# i18n sweep (Text с String / интерполяцией)

## Что изменено
- Новый хелпер `trf(_:_:)` и `LKBundle.uiLocale` в DesignSystem/Localization.swift.
- Интерполированные русские строки: `Text(verbatim: trf("… %@ / %lld …", …))`, toasts, accessibilityLabel, confirmationDialog, Button, Label (около 75 мест в Features/DesignSystem).
- 56 мест: `tr(...)` вокруг String-аргументов Label/Button/accessibilityLabel/Hint/Value/alert/confirmationDialog (тернарии, `title`-свойства, ошибки).
- Даты/относительное время: `Locale(identifier: "ru_RU")` заменён на `LKBundle.uiLocale` (Inbox, Sessions, Plans, Versions, Trash, CaseView, Journal, ChatList, Chat); `static let`-форматтеры стали вычисляемыми.
- Склонение «файл/файла/файлов»: слово прогоняется через `tr` (en: file/files, kk: файл).
- Localizable.strings: en +268, kk +269 ключей (формат-ключи с %@/%lld, весь редактор/сканер/входящие/доступ к кейсу, которые раньше не имели переводов).

## Не проверено
- Всё, что видно только на устройстве/симуляторе с языком en/kk (разметка длинных строк).
- Виджеты и Share extension (loKEYWidgets/LoKEYWidgets.swift, loKEYShare/*): своих Localizable нет, тексты только русские (в т.ч. «Открыто кейсов %d из %d», «1 ГБ», «Файл больше N МБ»). Вне моей зоны.
- Core/Domain/Shared (вне зоны): тексты ошибок Models.swift:149, InboxStore.swift:22-27, Backup.swift:57 (`tr` с интерполяцией внутри ключа не сработает), ChatRepositoryImpl.swift:217 (системные строки «Исчезающие сообщения: …»), DemoContent/Mock*.
- Генерируемые имена файлов: «Снимок …», «Фото …», «… (ред.)», «Скан …» (CaseView, EditorModel, ScanEngine) оставлены русскими, чтобы не менять данные; ScanEngine/PDFPageRenderer форматтеры дат остались ru_RU.
- Множественные числа: en/kk упрощены (`%lld files`, «1 files» возможно в местах с общим ключом); kk-переводы требуют проверки носителем.
- Русская локаль: `LKBundle.forceBase` возвращает ключ как есть, `trf` в ru работает через String(format:).
