# Паспорт документа «Оприбуткування надлишків»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`; реалізація до погодження не виконується.
- Ревізія: `r3`.
- Розділ меню (Taxi): `Склад` → група «Інвентаризація» (після «Інвентаризація товарів»).
- Залежності: `RefWarehouse`, `RefProduct` r3 (`productKind`), `DocInventoryCount`
  (необов'язкова підстава), `RegStockBalance`, `RegStockCost` (оцінка й рух вартості),
  `RegSupplierPrice` (резервне джерело ціни).
- Аналог у 1С:УТ 11: Документ.ОприходованиеИзлишковТоваров (спрощено: без статей
  доходів, без ордерної схеми).
- Функції каталогу: `F-WH-05` (основна), `F-WH-04`/`F-SRV-01` (введення на підставі
  інвентаризації), `F-WH-09` (вартісна оцінка), `F-PRC-04` (ціна постачальника як
  резервна оцінка).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Оприбуткування надлишків (список — «Оприбуткування надлишків товарів») |
| Технічне ім'я | `DocSurplusPosting` |
| Технічний ключ | `Document.DocSurplusPosting` |
| Клас / ID | `SurplusPosting` / `SurplusPostingId` |
| Клас рядка | `SurplusPostingLine` / `SurplusPostingLineId` |
| Таблиці | `doc_surplus_posting`, `doc_surplus_posting_goods` |
| DTO | `SurplusPostingDto`, `SurplusPostingLineDto`, `SurplusPostingListItemDto` |
| API | `/api/v1/documents/surplus-postings` |
| Сторінки APEX | 310 — список, 311 — форма документа |
| Нумерація | `doc_surplus_posting_num_seq`, 9 цифр, присвоюється під час першого запису |
| Дата | `occurredAt`, `DATETIME`, секунди, Europe/Kyiv |
| Підстава | `DocInventoryCount` у статусі `POSTED`, необов'язкова, але типова (`baseInventoryId`) |
| Видалення | чернетку — фізично; проведений не видаляється |
| recorder_type | `DocSurplusPosting` |

Документ оприбутковує на склад товар, виявлений понад облікову кількість (за
результатами інвентаризації або окремим актом), і оцінює його для регістру
собівартості. Розрахунків з контрагентами не виникає.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування (по статусах) | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ніколи | PK |
| `number` | Номер | String | 9 | так | sequence | DRAFT | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | now; з підставою — `inventory.occurredAt + 1 с` | DRAFT | `occurred_at`, index |
| `baseInventoryId` | Інвентаризація (підстава) | ref `DocInventoryCount` | 32 | ні | з «Створити на підставі» | DRAFT, лише без рядків | `base_inventory_id`, FK, index |
| `warehouseId` | Склад | ref `RefWarehouse` | 32 | так | з підстави | DRAFT; read-only, якщо є підстава | `warehouse_id`, FK |
| `reason` | Підстава оприбуткування | String | 255 | так | з підставою: «Надлишки за інвентаризацією №… від …» | DRAFT | `reason` |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | ніколи в r3 | CHECK = 'UAH' |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ніколи | stored |
| `comment` | Коментар | String | 1000 | ні | — | DRAFT | `doc_comment` |
| `status` | Статус | enum | 10 | так | `DRAFT` | командами | CHECK |
| `version`, аудит | Службові | — | — | так | server | ніколи | — |

Правила шапки з підставою: `warehouseId = inventory.warehouseId`
(`BASE_WAREHOUSE_MISMATCH` через API); `occurredAt > inventory.occurredAt`
(`DATE_NOT_AFTER_BASE`); інвентаризація має бути `POSTED` (`BASE_NOT_POSTED`).

### 3. Таблична частина `Goods` («Товари»)

Таблиця `doc_surplus_posting_goods`, стабільний `lineId`, `lineNumber`. Товар може
повторюватися (перевірки ліміту — за сумою по товару). Лише `productKind = GOODS`.

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ніколи | PK |
| `lineNumber` | N | int | 10 | так | наступний | порядком | `line_number` |
| `productId` | Товар | ref `RefProduct` | 32 | так | — | DRAFT | FK |
| `quantity` | Кількість | Decimal | 19,3 | так | 1 / залишок відхилення | DRAFT | CHECK > 0 |
| `price` | Ціна оцінки | Decimal | 19,2 | на `POST` | правило §8 | DRAFT (ручне перевизначення) | CHECK `price IS NULL OR price >= 0` |
| `priceSource` | Джерело ціни | enum | 20 | так | розрахунок | ніколи | `AVERAGE_COST` / `LAST_AVERAGE_COST` / `SUPPLIER_PRICE` / `INVENTORY` / `MANUAL` / `NONE` |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ніколи | stored; 0 якщо price null |
| `remainingDeviation` | Залишок надлишку | Decimal | 19,3 | — | з підстави | ніколи | transient, лише з підставою |

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Редагованість |
|---|---|---|---|---|---|
| — | `NEW` / на підставі | `DRAFT` | `document.surplus-posting.create` | підстава `POSTED`, якщо задана | шапка, рядки |
| `DRAFT` | `SAVE`, `FILL_FROM_BASE` | `DRAFT` | `document.surplus-posting.update` | версія | шапка, рядки |
| `DRAFT` | `POST` | `POSTED` | `document.surplus-posting.post` | §7.3 | read-only |
| `POSTED` | `POST` повторно | `POSTED` | `document.surplus-posting.post` | §7.3 | read-only |
| `POSTED` | `UNPOST` | `DRAFT` | `document.surplus-posting.unpost` | §7.4 | шапка, рядки |
| `DRAFT` | `DELETE` | — | `document.surplus-posting.delete` | — | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `document.surplus-posting.create` | — | — |

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 310)

- Колонки: `stateIcon[4]` | `number[12]` | `occurredAt[16]` | `warehouse[24]` |
  `baseInventory[22]` | `reason[30]` | `totalAmount[14]`.
- Фільтри: період, склад, статус, інвентаризація.
- Команди: `Створити` | `Скопіювати (F9)` | `Провести` | `Скасувати проведення` |
  `Пошук (Ctrl+F)` | `Друк ▾`.

#### 5.2. Форма документа (сторінка 311)

```text
FORM surplusPostingEditor  title: «Оприбуткування надлишків № <number> від <occurredAt> (проведено)»

HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення |
           Створити на підставі ▾ (порожнє в r3) | Друк ▾ (Акт оприбуткування надлишків) |
           Ще ▾ (Скопіювати F9, Структура підпорядкованості, Рухи документа)
  number[20] | occurredAt[22]
  baseInventory[50] (ReferenceField, лише POSTED інвентаризації; «Відкрити»)
  warehouse[50] (read-only при підставі)
  reason[100]
CONTENT
  scanInput[30] «Штрихкод» (над вкладкою «Товари», Ctrl+Shift+B; лише DRAFT)
  TAB Товари (N)
    commands: Додати | Підбір | Заповнити за інвентаризацією (лише з підставою) |
              Перезаповнити ціни | Видалити | ↑ ↓
    GoodsTable: lineNumber[5] | product[38] | remainingDeviation[12] | quantity[12]* |
                price[12]* | priceSource[14] | amount[14]
    total: «Всього: <totalAmount> UAH»
  TAB Рухи (лише POSTED)
    QueryTable postingMovements (GetDocumentMovements): register | lineNumber | product |
               quantity | costAmount
FOOTER
  comment[100]
```

Рядок із `price = null` підсвічується червоним пунктиром (обов'язкове до проведення);
`priceSource = MANUAL` показується курсивом.

#### 5.3. Форма вибору документа

`number[12] | occurredAt[16] | warehouse[24] | totalAmount[14]`, лише `POSTED`.

### 6. Події введення

| Поле | Компонент | INPUT_COMMITTED → команда | Залежності | Сервер перераховує | Повертає | Помилка / фокус |
|---|---|---|---|---|---|---|
| `number` | TextField | `ChangeSurplusPostingHeader(number)` | — | — | поле | `DOCUMENT_NUMBER_NOT_UNIQUE` |
| `occurredAt` | DateTimeField | `ChangeSurplusPostingHeader(occurredAt)` | base | `remainingDeviation`; ціни не змінюються (лише «Перезаповнити ціни») | документ | `DATE_NOT_AFTER_BASE` |
| `baseInventoryId` | ReferenceField | `ChangeSurplusPostingBase(baseInventoryId)` | рядки порожні | warehouse, reason, occurredAt | документ | `BASE_NOT_POSTED`, `BASE_CHANGE_WITH_LINES` |
| `warehouseId` | ReferenceField | `ChangeSurplusPostingHeader(warehouseId)` | без підстави | ціни рядків з `priceSource ≠ MANUAL` | документ | `REFERENCE_NOT_ACTIVE`, `BASE_WAREHOUSE_MISMATCH` |
| `reason` | TextField | `ChangeSurplusPostingHeader(reason)` | — | — | поле | `REQUIRED_FIELD_EMPTY` |
| `comment` | TextArea | `ChangeSurplusPostingHeader(comment)` | — | — | поле | довжина |
| `totalAmount` | NumberField (disabled) | — | — | — | — | — |
| `scanInput` (форма) | TextField | `LookupBarcode(barcode)` → `AddOrIncrementLineByBarcode(documentId, productId, unitQuantity, expectedVersion)` | `RegBarcode` | quantity, amount, totalAmount | рядок + підсумок | `BARCODE_NOT_FOUND`, `PRODUCT_SERVICE_NOT_ALLOWED`, `SURPLUS_PRODUCT_NOT_IN_BASE` (попередження); поле очищується, фокус лишається |
| `line.productId` | ReferenceCell | `SetSurplusPostingLineProduct(lineId, productId, version)` | warehouse, occurredAt, base | price, priceSource, amount, remainingDeviation, total | рядок + підсумок | `PRODUCT_SERVICE_NOT_ALLOWED`, `SURPLUS_PRODUCT_NOT_IN_BASE` (попередження) |
| `line.quantity` | NumberCell | `ChangeSurplusPostingLineQuantity(lineId, quantity, version)` | дробність, remaining | amount, total | рядок + підсумок | `QUANTITY_NOT_FRACTIONAL`, `QUANTITY_MUST_BE_POSITIVE`, `SURPLUS_EXCEEDS_DEVIATION` (попередження) |
| `line.price` | NumberCell | `ChangeSurplusPostingLinePrice(lineId, price\|null, version)` | — | priceSource=MANUAL (або перерахунок за правилом, якщо null), amount, total | рядок + підсумок | `PRICE_MUST_BE_NON_NEGATIVE`; 0 → `ZERO_VALUATION` (попередження) |
| `line.priceSource`, `amount`, `remainingDeviation` | (disabled) | — | — | — | — | — |

Сканер: Наявний рядок товару (перший за `lineNumber`) → `quantity += unitQuantity`; інакше новий рядок з `quantity = unitQuantity` і ціною за §8; SERVICE → `PRODUCT_SERVICE_NOT_ALLOWED`.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Спільні правила: права, `expectedVersion` (`OPTIMISTIC_LOCK_CONFLICT`), статус
(`DOCUMENT_POSTED_READ_ONLY`), `idempotencyKey` для `POST`, `UNPOST`, `COPY`,
`FILL_FROM_BASE`, аудит `sys_audit_log`.

#### 7.1. NEW — `InitializeSurplusPosting(baseInventoryId?)`

Без підстави: порожня чернетка, `occurredAt = now`. З підставою — делегує
`DocInventoryCount.CREATE_SURPLUS_POSTING` (див. паспорт інвентаризації §7.9):
шапка з підстави, рядки = `FILL_FROM_BASE`; наявна чернетка за цією підставою
повертається замість нової.

#### 7.2. SAVE — `SaveSurplusPosting(dto, expectedVersion)`

Lock шапки, merge рядків, для рядків без ручної ціни — ціна за §8 (лише якщо поле
порожнє), перерахунок `amount/totalAmount`. Валідації: обов'язкові поля, SERVICE,
дробність, правила підстави (§2). Ліміт відхилення — попередження.

#### 7.3. POST — `PostSurplusPosting(id, expectedVersion, idempotencyKey)`

1. Lock шапки `FOR UPDATE`; `NO_LINES`.
2. `price is null` у будь-якому рядку → `PRICE_REQUIRED` «Рядок N: не вказано ціну
   оцінки товару «…» (немає собівартості та ціни постачальника). Вкажіть ціну вручну.»
3. Якщо є підстава: lock `doc_inventory_count … for update`, статус `POSTED`
   (`BASE_NOT_POSTED`), `occurredAt > inventory.occurredAt`, склад збігається.
   Для кожного товару: товар є в інвентаризації з `deviation > 0`
   (`SURPLUS_PRODUCT_NOT_IN_BASE` «Товар «…» не має надлишку за інвентаризацією №…»);
   `Σ quantity товару в документі + Σ в інших POSTED оприбуткуваннях за цією
   інвентаризацією <= deviation`, інакше `SURPLUS_EXCEEDS_DEVIATION` «Товар «…»:
   оприбутковується 1,000, а надлишок за інвентаризацією №… — 0,500 (уже оприбутковано
   0,000).»
4. Lock `ref_warehouse(warehouseId)`; `delete_movements('DocSurplusPosting', id)`;
   вставка рухів §9.
5. Перевірки в тій самій транзакції: при повторному проведенні (repost) зі зменшеною кількістю —
   `check_free_stock` (`INSUFFICIENT_FREE_STOCK`); `RegStockCost` ≥ 0.
6. Попередження `INVENTORY_RESULT_OUTDATED`, якщо дата ≤ дати проведеної інвентаризації
   цього складу (крім власної підстави; див. паспорт інвентаризації §7.11).
7. `status = POSTED`, аудит. Помилка — повний rollback.

#### 7.4. UNPOST — `UnpostSurplusPosting(id, expectedVersion, idempotencyKey)`

`require_posted`; lock складу; видалення рухів; `check_free_stock(warehouseId, products)` (інваріант `RegStockBalance − Σ RegStockReserve ≥ 0` за поточними підсумками `*_tot`) —
якщо оприбутковане вже продано/списано/переміщено (або зарезервовано) → `INSUFFICIENT_FREE_STOCK` «Недостатньо вільного
товару «…» на складі «…»: не вистачає 0,500 шт.»; `RegStockCost` < 0 →
`STOCK_COST_NEGATIVE`. `status = DRAFT`, аудит. Після скасування повторне «Створити
на підставі» в інвентаризації знову запропонує цю кількість.

#### 7.5. COPY (F9) — `CopySurplusPosting(id)`

Нова чернетка: склад, причина, коментар, рядки (`productId`, `quantity`, `price`,
`priceSource`); `baseInventoryId` **не копіюється** (повторне оприбуткування за тією
самою інвентаризацією має йти через команду підстави з контролем залишку);
`occurredAt = now`; без номера, аудиту, рухів.

#### 7.6. FILL_FROM_BASE — `FillSurplusPostingFromInventory(id, expectedVersion)`

Лише з підставою; замінює рядки (підтвердження в UI) рядками інвентаризації з
`remaining = deviation − Σ POSTED оприбутковано > 0`; `quantity = remaining`,
`price = inventory.price` (`priceSource = INVENTORY`), якщо null — правило §8.
Порожньо → `NOTHING_TO_POST_SURPLUS`.

#### 7.7. REFILL_PRICES — `RefillSurplusPostingPrices(id, includeManual, expectedVersion)`

Перераховує ціни за §8 на поточні `occurredAt`/склад; рядки `MANUAL` — лише якщо
`includeManual = true`.

#### 7.8. Довідник помилок

Усі помилки піднімаються через `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error(-20100, …)`); код — UPPER_SNAKE на початку тексту в квадратних дужках, попередження (warning) повертаються як повідомлення APEX без rollback.

| Код | Повідомлення |
|---|---|
| `PRICE_REQUIRED` | Рядок N: не вказано ціну оцінки товару «…». Вкажіть ціну вручну. |
| `ZERO_VALUATION` (warning) | Рядок N: товар оприбутковується з нульовою вартістю. |
| `SURPLUS_EXCEEDS_DEVIATION` | Товар «…»: оприбутковується X, а надлишок за інвентаризацією №… — Y (уже оприбутковано Z). |
| `SURPLUS_PRODUCT_NOT_IN_BASE` | Товар «…» не має надлишку за інвентаризацією №… |
| `BASE_NOT_POSTED` | Інвентаризацію-підставу не проведено. |
| `BASE_WAREHOUSE_MISMATCH` | Склад документа має збігатися зі складом інвентаризації («…»). |
| `BASE_CHANGE_WITH_LINES` | Щоб змінити підставу, спочатку очистіть табличну частину. |
| `DATE_NOT_AFTER_BASE` | Дата документа має бути пізнішою за дату інвентаризації (…). |
| `NOTHING_TO_POST_SURPLUS` | Надлишків для оприбуткування немає. |
| `PRODUCT_SERVICE_NOT_ALLOWED` | «…» — послуга; послуги не оприбутковуються на склад. |
| `BARCODE_NOT_FOUND` | Штрихкод «…» не знайдено. |
| `INSUFFICIENT_FREE_STOCK` | Недостатньо вільного товару «…» на складі «…»: не вистачає … (залишок …, резерв …). |
| `STOCK_COST_NEGATIVE` | Вартість запасу товару «…» на складі «…» стане від'ємною. |
| спільні r2 | `NO_LINES`, `DOCUMENT_NOT_POSTED`, `DOCUMENT_POSTED_READ_ONLY`, `OPTIMISTIC_LOCK_CONFLICT`, `PERMISSION_DENIED`, `QUANTITY_NOT_FRACTIONAL`, `REQUIRED_FIELD_EMPTY` |

### 8. Розрахунки

Ціна оцінки (під час вибору товару, `FILL_FROM_BASE`, `REFILL_PRICES`), перше непорожнє:

1. `INVENTORY` — `price` рядка інвентаризації-підстави (якщо задана й не null);
2. `AVERAGE_COST` — `round(costBalance / qtyBalance, 2)` з `RegStockCost`
   (warehouseId, productId) на `occurredAt`, якщо `qtyBalance > 0`;
3. `LAST_AVERAGE_COST` — `RegStockCost.lastAverageCost(warehouseId, productId, occurredAt)`:
   середня на останній момент до `occurredAt`, коли залишок був > 0;
4. `SUPPLIER_PRICE` — остання за `period <= occurredAt` ціна `RegSupplierPrice` товару
   (будь-який постачальник; при однаковому периоді — більша `lineNumber` пізнішого реєстратора);
5. `NONE` — `price = null`, ручне введення обов'язкове до `POST`.

Ручне введення ставить `priceSource = MANUAL`; очищення ціни повертає до правила.

- `amount = round(quantity × price, 2)` `HALF_UP`; `price = null` → `amount = 0`
  (документ не проводиться).
- `totalAmount = Σ amount`, stored.
- `remainingDeviation = inventory.deviation − Σ quantity товару в POSTED оприбуткуваннях
  за підставою (без поточного)`, transient.

Приклади:

| Товар | Стан RegStockCost / ціни | Ціна | Джерело | К-сть | Сума |
|---|---|---|---|---|---|
| Кабель | 4,000 / 80,00 | 20,00 | AVERAGE_COST | 0,500 | 10,00 |
| Фарба | 0 зараз; до цього 115,00 | 115,00 | LAST_AVERAGE_COST | 1,000 | 115,00 |
| Клей | ніколи не було; RegSupplierPrice 42,50 | 42,50 | SUPPLIER_PRICE | 3,000 | 127,50 |
| Скотч | нічого | null → 15,00 вручну | MANUAL | 2,000 | 30,00 |
| Шпатель | 3,000 / 100,00 | 33,33 | AVERAGE_COST | 0,333 | 11,10 |

### 9. Проведення й регістри

Запис у регістри — лише всередині проведення під прапором `trade_core.g_internal`; похідні таблиці підсумків `*_tot` і знімків `*_snap` регістрів залишків оновлюються в тій самій транзакції. Порядок блокувань: рядок документа-підстави → `ref_counterparty` → `ref_warehouse` (`FOR UPDATE`).

`period = occurredAt`; `lineNumber` руху = `lineNumber` рядка в обох регістрах.

#### 9.1. RegStockBalance

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **+** |

#### 9.2. RegStockCost

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **+** |
| `costAmount` | `line.amount` | **+** |

Оприбуткування, як і надходження, змінює середню ковзну: нова середня =
`(costBalance + amount) / (qtyBalance + quantity)`. Приклад: Кабель 4,000/80,00 +
0,500/10,00 → 4,500/90,00, середня 20,00 (не змінилась, бо оцінка за середньою);
Клей 0/0 + 3,000/127,50 → середня 42,50.

`RegCounterpartySettlement`, `RegSales`, `RegSupplierPrice` не змінюються.

#### 9.3. Повторне проведення й скасування

Повторне проведення атомарно замінює набори обох регістрів (ціни не перераховуються —
беруться збережені). `UNPOST` видаляє набори з перевіркою від'ємних залишків (§7.4).
`trade_ops.delete_movements` доповнюється `reg_stock_cost_mv`.

### 10. Зберігання й API

```text
doc_surplus_posting
  PK id; UNIQUE doc_number; FK warehouse_id → ref_warehouse;
  FK base_inventory_id → doc_inventory_count(id) (nullable);
  NOT NULL reason varchar2(255); CHECK status IN ('DRAFT','POSTED'); CHECK currency_code = 'UAH'
  INDEX (occurred_at), (warehouse_id), (base_inventory_id, status)
doc_surplus_posting_goods
  PK id; FK document_id ON DELETE CASCADE; FK product_id → ref_product;
  CHECK quantity > 0; CHECK price IS NULL OR price >= 0;
  CHECK price_source IN ('INVENTORY','AVERAGE_COST','LAST_AVERAGE_COST','SUPPLIER_PRICE','MANUAL','NONE');
  INDEX (document_id, line_number); INDEX (product_id)
```

Тригер read-only у `POSTED`; пакет `trade_ops`: `post_surplus_posting`,
`unpost_surplus_posting`, `copy_surplus_posting`, `fill_surplus_from_inventory`,
`surplus_price(p_warehouse_id, p_product_id, p_at, o_source)`.

| Метод | Шлях | Призначення |
|---|---|---|
| GET | `/api/v1/documents/surplus-postings` | список (period, warehouseId, status, baseInventoryId) |
| GET | `…/new?baseInventoryId=` | ініціалізація |
| GET/POST/PUT | `…/{id}`, `…`, `…/{id}` | читання/створення/запис |
| POST | `…/{id}/post`, `/unpost`, `/copy`, `/fill-from-base`, `/refill-prices` | команди |
| GET | `…/{id}/movements` | рухи |
| GET | `…/{id}/print/act` | «Акт оприбуткування надлишків» (PDF): склад, підстава, причина, товари з цінами й сумами, підписи комісії |

### 11. Тести й готовність

- Unit: ланцюг джерел ціни (усі 5 гілок), `MANUAL` і повернення до правила, `amount`
  з null.
- Проведення: обидва регістри, нова середня, repost без дублів, `PRICE_REQUIRED`.
- Підстава: `SURPLUS_EXCEEDS_DEVIATION` з урахуванням інших POSTED документів,
  `SURPLUS_PRODUCT_NOT_IN_BASE`, `BASE_WAREHOUSE_MISMATCH`, `DATE_NOT_AFTER_BASE`;
  паралельне проведення двох оприбуткувань за однією інвентаризацією (lock підстави).
- UNPOST після споживання надлишку → `INSUFFICIENT_FREE_STOCK`.

Наскрізний сценарій:

1. Інвентаризація №1 (склад «Основний», 10.11 18:00) проведена: Кабель облік 4,000,
   факт 4,500 (+0,500, ціна 20,00); Клей облік 0, факт 3,000 (+3,000, ціна null).
2. «Створити на підставі → Оприбуткування надлишків» → чернетка №1 від 10.11 18:00:01:
   Кабель 0,500 × 20,00 (INVENTORY) = 10,00; Клей 3,000 × 42,50 (SUPPLIER_PRICE) = 127,50;
   всього 137,50.
3. Оператор змінює Клей на 4,000 → попередження `SURPLUS_EXCEEDS_DEVIATION`; «Провести»
   → помилка; повертає 3,000 → проводиться: Stock Кабель 4,500, Клей 3,000; StockCost
   Кабель 90,00, Клей 127,50.
4. Друга спроба «Створити на підставі» → `NOTHING_TO_POST_SURPLUS`.
5. Окреме оприбуткування №2 без підстави: Скотч 2,000, ціна вручну 15,00 → 30,00, проведено.
6. Реалізація 3,000 Клею → залишок 0; `UNPOST` оприбуткування №1 → `INSUFFICIENT_FREE_STOCK`
   «Недостатньо вільного товару «Клей» на складі «Основний»: не вистачає 3,000 шт.»
7. `UNPOST` інвентаризації №1 → `BASE_HAS_POSTED_DERIVED`.
