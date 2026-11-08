# Паспорт інформаційного регістру «Штрихкоди номенклатури»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувача
  перед реалізацією.
- Ревізія: `r3`.
- Розділ основного меню: `НСІ та адміністрування` (група «Номенклатура»); також
  вкладка «Штрихкоди» форми номенклатури (сторінка 21).
- Залежності: `RefProduct` r3, `RefUnitOfMeasure` (дробність `unitQuantity`).
- Використовують: форми всіх документів з табличною частиною «Товари» (сканування),
  `RefProduct` r3 (`LookupProduct`, форма вибору).
- Аналог у 1С:УТ 11: РегистрСведений.ШтрихкодыНоменклатуры.
- Функції каталогу: `F-NSI-04` (артикул і штрихкоди), `F-SRV-02` (підбір — пошук за
  штрихкодом).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Штрихкоди номенклатури |
| Технічне ім'я | `RegBarcode` |
| Технічний ключ | `Register.Barcode` |
| Вид | інформаційний регістр, `NON_PERIODIC`, `INDEPENDENT` |
| Доменний клас запису / ID-клас | `BarcodeRecord` / `BarcodeRecordId` |
| Таблиця БД | `reg_barcode` |
| DTO | `BarcodeRecordDto`, `BarcodeLookupResultDto` |
| Базовий API | `/api/v1/registers/barcodes` |
| APEX сторінки | 190 (єдина форма списку з редагуванням); QueryTable на сторінці 21 |
| PL/SQL | `trade_nsi.save_barcode`, `trade_nsi.delete_barcode`, `trade_nsi.lookup_barcode`, `trade_nsi.ean13_valid` |

Регістр зіставляє штрихкод (EAN-13, EAN-8, Code128, внутрішній) з номенклатурою та
кількістю одиниць товару в упаковці, яку позначає цей код. Один товар може мати
багато штрихкодів (штука, блок 6 шт, ящик 24 шт); один штрихкод належить рівно одному
товару.

- Періодичність: `NON_PERIODIC` — історія значень не зберігається, лише аудит.
- Режим запису: `INDEPENDENT` — записи створюються/змінюються/видаляються користувачем
  через типізовані команди з форми списку; реєстраторів немає.
- Вид видалення: фізичне `DELETE` запису з обов'язковим аудитом (стан запису не
  ведеться).

### 2. Поля

| Поле (camelCase) | Роль | Назва | Тип | Розмір/точність | Обов'язкове | Default | Редагованість | Посилання | БД колонка/індекс |
|---|---|---|---|---|---|---|---|---|---|
| `id` | системне | ID запису | UUID | 32 hex | так | `rawtohex(sys_guid())` | ні | — | `id`, PK |
| `barcode` | **вимір** | Штрихкод | String | 1–64 | так | — | так | — | `barcode varchar2(64)`, UNIQUE `reg_barcode_uk` |
| `productId` | ресурс | Номенклатура | reference | UUID | так | товар з контексту (сторінка 21) | так | `RefProduct` | `product_id varchar2(32)`, FK, index `reg_barcode_prd_ix` |
| `unitQuantity` | ресурс | Кількість в упаковці | Number | 19,3 | так | `1` | так | — | `unit_quantity number(19,3)`, CHECK > 0 |
| `version` | системне | Версія | Long | — | так | `0` | ні | — | `version` |
| `createdAt` / `createdBy` | системне | Створено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `created_at`, `created_by` |
| `updatedAt` / `updatedBy` | системне | Змінено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `updated_at`, `updated_by` |

Правила полів:

- `barcode`: перед перевіркою видаляються пробіли, табуляції та символи переносу
  (сканер часто додає `CR/LF`); дозволені друковані ASCII `0x21–0x7E`; регістр літер
  зберігається, порівняння точне (case-sensitive), бо Code128 розрізняє регістр.
- Якщо `barcode` складається рівно з 13 цифр — обов'язкова перевірка контрольної
  цифри EAN-13 (§8). Інші довжини (8, 12, 14 цифр, алфавітні коди) записуються без
  перевірки контрольної цифри.
- `productId`: для нового або зміненого запису — лише `ACTIVE` товар. Дозволені обидва
  види (`GOODS` і `SERVICE` — наприклад, штрихкод подарункової упаковки-послуги).
  Записи поміченого товару зберігаються.
- `unitQuantity`: > 0, scale 3 `HALF_UP`; якщо одиниця виміру товару не дозволяє
  дробову кількість (`fractional = 'N'`), значення має бути цілим.

### 3. Виміри, ресурси й ключ

- Ключ регістру (`NON_PERIODIC`): `barcode` — глобально унікальний.
- Ресурси: `productId`, `unitQuantity`.
- Додатковий неунікальний індекс `product_id` — для вкладки «Штрихкоди» товару й
  копіювання.
- Унікальність пари `productId + unitQuantity` **не** вимагається (у товару може бути
  два коди на одну штуку від різних виробників).

### 4. Стани, інваріанти та типізовані команди

1. `barcode` після нормалізації 1–64 символи, лише `0x21–0x7E`, глобально унікальний.
2. 13 цифр ⇒ коректна контрольна цифра EAN-13.
3. `productId` існує; для нових/змінених значень — `ACTIVE`.
4. `unitQuantity > 0`; для недробової одиниці — ціле.
5. Будь-яка зміна (створення, зміна, видалення) пишеться в `sys_audit_log`.
6. Повторний запис того самого `barcode` іншим записом — помилка, а не перезапис
   (немає неявного «upsert»).

Команди: `InitializeBarcodeRecord(productId?)` (NEW), `CreateBarcodeRecord`,
`UpdateBarcodeRecord` (SAVE), `DeleteBarcodeRecord` (DELETE); queries
`ListBarcodes`, `LookupBarcode(barcode)`.

## БЛОК B. UI

### 5. Форма списку (сторінка 190)

Єдина системна форма (`INFORMATION_REGISTER_PASSPORT_UK.md`). Окремих форм запису й
вибору немає; редагування — рядок Interactive Grid або modal-діалог рядка, обидва
викликають ті самі серверні команди.

```text
FORM barcodeList
HEADER
  title «Штрихкоди номенклатури»
  filters: product (ReferenceField RefProduct), barcode (містить), productGroup (tree), withMarkedProducts
  commands: Створити (Insert) | Змінити (F2) | Видалити (Del) | Скопіювати (F9) | Оновити | Пошук (Ctrl+F) | Експорт CSV
CONTENT
  IG: barcode[30] | barcodeType[10] | product.code[12] | product[33] | unitQuantity[10] | unitOfMeasure[8] | updatedAt[12] | updatedBy[12]
FOOTER
  «Записів: N»
```

- `barcodeType` — розрахункова колонка для читання: `EAN-13`, `EAN-8`, `UPC-A`, `ITF-14`,
  `Інший`.
- Сортування: `product.name ASC, unitQuantity ASC, barcode ASC`.
- Поле фільтра `barcode` приймає ввід сканера: `Enter` у ньому шукає точний збіг і
  виділяє рядок.
- `F9` копіює рядок з порожнім штрихкодом (для упаковки того самого товару).
- `Delete` — підтвердження «Видалити штрихкод 4820000000017 товару «Вода 1,5 л»?
  Дію не можна скасувати.» Право `register.barcode.delete`.
- Для поміченого товару рядок закреслений; редагування дозволене лише видаленням.
- Вкладка «Штрихкоди» сторінки 21 — та сама логіка з фільтром `product` = поточний
  товар і прихованими колонками товару.

#### 5.1. Сканування в документах (обов'язкова поведінка форм документів r3)

Над табличною частиною «Товари» кожного документа є поле `scanInput[25]`
(«Штрихкод», фокус `Ctrl+Shift+B`). Сканер працює як клавіатура й завершує ввід `Enter`.

1. UI надсилає `LookupBarcode(barcode)`; ввід не очищується до відповіді.
2. Не знайдено → повідомлення `BARCODE_NOT_FOUND`, поле виділяється, фокус лишається;
   кнопка «Знайти товар» відкриває форму вибору з текстом як пошуком.
3. Знайдено, але товар `MARKED_FOR_DELETION` → `PRODUCT_NOT_ACTIVE`.
4. Знайдено `SERVICE` у складському документі → `PRODUCT_SERVICE_NOT_ALLOWED`.
5. Інакше документ виконує власну команду рядка `AddOrIncrementLineByBarcode(docId,
   productId, unitQuantity, expectedVersion)`: якщо є рядок з тим самим `productId` (і в
   документах з ціною — без ручної зміни ціни), його `quantity += unitQuantity`, інакше
   додається рядок `quantity = unitQuantity` з ціною за правилами документа.
6. Після успіху поле очищується, фокус повертається в `scanInput`, змінений рядок
   підсвічується.

### 6. Події введення

| Реквізит | Компонент | Початок | Завершення | Команда | Серверна реакція |
|---|---|---|---|---|---|
| `barcode` | TextField (scanner-friendly, моноширинний) | STANDARD | CUSTOM `onBarcodeCommitted`: нормалізація пробілів/CRLF, локальна перевірка EAN-13 | `CheckBarcode(id?, barcode)` (query) | повертає `normalized`, `barcodeType`, помилку `BARCODE_EAN13_CHECKSUM_INVALID` або `BARCODE_DUPLICATE` з власником |
| `productId` | ReferenceField `RefProduct` | STANDARD reference search (код, артикул, назва) | commit `ProductRef` | `Create/UpdateBarcodeRecord` | товар `ACTIVE`; повертає `unitOfMeasure.fractional` для перевірки кількості |
| `unitQuantity` | NumberField (scale 3) | STANDARD | STANDARD | `Create/UpdateBarcodeRecord` | > 0; ціле для недробової одиниці |
| `id`, `version`, аудит, `barcodeType` | — | DISABLED | DISABLED | — | — |
| `scanInput` (документи) | TextField | STANDARD | CUSTOM `onScanCommitted` (`Enter`) | `LookupBarcode` → `AddOrIncrementLineByBarcode` | див. §5.1 |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Помилки — `raise_application_error(-20100, '[КОД] повідомлення')`.

#### 7.1. NEW

`InitializeBarcodeRecord(productId?)`, право `register.barcode.create`. Повертає
`barcode=''`, `productId` (якщо переданий і `ACTIVE`), `unitQuantity=1`, `version=0`.

#### 7.2. SAVE

- `CreateBarcodeRecord(barcode, productId, unitQuantity, idempotencyKey)` —
  `register.barcode.create`.
- `UpdateBarcodeRecord(id, barcode, productId, unitQuantity, expectedVersion)` —
  `register.barcode.update`. Зміна самого `barcode` дозволена (виправлення помилки
  введення) і перевіряє унікальність нового значення.
- Транзакція: нормалізація → перевірки → insert/update → аудит. Порушення
  `reg_barcode_uk` при гонці перетворюється на `BARCODE_DUPLICATE`.

#### 7.3. DELETE

`DeleteBarcodeRecord(id, expectedVersion)`, право `register.barcode.delete`. Фізичне
видалення; документи зберігають `productId`, а не штрихкод, тож видалення не впливає
на документи й рухи.

#### 7.4. Queries

- `ListBarcodes(productId?, barcodeContains?, groupId?, withMarkedProducts, page)` —
  `register.barcode.read`.
- `LookupBarcode(barcode)` — `register.barcode.read` **або** будь-яке право `*.create`/
  `*.update` документа з табличною частиною товарів; точний пошук за нормалізованим
  значенням через `reg_barcode_uk`; повертає `barcode, productId, productCode,
  productName, article, productKind, productState, unitOfMeasureId, fractional,
  unitQuantity` або `found=false`.

| Код | Повідомлення |
|---|---|
| `BARCODE_REQUIRED` | Введіть штрихкод. |
| `BARCODE_INVALID_CHARS` | Штрихкод містить недопустимі символи (дозволено латиницю, цифри й знаки ASCII без пробілів). |
| `BARCODE_TOO_LONG` | Штрихкод довший за 64 символи. |
| `BARCODE_EAN13_CHECKSUM_INVALID` | Неправильна контрольна цифра EAN-13 у «4006381333932»: очікується 1. |
| `BARCODE_DUPLICATE` | Штрихкод «4820000000017» уже призначено товару 000000042 «Вода 1,5 л». |
| `BARCODE_NOT_FOUND` | Штрихкод «4821234567895» не знайдено. |
| `BARCODE_UNIT_QUANTITY_INVALID` | Кількість в упаковці має бути більшою за 0. |
| `BARCODE_UNIT_QUANTITY_FRACTION_NOT_ALLOWED` | Одиниця «шт» не дозволяє дробову кількість: 1,5. |
| `PRODUCT_NOT_ACTIVE` | Товар «…» помічений на видалення. |
| `OPTIMISTIC_LOCK_CONFLICT` | Запис змінив інший користувач. |

#### 7.5. Аудит незалежних змін

Кожна команда пише рядок `sys_audit_log` в тій самій транзакції:

| `object_type` | `object_id` | `action` | `details` (JSON) |
|---|---|---|---|
| `Register.Barcode` | `reg_barcode.id` | `INSERT` | `{"after":{"barcode":"…","productId":"…","unitQuantity":6}}` |
| `Register.Barcode` | `reg_barcode.id` | `UPDATE` | `{"before":{…},"after":{…}}` — лише змінені поля |
| `Register.Barcode` | `reg_barcode.id` | `DELETE` | `{"before":{"barcode":"…","productId":"…","unitQuantity":1}}` |

Аудит доступний з форми списку командою «Історія змін» (read-only QueryTable за
`object_type = 'Register.Barcode'`, фільтр за штрихкодом у `details`), а також на
сторінці 21 для всіх штрихкодів товару.

### 8. Розрахунки

Контрольна цифра EAN-13: для перших 12 цифр `d1…d12` вага 1 для непарних позицій і 3
для парних; `check = (10 − (Σ dᵢ·wᵢ mod 10)) mod 10`; має дорівнювати `d13`.

- `4006381333931`: сума `4+0+0+18+3+24+1+9+3+9+9+9 = 89`, `check = (10−9) mod 10 = 1` — коректний.
- `4006381333932` — `BARCODE_EAN13_CHECKSUM_INVALID`, очікується 1.
- `4820000000017`: сума `4+24+2+0+…+3 = 33`, `check = 7` — коректний.
- `4821234567895` — коректний (`check = 5`).
- `0000000000000` — коректний за формулою (`check = 0`), допускається.
- ` 4820000000017\r\n` → нормалізується до `4820000000017`.
- `482000000001` (12 цифр) — записується без перевірки, тип `UPC-A`.
- `ABC-123/x` — записується без перевірки, тип `Інший`.

`unitQuantity`: `6` → `6,000`; `0,2505` → `0,251` (для дробової одиниці «кг»);
`1,5` для «шт» → `BARCODE_UNIT_QUANTITY_FRACTION_NOT_ALLOWED`; `0` або `null` →
`BARCODE_UNIT_QUANTITY_INVALID`.

Сканування в документ: рядок «Вода 1,5 л» 6 шт, скан коду ящика (`unitQuantity=24`) →
`30`; повторний скан коду штуки → `31`.

### 9. Зберігання й API

```sql
create table reg_barcode (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  barcode       varchar2(64)  not null,
  product_id    varchar2(32)  not null,
  unit_quantity number(19,3)  default 1 not null,
  version       number(19)    default 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint reg_barcode_pk primary key (id),
  constraint reg_barcode_uk unique (barcode),
  constraint reg_barcode_qty_ck check (unit_quantity > 0),
  constraint reg_barcode_chars_ck check (regexp_like(barcode, '^[!-~]{1,64}$')),
  constraint reg_barcode_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_barcode_prd_ix on reg_barcode (product_id);
```

Перевірка EAN-13 — у `trade_nsi.ean13_valid` (виклик із `save_barcode` і з тригера
`before insert or update` як захист від прямих DML).

API:

- `GET /api/v1/registers/barcodes?productId=&barcode=&groupId=&withMarkedProducts=&offset=&limit=`;
- `GET /api/v1/registers/barcodes/lookup?barcode=` → `BarcodeLookupResultDto` (200 з
  `found=false`, якщо не знайдено);
- `GET /api/v1/registers/barcodes/check?barcode=&id=`;
- `GET /api/v1/registers/barcodes/new?productId=`;
- `POST /api/v1/registers/barcodes`; `PUT /api/v1/registers/barcodes/{id}`;
- `DELETE /api/v1/registers/barcodes/{id}?expectedVersion=`;
- `GET /api/v1/registers/barcodes/{id}/history` (аудит).

Права: `register.barcode.read|create|update|delete`. Стабільне сортування списку —
`product name, unit_quantity, barcode, id`.

### 10. Тести й критерії готовності

- Unit: `ean13_valid` для прикладів §8; нормалізація CR/LF/пробілів; класифікація
  `barcodeType`.
- Application: дубль штрихкоду для іншого товару — `BARCODE_DUPLICATE` з назвою
  власника; зміна `barcode` на вільне значення; неактивний товар; дробність одиниці;
  optimistic lock; idempotency повторного `Create`.
- DB: `reg_barcode_uk`, CHECK символів і кількості, FK; прямий `insert` з поганим
  EAN-13 відхиляє тригер; паралельні два `insert` одного коду — один успішний.
- Аудит: INSERT/UPDATE/DELETE створюють рядки з коректними before/after; видалений
  запис видно в історії.
- API: `lookup` знайдено/не знайдено, права, `DELETE` без `expectedVersion` — 400.
- UI: сторінка 190 (фільтри, `Enter` у полі сканера, підтвердження видалення), вкладка
  на сторінці 21.
- Наскрізний сценарій: товар «Вода 1,5 л» (шт) з кодами штуки (1) і ящика (24) → у
  чернетці реалізації відсканувати ящик і штуку → рядок 25 шт → провести; відсканувати
  невідомий код → `BARCODE_NOT_FOUND`, документ не змінено; відсканувати код послуги в
  переміщенні → `PRODUCT_SERVICE_NOT_ALLOWED`.

Реалізація дозволена тільки після явного погодження цього паспорта.
