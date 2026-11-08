# Паспорт документа «Замовлення постачальнику»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`. Реалізація до погодження заборонена.
- Ревізія: `r3`.
- Розділ меню (підсистема «Такси»): `Purchases` «Закупівлі», група «Закупівлі», позиція перед
  «Прибуткова накладна» (`is_important = 'Y'`); звіт «Потреба в закупівлі» — колонка 2.
- Залежності: `RefCounterparty`, `RefContract` (вид `WITH_SUPPLIER`), `RefWarehouse`,
  `RefProduct` r3 (`productKind`), `RegSupplierPrice`, `RegSupplierOrders`, `RegReorderPolicy`,
  `RegStockBalance`, `RegStockReserve`, `DocGoodsReceipt` r3, `RegStockCost`.
- Аналог у 1С:УТ 11: `Документ.ЗаказПоставщику` (спрощено: без графіка оплати й етапів;
  заповнення за потребою — аналог обробки «Формирование заказов по потребностям»).
- Функції каталогу: F-PUR-01, F-PUR-03, F-PUR-06, F-PRC-04, F-WH-08, F-SRV-01, F-SRV-02,
  F-SRV-03, F-REP-07.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Замовлення постачальнику |
| Технічне ім'я | `DocSupplierOrder` |
| Технічний ключ | `Document.SupplierOrder` |
| Клас / ID | `SupplierOrder` / `SupplierOrderId` |
| Таблиці | `doc_supplier_order`, `doc_supplier_order_goods` |
| DTO | `SupplierOrderDto`, `SupplierOrderLineDto`, `SupplierOrderListItemDto` |
| API | `/api/v1/documents/supplier-orders` |
| Сторінки APEX | 270 — список, 271 — форма документа |
| Recorder type | `DocSupplierOrder` (`trade_ops.c_supplier_order`) |
| Нумерація | 9 цифр, `doc_supplier_order_num_seq`, під час першого запису, унікальна, редагована в `DRAFT` |
| Дата | `occurredAt`, DateTime (секунди, Oracle `date`) |
| Підстава | не має; заповнюється з `RegReorderPolicy`; є підставою для `DocGoodsReceipt` r3 |
| Видалення | `DRAFT` — фізично; `POSTED` — заборонено |

Документ фіксує план закупівлі: що, скільки, за якою ціною й до якої дати очікується від
постачальника. Невиконаний залишок враховується в розрахунку потреби як «в дорозі».

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ні | PK |
| `number` | Номер | String | 9 | так | sequence | `DRAFT` | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | `sysdate` | `DRAFT` | `occurred_at`, index |
| `supplierId` | Постачальник | reference | 32 | так | — | `DRAFT` | `RefCounterparty`, FK `supplier_id` |
| `contractId` | Договір | reference | 32 | ні | `ResolveDefaultContract(supplierId, WITH_SUPPLIER, occurredAt)` — лише якщо чинний договір рівно один | `DRAFT` | `RefContract`, FK `contract_id` |
| `warehouseId` | Склад | reference | 32 | так | склад останнього замовлення користувача | `DRAFT` | `RefWarehouse`, FK |
| `expectedDate` | Очікувана дата надходження | Date | day | так | `trunc(occurredAt) + 7` | `DRAFT` | `expected_date`, index |
| `closed` | Закрите | Boolean | 1 | так | `false` | командами `CLOSE/REOPEN` | `closed` `'Y'/'N'` |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | read-only | CHECK = `UAH` |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ні | stored |
| `comment` | Коментар | String | 1000 | ні | — | `DRAFT` | `doc_comment` |
| `status` | Статус | enum | — | так | `DRAFT` | командами | `DRAFT/POSTED` |
| `version`, аудит | Службові | — | — | так | server | ні | optimistic/audit |

`executionState` (похідне, не stored): `CLOSED` «Закрите», якщо `closed = true`; `RECEIVED` «Отримане»,
якщо відкрите і залишок `RegSupplierOrders` по всіх товарах = 0; інакше `OPEN` «Відкрите»; для `DRAFT` порожнє.

### 3. Таблична частина `Goods` «Товари»

Таблиця `doc_supplier_order_goods`, клас `SupplierOrderLine`, стабільний `lineId` (UUID),
`lineNumber` 1..n.

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Обмеження |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ні | PK |
| `lineNumber` | N | Integer | 10 | так | max+1 | порядком | — |
| `productId` | Номенклатура | reference | 32 | так | — | `DRAFT` | `RefProduct`, `GOODS` або `SERVICE`, `ACTIVE` |
| `quantity` | Кількість | Decimal | 19,3 | так | 1 | `DRAFT` | > 0, дробність |
| `price` | Ціна | Decimal | 19,2 | так | `trade_lines.get_supplier_price(supplierId, productId, occurredAt)` | `DRAFT` | >= 0 |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ні | stored |

Товар може повторюватися рядками; команда «Заповнити за потребою» групує по товару і додає лише
`GOODS`. Послуги (наприклад, доставка постачальника) дозволені й рухають `RegSupplierOrders`.

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Шапка / рядки |
|---|---|---|---|---|---|
| — | `NEW` | `DRAFT` | `document.supplier-order.create` | — | редаговані |
| `DRAFT` | `SAVE` | `DRAFT` | `...update` | валідація | редаговані |
| `DRAFT` | `FILL_BY_REORDER_POLICY` | `DRAFT` | `...update` | склад заданий | редаговані |
| `DRAFT` | `POST` | `POSTED`, `closed=false` | `...post` | є рядки | read-only |
| `POSTED` | `POST` повторно | `POSTED` | `...post` | idempotent | read-only |
| `POSTED`, відкрите | `CLOSE` | `POSTED`, `closed=true` | `...close` | — | read-only |
| `POSTED`, закрите | `REOPEN` | `POSTED`, `closed=false` | `...close` | — | read-only |
| `POSTED` | `UNPOST` | `DRAFT`, `closed=false` | `...unpost` | немає проведених надходжень на підставі | редаговані |
| `DRAFT` | `DELETE` | — | `...delete` | немає документів на підставі | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `...create` | — | — |

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 270)

Колонки: `icon[4] | number[10] | occurredAt[14] | supplier[24] | warehouse[14] |
expectedDate[10] | totalAmount[12] | receivedPercent[8] | executionState[8] | comment[*]`.
`receivedPercent = round(100 × (замовлено − залишок) / замовлено)` за кількістю з `RegSupplierOrders`.
Іконки: `fa-file-o` — `DRAFT`; `fa-check-square` — `OPEN`; `fa-truck` — `RECEIVED`; `fa-lock` — `CLOSED`;
прострочене (`expectedDate < trunc(sysdate)` і залишок > 0) — червона дата.
Фільтри: період, постачальник, склад, стан (Чернетки/Відкриті/Закриті/Усі), «Прострочені».
Команди: `Створити` | `Скопіювати (F9)` | `Провести` | `Скасувати проведення` | `Закрити
замовлення` | `Створити на підставі ▾` (Прибуткова накладна) | `Пошук (Ctrl+F)` | `Ще`.

#### 5.2. Форма документа (сторінка 271)

```text
FORM supplierOrder  title: «Замовлення постачальнику 000000007 від 08.11.2026 (проведено, відкрите)»
HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення
           | Закрити замовлення / Відкрити замовлення
           | Створити на підставі ▾ (Прибуткова накладна)
           | Друк ▾ (Замовлення постачальнику) | Ще ▾ (Скопіювати F9, Рухи документа, Журнал змін)
  row1: number[15] | occurredAt[20] | expectedDate[15] | status/executionState[20, read-only]
  row2: supplier[45] | contract[35]
  row3: warehouse[45]
CONTENT
  scanInput[40] «Штрихкод» (над вкладкою «Товари», Ctrl+Shift+B; лише DRAFT)
  TAB «Товари» (DocumentLineTable)
    commands: Додати | Підбір | Заповнити за потребою… | Оновити ціни постачальника
              | ↑ | ↓ | Видалити | Ще
    columns: lineNumber[4] | product[40] | unit[6, ro] | quantity[12] | price[12] | amount[14, ro]
    footer: «Всього:» totalAmount
  TAB «Потреба» (QueryTable reorderNeed)
  TAB «Виконання» (QueryTable fulfillment, лише POSTED)
FOOTER
  comment[100]
```

Діалог «Заповнити за потребою…»: `mode` (Замінити рядки / Додати до рядків, default «Замінити»),
прапорець «Лише товари з основним постачальником = постачальник документа» (default увімкнено),
прапорець «Включати товари без основного постачальника» (default вимкнено), відбір групи
`RefProductGroup` (необов'язковий). Кнопки `Заповнити` | `Скасувати`.

`QUERY_TABLE reorderNeed "Потреба"`: query `GetReorderNeed`; params `warehouseId <- HEADER`,
`supplierId <- HEADER`, `atMoment <- sysdate`; колонки `product`, `minQuantity "Мін."`,
`maxQuantity "Макс."`, `balance "Залишок"`, `reserved "Резерв"`, `onOrder "Замовлено"`,
`available "Доступно" calculated`, `need "Потреба" calculated`; refresh `ON_OPEN, MANUAL`.

`QUERY_TABLE fulfillment "Виконання"`: `ordered`, `received`, `remaining` (`RegSupplierOrders`),
row action — відкрити прибуткову накладну.

#### 5.3. Форма вибору

`number[12] | occurredAt[14] | supplier[30] | expectedDate[10] | totalAmount[12] | executionState[10]`;
лише `POSTED`; з поля `DocGoodsReceipt.baseOrderId` — відбір відкритих замовлень постачальника.

### 6. Події введення

Команди містять `documentId`, `expectedVersion`, рядкові — `lineId`; відповідь — повний
`SupplierOrderDto` + `warnings[]`.

| Реквізит | Компонент | Команда | Серверна реакція / перераховано |
|---|---|---|---|
| `number` | TextField | `ChangeSupplierOrderNumber(id, value, version)` | формат, унікальність |
| `occurredAt` | DateTimeField | `ChangeSupplierOrderDate(id, value, version)` | `expectedDate` зсувається до `trunc(value)+7`, якщо стає меншою за дату; ціни не змінюються |
| `expectedDate` | DateField | `ChangeSupplierOrderExpectedDate(id, value, version)` | `>= trunc(occurredAt)`, інакше `EXPECTED_DATE_BEFORE_ORDER_DATE` |
| `supplierId` | ReferenceField | `ChangeSupplierOrderSupplier(id, supplierId, version)` | очищення договору; `ResolveDefaultContract(supplierId, WITH_SUPPLIER, occurredAt)`; warning «Застосуйте Оновити ціни постачальника» |
| `contractId` | ReferenceField (owner=supplier, kind=WITH_SUPPLIER) | `ChangeSupplierOrderContract(id, contractId, version)` | `CONTRACT_OWNER_MISMATCH`, `CONTRACT_KIND_MISMATCH`, `CONTRACT_NOT_VALID_ON_DATE` |
| `warehouseId` | ReferenceField | `ChangeSupplierOrderWarehouse(id, warehouseId, version)` | оновлення `reorderNeed` |
| `comment` | TextArea | `ChangeSupplierOrderComment(id, value, version)` | ≤ 1000 |
| `closed` | — | `CloseSupplierOrder` / `ReopenSupplierOrder` | без mutation поля |
| `Goods.productId` | ReferenceTableCell | `ChangeSupplierOrderLineProduct(lineId, productId, version)` | `price = trade_lines.get_supplier_price(supplierId, productId, occurredAt)`, якщо знайдено; `amount`, `totalAmount` |
| `Goods.quantity` | NumericCell 19,3 | `ChangeSupplierOrderLineQuantity(lineId, value, version)` | дробність; `amount`, `totalAmount` |
| `Goods.price` | NumericCell 19,2 | `ChangeSupplierOrderLinePrice(lineId, value, version)` | `>= 0`; `amount`, `totalAmount` |
| `Goods.amount` | — | disabled | — |
| `Goods.lineNumber` | — | `MoveSupplierOrderLine(lineId, direction, version)` | перенумерація |
| `scanInput` | TextField (transient) | `LookupBarcode(code)` → `AddOrIncrementLineByBarcode(docId, productId, unitQuantity, expectedVersion)` | `RegBarcode`; +`unitQuantity` до наявного рядка товару або новий рядок з ціною постачальника; `BARCODE_NOT_FOUND` — поле очищається, фокус лишається |

Рядки: `AddSupplierOrderLine`, `DeleteSupplierOrderLine`, `CopySupplierOrderLine` (новий `lineId`).

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Обов'язкові сценарії

Спільне: право, статус, `expectedVersion` (`OPTIMISTIC_LOCK_CONFLICT`), `idempotencyKey`, аудит;
помилки — `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error -20100`).

- **NEW** `InitializeSupplierOrder()` — `occurredAt=sysdate`, `expectedDate=trunc(sysdate)+7`,
  `closed=false`, `UAH`, порожні рядки.
- **SAVE** `SaveSupplierOrder(dto, expectedVersion, idempotencyKey)` — `DRAFT`; валідації:
  обов'язкові поля, `REF_NOT_ACTIVE`, `CONTRACT_OWNER_MISMATCH`, `CONTRACT_KIND_MISMATCH`
  «Договір не є договором з постачальником», `CONTRACT_NOT_VALID_ON_DATE`, `EXPECTED_DATE_BEFORE_ORDER_DATE` «Очікувана дата не
  може бути раніше дати замовлення», `QUANTITY_NOT_POSITIVE`, `QUANTITY_FRACTION_NOT_ALLOWED`, `PRICE_REQUIRED`
  «Для товару «X» немає ціни постачальника — вкажіть ціну». `POSTED` → `DOCUMENT_POSTED_READ_ONLY`.
- **POST** `PostSupplierOrder(id, expectedVersion, idempotencyKey)` — `select for update` шапки,
  `DOCUMENT_HAS_NO_LINES`, повторна валідація, `lock_counterparty(supplierId)`; заміна рухів
  `RegSupplierOrders`; при повторному проведенні — `ORDER_QUANTITY_BELOW_RECEIVED` «Кількість «X»
  менша за вже отриману», якщо залишок по товару став < 0; `status=POSTED`, `closed=false`; аудит `POST`.
- **UNPOST** `UnpostSupplierOrder(id, expectedVersion)` — видалення всіх рухів (також закривальних);
  залишок `RegSupplierOrders(order, product) < 0` → `ORDER_HAS_RECEIPTS` «Є проведені
  надходження на підставі замовлення: <номери>.»; `status=DRAFT`, `closed=false`; аудит.
- **COPY** `CopySupplierOrder(id)` — нова чернетка без `id/number/status/closed/аудиту`, нові
  `lineId`, ціни копіюються як є; аудит `COPY`.
- **CLOSE** `CloseSupplierOrder(id, expectedVersion)` — перепроведення зі звичайними й закривальними
  рухами (розд. 9.2), `closed=true`; повтор idempotent; `DOCUMENT_NOT_POSTED`. **REOPEN** — видаляє рухи з
  `lineNumber >= 10000`, `closed=false`.
- **UPDATE_SUPPLIER_PRICES** «Оновити ціни постачальника» `UpdateSupplierOrderPrices(id, version)` —
  для кожного рядка `price = trade_lines.get_supplier_price(supplierId, productId, occurredAt)`
  (`RegSupplierPrice` latestAt); без ціни — рядок без змін + `warnings[]`.
- **FILL_BY_REORDER_POLICY** `FillSupplierOrderByReorderPolicy(id, mode, onlyPreferred,
  includeWithoutSupplier, groupId?, expectedVersion)` — `DRAFT`, право `update`, склад обов'язковий
  (`WAREHOUSE_REQUIRED`). Алгоритм:
  1. Вибрати політики `RegReorderPolicy` з `warehouseId = header.warehouseId` (і групою, якщо задано);
     фільтр постачальника: `preferredSupplierId = header.supplierId`; при
     `includeWithoutSupplier` — також `preferredSupplierId is null`; при `onlyPreferred=false` — усі.
  2. Для кожного `(warehouse, product)` за формулою паспорта `RegReorderPolicy`:
     `available = balance − reserved + onOrder`, де `balance` — `RegStockBalance`, `reserved` —
     `RegStockReserve` (усі замовлення), `onOrder` — залишок `RegSupplierOrders` відкритих проведених
     замовлень на цей склад; якщо `available <= minQuantity`, то `need = maxQuantity − available`,
     інакше `need = 0`.
  3. У режимі «Додати» `need -= Σ quantity` рядків цього документа з тим самим товаром.
  4. Для одиниць без дробності `need = ceil(need)`; `need <= 0` — пропуск.
  5. Рядок: `quantity = need`, `price = trade_lines.get_supplier_price(header.supplierId, product, occurredAt)` або порожня
     (warning `PRICE_REQUIRED`). «Замінити» видаляє всі рядки перед заповненням.
  Результат: кількість доданих рядків; якщо 0 — інформація `NO_REORDER_NEED` «Потреби в закупівлі
  немає». Аудит `FILL_BY_REORDER_POLICY`.
- **CREATE_BASED_ON** `CreateBasedOnSupplierOrder(id, 'DocGoodsReceipt')` — лише `POSTED`,
  `closed=false` (`BASE_ORDER_NOT_POSTED`, `BASE_ORDER_CLOSED`), залишок > 0 (`NOTHING_TO_RECEIVE` «За замовленням усе
  отримано»); повертає незаписану чернетку надходження (розд. 10).

### 8. Розрахунки

- `amount = round(quantity × price, 2)`, `HALF_UP`, stored; `totalAmount = Σ amount`.
- `null`: незавершене введення не надсилається; `price=null` на SAVE → `trade_lines.get_supplier_price`,
  інакше `PRICE_REQUIRED`.
- Приклади: `2,500 × 12,34 = 30,85`; `3 × 33,35 = 100,05`; `0,125 × 10,01 = 1,25125 → 1,25`;
  `0,333 × 1,50 = 0,4995 → 0,50` (HALF_UP); ціна 0,00 дає суму 0,00 (безкоштовна поставка).
  Рядки 30,85 + 100,05 + 1,25 → `totalAmount = 132,15`.
- Потреба (приклад): `min = 10`, `max = 50`, залишок 12, резерв 5, у замовленнях 3 →
  `available = 12 − 5 + 3 = 10 <= 10` → `need = 40`. Залишок 20 → `available = 18 > 10` → 0.
  Дробна одиниця «кг»: `max = 25,5`, `available = 4,25` → `need = 21,250`; штучна: `need = 7,2 → 8`.

### 9. Проведення й регістри

#### 9.1. `RegSupplierOrders` — один рух на рядок

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `recorder` | `DocSupplierOrder`, `id` | — |
| `lineNumber` | `Goods.lineNumber` | — |
| `supplierOrderId` | `header.id` | — |
| `productId` | `Goods.productId` | — |
| `quantity` | `Goods.quantity` | + |
| `amount` | `Goods.amount` | + |

Перевірки в транзакції: при повторному проведенні — залишок по `(order, product) >= 0`.

#### 9.2. Закриття

`CLOSE` перепроводить замовлення: звичайні рухи 9.1 + для кожного товару `k` (1, 2, … за мінімальним
`lineNumber` товару) із залишком > 0 рух того самого
реєстратора `lineNumber = 10000 + k`, `period = sysdate`, `quantity = −remainingQty`,
`amount = −remainingAmount`. `REOPEN` видаляє ці рухи. Повторне проведення атомарно замінює
набір; `UNPOST` видаляє всі рухи з перевіркою залежних надходжень.

### 10. Зміни суміжних об'єктів (`DocGoodsReceipt` r3)

Описано тут; під час погодження переноситься в паспорт `DocGoodsReceipt` як ревізія r3.

**Нові поля шапки `doc_goods_receipt`:** `baseOrderId` «Замовлення постачальнику» (reference
`DocSupplierOrder`, необов'язкове, `DRAFT`, FK `base_order_id`, index); `contractId` «Договір»
(`RefContract` `WITH_SUPPLIER`, необов'язкове, FK `contract_id`). Рядки r3 — `GOODS` і `SERVICE`;
послуги не рухають `RegStockBalance` і `RegStockCost`, але пишуться в `RegSupplierOrders`,
розрахунки й `RegSupplierPrice`. Зв'язку рядків із рядками замовлення немає — зіставлення лише
за `productId`.

**Заповнення на підставі** (`CreateBasedOnSupplierOrder` або команда «Заповнити за замовленням»
`FillGoodsReceiptByOrder(receiptId, version)`): `supplierId, contractId, warehouseId` — із
замовлення; для кожного товару `remainingQty` з `RegSupplierOrders` розподіляється по рядках
замовлення в порядку `lineNumber` (`min(line.quantity, залишок)`), `price = line.price`.
Приклад: замовлено 100 шт × 12,00, отримано 60 → рядок 40 × 12,00 = 480,00.

**Валідації `POST` з `baseOrderId`:** замовлення `POSTED` (`BASE_ORDER_NOT_POSTED`), `closed=false`
(`BASE_ORDER_CLOSED`); `receipt.supplierId = order.supplierId` (`BASE_ORDER_SUPPLIER_MISMATCH`);
`receipt.warehouseId = order.warehouseId` (`BASE_ORDER_WAREHOUSE_MISMATCH`). Порядок блокувань:
шапка надходження → рядок замовлення `FOR UPDATE` → `lock_counterparty(supplierId)` →
`lock_warehouse(warehouseId)`. Форма надходження r3 також отримує `scanInput` над «Товари».

**Рухи надходження r3** (`lineNumber` = `Goods.lineNumber`; settlement — 1):

| Регістр | Умова | Мапінг |
|---|---|---|
| `RegStockBalance` | `GOODS` | `quantity = +q` (як r1) |
| `RegCounterpartySettlement` | завжди | `PAYABLE`, `+totalAmount` (як r1) |
| `RegSupplierOrders` | `baseOrderId` задано і `received > 0` | `supplierOrderId = baseOrderId`, `productId`, `quantity = −received`, `amount = −receivedAmount` |
| `RegSupplierPrice` | `Σamount > 0` по товару | запис на кожен окремий товар (див. нижче) |
| `RegStockCost` | `GOODS` | `quantity = +q`, `costAmount = +Goods.amount` |

`received = min(q, remainingLeft)` — рядки товару обробляються за `lineNumber`, `remainingLeft`
зменшується; надлишок над замовленням не рухає `RegSupplierOrders` і дає warning
`RECEIPT_EXCEEDS_ORDER` «Отримано 105,000 при залишку замовлення 100,000». `receivedAmount`: при
`received = Rq` — увесь `Ra`, інакше `round(received × Ra / Rq, 2)` (оцінка за цінами замовлення;
повне виконання дає рівно 0). Приклад: `Rq = 100`, `Ra = 1 200,00`; надходження 105 → рух
`−100 / −1 200,00` + warning; надходження 25 → `−25 / −300,00`.

`RegSupplierPrice`: один запис на окремий товар документа: `period = occurredAt`,
`supplierId = header.supplierId`, `productId`, `price = round(Σ amount / Σ quantity, 2)` за рядками
товару (середньозважена), `lineNumber` = мінімальний `lineNumber` товару; `recorder = DocGoodsReceipt`;
якщо `Σ amount = 0` — запис не створюється. Приклад: 10 × 2,40 і 5 × 2,55 → `36,75/15 = 2,45`.
Читання — `trade_lines.get_supplier_price(supplierId, productId, date)` (latestAt).

Перевірки в транзакції: `RegStockBalance >= 0` (для повторного проведення), `RegSupplierOrders >= 0`,
`RegStockCost` за правилами його паспорта. Скасування надходження видаляє всі рухи (залишок
замовлення відновлюється); якщо товар уже продано — `RegStockBalance` стає від'ємним і
скасування блокується (як r1). Надходження «заднім числом» позначає пізніші рухи `RegStockCost` до
перерахунку (паспорт `RegStockCost`).

### 11. Зберігання й API

```text
doc_supplier_order: id PK, doc_number UK, occurred_at, supplier_id FK, contract_id FK NULL,
  warehouse_id FK, expected_date date NOT NULL, closed varchar2(1) DEFAULT 'N' CHECK in ('Y','N'),
  currency_code CHECK='UAH', total_amount number(19,2), doc_comment, status CHECK in ('DRAFT','POSTED'),
  version, audit; CHECK (expected_date >= trunc(occurred_at)); CHECK (status='POSTED' or closed='N')
  indexes: (occurred_at), (supplier_id, occurred_at), (expected_date), (status, closed)
doc_supplier_order_goods: id PK, document_id FK ON DELETE CASCADE, line_number, product_id FK,
  quantity number(19,3) CHECK > 0, price number(19,2) CHECK >= 0, amount number(19,2);
  index (document_id, line_number), (product_id)
```

Тригери: `doc_supplier_order_biud`, compound `doc_supplier_order_goods_ct` (check_editable,
check_goods, ціна постачальника, amount, renumber, total). Пакет
`trade_ops`: `post_/unpost_/copy_/close_/reopen_supplier_order`, `fill_supplier_order_by_policy`.

API: `GET /`, `GET /picker`, `GET /new`, `GET /{id}`, `POST /`, `PUT /{id}`, `DELETE /{id}`,
`POST /{id}/post|unpost|close|reopen|copy|update-supplier-prices|fill-by-reorder-policy|lines/by-barcode`,
`POST /{id}/create-based-on/DocGoodsReceipt`, `GET /{id}/reorder-need`, `GET /{id}/fulfillment`,
`GET /{id}/movements`, `GET /{id}/print/order`. Права:
`document.supplier-order.read/create/update/delete/post/unpost/close`.
Друк «Замовлення постачальнику»: постачальник, договір, склад, очікувана дата, таблиця
N/Товар/Од./К-сть/Ціна/Сума, «Всього», підпис закупівельника.

### 12. Тести й готовність

- Unit: `amount`, дробність, формула потреби (усі приклади розд. 8), округлення `ceil`.
- Application: NEW/SAVE/POST/UNPOST/COPY/CLOSE/REOPEN; FILL_BY_REORDER_POLICY у режимах
  «Замінити»/«Додати» з фільтрами постачальника; idempotency; optimistic lock.
- БД: CHECK-и, FK, тригери, унікальність recorder+lineNumber, закривальні рухи 10000+k.
- API/UI: права, стани кнопок, діалог потреби, QueryTable, підбір, вибір.
- Наскрізний сценарій: політика «Цвях 100 мм» min 10/max 50, preferredSupplier = «Метизи»,
  залишок 12, резерв 5 → заповнення за потребою дає 40 шт × 2,40 (ціна постачальника) = 96,00;
  проведення → «Замовлено» 40; надходження на підставі 25 шт × 2,50 → `RegSupplierOrders −25 / −60,00`,
  `RegSupplierPrice` 2,50, `RegStockCost +62,50`; потреба тепер `available = 37 − 5 + 15 = 47 > 10`;
  `CLOSE` → залишок 0; `UNPOST` замовлення → `ORDER_HAS_RECEIPTS`.
