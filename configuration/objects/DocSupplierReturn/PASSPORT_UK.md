# Паспорт документа «Повернення постачальнику»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`; реалізація до погодження не виконується.
- Ревізія: `r3`.
- Розділ меню (Taxi): `Закупівлі` → група «Закупівлі» (після «Надходження товарів»);
  посилання на список також у `Склад` → «Складські операції».
- Залежності: `DocGoodsReceipt` (r3, проведений документ-підстава), `RefCounterparty`,
  `RefWarehouse`, `RefProduct` r3 (`productKind`), `RefContract` (копіювання з
  підстави), `RegStockBalance`, `RegCounterpartySettlement`, `RegStockCost`.
- Аналог у 1С:УТ 11: Документ.ВозвратТоваровПоставщику (спрощено: без повернення коштів
  від постачальника, без партійного обліку, собівартість — середня ковзна).
- Функції каталогу: `F-PUR-04` (основна), `F-SRV-01` (введення на підставі
  «Надходження → Повернення»), `F-WH-09` (списання вартості запасу), `F-REP-02`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Повернення постачальнику (список — «Повернення постачальникам») |
| Технічне ім'я | `DocSupplierReturn` |
| Технічний ключ | `Document.DocSupplierReturn` |
| Клас / ID | `SupplierReturn` / `SupplierReturnId` |
| Клас рядка | `SupplierReturnLine` / `SupplierReturnLineId` |
| Таблиці | `doc_supplier_return`, `doc_supplier_return_goods` |
| DTO | `SupplierReturnDto`, `SupplierReturnLineDto`, `SupplierReturnListItemDto` |
| API | `/api/v1/documents/supplier-returns` |
| Сторінки APEX | 290 — список, 291 — форма документа |
| Нумерація | `doc_supplier_return_num_seq`, 9 цифр (`000000001`), присвоюється під час першого запису, унікальна |
| Дата | `occurredAt`, `DATETIME`, точність секунда, Europe/Kyiv |
| Підстава | `DocGoodsReceipt` у статусі `POSTED`, обов'язкова (`baseReceiptId`) |
| Видалення | чернетку — фізично; проведений документ не видаляється |
| recorder_type | `DocSupplierReturn` |

Документ фіксує повернення постачальнику товару, отриманого раніше за надходженням
(брак, пересорт, надлишок поставки): товар вибуває зі складу за середньою
собівартістю, кредиторська заборгованість перед постачальником зменшується на суму
повернення за цінами надходження.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування (по статусах) | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ніколи | PK |
| `number` | Номер | String | 9 | так | sequence | DRAFT | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | now | DRAFT | `occurred_at`, index |
| `baseReceiptId` | Надходження (підстава) | ref `DocGoodsReceipt` | 32 | так | з «Створити на підставі» | DRAFT, лише без рядків | `base_receipt_id`, FK, index |
| `supplierId` | Постачальник | ref `RefCounterparty` | 32 | так | `baseReceipt.supplierId` | ніколи | `supplier_id`, FK, index |
| `contractId` | Договір | ref `RefContract` | 32 | ні | `baseReceipt.contractId` | ніколи | `contract_id`, FK |
| `warehouseId` | Склад | ref `RefWarehouse` | 32 | так | `baseReceipt.warehouseId` | DRAFT | `warehouse_id`, FK |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | ніколи в r3 | CHECK = 'UAH' |
| `returnReason` | Причина повернення | String | 255 | так | — | DRAFT | `return_reason` |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ніколи | stored |
| `comment` | Коментар | String | 1000 | ні | — | DRAFT | `doc_comment` |
| `status` | Статус | enum | 10 | так | `DRAFT` | командами | CHECK |
| `version`, аудит | Службові | — | — | так | server | ніколи | — |

Правила шапки:

- Договір під час `POST` повторно перевіряється спільними правилами `RefContract`: власник = контрагент документа (`CONTRACT_OWNER_MISMATCH`), вид договору відповідає операції — з постачальником (`CONTRACT_KIND_MISMATCH`).
- `supplierId`, `contractId` завжди з підстави (сервер перезаписує).
- `warehouseId` редагований: товар могли перемістити на інший склад після надходження;
  повертається зі складу, де він фактично є.
- `occurredAt >= baseReceipt.occurredAt`, інакше `RETURN_DATE_BEFORE_BASE`.
- `returnReason` обов'язкова (друкується в накладній на повернення; претензійна
  робота з постачальником).

### 3. Таблична частина `Goods` («Товари»)

Таблиця `doc_supplier_return_goods`, стабільний `lineId`, `lineNumber`; UNIQUE
`document_id + base_receipt_line_id`.

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ніколи | PK |
| `lineNumber` | N | int | 10 | так | наступний | порядком | `line_number` |
| `baseReceiptLineId` | Рядок надходження | UUID | 32 | так | з підбору | ніколи | FK → `doc_goods_receipt_goods(id)` |
| `productId` | Товар | ref `RefProduct` | 32 | так | з рядка підстави | ніколи | FK |
| `quantity` | Кількість | Decimal | 19,3 | так | повертаємий залишок | DRAFT | CHECK > 0 |
| `price` | Ціна закупівлі | Decimal | 19,2 | так | ціна рядка надходження | ніколи | CHECK >= 0 |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ніколи | stored |
| `receivedQuantity` | Надійшло | Decimal | 19,3 | — | з підстави | ніколи | transient |
| `returnableQuantity` | Можна повернути | Decimal | 19,3 | — | розрахунок | ніколи | transient |
| `stockQuantity` | Залишок на складі | Decimal | 19,3 | — | `RegStockBalance` на `occurredAt` | ніколи | transient |
| `avgCost` | Середня собівартість | Decimal | 19,2 | — | `RegStockCost` на `occurredAt` | ніколи | transient |

Рядок додається лише з рядків підстави. `SERVICE`-рядки підстави (якщо надходження
містило послугу) можна повернути — вони впливають лише на PAYABLE.

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Редагованість |
|---|---|---|---|---|---|
| — | `NEW` (на підставі) | `DRAFT` | `document.supplier-return.create` | підстава `POSTED` | шапка, рядки |
| `DRAFT` | `SAVE` | `DRAFT` | `document.supplier-return.update` | версія | шапка, рядки |
| `DRAFT` | `POST` | `POSTED` | `document.supplier-return.post` | §7.3 | read-only |
| `POSTED` | `POST` повторно | `POSTED` | `document.supplier-return.post` | §7.3 | read-only |
| `POSTED` | `UNPOST` | `DRAFT` | `document.supplier-return.unpost` | §7.4 | шапка, рядки |
| `DRAFT` | `DELETE` | — | `document.supplier-return.delete` | — | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `document.supplier-return.create` | підстава `POSTED` | — |

Зміна суміжного об'єкта `DocGoodsReceipt` r3: скасування проведення надходження
заборонене, поки існує `POSTED` повернення з цим `baseReceiptId` —
`BASE_HAS_POSTED_RETURNS` «Надходження №… не можна скасувати: за ним проведено
повернення постачальнику №…».

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 290)

- Колонки: `stateIcon[4]` | `number[12]` | `occurredAt[16]` | `supplier[30]` |
  `warehouse[20]` | `baseReceipt[22]` | `totalAmount[14]` | `returnReason[24]`.
- Фільтри: період, постачальник, склад, статус, надходження.
- Команди: `Створити` (вибір проведеного надходження) | `Скопіювати (F9)` | `Провести` |
  `Скасувати проведення` | `Пошук (Ctrl+F)` | `Друк ▾`.

#### 5.2. Форма документа (сторінка 291)

```text
FORM supplierReturnEditor  title: «Повернення постачальнику № <number> від <occurredAt> (проведено)»

HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення |
           Створити на підставі ▾ (порожнє в r3) | Друк ▾ (Накладна на повернення постачальнику) |
           Ще ▾ (Скопіювати F9, Структура підпорядкованості, Рухи документа)
  number[20] | occurredAt[22]
  baseReceipt[50] (ReferenceField, лише POSTED надходження)
  supplier[50] (read-only) | contract[30] (read-only)
  warehouse[40]
  returnReason[100] (обов'язкове, червоне підкреслення)
CONTENT
  scanInput[30] «Штрихкод» (над вкладкою «Товари», Ctrl+Shift+B; лише DRAFT)
  TAB Товари (N)
    commands: Додати (вибір рядка надходження) | Заповнити за надходженням | Видалити | ↑ ↓
    GoodsTable: lineNumber[5] | product[36] | receivedQuantity[11] | returnableQuantity[11] |
                stockQuantity[11] | quantity[11]* | price[11] | amount[13] | avgCost[11]
    total: «Всього: <totalAmount> UAH»
  TAB Розрахунки
    QueryTable supplierSettlement «Взаєморозрахунки з постачальником»
      query: GetCounterpartySettlementBalance(counterpartyId=supplierId, direction=PAYABLE, at=occurredAt)
      columns: balanceBefore[14] | returnAmount[14] | balanceAfter[14] calculated
      refresh: ON_OPEN, MANUAL, AFTER_SAVE
  TAB Рухи (лише POSTED)
    QueryTable postingMovements (GetDocumentMovements), колонки як у DocCustomerReturn
FOOTER
  comment[100]
  info: «Відхилення вартості (ціна закупівлі − середня собівартість): <costDifference> UAH»
```

Рядок, де `quantity > stockQuantity`, підсвічується червоним (попередження до `POST`).

#### 5.3. Форма підбору рядків підстави

Як у `DocCustomerReturn`: `lineNumber | product | receivedQuantity | alreadyReturned |
returnableQuantity | stockQuantity | price`; лише рядки з `returnable > 0`, яких немає
в документі. Кнопка «Перенести в документ» ставить
`quantity = min(returnable, max(stockQuantity, 0))`, якщо результат > 0, інакше
`returnable` (з попередженням).

#### 5.4. Форма вибору документа

`number[12] | occurredAt[16] | supplier[30] | totalAmount[14]`, лише `POSTED`.

### 6. Події введення

| Поле | Компонент | INPUT_COMMITTED → команда | Залежності | Сервер перераховує | Повертає | Помилка / фокус |
|---|---|---|---|---|---|---|
| `number` | TextField | `ChangeSupplierReturnHeader(number)` | — | — | поле | `DOCUMENT_NUMBER_NOT_UNIQUE` |
| `occurredAt` | DateTimeField | `ChangeSupplierReturnHeader(occurredAt)` | baseReceipt, warehouse | returnable, stockQuantity, avgCost рядків | документ | `RETURN_DATE_BEFORE_BASE` |
| `baseReceiptId` | ReferenceField | `ChangeSupplierReturnBase(baseReceiptId)` | рядки порожні | supplier, contract, warehouse | документ | `BASE_NOT_POSTED`, `BASE_CHANGE_WITH_LINES` |
| `supplierId` | ReferenceField (disabled) | — | — | — | — | — |
| `contractId` | ReferenceField (disabled) | — | — | — | — | — |
| `warehouseId` | ReferenceField | `ChangeSupplierReturnHeader(warehouseId)` | — | stockQuantity, avgCost | документ | `REFERENCE_NOT_ACTIVE` |
| `returnReason` | TextField | `ChangeSupplierReturnHeader(returnReason)` | — | — | поле | `REQUIRED_FIELD_EMPTY` при записі |
| `comment` | TextArea | `ChangeSupplierReturnHeader(comment)` | — | — | поле | довжина |
| `totalAmount` | NumberField (disabled) | — | — | — | — | — |
| `scanInput` (форма) | TextField | `LookupBarcode(barcode)` → `AddOrIncrementLineByBarcode(documentId, productId, unitQuantity, expectedVersion)` | `RegBarcode` | quantity, amount, totalAmount | рядок + підсумок | `BARCODE_NOT_FOUND`, `BARCODE_PRODUCT_NOT_IN_BASE`; поле очищується, фокус лишається |
| `line.baseReceiptLineId` | ChoiceCell | `AddSupplierReturnLines(baseReceiptLineIds[])` | baseReceipt | product, price, quantity, amount, totalAmount, stock, avgCost | документ | `BASE_LINE_ALREADY_IN_DOCUMENT`, `NOTHING_TO_RETURN` |
| `line.productId` | ReferenceCell (disabled) | — | — | — | — | — |
| `line.quantity` | NumberCell | `ChangeSupplierReturnLineQuantity(lineId, quantity, version)` | returnable, stock, дробність | amount, totalAmount, costDifference | рядок + підсумок | `RETURN_EXCEEDS_RECEIVED` (попередження), `QUANTITY_NOT_FRACTIONAL`, `QUANTITY_MUST_BE_POSITIVE` |
| `line.price` / `amount` / `avgCost` / `stockQuantity` / `receivedQuantity` / `returnableQuantity` | NumberCell (disabled) | — | — | — | — | — |

Сканер: Товар має бути серед рядків надходження-підстави: наявний рядок → `quantity += unitQuantity`; рядок підстави ще не в документі → додається з `quantity = unitQuantity`; товару немає в підставі → `BARCODE_PRODUCT_NOT_IN_BASE` «Товару «…» немає в надходженні-підставі.»

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Спільні правила (права, `expectedVersion` → `OPTIMISTIC_LOCK_CONFLICT`, статус →
`DOCUMENT_POSTED_READ_ONLY`, `idempotencyKey`, аудит `sys_audit_log`) — як у
`DocCustomerReturn` §7.

#### 7.1. NEW — `InitializeSupplierReturn(baseReceiptId)`

Підстава `POSTED` (`BASE_NOT_POSTED` «Повернення постачальнику можна ввести лише на
підставі проведеного надходження.»). Шапка з підстави, `occurredAt = now`, рядки =
`FILL_FROM_BASE`. Нічого повертати — `NOTHING_TO_RETURN` «За надходженням №… весь товар
уже повернено.»

#### 7.2. SAVE — `SaveSupplierReturn(dto, expectedVersion)`

Lock шапки, merge рядків за `lineId`, перерахунок `amount/totalAmount`, валідації:
обов'язкові поля (`returnReason`), належність рядків підставі (`BASE_LINE_FOREIGN`),
унікальність, дробність, дата ≥ дати підстави. Перевищення повертаємого й залишку —
попередження.

#### 7.3. POST — `PostSupplierReturn(id, expectedVersion, idempotencyKey)`

1. Lock шапки `FOR UPDATE`, версія; `NO_LINES`.
2. Lock підстави `doc_goods_receipt … for update`; підстава `POSTED`.
3. Lock `ref_counterparty(supplierId)`, `ref_warehouse(warehouseId)`.
4. `returnable = baseLine.quantity − Σ quantity інших POSTED повернень рядка`;
   `quantity > returnable` → `RETURN_EXCEEDS_RECEIVED` «Рядок N: товар «…» —
   повертається 8,000 шт, а можна повернути не більше 5,000 шт (надійшло 10,000, уже
   повернено 5,000).»
5. Обчислення `costAmount` кожного GOODS-рядка за §8 з `RegStockCost` на `occurredAt`
   (після lock складу; рядки з однаковим товаром обробляються послідовно за
   `lineNumber`, кожен наступний бачить зменшений залишок).
6. `delete_movements('DocSupplierReturn', id)`; вставка рухів §9.
7. Перевірки в тій самій транзакції: `check_free_stock` → `INSUFFICIENT_FREE_STOCK` «Недостатньо вільного
   товару «…» на складі «…»: не вистачає 3,000 шт (залишок 5,000, резерв 3,000).» — враховуються резерви `RegStockReserve`; `RegStockCost` ≥ 0
   (`STOCK_COST_NEGATIVE`); PAYABLE ≥ 0 (`SETTLEMENT_NEGATIVE_PAYABLE`).
8. `status = POSTED`, аудит `POST`; помилка — повний rollback.

#### 7.4. UNPOST — `UnpostSupplierReturn(id, expectedVersion, idempotencyKey)`

`require_posted`; lock постачальника й складу; видалення рухів. Залишок товару і
вартість зростають, PAYABLE зростає — перевірки від'ємних залишків формально
виконуються (`check_free_stock`), але не можуть спрацювати. `status = DRAFT`, аудит.

Примітка: скасування й повторне проведення повернення після інших рухів складу
перерахує `costAmount` за середньою на дату повернення в новому контексті — це
очікувана поведінка середньої ковзної (див. `RegStockCost`).

#### 7.5. COPY (F9) — `CopySupplierReturn(id)`

Нова чернетка з тією самою підставою, складом, причиною, коментарем і рядками
(`baseReceiptLineId`, `quantity`); ціни перечитуються з підстави; без номера, аудиту,
рухів; `occurredAt = now`.

#### 7.6. FILL_FROM_BASE — `FillSupplierReturnFromBase(id, expectedVersion, mode)`

`REPLACE` / `ADD_MISSING`; для кожного рядка підстави з `returnable > 0`:
`quantity = returnable`, `price = baseLine.price`. Порядок — `lineNumber` підстави.

#### 7.7. Довідник помилок

Усі помилки піднімаються через `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error(-20100, …)`); код — UPPER_SNAKE на початку тексту в квадратних дужках, попередження (warning) повертаються як повідомлення APEX без rollback.

| Код | Повідомлення |
|---|---|
| `BASE_NOT_POSTED` | Повернення постачальнику можна ввести лише на підставі проведеного надходження. |
| `BASE_CHANGE_WITH_LINES` | Щоб змінити надходження-підставу, спочатку очистіть табличну частину. |
| `BASE_LINE_FOREIGN` | Рядок N не належить надходженню-підставі. |
| `BASE_LINE_ALREADY_IN_DOCUMENT` | Рядок надходження вже додано (рядок N). |
| `RETURN_DATE_BEFORE_BASE` | Дата повернення не може бути раніше дати надходження (…). |
| `RETURN_EXCEEDS_RECEIVED` | Рядок N: можна повернути не більше X (надійшло Y, уже повернено Z). |
| `NOTHING_TO_RETURN` | За надходженням №… весь товар уже повернено. |
| `SETTLEMENT_NEGATIVE_PAYABLE` | Повернення на суму … перевищує заборгованість перед постачальником «…» (…). Повернення коштів від постачальника в r3 не підтримується. |
| `BARCODE_NOT_FOUND` | Штрихкод «…» не знайдено. |
| `BARCODE_PRODUCT_NOT_IN_BASE` | Товару «…» немає в документі-підставі. |
| `INSUFFICIENT_FREE_STOCK` | Недостатньо вільного товару «…» на складі «…»: не вистачає … (залишок …, резерв …). |
| `STOCK_COST_NEGATIVE` | Вартість запасу товару «…» на складі «…» стане від'ємною. |
| `REQUIRED_FIELD_EMPTY` | Не заповнено поле «Причина повернення». |
| спільні r2 | `NO_LINES`, `DOCUMENT_NOT_POSTED`, `DOCUMENT_POSTED_READ_ONLY`, `OPTIMISTIC_LOCK_CONFLICT`, `PERMISSION_DENIED`, `QUANTITY_NOT_FRACTIONAL` |

### 8. Розрахунки

- `returnable = baseLine.quantity − Σ quantity(POSTED supplier returns рядка, id ≠ current)`.
- `amount`: якщо рядок підстави повертається до кінця → `baseLine.amount − Σ amount
  попередніх POSTED повернень рядка`; інакше `round(quantity × price, 2)` `HALF_UP`.
- `totalAmount = Σ amount`.
- `avgCost = round(costBalance / qtyBalance, 2)` з `RegStockCost` на `occurredAt`
  (transient, лише для показу); `null`, якщо `qtyBalance <= 0`.
- `costAmount` (рух `RegStockCost`): якщо `quantity = qtyBalance` (вибуває весь
  залишок) → `costAmount = costBalance` (без залишку «копійок»); інакше
  `round(costBalance × quantity / qtyBalance, 2)` — обчислення з повної точності
  балансу, а не з округленої `avgCost`. Якщо `qtyBalance < quantity` → `INSUFFICIENT_FREE_STOCK`.
- `costDifference = Σ amount − Σ costAmount` (GOODS-рядки) — transient, показується у
  підвалі; у регістрах r3 не відображається (фінансовий результат — r4).
- `null`: `quantity` з UI порожнім не надсилається; `price` NOT NULL з підстави.

Приклад (склад «Основний», товар «Фарба»):

| Подія | qty | costAmount | Середня |
|---|---|---|---|
| Надходження №1: 10 × 100,00 | 10,000 | 1 000,00 | 100,00 |
| Надходження №2: 10 × 130,00 | 20,000 | 2 300,00 | 115,00 |
| Повернення 3,000 на підставі №2 | 17,000 | 2 300,00 − 345,00 = 1 955,00 | 115,00 |

Повернення: `amount = 3 × 130,00 = 390,00` (PAYABLE −390,00), `costAmount = 345,00`,
`costDifference = 45,00` (закупівельна ціна партії вища за середню; різниця лишається
розподіленою в середній оцінці решти запасу — у r3 це свідоме спрощення без партій).

Округлення: qty 3,000, costBalance 100,00 → `round(100,00 × 1/3, 2) = 33,33` за 1,000;
повернення всіх 3,000 → `100,00`.

### 9. Проведення й регістри

Запис у регістри — лише всередині проведення під прапором `trade_core.g_internal`; похідні таблиці підсумків `*_tot` і знімків `*_snap` регістрів залишків оновлюються в тій самій транзакції. Порядок блокувань: рядок документа-підстави → `ref_counterparty` → `ref_warehouse` (`FOR UPDATE`).

`period = occurredAt`; `lineNumber` руху = `lineNumber` рядка для `RegStockBalance` і
`RegStockCost`; `RegCounterpartySettlement` — один рух `lineNumber = 1`.

#### 9.1. RegStockBalance (лише GOODS)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **−** |

#### 9.2. RegCounterpartySettlement

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `counterpartyId` | `header.supplierId` | — |
| `direction` | `PAYABLE` | — |
| `currencyCode` | `UAH` | — |
| `amount` | `header.totalAmount` | **−** |

**Рішення щодо від'ємної кредиторки: заборонено** (узгоджено з `DocCustomerReturn`).
Якщо надходження вже оплачено й повернення зробило б PAYABLE < 0 (постачальник винен
нам), проведення відхиляється з `SETTLEMENT_NEGATIVE_PAYABLE`. Обґрунтування:

1. Погоджений паспорт `RegCounterpartySettlement` забороняє від'ємний залишок; на цій
   перевірці побудовані `DocSupplierPayment` («переплата постачальнику») та unpost
   надходження.
2. Борг постачальника перед нами — це RECEIVABLE-сутність (або аванс); змішування
   знаків в одному напрямку робить звіт `F-REP-02` неоднозначним.
3. Отримання коштів від постачальника потребує окремого документа («Повернення коштів
   від постачальника», r4).

Обхід у r3: скасувати/зменшити оплату постачальнику, провести повернення, повторно
провести оплату на залишок боргу.

#### 9.3. RegStockCost (лише GOODS)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **−** |
| `costAmount` | `costAmount` за §8 (середня ковзна на `occurredAt`) | **−** |

`RegSupplierPrice` поверненням не змінюється (остання ціна закупівлі лишається
ціною надходження).

#### 9.4. Повторне проведення й скасування

Повторне проведення атомарно замінює набори всіх трьох регістрів; `UNPOST` видаляє.
Документи, проведені пізніше з тим самим складом/товаром, не перераховуються
автоматично (середня ковзна r3 рахується на момент проведення; див. `RegStockCost`).

### 10. Зберігання й API

```text
doc_supplier_return
  PK id; UNIQUE doc_number; FK base_receipt_id → doc_goods_receipt(id);
  FK supplier_id → ref_counterparty; FK contract_id → ref_contract;
  FK warehouse_id → ref_warehouse; CHECK status IN ('DRAFT','POSTED');
  CHECK currency_code = 'UAH'; NOT NULL return_reason
  INDEX (occurred_at), (supplier_id), (base_receipt_id)
doc_supplier_return_goods
  PK id; FK document_id ON DELETE CASCADE; FK base_receipt_line_id → doc_goods_receipt_goods(id);
  FK product_id → ref_product; CHECK quantity > 0; CHECK price >= 0;
  UNIQUE (document_id, base_receipt_line_id); INDEX (document_id, line_number); INDEX (base_receipt_line_id)
```

Тригер read-only у `POSTED`; пакет `trade_ops`: `post_supplier_return`,
`unpost_supplier_return`, `copy_supplier_return`, `fill_supplier_return`.

| Метод | Шлях | Призначення |
|---|---|---|
| GET | `/api/v1/documents/supplier-returns` | список |
| GET | `…/new?baseReceiptId=` | ініціалізація на підставі |
| GET/POST/PUT | `…/{id}`, `…`, `…/{id}` | читання/створення/запис |
| POST | `…/{id}/post`, `/unpost`, `/copy`, `/fill-from-base` | команди |
| GET | `…/{id}/movements` | рухи |
| GET | `…/{id}/print/return-note` | «Накладна на повернення постачальнику» (PDF): постачальник, підстава, причина, товари за цінами закупівлі, сума, підписи |

### 11. Тести й готовність

- Unit: залишковий метод суми, `costAmount` (повний/частковий залишок), `costDifference`.
- Проведення: три регістри, знаки, SERVICE-рядок лише в PAYABLE, repost без дублів.
- Перевірки: `RETURN_EXCEEDS_RECEIVED`, `INSUFFICIENT_FREE_STOCK` (товар уже продано),
  `SETTLEMENT_NEGATIVE_PAYABLE`, `BASE_HAS_POSTED_RETURNS` для unpost надходження.
- Конкурентність: паралельні повернення за одним надходженням, повернення паралельно з
  реалізацією того самого товару (lock складу).

Наскрізний сценарій:

1. Надходження №1 від «Постач-1»: «Фарба» 10 × 100,00 → PAYABLE 1 000,00, StockCost 10/1 000,00.
2. Надходження №2: «Фарба» 10 × 130,00 → PAYABLE 2 300,00, StockCost 20/2 300,00.
3. Оплата постачальнику 2 000,00 → PAYABLE 300,00.
4. Повернення №1 на підставі №2: 3,000 → amount 390,00 → PAYABLE −90,00 →
   `SETTLEMENT_NEGATIVE_PAYABLE`.
5. Скасовуємо оплату, проводимо 1 600,00. Повернення №1 проводиться: PAYABLE 2 300,00 −
   1 600,00 − 390,00 = 310,00; Stock 17,000; StockCost 1 955,00; `costDifference` 45,00.
6. Повернення №2 на 8,000 за надходженням №2 → `RETURN_EXCEEDS_RECEIVED` (можна 7,000).
7. Реалізація 15,000 «Фарби» → залишок 2,000. Повернення №2 на 5,000 →
   `INSUFFICIENT_FREE_STOCK` «…не вистачає 3,000 шт.»
8. Спроба `UNPOST` надходження №2 → `BASE_HAS_POSTED_RETURNS`.
