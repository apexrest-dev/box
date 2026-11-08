# Завдання MVP конфігуратора

## 1. Мета

Локальний JavaFX-конфігуратор створює повний паспорт довідника, документа або
регістру, перевіряє й погоджує його та експортує специфікацію агенту.
Конфігуратор не генерує і не виконує runtime-код Trade.

## 2. Реалізований фундамент

- [x] JavaFX без FXML, SQLite, JDBC repository port і application service.
- [x] Міграції V001–V024 та дерево чотирьох видів метаоб'єктів.
- [x] Автоматичні системні поля, форми, команди й початкові статуси.
- [x] Реквізити, виміри, ресурси, табличні частини та структурний редактор форм.

## 3. Модель реквізиту

- [x] Domain/application/persistence/UI для довжини строки, precision/scale числа й формату.
- [x] Default description, `INPUT/CALCULATED/AGGREGATE_QUERY`.
- [x] `STORED/TRANSIENT/READ_MODEL` і перевірка сумісності властивостей із типом.
- [x] Типізована ціль посилання та archive/delete policy.

## 4. Події введення

- [x] Автоматичні `INPUT_STARTED` та `INPUT_COMMITTED`.
- [x] `STANDARD/CUSTOM/DISABLED`, command name, `FIELD/ROW/OBJECT`.
- [x] Error/focus policy та заборона mutation-подій read-only системних полів.
- [x] Окремий редактор подій у картці реквізиту.

## 5. Бізнес-правила

- [x] `cfg_business_rule`, dependencies та examples.
- [x] Validation, calculation, default value, access, transition і posting.
- [x] Trigger, algorithm, rounding, manual override і вид зберігання результату.
- [x] Контрольний приклад для розрахункового правила.
- [x] Markdown-опис є специфікацією і ніколи не виконується як код.

## 6. Мінімальні паспорти чотирьох видів

- [x] Довідник: ієрархія, автоматичні parent/owner, автонумерація, ручне редагування коду, видалення й базові команди.
- [x] Документ: номер, точність дати, підстава, copy policy, статусна редагованість і додаткові команди.
- [x] Реєстр залишків: movement model, negative balance, totals, snapshots, recalculation і реєстратори.
- [x] Регістр відомостей: periodicity, write mode, precision, unique key і latest slice.

## 7. Проведення та рухи

- [x] Definitions рухів, цільовий регістр і таблична частина-джерело.
- [x] Mapping усіх вимірів і ресурсів із перевіркою повноти.
- [x] Period, recorder, lineNumber, sign, condition, repost та unpost policy.

## 8. Спеціальні UI-таблиці

- [x] `QUERY_TABLE`: parameters, columns, actions, paging, refresh і типізований binding.
- [x] `OWNED_CATALOG_TABLE`: target catalog, owner field, persisted owner policy та дії.
- [x] Обидва види доступні в редакторі JavaFX-форми.

## 9. Валідація паспорта

- [x] Єдине вікно помилок із переходом до вузла дерева.
- [x] Системні поля, required forms і required UI bindings.
- [x] Події, статуси, команди, переходи, регістри, рухи, залежності й бізнес-правила.
- [x] Погодження заборонене за наявності blocking errors.

## 10. Ревізії та експорт

- [x] `DRAFT -> AGREED`; погоджена ревізія незмінна.
- [x] Новий DRAFT повністю копіюється з AGREED із новими UUID та відновленими binding.
- [x] `passport.yaml`, `passport.md`, `implementation-task.md`.
- [x] `manifest.json` з UUID, schema version і SHA-256.
- [x] Експортується лише валідна AGREED-ревізія.

## 11. Technical name

- [x] Порт `TechnicalNameGenerator` і локальний генератор пропозиції.
- [x] Повторна генерація, ручне виправлення й ручний fallback.
- [x] Перевірка формату та унікальності перед записом.

## 12. Тести й критерій готовності

- [x] Чиста SQLite та upgrade V001→V012.
- [x] Integration-тести кожного виду паспорта й blocking validators.
- [x] Повний сценарій create → fill → validate → agree → export.
- [x] Фінальний запуск Maven на JDK 21: 2026-11-03, Temurin 21.0.13, 51 тест пройдено.

Проєкт використовує локальну JDK із `.tools/jdk-21`, яку BAT-файли підключають
лише на час запуску Trade. Глобальні `JAVA_HOME` і `PATH` не змінюються.
