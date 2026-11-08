# Структура бази метаданих конфігуратора

## 1. Фізична база

Початкове сховище — окремий файл `trade-configurator.sqlite`. Схема змінюється лише міграціями. UUID зберігаються у переносному текстовому форматі, час — UTC.

Універсальність цієї БД допустима лише для design-time метаданих. Вона не замінює типізовані таблиці робочої системи Trade.

## 2. Ядро та ревізії

### Спільний контракт назв

Кожна іменована сутність має `technical_name` англійською та `display_name_uk` українською. Для операторського пошуку application-сервіс зберігає тільки `display_name_uk_normalized`. UUID залишається єдиною фактичною ідентичністю.

`technical_name` використовується для Java/API/YAML і як джерело для
детермінованого фізичного імені БД, показується тільки в картці й після першого
погодження не змінюється. Воно не підставляється у SQL безпосередньо. Правила
префіксів, `snake_case` і довжини визначені в
`CONFIGURATOR_NAMING_AND_UI_UK.md`. Українська назва є основною в UI та може
змінюватися контрольованою командою зі збереженням попереднього значення як
український alias.

### `cfg_project`

| Колонка | Призначення |
|---|---|
| `id` | UUID проєкту |
| `technical_name` | стабільне англійське ім'я |
| `display_name_uk` | українська назва конфігурації |
| `display_name_uk_normalized` | нормалізований пошук |
| `description_uk` | український опис |
| `created_at/by`, `updated_at/by` | аудит |

### `cfg_object`

| Колонка | Призначення |
|---|---|
| `id` | стабільний UUID об'єкта |
| `project_id` | FK на проєкт |
| `technical_name` | англійське ім'я об'єкта |
| `display_name_uk` | українська операційна назва |
| `display_name_uk_normalized` | пошукове значення |
| `object_key` | наприклад `Catalog.Counterparty` |
| `object_kind` | `CATALOG`, `DOCUMENT`, `INFORMATION_REGISTER`, `BALANCE_REGISTER` |
| `lifecycle_state` | `ACTIVE`, `ARCHIVED`, `DELETED_DRAFT` |
| `lifecycle_changed_at/by` | аудит архівування, видалення або відновлення |
| `created_at/by` | аудит |

`DELETED_DRAFT` використовується лише для об'єкта без погодженої історії та
дозволяє відновлення з кошика. Якщо існує `AGREED` або `IMPLEMENTED`, об'єкт
переходить в `ARCHIVED` і фізично не видаляється. Архів і кошик не потрапляють
до активного дерева, picker, пошуку та AI resolver, але імена залишаються
зарезервованими для безпеки історичних контрактів.

Унікальність: `(project_id, object_key)`, `(project_id, object_kind, technical_name)` і `(project_id, object_kind, display_name_uk_normalized)`.

### `cfg_object_alias`

Під час контрольованого перейменування попередня українська назва автоматично
стає активним alias у тій самій транзакції. Повернення до попередньої назви
деактивує однойменний alias поточного об'єкта.
`id`, `object_id`, `alias_uk`, `alias_uk_normalized`, `is_active`, `created_at/by`.

Alias у межах проєкту й виду не може неоднозначно вказувати на різні активні об'єкти.

### `cfg_object_revision`

| Колонка | Призначення |
|---|---|
| `id` | UUID ревізії |
| `object_id` | FK на стабільний об'єкт |
| `revision_no` | послідовний номер |
| `status` | `DRAFT`, `AGREED`, `IMPLEMENTED` |
| `technical_name_snapshot` | англійське ім'я на момент ревізії |
| `display_name_uk_snapshot` | українська назва на момент ревізії |
| `class_name`, `id_class_name` | технічні імена |
| `table_name`, `api_path` | цільові імена |
| `purpose` | бізнес-призначення |
| `business_logic_description` | загальний Markdown-опис |
| `based_on_revision_id` | ревізія-джерело копії |
| `blueprint_version` | версія автоматичного каркаса системних папок і форм |
| `version` | optimistic locking |
| `main_menu_section_id` | обов'язковий FK на елемент системного довідника `cfg_main_menu_section` |
| аудит і погодження | автори та UTC-час |

Унікальність: `(object_id, revision_no)`. Зміни дозволені лише для `DRAFT`.

### `cfg_main_menu_section`

Системний довідник описує розділи головного меню робочого JavaFX-клієнта. Це нормалізована таблиця, а не Java enum і не довільний JSON.

| Колонка | Призначення |
|---|---|
| `id` | стабільний UUID елемента |
| `project_id` | FK на конфігурацію |
| `technical_name` | англійське службове ім'я для коду та експорту |
| `display_name_uk` | українська назва в UI |
| `display_name_uk_normalized` | нормалізована унікальна назва |
| `sort_order` | порядок у головному меню |
| `active` | доступність для нових паспортів |
| `is_system` | ознака початкового системного елемента |
| аудит | `created_at/by`, `updated_at/by` |

Після створення проєкту автоматично додаються `Catalogs / Довідники`, `Documents / Документи`, `Reports / Звіти`, `Settings / Налаштування`. Новий довідник типово потрапляє в `Довідники`, документ — у `Документи`, обидва види регістрів — у `Звіти`. Оператор може змінити вибір у картці об'єкта або паспорті через стандартне поле-посилання. Елемент меню обирається за українською назвою; технічне ім'я залишається доступним у даних і експорті.

В експорті разом із посиланням фіксується `targetFormKind: LIST`: натискання команди об'єкта в головному меню відкриває форму списку, а не картку елемента.


## 3. Окремі паспорти видів

Кожна ревізія має рівно один запис у таблиці свого виду:

- `cfg_catalog_passport`;
- `cfg_document_passport`;
- `cfg_balance_register_passport`;
- `cfg_information_register_passport`.

Їхні поля визначені у відповідних документах паспортів. Domain validator перевіряє відповідність `object_kind`.

## 4. Структура реквізитів

### `cfg_table_part`

`id`, `revision_id`, `technical_name`, `display_name_uk`, `display_name_uk_normalized`, `line_class_name`, `table_name`, `sort_order`, `description_uk`.

Унікальність технічної назви в межах ревізії.

### `cfg_field`

Єдина таблиця описує поля об'єкта, шапки, регістру і табличних частин:

| Група | Колонки |
|---|---|
| власник | `revision_id`, nullable `table_part_id`, `field_path`, `lineage_id` |
| походження | `origin`, nullable `system_key`, `ui_policy` |
| назви | `technical_name`, `display_name_uk`, `display_name_uk_normalized`, `description_uk` |
| роль | `field_role`: `ATTRIBUTE`, `HEADER`, `DIMENSION`, `RESOURCE` |
| тип | `data_type`, `length`, `precision`, `scale`, `date_time_precision`, `time_zone_policy` |
| значення | `required`, `default_description`, `editable` |
`lineage_id` є стабільною ідентичністю логічного реквізиту між ревізіями.
При клонуванні ревізії `id` реквізиту змінюється, а `lineage_id` зберігається;
це дозволяє заборонити зміну technical name після першого погодження.

| посилання | nullable `reference_target_object_id`, `archive_policy`, `delete_policy` |
| розрахунок | `value_kind`, `storage_kind`, `manual_override_policy` |
| UI default | `component_type`, `format_pattern` |
| порядок | `sort_order` |

`field_path` унікальний у ревізії: `client`, `goods.product`, `goods.amount`.

`origin`: `SYSTEM` або `USER`. Blueprint автоматично створює system fields із `SYSTEM_FIELDS_UK.md`. Унікальність `system_key` діє в межах відповідного owner.

### `cfg_field_alias`

`id`, `field_id`, `alias_uk`, `alias_uk_normalized`, `is_active`.

Попередня українська назва автоматично записується сюди під час перейменування.
Aliases копіюються до нової ревізії разом із lineage реквізиту та використовуються
операторським пошуком і AI resolver.

`value_kind`: `INPUT`, `CALCULATED`, `AGGREGATE_QUERY`.  
`storage_kind`: `STORED`, `TRANSIENT`, `READ_MODEL`.

`data_type` не є довільним текстом. Допустимі значення й контексти визначає `CONFIGURATOR_TYPE_SYSTEM_UK.md`. SQLite має CHECK constraint на закритий перелік.

## 5. UI

### `cfg_form`

`id`, `revision_id`, `form_kind`, `system_key`, `technical_name`, `display_name_uk`, `is_default`, `required`, `is_system`, `description_uk`.

Для довідника й документа application-сервіс автоматично створює три required/system форми: element/document, list і picker. Для реєстру залишків і реєстру відомостей створюється лише одна required/system форма списку. Повторна ініціалізація blueprint не створює дублікати `system_key`.

### `cfg_form_node`

Дерево форми:

`id`, `form_id`, nullable `parent_node_id`, `node_kind`, nullable `field_id`, nullable `table_part_id`, nullable `query_definition_id`, nullable `owned_catalog_table_definition_id`, nullable `object_command_id`, `technical_name`, `caption_uk`, `description_uk`, `orientation`, `width_mode`, `width_value`, `sort_order`, `read_only`, `visible`, nullable `spacing`, nullable `label_position`, `format_override`, `empty_text_uk`, `loading_text_uk`, `total_expression_uk`.

`node_kind` додатково містить `TOTAL`. Розширені presentation-властивості зберігаються типізованими колонками, а не JSON. `total_expression_uk` є описом для реалізації read model і не виконується конфігуратором як код.

Залежно від `node_kind` вузол може посилатися на реквізит, табличну частину, QueryTable, OwnedCatalogTable або object-команду; domain validator перевіряє рівно одну допустиму прив'язку.

### `cfg_query_table`

`id`, `revision_id`, `technical_name`, `display_name_uk`, `description_uk`, `query_name`, `permission_key`, `row_key_description`, `paging_policy`, `default_page_size`, `refresh_policy`, `sort_order`.

### `cfg_query_table_parameter`

`id`, `query_table_id`, `technical_name`, `data_type`, `source_kind`, nullable `source_field_id`, `required`, `default_description`, `sort_order`.

`source_kind`: `FORM_OBJECT_ID`, `FORM_FIELD`, `TABLE_FILTER`, `CURRENT_USER`, `FIXED_DESCRIPTION`.

### `cfg_query_table_column`

`id`, `query_table_id`, `technical_name`, `caption_uk`, `data_type`, nullable `reference_target_object_id`, `format_pattern`, `width_mode`, `width_value`, `alignment`, `sortable`, `filterable`, `calculated`, `calculation_description_uk`, `sort_order`.

### `cfg_query_table_action`

`id`, `query_table_id`, `technical_name`, `display_name_uk`, `action_kind`, `permission_key`, `description_uk`, `sort_order`.

QueryTable не має persistence table у цільовому Trade. Її визначення експортується агенту для реалізації application query, result DTO та JavaFX-компонента.

### `cfg_owned_catalog_table`

`id`, `revision_id`, `technical_name`, `display_name_uk`, `target_catalog_revision_id`, `owner_field_id`, `owner_source`, `require_persisted_owner`, `edit_mode`, `refresh_policy`, `sort_order`, `description_uk`.

Початкові фіксовані значення:

- `owner_source = FORM_OBJECT_ID`;
- `require_persisted_owner = true`;
- `edit_mode = CHILD_EDITOR`.

Команди й права беруться з паспорта цільового дочірнього довідника. `owner_field_id` є FK на реквізит конкретної цільової ревізії. Конфігуратор перевіряє, що поле є обов'язковим owner-посиланням і його target type відповідає типу об'єкта форми.

## 6. Події та команди

### `cfg_field_event`

`id`, `field_id`, `event_type`, `handler_mode`, nullable `handler_name`, `description`, nullable `query_name`, nullable `command_name`.

`event_type`: `INPUT_STARTED`, `INPUT_COMMITTED`.  
`handler_mode`: `STANDARD`, `CUSTOM`, `DISABLED`. Для кожного поля мають існувати обидва записи.

### `cfg_object_command`

`id`, `revision_id`, `command_type`, `technical_name`, `display_name_uk`, `description_uk`, `permission_key`, `sort_order`, `is_system`.

### `cfg_command_contract`

`command_id`, `allowed_statuses`, `result_contract_uk`, `error_contract_uk`.

`allowed_statuses` застосовується тільки до документа. Для користувацької команди result/error contracts обов'язкові; системні команди можуть використовувати стандартний контракт майбутньої runtime-бібліотеки.

Типи включають `NEW`, `SAVE`, `POST`, `UNPOST`, `ARCHIVE`, `RESTORE`, `COPY` та специфічні команди.

### `cfg_document_status`

`id`, `document_revision_id`, `technical_name`, `display_name_uk`, `is_initial`, `is_posted`, `sort_order`, `description_uk`.

### `cfg_document_transition`

`id`, `document_revision_id`, `from_status_id`, `object_command_id`, `to_status_id`, `condition_description`, `header_editable`, `lines_editable`.

Статуси й переходи існують лише для ревізії документа. Має бути рівно один initial status.

## 7. Бізнес-правила

### `cfg_business_rule`

`id`, `revision_id`, nullable `result_field_id`, `rule_kind`, `technical_name`, `display_name_uk`, `description_markdown_uk`, `trigger_description_uk`, `algorithm_markdown_uk`, `rounding_mode`, `manual_override_policy`, `persistence_policy`, `error_policy`, `sort_order`.

`rule_kind`: `VALIDATION`, `CALCULATION`, `DEFAULT_VALUE`, `STATE_TRANSITION`, `POSTING`, `ACCESS`.

### `cfg_rule_dependency`

`rule_id`, `source_field_id`, `sort_order`.

### `cfg_rule_example`

`id`, `rule_id`, `title`, `input_markdown`, `expected_markdown`, `sort_order`.

Опис не виконується конфігуратором як код. Він експортується агенту і перевіряється на структурну повноту.

## 8. Залежності, права і рухи

### `cfg_object_dependency`

`id`, `source_revision_id`, `target_object_id`, `dependency_kind`, `required`, `blocking`, `description_uk`.

У таблиці зберігаються явні залежності. Залежності `REFERENCE`, `MOVEMENT`, `OWNED_CATALOG` і `BUSINESS_RULE` також обчислюються з типізованих метаданих та не дублюються обов'язково окремим рядком. `blocking` означає, що несумісну зміну треба показати користувачу до збереження.

### `cfg_register_recorder`

`id`, `register_revision_id`, `document_object_id`, `required_movement_mapping`, `description`.

Для independent інформаційного регістру список реєстраторів має бути порожнім.

### `cfg_permission`

`id`, `revision_id`, `permission_key`, `action_kind`, `description_uk`, `is_system`.

Закритий перелік `action_kind`: `READ`, `CREATE`, `UPDATE`, `ARCHIVE`, `POST`, `UNPOST`. Ключ унікальний у межах ревізії; команда може посилатися лише на ключ тієї самої ревізії.

### `cfg_document_movement`

`id`, `document_revision_id`, `register_object_id`, `table_part_id`, `movement_kind`, `description`, `sort_order`.

### `cfg_movement_mapping`

`id`, `movement_id`, `target_register_field_key`, `source_field_path`, `expression_description`, `sort_order`.

## 9. Експорт і реалізація

### `cfg_export`

`id`, `revision_id`, `export_schema_version`, `created_at/by`, `directory`, `revision_hash`.

### `cfg_implementation_report`

`id`, `revision_id`, `status`, `source_revision_hash`, `git_commit`, `report_markdown`, `verified_at/by`.

Статус `IMPLEMENTED` дозволений тільки після перевіреного звіту, що посилається на той самий hash погодженої ревізії.

### `cfg_implementation_report_import`

Зберігає кожну спробу структурованого імпорту: версії report/export schema,
`source_revision_hash`, commit, загальний стан, український підсумок, JSON-переліки
артефактів і checklist, шлях до файла, ознаку перевірки checksum та аудит імпорту.
Часткових звітів може бути декілька. Вони не змінюють стан погодженої ревізії.

Повний звіт додатково атомарно створює `cfg_implementation_report` і стан `IMPLEMENTED`.

### `cfg_ui_state`

Локальне key/value-сховище JSON-стану вікон конфігуратора. Поточний ключ
`main-window` зберігає розмір, пошук, вибір і розгорнуті вузли. Таблиця не є частиною
ревізії паспорта та не потрапляє до export package.

## 10. Ключові обмеження

- FK використовують `RESTRICT` для погоджених ревізій;
- у кожного поля рівно один власник: ревізія або її таблична частина;
- system fields відповідають blueprint виду й не можуть бути видалені;
- `object_kind` і `data_type` відповідають закритій системі десяти типів;
- вузол форми має тільки сумісну зі своїм видом прив'язку;
- `QUERY_TABLE` form node посилається на `cfg_query_table` і завжди read-only;
- `OWNED_CATALOG_TABLE` form node посилається на `cfg_owned_catalog_table`;
- mutation через OwnedCatalogTable заборонена для незбереженого owner;
- reference-поле обов'язково має `reference_target_object_id`;
- кожна іменована сутність має валідні англійське technical name та українську display name;
- name resolver не виконує mutation за неоднозначною назвою;
- non-reference поле не може мати цільове посилання;
- у погодженій ревізії заборонені UPDATE/DELETE application-рівнем;
- експорт створюється лише після domain/application-валідації всієї ревізії;
- база не містить виконуваних Java/SQL-скриптів бізнес-логіки.
- документ має рівно один початковий статус і валідний граф переходів;
- recorder-managed регістр має щонайменше одного допустимого реєстратора.
- required/system форми відповідають blueprint виду об'єкта й не можуть бути видалені;

## 11. Каркас системи та реліз конфігурації

### `cfg_framework_revision`

Зберігає незалежні ревізії глобального каркаса: `id`, `revision_no`, `status`,
`version`, аудит, `based_on_revision_id` і дані погодження. Одночасно може
існувати лише одна DRAFT-ревізія. AGREED-ревізія незмінна.

### `cfg_framework_rule`

Правило належить одній ревізії каркаса і має категорію `ARCHITECTURE`,
`SERVER_CONTRACT`, `UI_COMPONENT`, `OBJECT_BLUEPRINT` або `QUALITY`, англійське
technical name, українську назву, опис, повний Markdown правила, обов'язковість
і порядок. Саме ці записи, а не файли `docs/ui`, є джерелом глобальних правил
після погодження каркаса.

### `cfg_configuration_release`

Незмінний реліз фіксує `framework_revision_id`, номер, каталог експорту,
SHA-256 і версію схеми. `cfg_configuration_release_object` містить точні UUID
ревізій усіх включених паспортів. Реліз дозволений лише для погодженого каркаса
та погоджених валідних паспортів.

Експорт містить `manifest.json`, `framework.json`, `FRAMEWORK_RULES_UK.md`,
окремі файли правил, паспорти об'єктів, dependency graph, checklist і checksums.
