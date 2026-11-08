# Паспорт документа «Інвентаризація товарів»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`; реалізація до погодження не виконується.
- Ревізія: `r3`.
- Розділ меню (Taxi): `Склад` → нова група «Інвентаризація» (Інвентаризація товарів,
  Оприбуткування надлишків, Списання товарів).
- Залежності: `RefWarehouse`, `RefProduct` r3 (`productKind`, `groupId`),
  `RefProductGroup` (відбір заповнення), `RegStockBalance` (облікові залишки),
  `RegStockCost` (оцінка), `RegBarcode` (сканер), `DocSurplusPosting`,
  `DocGoodsWriteOff` r3 (зміни описано в §12).
- Аналог у 1С:УТ 11: Документ.ПересчетТоваров + Документ.ИнвентаризацияТоваров
  (об'єднано; без ордерної схеми й комірок), похідні — ОприходованиеИзлишковТоваров,
  СписаниеНедостачТоваров.
- Функції каталогу: `F-WH-04` (основна), `F-WH-05`, `F-WH-06` (введення на підставі),
  `F-SRV-01`, `F-NSI-04` (штрихкоди), `F-NSI-02` (відбір за групою).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Інвентаризація товарів (список — «Інвентаризації товарів») |
| Технічне ім'я | `DocInventoryCount` |
| Технічний ключ | `Document.DocInventoryCount` |
| Клас / ID | `InventoryCount` / `InventoryCountId` |
| Клас рядка | `InventoryCountLine` / `InventoryCountLineId` |
| Таблиці | `doc_inventory_count`, `doc_inventory_count_goods` |
| DTO | `InventoryCountDto`, `InventoryCountLineDto`, `InventoryCountListItemDto` |
| API | `/api/v1/documents/inventory-counts` |
| Сторінки APEX | 300 — список, 301 — форма документа |
| Нумерація | `doc_inventory_count_num_seq`, 9 цифр, присвоюється під час першого запису |
| Дата | `occurredAt` = дата й час інвентаризації (`countDate`), `DATETIME`, секунди; облікові залишки беруться **на цей момент включно** (`period <= occurredAt`) |
| Підстава | немає; сам є підставою для `DocSurplusPosting` і `DocGoodsWriteOff` r3 |
| Рухи | **немає** — документ фіксує результат і заморожує його |
| Видалення | чернетку — фізично; проведений не видаляється |

Документ фіксує фактичну наявність товару на складі на момент перерахунку, порівнює її з
обліковим залишком і показує відхилення в кількості й вартості. Корекція залишків
виконується похідними документами: надлишки — `DocSurplusPosting`, недостачі —
`DocGoodsWriteOff` r3.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування (по статусах) | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ніколи | PK |
| `number` | Номер | String | 9 | так | sequence | DRAFT | `doc_number`, UNIQUE |
| `occurredAt` | Дата інвентаризації | DateTime | seconds | так | now | DRAFT | `occurred_at`, index |
| `warehouseId` | Склад | ref `RefWarehouse` | 32 | так | — | DRAFT | `warehouse_id`, FK, index |
| `responsiblePerson` | Відповідальна особа | String | 255 | так | ПІБ поточного користувача | DRAFT | `responsible_person` |
| `surplusAmount` | Надлишки, сума | Decimal | 19,2 | так | 0 | ніколи | stored |
| `shortageAmount` | Недостачі, сума | Decimal | 19,2 | так | 0 | ніколи | stored (додатне число) |
| `comment` | Коментар | String | 1000 | ні | — | DRAFT | `doc_comment` |
| `status` | Статус | enum | 10 | так | `DRAFT` | командами | CHECK (`DRAFT`,`POSTED`) |
| `version`, аудит | Службові | — | — | так | server | ніколи | — |

Склад має бути `ACTIVE`. Зміна `warehouseId` або `occurredAt` у документі з рядками
виконує `FILL_WITH_BOOK_BALANCES(mode=REFRESH_BOOK)` — облікові кількості й ціни
перечитуються, `actualQuantity` зберігається.

### 3. Таблична частина `Goods` («Товари»)

Таблиця `doc_inventory_count_goods`, стабільний `lineId`, `lineNumber`. Товар у
документі унікальний (UNIQUE `document_id + product_id`) — повторне сканування
збільшує фактичну кількість наявного рядка. Товари з `productKind = SERVICE`
заборонені (`PRODUCT_SERVICE_NOT_ALLOWED`).

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ніколи | PK |
| `lineNumber` | N | int | 10 | так | наступний | порядком | `line_number` |
| `productId` | Товар | ref `RefProduct` | 32 | так | — | DRAFT, лише новий рядок | FK |
| `bookQuantity` | Облікова кількість | Decimal | 19,3 | так | `RegStockBalance` на `occurredAt` | ніколи (лише сервер) | `book_quantity` |
| `actualQuantity` | Фактична кількість | Decimal | 19,3 | ні (до підрахунку) | `null` | DRAFT | `actual_quantity`, CHECK >= 0 |
| `deviation` | Відхилення | Decimal | 19,3 | ні | розрахунок | ніколи | stored, `null` якщо не пораховано |
| `price` | Ціна оцінки | Decimal | 19,2 | ні | середня собівартість §8 | ніколи | `price` |
| `deviationAmount` | Сума відхилення | Decimal | 19,2 | ні | розрахунок | ніколи | stored |
| `surplusProcessed` | Оприбутковано | Decimal | 19,3 | — | з POSTED `DocSurplusPosting` | ніколи | transient |
| `shortageProcessed` | Списано | Decimal | 19,3 | — | з POSTED `DocGoodsWriteOff` | ніколи | transient |

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Редагованість |
|---|---|---|---|---|---|
| — | `NEW` | `DRAFT` | `document.inventory-count.create` | — | шапка, рядки |
| `DRAFT` | `SAVE`, `FILL_*`, `SCAN_BARCODE` | `DRAFT` | `document.inventory-count.update` | версія | шапка, рядки |
| `DRAFT` | `POST` | `POSTED` | `document.inventory-count.post` | §7.3 | read-only (заморожено) |
| `POSTED` | `POST` повторно | `POSTED` | `document.inventory-count.post` | немає похідних POSTED | read-only |
| `POSTED` | `UNPOST` | `DRAFT` | `document.inventory-count.unpost` | немає POSTED похідних | шапка, рядки |
| `POSTED` | `CREATE_SURPLUS_POSTING` | `POSTED` (+ чернетка DocSurplusPosting) | `document.surplus-posting.create` | є залишок надлишків | — |
| `POSTED` | `CREATE_SHORTAGE_WRITE_OFF` | `POSTED` (+ чернетка DocGoodsWriteOff) | `document.goods-write-off.create` | є залишок недостач | — |
| `DRAFT` | `DELETE` | — | `document.inventory-count.delete` | немає похідних (навіть чернеток) | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `document.inventory-count.create` | — | — |

«Проведення» інвентаризації не формує рухів: воно фіксує облікові кількості на
`occurredAt`, забороняє зміни й відкриває введення похідних документів.

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 300)

- Колонки: `stateIcon[4]` | `number[12]` | `occurredAt[16]` | `warehouse[24]` |
  `responsiblePerson[24]` | `surplusAmount[13]` | `shortageAmount[13]` |
  `resultState[14]` («Не оформлено» / «Частково» / «Оформлено» — за похідними).
- Фільтри: період, склад, статус, стан оформлення.
- Команди: `Створити` | `Скопіювати (F9)` | `Провести` | `Скасувати проведення` |
  `Створити на підставі ▾` | `Пошук (Ctrl+F)` | `Друк ▾`.

#### 5.2. Форма документа (сторінка 301)

```text
FORM inventoryCountEditor  title: «Інвентаризація товарів № <number> від <occurredAt> (проведено)»

HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення |
           Створити на підставі ▾ (Оприбуткування надлишків | Списання недостач) |
           Друк ▾ (Інвентаризаційний опис | Порівняльна відомість) |
           Ще ▾ (Скопіювати F9, Структура підпорядкованості)
  number[20] | occurredAt[22]
  warehouse[50]
  responsiblePerson[60]
CONTENT
  scanInput[30] «Штрихкод» (над вкладкою «Товари», Ctrl+Shift+B, Enter — сканування)
  TAB Товари (N)
    commands: Додати | Підбір | Заповнити ▾ (Заповнити обліковими залишками |
              Додати відсутні з обліку | Оновити облікові кількості |
              Заповнити фактичну обліковою (незлічені) | Очистити фактичну) |
              Видалити | ↑ ↓
    filter chips: Усі | Незлічені | З відхиленням | Надлишки | Недостачі
    GoodsTable: lineNumber[5] | product[34] | bookQuantity[11] | actualQuantity[11]* |
                deviation[11] (зелений > 0, червоний < 0) | price[11] | deviationAmount[13] |
                surplusProcessed[10] | shortageProcessed[10]  (дві останні — лише POSTED)
    totals: «Надлишки: <surplusAmount>   Недостачі: <shortageAmount>   Незлічено: <count>»
  TAB Оформлення результатів (лише POSTED)
    QueryTable derivedDocuments «Документи за результатами інвентаризації»
      query: GetInventoryDerivedDocuments(inventoryId)
      columns: documentType[20] | number[12] DOCUMENT → відкриття | occurredAt[16] |
               status[10] | quantity[12] | amount[14]
      refresh: ON_OPEN, MANUAL, AFTER_POSTING
    QueryTable bookDrift «Зміни облікових залишків після проведення»
      query: GetInventoryBookDrift(inventoryId) — рядки, де поточний залишок RegStockBalance
             на occurredAt ≠ збереженому bookQuantity
      columns: product[30] | bookQuantity[12] | currentBook[12] | difference[12] calculated
FOOTER
  comment[100]
```

Поле `scanInput` активне лише в `DRAFT`; фокус після `Enter` лишається в ньому
(безперервне сканування). Фільтр-чипи — локальні, не змінюють документ.

#### 5.3. Форма підбору

Стандартний підбір товарів (`F-SRV-02`) з відбором за групою `RefProductGroup` і
колонкою «Обліковий залишок на <occurredAt>»; лише `GOODS`.

#### 5.4. Форма вибору документа

`number[12] | occurredAt[16] | warehouse[24] | responsiblePerson[24]`, лише `POSTED`;
використовується полем `baseInventoryId` у `DocSurplusPosting` і `DocGoodsWriteOff`.

### 6. Події введення

| Поле | Компонент | INPUT_COMMITTED → команда | Залежності | Сервер перераховує | Повертає | Помилка / фокус |
|---|---|---|---|---|---|---|
| `number` | TextField | `ChangeInventoryCountHeader(number)` | — | — | поле | `DOCUMENT_NUMBER_NOT_UNIQUE` |
| `occurredAt` | DateTimeField | `ChangeInventoryCountHeader(occurredAt)` | warehouse | book, price, deviation, deviationAmount усіх рядків, підсумки | документ | `INVENTORY_DATE_IN_FUTURE` (попередження) |
| `warehouseId` | ReferenceField | `ChangeInventoryCountHeader(warehouseId)` (з підтвердженням, якщо є рядки) | occurredAt | як вище | документ | `REFERENCE_NOT_ACTIVE` |
| `responsiblePerson` | TextField | `ChangeInventoryCountHeader(responsiblePerson)` | — | — | поле | `REQUIRED_FIELD_EMPTY` |
| `comment` | TextArea | `ChangeInventoryCountHeader(comment)` | — | — | поле | довжина |
| `surplusAmount`, `shortageAmount` | NumberField (disabled) | — | — | — | — | — |
| `scanInput` (форма) | TextField | `LookupBarcode(barcode)` → `AddOrIncrementLineByBarcode(documentId, productId, unitQuantity, expectedVersion)` | warehouse, occurredAt | рядок (новий або існуючий), підсумки | рядок + підсумки | `BARCODE_NOT_FOUND`, `PRODUCT_SERVICE_NOT_ALLOWED`; поле очищується, фокус лишається |
| `line.productId` | ReferenceCell | `SetInventoryCountLineProduct(lineId, productId, version)` | warehouse, occurredAt | book, price, deviation (null), підсумки | рядок | `PRODUCT_DUPLICATE_IN_INVENTORY` (фокус на наявний рядок), `PRODUCT_SERVICE_NOT_ALLOWED` |
| `line.bookQuantity` | NumberCell (disabled) | — | — | — | — | — |
| `line.actualQuantity` | NumberCell (порожнє дозволено) | `ChangeInventoryCountLineActual(lineId, actualQuantity\|null, version)` | book, price, дробність | deviation, deviationAmount, підсумки | рядок + підсумки | `QUANTITY_NOT_FRACTIONAL`, `QUANTITY_MUST_BE_NON_NEGATIVE` |
| `line.deviation`, `price`, `deviationAmount`, `surplusProcessed`, `shortageProcessed` | NumberCell (disabled) | — | — | — | — | — |

Очищення `actualQuantity` (Delete у клітинці) — явне значення `null` = «не пораховано»;
це відрізняється від `0` = «пораховано, товару немає».

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Спільні правила: права, `expectedVersion` (`OPTIMISTIC_LOCK_CONFLICT`), статус `DRAFT`
для змін (`DOCUMENT_POSTED_READ_ONLY`), `idempotencyKey` для `POST`, `UNPOST`, `COPY`,
`FILL_*`, `CREATE_*`; аудит `sys_audit_log` (`CREATE`, `UPDATE`, `FILL`, `POST`,
`UNPOST`, `COPY`, `CREATE_DERIVED`). `SCAN_BARCODE` (`AddOrIncrementLineByBarcode`) ідемпотентності не має (кожне
сканування — +1), але вимагає `version`.

#### 7.1. NEW — `InitializeInventoryCount(warehouseId?)`

`occurredAt = now`, `responsiblePerson` = ПІБ користувача, рядків немає. Рекомендований
сценарій: вибрати склад → «Заповнити обліковими залишками» → друк інвентаризаційного
опису → внести/сканувати фактичні кількості → «Провести».

#### 7.2. SAVE — `SaveInventoryCount(dto, expectedVersion)`

Lock шапки, merge рядків, перерахунок `deviation`, `deviationAmount`, підсумків.
Валідації: обов'язкові поля, унікальність товару, заборона SERVICE, дробність.
`bookQuantity`/`price` із DTO ігноруються (лише сервер).

#### 7.3. POST — `PostInventoryCount(id, expectedVersion, idempotencyKey)`

1. Lock шапки `FOR UPDATE`; `NO_LINES`.
2. Lock `ref_warehouse(warehouseId)` — серіалізує з проведеннями складських документів.
3. Незлічені рядки (`actualQuantity is null`) → `ACTUAL_QUANTITY_NOT_COUNTED` «Не
   внесено фактичну кількість у N рядках (перший — рядок 4, «…»). Внесіть кількість
   або виконайте «Заповнити фактичну обліковою».»
4. Перечитування `bookQuantity` і `price` з регістрів на `occurredAt` для всіх рядків;
   якщо хоч одне значення змінилося після останнього запису — значення оновлюються і
   повертається попередження `INVENTORY_BOOK_REFRESHED` «Облікові кількості оновлено
   в N рядках (документи, внесені заднім числом).»
5. Перерахунок `deviation`, `deviationAmount`, підсумків; `status = POSTED`, аудит.
6. Рухів регістрів немає; `delete_movements` не викликається.

#### 7.4. UNPOST — `UnpostInventoryCount(id, expectedVersion, idempotencyKey)`

Заборонено, якщо існує `POSTED` `DocSurplusPosting` або `DocGoodsWriteOff` з
`baseInventoryId = id` → `BASE_HAS_POSTED_DERIVED` «Інвентаризацію не можна
скасувати: за нею проведено документи: Оприбуткування надлишків №…». Чернетки похідних
не блокують, але їх проведення вимагатиме повторного проведення інвентаризації
(`BASE_NOT_POSTED`).

#### 7.5. COPY (F9) — `CopyInventoryCount(id)`

Нова чернетка: склад, відповідальна особа, коментар, рядки з `productId`;
`actualQuantity = null`, `bookQuantity/price` перечитуються на нову `occurredAt = now`.

#### 7.6. FILL_WITH_BOOK_BALANCES — `FillInventoryCountWithBookBalances(id, mode, productGroupId?, expectedVersion)`

- Джерело: `RegStockBalance` на `occurredAt` для `warehouseId`, товари з залишком ≠ 0
  (від'ємних у r3 не буває, але правило загальне), лише `GOODS`, опційно в межах групи
  `productGroupId` з підгрупами.
- `mode = REPLACE` — очищає рядки (підтвердження в UI) і створює рядки за залишками,
  `actualQuantity = null`, сортування за назвою товару.
- `mode = ADD_MISSING` — додає лише товари, яких немає в документі.
- `mode = REFRESH_BOOK` — оновлює `bookQuantity`, `price` наявних рядків, `actual` не
  змінює; товари з нульовим обліковим лишаються з `bookQuantity = 0`.
- Ціна — §8. Повертає весь документ.

#### 7.7. FILL_ACTUAL_WITH_BOOK / CLEAR_ACTUAL

`FillInventoryActualWithBook(id, scope = UNCOUNTED|SELECTED, lineIds?)` —
`actualQuantity = bookQuantity` для незлічених або виділених рядків.
`ClearInventoryActual(id, lineIds?)` — `actualQuantity = null`.

#### 7.8. SCAN_BARCODE — `LookupBarcode(barcode)` + `AddOrIncrementLineByBarcode(id, productId, unitQuantity, expectedVersion)`

Спільний для r3 контракт сканера; для інвентаризації інкрементується `actualQuantity`
(а не `quantity`, як в інших документах).

1. `LookupBarcode`: пошук у `RegBarcode` за точним значенням (trim) → `productId`, `unitQuantity`
   (кількість одиниць у пакуванні штрихкоду, default 1); не знайдено —
   `BARCODE_NOT_FOUND` «Штрихкод «…» не знайдено.» (звуковий сигнал помилки в UI).
2. SERVICE → `PRODUCT_SERVICE_NOT_ALLOWED`.
3. Рядок товару є → `actualQuantity = coalesce(actualQuantity, 0) + unitQuantity`; немає →
   новий рядок у кінці: `bookQuantity`, `price` з регістрів, `actualQuantity = unitQuantity`.
4. Ваговий штрихкод (кількість у самому коді) — r4. Повертає змінений рядок, підсумки й нову `version`; рядок
   підсвічується і прокручується у видиму область.

#### 7.9. CREATE_SURPLUS_POSTING — `CreateSurplusPostingFromInventory(id, idempotencyKey)`

- Інвентаризація `POSTED` (`BASE_NOT_POSTED` «Спочатку проведіть інвентаризацію.»);
  lock рядка інвентаризації `FOR UPDATE`.
- Якщо вже існує `DRAFT` `DocSurplusPosting` з цим `baseInventoryId` — новий не
  створюється, повертається його ID (`INVENTORY_DERIVED_DRAFT_EXISTS`, інформаційне).
- `remaining = deviation − Σ quantity товару в POSTED DocSurplusPosting цієї
  інвентаризації` для рядків з `deviation > 0`; рядки з `remaining > 0` переносяться:
  `productId`, `quantity = remaining`, `price = inventory.price` (якщо null — за правилом
  ціни `DocSurplusPosting`).
- Шапка: `warehouseId = inventory.warehouseId`, `occurredAt = inventory.occurredAt + 1 с`,
  `baseInventoryId = id`, `reason = «Надлишки за інвентаризацією №<number> від <dd.mm.yyyy>»`.
- Нічого — `NOTHING_TO_POST_SURPLUS` «Надлишків для оприбуткування немає.»
- Результат: ID чернетки, форма 311 відкривається.

#### 7.10. CREATE_SHORTAGE_WRITE_OFF — `CreateShortageWriteOffFromInventory(id, idempotencyKey)`

Аналогічно: рядки з `deviation < 0`, `remaining = −deviation − Σ quantity товару в
POSTED DocGoodsWriteOff з цим baseInventoryId`; шапка `DocGoodsWriteOff`:
`warehouseId`, `occurredAt = inventory.occurredAt + 1 с`, `baseInventoryId`,
`reason = «Недостача за інвентаризацією №<number> від <dd.mm.yyyy>»`. Наявна чернетка
повертається; нічого — `NOTHING_TO_WRITE_OFF` «Недостач для списання немає.»

#### 7.11. Політика документів, датованих раніше проведеної інвентаризації

Рішення r3: **лише попередження, без блокування.** Під час `POST`/`UNPOST` будь-якого
документа, що рухає `RegStockBalance` складу W з `occurredAt <= countDate` проведеної
інвентаризації складу W, сервер повертає неблокувальне попередження
`INVENTORY_RESULT_OUTDATED` «Документ змінює залишки складу «…» до дати проведеної
інвентаризації №… від …. Облікові дані інвентаризації застаріли.» Інвентаризація не
змінюється; розбіжність видно у вкладці «Зміни облікових залишків після проведення».
Обґрунтування: заборона потребувала б закриття періоду (r4), а в r3 виправлення
помилок заднім числом є частим сценарієм. Похідні документи датуються
`countDate + 1 с`, тому попередження не викликають. Реалізація — спільна процедура
`trade_ops.warn_inventory_outdated(warehouseId, occurredAt)` у post/unpost
`DocGoodsReceipt`, `DocGoodsSale`, `DocGoodsTransfer`, `DocGoodsWriteOff`,
`DocCustomerReturn`, `DocSupplierReturn`, `DocSurplusPosting`.

#### 7.12. Довідник помилок

Усі помилки піднімаються через `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error(-20100, …)`); код — UPPER_SNAKE на початку тексту в квадратних дужках, попередження (warning) повертаються як повідомлення APEX без rollback.

| Код | Повідомлення |
|---|---|
| `ACTUAL_QUANTITY_NOT_COUNTED` | Не внесено фактичну кількість у N рядках (перший — рядок …). |
| `PRODUCT_DUPLICATE_IN_INVENTORY` | Товар «…» уже є в рядку N. |
| `PRODUCT_SERVICE_NOT_ALLOWED` | «…» — послуга; послуги не мають залишків і не інвентаризуються. |
| `BARCODE_NOT_FOUND` | Штрихкод «…» не знайдено. |
| `BASE_HAS_POSTED_DERIVED` | Інвентаризацію не можна скасувати: за нею проведено документи … |
| `BASE_NOT_POSTED` | Спочатку проведіть інвентаризацію. |
| `NOTHING_TO_POST_SURPLUS` / `NOTHING_TO_WRITE_OFF` | Надлишків для оприбуткування немає. / Недостач для списання немає. |
| `INVENTORY_DERIVED_DRAFT_EXISTS` (info) | Відкрито наявну чернетку №… |
| `INVENTORY_BOOK_REFRESHED` (warning) | Облікові кількості оновлено в N рядках. |
| `INVENTORY_RESULT_OUTDATED` (warning) | Документ змінює залишки до дати проведеної інвентаризації №… |
| `INVENTORY_DATE_IN_FUTURE` (warning) | Дата інвентаризації пізніша за поточний момент. |
| спільні r2 | `NO_LINES`, `DOCUMENT_NOT_POSTED`, `DOCUMENT_POSTED_READ_ONLY`, `OPTIMISTIC_LOCK_CONFLICT`, `PERMISSION_DENIED`, `QUANTITY_NOT_FRACTIONAL`, `REQUIRED_FIELD_EMPTY` |

### 8. Розрахунки

- `bookQuantity = Σ RegStockBalance.quantity (warehouseId, productId, period <= occurredAt)`, scale 3.
- `price`: якщо `qtyBalance(RegStockCost, на occurredAt) > 0` →
  `round(costBalance / qtyBalance, 2)`; інакше «остання середня собівартість»
  (`RegStockCost` query `lastAverageCost(warehouseId, productId, at)`); інакше `null`.
- `deviation = actualQuantity − bookQuantity`; `null`, якщо `actualQuantity is null`.
- `deviationAmount = round(deviation × price, 2)` `HALF_UP`; `null`, якщо deviation
  або price `null`.
- `surplusAmount = Σ deviationAmount where > 0`; `shortageAmount = Σ |deviationAmount|
  where < 0`; `null` пропускаються; stored, перераховуються при кожній зміні рядка.
- Вартість у документі — довідкова; фактична вартість корекції визначається похідними
  документами на їхню дату.

Приклади (склад «Основний»):

| Товар | Облік | Факт | Відхилення | Ціна | Сума |
|---|---|---|---|---|---|
| Фарба | 17,000 | 15,000 | −2,000 | 115,00 | −230,00 |
| Кабель | 4,000 | 4,500 | 0,500 | 20,00 | 10,00 |
| Клей (новий, обліку не було) | 0 | 3,000 | 3,000 | null | null |
| Ґрунт | 2,000 | null | null | 50,00 | null (блокує POST) |
| Шпатель | 1,000 | 1,000 | 0 | 33,33 | 0,00 |

`surplusAmount = 10,00`, `shortageAmount = 230,00`. Округлення: 0,333 × 33,33 = 11,10.

### 9. Проведення й регістри

Рухів немає (рядок `DocInventoryCount` у матриці 2.2 порожній). `POST` лише змінює
статус і заморожує документ; `UNPOST` повертає `DRAFT` за умови §7.4. Перевірки
залишків не виконуються. Recorder-ID інвентаризації не з'являється в жодному
регістрі; коригувальні рухи несуть похідні документи (див. `DocSurplusPosting` §9 і
§12 цього паспорта).

### 10. Зберігання й API

```text
doc_inventory_count
  PK id; UNIQUE doc_number; FK warehouse_id → ref_warehouse;
  NOT NULL responsible_person varchar2(255); CHECK status IN ('DRAFT','POSTED');
  CHECK surplus_amount >= 0; CHECK shortage_amount >= 0
  INDEX (occurred_at), (warehouse_id, status, occurred_at)  -- політика §7.11
doc_inventory_count_goods
  PK id; FK document_id ON DELETE CASCADE; FK product_id → ref_product;
  UNIQUE (document_id, product_id); CHECK actual_quantity IS NULL OR actual_quantity >= 0;
  INDEX (document_id, line_number)
```

Тригер read-only у `POSTED`. Пакет `trade_ops`: `post_inventory_count`,
`unpost_inventory_count`, `copy_inventory_count`, `fill_inventory_book`,
`add_or_increment_line_by_barcode` (спільна, гілка інвентаризації), `create_surplus_from_inventory`,
`create_write_off_from_inventory`, `warn_inventory_outdated`.

| Метод | Шлях | Призначення |
|---|---|---|
| GET | `/api/v1/documents/inventory-counts` | список |
| GET | `…/new` | ініціалізація |
| GET/POST/PUT | `…/{id}`, `…`, `…/{id}` | читання/створення/запис |
| POST | `…/{id}/post`, `/unpost`, `/copy` | команди |
| POST | `…/{id}/fill-book-balances`, `/fill-actual-with-book`, `/clear-actual`, `/scan-barcode` | заповнення, сканер |
| POST | `…/{id}/create-surplus-posting`, `…/{id}/create-shortage-write-off` | введення на підставі |
| GET | `…/{id}/derived-documents`, `…/{id}/book-drift` | QueryTable |
| GET | `…/{id}/print/count-sheet` | «Інвентаризаційний опис»: товари, одиниці, порожня колонка «Фактично», без облікових кількостей (сліпий підрахунок), підписи комісії |
| GET | `…/{id}/print/comparison` | «Порівняльна відомість»: облік, факт, відхилення, ціна, суми, підсумки |

### 11. Тести й готовність

- Unit: deviation/deviationAmount з `null`, підсумки, правило ціни.
- FILL: REPLACE/ADD_MISSING/REFRESH_BOOK, відбір за групою, межа `period <= occurredAt`.
- Сканер: новий рядок, інкремент, невідомий штрихкод, послуга.
- POST: незлічені блокують, оновлення облікових, заморожування; UNPOST з похідними.
- Похідні: залишок до оформлення, повторне створення повертає чернетку, ліміти
  `SURPLUS_EXCEEDS_DEVIATION` / `WRITE_OFF_EXCEEDS_SHORTAGE`.
- Попередження `INVENTORY_RESULT_OUTDATED` для документа заднім числом.

Наскрізний сценарій:

1. Склад «Основний» на 10.11 10:00: Фарба 17,000 (собів. 1 955,00), Кабель 4,000 (80,00).
2. Інвентаризація №1 від 10.11 18:00 → «Заповнити обліковими залишками»: 2 рядки,
   ціни 115,00 і 20,00, факт порожній.
3. Сканування штрихкоду Кабелю 4 рази → actual 4; ручний ввід 4,500; Фарба 15,000;
   сканування невідомого коду → `BARCODE_NOT_FOUND`.
4. «Провести» → `POSTED`; надлишки 10,00, недостачі 230,00.
5. «Створити на підставі → Оприбуткування надлишків» → чернетка: Кабель 0,500 × 20,00,
   дата 10.11 18:00:01. Проведення → Stock Кабель 4,500.
6. «Списання недостач» → `DocGoodsWriteOff`: Фарба 2,000, причина «Недостача за
   інвентаризацією №000000001 від 10.11.2026». Проведення → Stock Фарба 15,000,
   StockCost −230,00.
7. Повторне «Списання недостач» → `NOTHING_TO_WRITE_OFF`; список показує «Оформлено».
8. Реалізація від 10.11 12:00 (заднім числом) Фарби 1,000 → проводиться з попередженням
   `INVENTORY_RESULT_OUTDATED`; вкладка «Зміни облікових залишків» показує 17 → 16.
9. `UNPOST` інвентаризації → `BASE_HAS_POSTED_DERIVED`.

## 12. Зміни суміжних об'єктів (DocGoodsWriteOff r3)

Ревізія r3 паспорта `DocGoodsWriteOff` (власник змін — цей паспорт у частині
інвентаризації; `RegStockCost` − за середньою — у паспорті `RegStockCost`):

| Поле | Назва | Тип | Обов'язкове | Редагування | БД |
|---|---|---|---|---|---|
| `baseInventoryId` | Інвентаризація (підстава) | ref `DocInventoryCount` | ні | DRAFT, лише без рядків | `base_inventory_id`, FK → `doc_inventory_count(id)`, index |

Правила, якщо `baseInventoryId` заповнено:

- Заповнення: команда `CREATE_SHORTAGE_WRITE_OFF` (§7.10) або кнопка
  «Заповнити за інвентаризацією» у формі списання (`FillWriteOffFromInventory`, ті самі
  правила `remaining`); `reason` пропонується автоматично, але редагується.
- `warehouseId = inventory.warehouseId`, read-only (`BASE_WAREHOUSE_MISMATCH` через API).
- `occurredAt > inventory.occurredAt`, інакше `DATE_NOT_AFTER_BASE` «Дата документа має
  бути пізнішою за дату інвентаризації (…).»
- `POST`: інвентаризація `POSTED` (`BASE_NOT_POSTED`), lock інвентаризації `FOR UPDATE`;
  кожен товар має бути в інвентаризації з `deviation < 0`
  (`WRITE_OFF_PRODUCT_NOT_IN_BASE`), і `Σ quantity товару в цьому документі + Σ в інших
  POSTED списаннях за інвентаризацією <= −deviation` — інакше
  `WRITE_OFF_EXCEEDS_SHORTAGE` «Товар «…»: списується 3,000, а недостача за
  інвентаризацією №… — 2,000 (уже списано 0,000).»
- Рухи: як у r3 без підстави (`RegStockBalance` −, `RegStockCost` − за середньою).
- Форма списання: поле `baseInventory[50]` після `warehouse` (ReferenceField, вибір
  проведених інвентаризацій складу), кнопка «Відкрити»; у формі інвентаризації
  посилання на списання показується у вкладці «Оформлення результатів» і в
  «Структурі підпорядкованості».
- Скасування проведення списання знімає «оформленість» відповідної недостачі; повторне
  `CREATE_SHORTAGE_WRITE_OFF` знову запропонує цю кількість.
