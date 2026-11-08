# Паспорт документа «Замовлення клієнта»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`. Реалізація до погодження заборонена.
- Ревізія: `r3`.
- Розділ меню (підсистема «Такси»): `Sales` «Продажі», група «Продажі», позиція перед
  «Реалізація товарів» (`is_important = 'Y'`); у `Main` «Головне» — група «Продажі».
- Залежності: `RefCounterparty`, `RefContract` (вид `WITH_CUSTOMER`), `RefWarehouse`,
  `RefPriceType`, `RefProduct` r3 (`productKind`), `RegProductPrice`, `RegStockBalance`,
  `RegStockReserve`, `RegCustomerOrders`, `RegStockCost` (лише попередження ціни),
  `DocGoodsSale` r3, `DocInvoiceForPayment`.
- Аналог у 1С:УТ 11: `Документ.ЗаказКлиента` (спрощено: без етапів оплати, графіка, статусів
  «До забезпечення»; резерв — прапорцем рядка).
- Функції каталогу: F-SAL-01, F-SAL-02, F-SAL-05, F-PRC-03, F-PRC-05 (попередження),
  F-SRV-01, F-SRV-02, F-SRV-03, F-WH-07, F-REP-04, F-REP-05.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Замовлення клієнта |
| Технічне ім'я | `DocCustomerOrder` |
| Технічний ключ | `Document.CustomerOrder` |
| Клас / ID | `CustomerOrder` / `CustomerOrderId` |
| Таблиці | `doc_customer_order`, `doc_customer_order_goods` |
| DTO | `CustomerOrderDto`, `CustomerOrderLineDto`, `CustomerOrderListItemDto` |
| API | `/api/v1/documents/customer-orders` |
| Сторінки APEX | 260 — список, 261 — форма документа |
| Recorder type | `DocCustomerOrder` (константа `trade_ops.c_customer_order`) |
| Нумерація | 9 цифр із початковими нулями, послідовність `doc_customer_order_num_seq`, присвоюється під час першого запису, унікальна, редагована в `DRAFT` |
| Дата | `occurredAt`, DateTime з точністю до секунди (Oracle `date`), бізнес-зона Europe/Kyiv |
| Підстава | не має; сам є підставою для `DocInvoiceForPayment` і `DocGoodsSale` r3 |
| Видалення | `DRAFT` — фізично; `POSTED` — заборонено |

Документ фіксує домовленість із клієнтом: що, скільки, за якою ціною й коли відвантажити,
а також (за прапорцем рядка) резервує товар на складі під це замовлення.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ні | PK `id` |
| `number` | Номер | String | 9 | так | sequence під час запису | `DRAFT` | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | `sysdate` | `DRAFT` | `occurred_at`, index |
| `customerId` | Клієнт | reference | 32 | так | — | `DRAFT` | `RefCounterparty`, FK `customer_id` |
| `contractId` | Договір | reference | 32 | ні | `ResolveDefaultContract(customerId, WITH_CUSTOMER, occurredAt)` — лише якщо чинний договір рівно один | `DRAFT` | `RefContract`, FK `contract_id` |
| `warehouseId` | Склад | reference | 32 | так | склад останнього замовлення користувача | `DRAFT` | `RefWarehouse`, FK `warehouse_id` |
| `priceTypeId` | Вид цін | reference | 32 | ні | `contract.priceTypeId` | `DRAFT` | `RefPriceType`, FK `price_type_id` |
| `shipmentDate` | Бажана дата відвантаження | Date | day | так | `trunc(occurredAt) + 1` | `DRAFT` | `shipment_date`, index |
| `closed` | Закрите | Boolean | 1 | так | `false` | лише командами `CLOSE/REOPEN` у `POSTED` | `closed` `'Y'/'N'` |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | read-only у r3 | CHECK = `UAH` |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ні (розрахунок) | stored |
| `comment` | Коментар | String | 1000 | ні | — | `DRAFT` | `doc_comment` |
| `status` | Статус | enum | — | так | `DRAFT` | командами | `DRAFT/POSTED` |
| `version` | Версія | Long | — | так | 0 | ні | optimistic lock |
| `createdAt/By`, `updatedAt/By` | Аудит | — | — | так | server | ні | audit |

Похідне (не stored) поле списку `executionState`: `CLOSED` («Закрите»), якщо `closed = true`;
`SHIPPED` («Відвантажене»), якщо `closed = false` і залишок `RegCustomerOrders` по всіх товарах = 0;
інакше `OPEN` («Відкрите»); для `DRAFT` показується порожнім.

### 3. Таблична частина `Goods` «Товари»

Таблиця `doc_customer_order_goods`, клас `CustomerOrderLine`. Рядок має стабільний `lineId`
(UUID, не змінюється при перенумерації й переміщенні) та `lineNumber` (1..n, перенумерація
після кожної зміни складу рядків).

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Посилання/обмеження |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ні | PK `id` |
| `lineNumber` | N | Integer | 10 | так | max+1 | порядком рядків | `line_number` |
| `productId` | Номенклатура | reference | 32 | так | — | `DRAFT` | `RefProduct`, `GOODS` або `SERVICE`, `ACTIVE` |
| `quantity` | Кількість | Decimal | 19,3 | так | 1 | `DRAFT` | > 0, дробність одиниці виміру |
| `price` | Ціна | Decimal | 19,2 | так | з `RegProductPrice` | `DRAFT` | >= 0 |
| `discountPercent` | Знижка, % | Decimal | 5,2 | так | 0 | `DRAFT` | 0..100 |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ні | stored |
| `reserveFlag` | Резерв | Boolean | 1 | так | `false` | `DRAFT`, лише для `GOODS` | `reserve_flag` `'Y'/'N'` |

Один товар може повторюватися кількома рядками (наприклад, частина з резервом, частина без).
Рядок `SERVICE` не може мати `reserveFlag = true`.

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Шапка / рядки |
|---|---|---|---|---|---|
| — | `NEW` | `DRAFT` (не записаний) | `document.customer-order.create` | — | редаговані |
| `DRAFT` | `SAVE` | `DRAFT` | `...update` (`...create` для першого запису) | валідація шапки/рядків | редаговані |
| `DRAFT` | `POST` | `POSTED`, `closed=false` | `...post` | є рядки, резерв ≤ вільний залишок | read-only |
| `POSTED` | `POST` (повторно) | `POSTED` | `...post` | idempotent, рухи замінюються | read-only |
| `POSTED`, `closed=false` | `CLOSE` | `POSTED`, `closed=true` | `...close` | — | read-only |
| `POSTED`, `closed=true` | `REOPEN` | `POSTED`, `closed=false` | `...close` | відновлений резерв ≤ вільний залишок | read-only |
| `POSTED` | `UNPOST` | `DRAFT`, `closed=false` | `...unpost` | немає проведених реалізацій на підставі | редаговані |
| `DRAFT` | `DELETE` | — (фізично) | `...delete` | немає документів на підставі | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `...create` | — | — |

Поле `closed` не блокує `UNPOST` (правило 2.3); `UNPOST` скидає `closed` у `false`, бо закривальні
рухи видаляються разом з усіма рухами реєстратора. Окремого статусу «Відвантажене» не зберігається —
`SHIPPED` лише похідний стан списку.

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 260, `LIST_DOCUMENTS_UK.md`, Interactive Report)

Колонки: `icon[4]` | `number[10]` | `occurredAt[14]` | `customer[22]` | `contract[14]` |
`warehouse[14]` | `shipmentDate[10]` | `totalAmount[12]` | `executionState[8]` | `comment[*]`.

Іконка стану (`icon_class` у SQL): `fa-file-o` — `DRAFT`; `fa-check-square` (зелена) —
`OPEN`; `fa-truck` (синя) — `SHIPPED`; `fa-lock` (сіра) — `CLOSED`; рядок прострочення
(`shipmentDate < trunc(sysdate)` і залишок до відвантаження > 0) — червоний текст дати.

Фільтри: період `occurredAt`, «Клієнт», «Склад», «Стан» (Чернетки / Відкриті / Закриті / Усі),
прапорець «Лише з невідвантаженим залишком». Сортування за замовчуванням `occurredAt DESC, number DESC`.

Команди: `Створити` (перша, `Insert`) | `Скопіювати (F9)` | `Провести` | `Скасувати проведення` |
`Закрити замовлення` | `Створити на підставі ▾` (Реалізація товарів, Рахунок на оплату) |
`Пошук (Ctrl+F)` | `Ще`. Подвійний клік / `Enter` відкриває сторінку 261.

#### 5.2. Форма документа (сторінка 261)

```text
FORM customerOrder  title: trade_ui.doc_title → «Замовлення клієнта 000000012 від 08.11.2026 14:05 (проведено, відкрите)»
HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення
           | Закрити замовлення / Відкрити замовлення
           | Створити на підставі ▾ (Реалізація товарів | Рахунок на оплату)
           | Друк ▾ (Замовлення клієнта) | Ще ▾ (Скопіювати F9, Журнал змін, Рухи документа)
  row1: number[15] | occurredAt[20] | shipmentDate[15] | status/executionState[read-only, 20]
  row2: customer[45] | contract[35]
  row3: warehouse[45] | priceType[35]
CONTENT
  scanInput[40] «Штрихкод» (над вкладкою «Товари», фокус Ctrl+Shift+B; лише DRAFT)
  TAB «Товари» (DocumentLineTable, IG класу tx-tabpart)
    commands: Додати | Підбір | Заповнити ціни | Зарезервувати все | Зняти резерв
              | ↑ | ↓ | Видалити | Ще
    columns: lineNumber[4] | product[34] | unit[6, read-only] | quantity[10] | price[10]
             | discountPercent[7] | amount[12, read-only] | reserveFlag[6, checkbox]
             | free[10, read-only, transient з QueryTable]
    footer: «Всього:» totalAmount (праворуч), «Зарезервовано рядків: n з m»
  TAB «Вільні залишки» (QueryTable freeStock)
  TAB «Виконання» (QueryTable fulfillment, лише POSTED)
FOOTER
  comment[100]
  service row: Автор createdBy · Змінено updatedAt
```

`QUERY_TABLE freeStock "Вільні залишки"`: query `GetCustomerOrderFreeStock`, refresh
`ON_OPEN, MANUAL, AFTER_LINE_COMMIT, AFTER_POSTING`; params `warehouseId <- HEADER.warehouseId`,
`productIds <- Goods.productId (GOODS)`, `orderId <- FORM_OBJECT_ID`; columns
`product "Номенклатура"`, `balance "Залишок" NUMBER(19,3)`, `reservedTotal "Резерв усього"`,
`reservedThis "У т.ч. цим замовленням"`, `free "Вільно" calculated = balance − reservedTotal`,
`avgCost "Собівартість од." NUMBER(19,2)` (видима з правом `register.stock-cost.read`).

`QUERY_TABLE fulfillment "Виконання"`: query `GetCustomerOrderFulfillment`; колонки `product`,
`ordered`, `shipped`, `remaining` (з `RegCustomerOrders`), `reserved` (з `RegStockReserve`);
row action — відкрити реалізацію-реєстратор.

У `POSTED` усі поля, команди таблиці й колонки disabled; доступні `Скасувати проведення`,
`Закрити/Відкрити`, `Створити на підставі`, `Друк`. «Підбір» відкриває форму підбору (F-SRV-02):
дерево `RefProductGroup` ліворуч, список товарів із колонками `Ціна` (вид цін шапки),
`Вільно` (склад шапки), поле кількості й кнопка «Перенести в документ».

#### 5.3. Форма вибору

Колонки `number[12] | occurredAt[14] | customer[30] | totalAmount[12] | executionState[10]`.
Показує лише `POSTED`; відбір за клієнтом передається з поля, що відкриває вибір
(наприклад `DocGoodsSale.baseOrderId` показує лише відкриті замовлення клієнта).

### 6. Події введення

Кожне поле має `INPUT_STARTED/INPUT_COMMITTED` (`INPUT_LIFECYCLE_UK.md`). Команди містять
`documentId` (або `draftId`), `expectedVersion`; рядкові — також `lineId`. Відповідь — повний стан
документа (`CustomerOrderDto`) з `warnings[]`. Помилка залишає фокус у полі з повідомленням.

| Реквізит | Компонент | Команда | Серверна реакція / перераховано |
|---|---|---|---|
| `number` | TextField | `ChangeCustomerOrderNumber(id, value, version)` | формат 1–9 символів, унікальність під час запису |
| `occurredAt` | DateTimeField | `ChangeCustomerOrderDate(id, value, version)` | якщо `shipmentDate < trunc(value)` → `shipmentDate = trunc(value)+1` + warning; ціни не перераховуються |
| `shipmentDate` | DateField | `ChangeCustomerOrderShipmentDate(id, value, version)` | `>= trunc(occurredAt)`, інакше `SHIPMENT_DATE_BEFORE_ORDER_DATE` |
| `customerId` | ReferenceField | `ChangeCustomerOrderCustomer(id, customerId, version)` | очищає `contractId`, якщо власник інший; `ResolveDefaultContract(customerId, WITH_CUSTOMER, occurredAt)` підставляє договір лише якщо чинний рівно один; далі як `contractId`; інформаційний warning `CREDIT_LIMIT_EXCEEDED`, якщо борг уже > ліміту |
| `contractId` | ReferenceField (відбір owner=customer, kind=WITH_CUSTOMER) | `ChangeCustomerOrderContract(id, contractId, version)` | `CONTRACT_OWNER_MISMATCH`, `CONTRACT_KIND_MISMATCH`, `CONTRACT_NOT_VALID_ON_DATE`; `priceTypeId = contract.priceTypeId`, якщо той заданий; ціни рядків не змінюються (warning «Застосуйте Заповнити ціни») |
| `warehouseId` | ReferenceField | `ChangeCustomerOrderWarehouse(id, warehouseId, version)` | оновлює `freeStock`; резерв не перевіряється до `POST` |
| `priceTypeId` | ReferenceField | `ChangeCustomerOrderPriceType(id, priceTypeId, version)` | лише значення; перерахунок — командою `FILL_PRICES` |
| `comment` | TextArea | `ChangeCustomerOrderComment(id, value, version)` | trim, ≤ 1000 |
| `closed` | — | лише `CloseCustomerOrder` / `ReopenCustomerOrder` | немає `INPUT_COMMITTED` mutation |
| `Goods.productId` | ReferenceTableCell | `ChangeCustomerOrderLineProduct(lineId, productId, version)` | `price` з `RegProductPrice(priceTypeId, product, occurredAt)`; для `SERVICE` `reserveFlag=false`; `amount`, `totalAmount`; warning `PRICE_BELOW_COST` |
| `Goods.quantity` | NumericCell 19,3 | `ChangeCustomerOrderLineQuantity(lineId, value, version)` | дробність одиниці; `amount`, `totalAmount` |
| `Goods.price` | NumericCell 19,2 | `ChangeCustomerOrderLinePrice(lineId, value, version)` | ручне значення зберігається; `amount`, `totalAmount`; warning `PRICE_BELOW_COST` |
| `Goods.discountPercent` | NumericCell 5,2 | `ChangeCustomerOrderLineDiscount(lineId, value, version)` | 0..100, інакше `DISCOUNT_OUT_OF_RANGE`; `amount`, `totalAmount` |
| `Goods.amount` | — | disabled | — |
| `Goods.reserveFlag` | CheckboxCell | `ChangeCustomerOrderLineReserve(lineId, value, version)` | для `SERVICE` — `RESERVE_SERVICE_PRODUCT`; warning, якщо резерв рядків товару > `free` |
| `Goods.lineNumber` | — | `MoveCustomerOrderLine(lineId, direction, version)` | перенумерація |
| `scanInput` | TextField (transient, не зберігається) | `LookupBarcode(code)` → `AddOrIncrementLineByBarcode(docId, productId, unitQuantity, expectedVersion)` | `RegBarcode`: знайдено — +`unitQuantity` до першого рядка з цим товаром без зміненої вручну ціни або новий рядок з автоціною; не знайдено — `BARCODE_NOT_FOUND`, поле очищається, фокус лишається |

Додавання/видалення/копіювання рядка: `AddCustomerOrderLine(id, afterLineId?, version)`,
`DeleteCustomerOrderLine(lineId, version)`, `CopyCustomerOrderLine(lineId, version)` (новий `lineId`).

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Обов'язкові сценарії

Спільне: перевірка права, статусу й `expectedVersion` (`OPTIMISTIC_LOCK_CONFLICT`
«Документ змінено іншим користувачем. Оновіть форму.»), змінні команди — з `idempotencyKey`
(повтор з тим самим ключем повертає збережений результат). Помилки — `trade_core.fail` з
повідомленням `'[CODE] Українське повідомлення'` (`raise_application_error -20100`).

- **NEW** `InitializeCustomerOrder(baseRef?)` — право `create`; повертає `DRAFT` без ID/номера,
  `occurredAt = sysdate`, `shipmentDate = trunc(sysdate)+1`, `closed=false`, `currencyCode=UAH`,
  склад за замовчуванням, порожні рядки, capabilities.
- **SAVE** `SaveCustomerOrder(dto, expectedVersion, idempotencyKey)` — `DRAFT`; одна транзакція:
  шапка, рядки (merge за `lineId`), перенумерація, ціни, суми, `totalAmount`, аудит `SAVE`.
  Валідації: обов'язкові поля; активні посилання (`REF_NOT_ACTIVE`); `CONTRACT_OWNER_MISMATCH`
  «Договір належить іншому контрагенту»; `CONTRACT_KIND_MISMATCH` «Договір не є договором з
  покупцем»; `CONTRACT_NOT_VALID_ON_DATE` «Договір не діє на дату документа»;
  `SHIPMENT_DATE_BEFORE_ORDER_DATE` «Дата відвантаження не може бути раніше дати
  замовлення»; `QUANTITY_NOT_POSITIVE`; `QUANTITY_FRACTION_NOT_ALLOWED`; `PRICE_REQUIRED`
  «Вкажіть ціну або вид цін у шапці»; `PRICE_NOT_FOUND` «Для товару «X» не встановлено ціну виду
  «Y» на дату документа»; `DISCOUNT_OUT_OF_RANGE` «Знижка має бути від 0 до 100 %»;
  `RESERVE_SERVICE_PRODUCT` «Послугу не можна резервувати». У `POSTED` —
  `DOCUMENT_POSTED_READ_ONLY`.
- **POST** `PostCustomerOrder(id, expectedVersion, idempotencyKey)` — `DRAFT` або `POSTED`.
  Транзакція: `select ... for update` шапки; `DOCUMENT_HAS_NO_LINES`; повторна валідація SAVE;
  `lock_counterparty(customerId)`, `lock_warehouse(warehouseId)`; `g_internal := true`;
  видалення рухів реєстратора в `RegCustomerOrders` і `RegStockReserve`; вставка рухів (розд. 9);
  перевірка вільного залишку (`RESERVE_EXCEEDS_FREE_STOCK`); при повторному проведенні —
  перевірка, що залишок `RegCustomerOrders` по жодному товару не став від'ємним через уже
  проведені реалізації (`ORDER_QUANTITY_BELOW_SHIPPED` «Кількість «X» 3,000 менша за вже
  відвантажену 5,000»); кредитний ліміт договору — лише warning `CREDIT_LIMIT_EXCEEDED` (не
  блокує); `status=POSTED`, `closed=false`; аудит `POST`. Порядок блокувань: рядок замовлення
  `FOR UPDATE` → контрагент → склад.
- **UNPOST** `UnpostCustomerOrder(id, expectedVersion)` — `POSTED`. Видаляє всі рухи реєстратора
  (зокрема закривальні); якщо залишок `RegCustomerOrders(order, product)` < 0 —
  `ORDER_HAS_SHIPMENTS` «Є проведені реалізації на підставі замовлення: <номери>. Спочатку
  скасуйте їх проведення.»; `status=DRAFT`, `closed=false`; аудит `UNPOST`.
- **COPY** `CopyCustomerOrder(id)` — нова чернетка: шапка без `id/number/status/closed/аудиту`,
  `occurredAt=sysdate`, `shipmentDate=trunc(sysdate)+1`; рядки з новими `lineId`, ті самі
  `quantity/price/discountPercent/reserveFlag`; аудит `COPY` «Копія <id>».
- **CLOSE** `CloseCustomerOrder(id, expectedVersion)` — `POSTED`, `closed=false`, право `close`.
  Перепроводить замовлення: звичайні рухи + закривальні рухи (розд. 9.3), `closed=true`, аудит `CLOSE`. Повтор на
  закритому — idempotent (без змін). Помилка `DOCUMENT_NOT_POSTED`.
- **REOPEN** `ReopenCustomerOrder(id, expectedVersion)` — `POSTED`, `closed=true`. Видаляє
  закривальні рухи (`line_number >= 10000`), перевіряє `RESERVE_EXCEEDS_FREE_STOCK`,
  `closed=false`, аудит `REOPEN`.
- **FILL_PRICES** `FillCustomerOrderPrices(id, expectedVersion)` — `DRAFT`; для кожного рядка
  `price = RegProductPrice(priceTypeId, product, occurredAt)`; рядки без ціни лишаються без змін і
  повертаються у `warnings[]`; `PRICE_TYPE_REQUIRED`, якщо `priceTypeId` порожній.
- **RESERVE_ALL / UNRESERVE_ALL** `SetCustomerOrderReserveAll(id, value, version)` — `DRAFT`;
  `reserveFlag=value` для всіх рядків `GOODS`.
- **CREATE_BASED_ON** `CreateBasedOnCustomerOrder(id, targetType)` — право `create` цільового
  документа; `targetType ∈ {DocInvoiceForPayment, DocGoodsSale}`; повертає незаписану чернетку
  цілі (`NEW` з `baseRef`). Для `DocGoodsSale` — лише `POSTED` (`BASE_ORDER_NOT_POSTED`
  «Замовлення не проведене») і `closed=false` (`BASE_ORDER_CLOSED` «Замовлення закрите»); якщо невідвантаженого залишку
  немає — `NOTHING_TO_SHIP` «За замовленням усе відвантажено». Для `DocInvoiceForPayment` —
  лише `POSTED` (закрите дозволене).

### 8. Розрахунки

- Суми регістра `RegCustomerOrders` — за цінами замовлення (`amount` рядка).
- `amount = round(quantity × price × (1 − discountPercent / 100), 2)` (`HALF_UP`, stored,
  перераховується сервером після зміни `quantity/price/discountPercent/productId`);
- `totalAmount = Σ amount` (stored, після кожної зміни рядків);
- `null`: незавершене введення не надсилається; `discountPercent = null` нормалізується в 0;
  `price = null` під час SAVE → автопідстановка, інакше `PRICE_REQUIRED`.

| quantity | price | discount | Розрахунок | amount |
|---|---|---|---|---|
| 3 | 120,00 | 5 | 3 × 120 × 0,95 = 342,000 | 342,00 |
| 2,500 | 33,33 | 10 | 83,325 × 0,9 = 74,9925 | 74,99 |
| 1 | 10,05 | 12,5 | 10,05 × 0,875 = 8,79375 | 8,79 |
| 1 | 0,01 | 50 | 0,005 | 0,01 (HALF_UP) |
| 4 | 50,00 | 100 | 0 | 0,00 |
| 1 | 99,00 | 0 | 99 | 99,00 |

Рядки 342,00 + 74,99 + 8,79 → `totalAmount = 425,78`.

Вільний залишок (для перевірки резерву): `free(w, p) = Σ RegStockBalance.quantity(w, p) −
Σ RegStockReserve.quantity(w, p, усі замовлення)` за всіма рухами (поточні підсумки).
Попередження `PRICE_BELOW_COST` (F-PRC-05, правило в `RegStockCost`): якщо
`round(price × (1 − d/100), 2) < avgCost(warehouseId, productId)` — «Ціна 95,00 нижча за
собівартість 104,00»; не блокує запис і проведення.

### 9. Проведення й регістри

#### 9.1. `RegCustomerOrders` — один рух на кожен рядок (`GOODS` і `SERVICE`)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `recorder` | `DocCustomerOrder`, `id` | — |
| `lineNumber` | `Goods.lineNumber` | — |
| `customerOrderId` | `header.id` | — |
| `productId` | `Goods.productId` | — |
| `quantity` | `Goods.quantity` | + |
| `amount` | `Goods.amount` | + |

#### 9.2. `RegStockReserve` — рух на кожен рядок з `reserveFlag = true` і `productKind = GOODS`

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `lineNumber` | `Goods.lineNumber` | — |
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `Goods.productId` | — |
| `customerOrderId` | `header.id` | — |
| `quantity` | `Goods.quantity` | + |

Перевірка в тій самій транзакції після вставки: для кожного `productId` рядків з резервом
`free(warehouseId, productId) >= 0`, інакше `RESERVE_EXCEEDS_FREE_STOCK` «Неможливо
зарезервувати «Кабель 3×2,5»: потрібно 30,000 м, вільно 18,500 м на складі «Основний».»
(повідомлення на кожен товар). Перевірка ведеться за поточними підсумками, а не на дату документа.

#### 9.3. Закриття (`CLOSE`) — рухи того самого реєстратора

`CLOSE` перепроводить замовлення: звичайні рухи 9.1/9.2 + для кожного товару `k` (1, 2, … у порядку
мінімального `lineNumber` товару) з ненульовим залишком:
`RegCustomerOrders`: `lineNumber = 10000 + k`, `period = sysdate`, `quantity = −remainingQty`,
`amount = −remainingAmount`; `RegStockReserve` (якщо залишок резерву > 0): `lineNumber = 10000 + k`,
`quantity = −remainingReserve`. Після закриття залишок замовлення й резерву = 0, тому реалізація на
підставі неможлива. `REOPEN` видаляє лише рухи з `lineNumber >= 10000`.

#### 9.4. Повторне проведення й скасування

Повторне проведення атомарно видаляє й вставляє рухи обох регістрів; якщо нова кількість товару
менша за відвантажену — `ORDER_QUANTITY_BELOW_SHIPPED`. `UNPOST` видаляє всі рухи; блокується
(`ORDER_HAS_SHIPMENTS`), якщо будь-який залишок `RegCustomerOrders` по замовленню стає від'ємним.
Від'ємний `RegStockReserve` (резерв, що вже знятий реалізацією) так само блокує операцію.

### 10. Зміни суміжних об'єктів (`DocGoodsSale` r3)

Ця ревізія r3 реалізації описана тут і має бути перенесена в паспорт `DocGoodsSale` під час
погодження.

**Нові поля шапки `doc_goods_sale`:**

| Поле | Назва | Тип | Обов'язкове | Редагування | БД |
|---|---|---|---|---|---|
| `baseOrderId` | Замовлення клієнта | reference `DocCustomerOrder` | ні | `DRAFT` | `base_order_id`, FK, index |
| `contractId` | Договір | reference `RefContract` (`WITH_CUSTOMER`) | ні | `DRAFT` | `contract_id`, FK |

**Заповнення на підставі** (`CreateBasedOnCustomerOrder(id, 'DocGoodsSale')` або команда форми
«Заповнити за замовленням» `FillGoodsSaleByOrder(saleId, version)`):
`customerId, contractId, warehouseId, priceTypeId` — з замовлення; `occurredAt = sysdate`.
Зв'язку рядків реалізації з рядками замовлення немає: зіставлення із залишками замовлення — лише за
`productId`. Для кожного товару беруться `remainingQty` з `RegCustomerOrders(order, product)` і розподіляються по
рядках замовлення у порядку `lineNumber`: рядок отримує `min(line.quantity, залишок товару)`;
`price = round(order.price × (1 − discountPercent/100), 2)`. Приклад: замовлено 10 шт по 100,00 зі
знижкою 5 %, уже відвантажено 4 → рядок реалізації 6 шт × 95,00 = 570,00.

**Валідації під час `POST` реалізації з `baseOrderId`:** замовлення `POSTED` (`BASE_ORDER_NOT_POSTED`)
і `closed=false` (`BASE_ORDER_CLOSED`); `sale.customerId = order.customerId` (`BASE_ORDER_CUSTOMER_MISMATCH`
«Клієнт реалізації відрізняється від клієнта замовлення»); `sale.warehouseId = order.warehouseId`
(`BASE_ORDER_WAREHOUSE_MISMATCH`). Порядок блокувань: шапка реалізації → рядок замовлення
`FOR UPDATE` (послідовні реалізації одного замовлення) → `lock_counterparty` → `lock_warehouse`.

**Рухи реалізації r3** (`lineNumber` усіх рядкових рухів = `Goods.lineNumber`; settlement — 1):

| Регістр | Умова | Мапінг |
|---|---|---|
| `RegStockBalance` | `GOODS` | `warehouseId, productId`, `quantity = −q` (як r2) |
| `RegCounterpartySettlement` | завжди | `RECEIVABLE`, `+totalAmount` (як r2) |
| `RegSales` | усі рядки | `quantity = +q`, `amount = +amount` (як r2) |
| `RegCustomerOrders` | `baseOrderId` задано | `customerOrderId = baseOrderId`, `productId`, `quantity = −q`, `amount = −shippedAmount` |
| `RegStockReserve` | `baseOrderId` і `GOODS` і зарезервовано > 0 | `warehouseId, productId, customerOrderId`, `quantity = −min(q, reserveLeft)` |
| `RegStockCost` | `GOODS` | `quantity = −q`, `costAmount = −cost за середньою` (паспорт `RegStockCost`) |

`shippedAmount` оцінюється за цінами замовлення, а не за ціною реалізації, щоб повне відвантаження
давало рівно 0: по товару з залишком `Rq`/`Ra` рядки обробляються за `lineNumber`; якщо `q = Rq` —
весь `Ra`, інакше `round(q × Ra / Rq, 2)`, після чого `Rq -= q`, `Ra -= shippedAmount`. Приклад: `Q = 3`,
`A = 100,00`; відвантаження 1 → 33,33 (залишок 2 / 66,67); ще 1 → 33,34 (66,67/2 = 33,335 → 33,34);
останнє 1 → 33,33. Сума 100,00.
`reserveLeft` — поточний залишок `RegStockReserve(warehouse, product, order)` до цього рядка,
зменшується послідовно рядками. Приклад: резерв 5, відвантажено 7 → рух резерву −5.

**Перевірки в транзакції проведення реалізації:** `RegStockBalance >= 0` (як r2);
`RegCustomerOrders(baseOrderId, product) >= 0`, інакше (блокує) `ORDER_OVERSHIPMENT` «Відвантаження «X»
перевищує залишок замовлення: замовлено 10,000, відвантажено 4,000, у документі 7,000.»
(товар, відсутній у замовленні, має залишок 0 і дає ту саму помилку); вільний залишок
`free(warehouse, product) >= 0` після зняття власного резерву, інакше `INSUFFICIENT_FREE_STOCK`
«Товар «X» зарезервовано під інші замовлення: вільно 2,000, потрібно 5,000.»; кредитний ліміт:
якщо `contract.creditLimit` не `null` і `Σ RECEIVABLE(customerId)` після проведення строго більша за
`creditLimit` — блокує `CREDIT_LIMIT_EXCEEDED` (рівність дозволена) «Перевищено кредитний ліміт договору «Д-15»: ліміт 50 000,00,
борг після проведення 52 300,00.» (r3: ліміт порівнюється із загальним боргом контрагента —
регістр розрахунків не має виміру договору). Попередження `PRICE_BELOW_COST` не блокує.

**Послуги (`SERVICE`)** у реалізації не формують рухів `RegStockBalance`, `RegStockReserve`,
`RegStockCost` і не перевіряють залишок; формують `RegSales` і (на підставі) `RegCustomerOrders`.
**Скасування проведення реалізації** видаляє всі її рухи; залишок замовлення й резерв відновлюються
автоматично (резерв відновлюється без перевірки вільного залишку, бо товар повертається на склад тим
самим скасуванням).
**Сканер:** форма реалізації r3 отримує `scanInput` над вкладкою «Товари» (`Ctrl+Shift+B`,
`LookupBarcode` → `AddOrIncrementLineByBarcode`), як у замовленні.

### 11. Зберігання й API

```text
doc_customer_order: id PK, doc_number UK, occurred_at, customer_id FK ref_counterparty,
  contract_id FK ref_contract NULL, warehouse_id FK ref_warehouse, price_type_id FK ref_price_type NULL,
  shipment_date date NOT NULL, closed varchar2(1) DEFAULT 'N' CHECK in ('Y','N'),
  currency_code CHECK='UAH', total_amount number(19,2), doc_comment, status CHECK in ('DRAFT','POSTED'),
  version, created_at/by, updated_at/by;
  CHECK (shipment_date >= trunc(occurred_at)); CHECK (status = 'POSTED' or closed = 'N')
  indexes: (occurred_at), (customer_id, occurred_at), (shipment_date), (status, closed)
doc_customer_order_goods: id PK, document_id FK ON DELETE CASCADE, line_number, product_id FK,
  quantity number(19,3) CHECK > 0, price number(19,2) CHECK >= 0,
  discount_percent number(5,2) DEFAULT 0 CHECK between 0 and 100, amount number(19,2),
  reserve_flag varchar2(1) DEFAULT 'N' CHECK in ('Y','N'); index (document_id, line_number), (product_id)
```

Тригери за зразком r2: `doc_customer_order_biud` (нумерація, read-only у `POSTED`, захист `status`,
`closed`, `total_amount`), compound `doc_customer_order_goods_ct` (check_editable, check_goods,
автоціна, `RESERVE_SERVICE_PRODUCT`, amount, renumber, total). Пакет `trade_ops`:
`post_/unpost_/copy_/close_/reopen_customer_order`, `fill_customer_order_prices`.

API: `GET /` (список, фільтри `from,to,customerId,warehouseId,state,onlyRemaining`), `GET /picker`,
`GET /new`, `GET /{id}`, `POST /`, `PUT /{id}`, `DELETE /{id}` (DRAFT), `POST /{id}/post`,
`/unpost`, `/close`, `/reopen`, `/copy`, `/fill-prices`, `/reserve-all`, `/lines/by-barcode`, `/create-based-on/{targetType}`,
`GET /{id}/free-stock`, `GET /{id}/fulfillment`, `GET /{id}/movements`, `GET /{id}/print/order`.
Права: `document.customer-order.read/create/update/delete/post/unpost/close`.
Друкована форма «Замовлення клієнта»: шапка (номер, дата, клієнт, договір, склад, дата
відвантаження), таблиця N/Номенклатура/Од./К-сть/Ціна/Знижка %/Сума, «Всього», підписи.

### 12. Тести й готовність

- Unit: формула `amount` (таблиця розд. 8), межі знижки 0/100/100,01, дробність, `SERVICE` + резерв.
- Application: NEW/SAVE/POST/UNPOST/COPY/CLOSE/REOPEN/FILL_PRICES; idempotency повторного POST;
  `OPTIMISTIC_LOCK_CONFLICT`; автодоговір і вид цін із договору.
- БД: CHECK-и, тригер read-only, FK, перенумерація, унікальність recorder+lineNumber у регістрах.
- Конкурентність: два замовлення одночасно резервують останні 10 шт — друге отримує
  `RESERVE_EXCEEDS_FREE_STOCK` (блокування складу `FOR UPDATE`).
- API/UI: права, капабіліті кнопок у статусах, QueryTable «Вільні залишки», підбір, вибір.
- Наскрізний сценарій: надходження 20 шт «Фарба» на «Основний»; замовлення 001: 12 шт × 150,00,
  знижка 10 %, резерв → `amount = 1 620,00`, вільно 8; замовлення 002: 10 шт з резервом →
  `RESERVE_EXCEEDS_FREE_STOCK` (вільно 8,000); реалізація на підставі 001 на 5 шт → резерв 7,
  залишок замовлення 7 / 945,00, вільно 8; реалізація 8 шт → `ORDER_OVERSHIPMENT`;
  `CLOSE` 001 → резерв 0, вільно 15; `UNPOST` 001 → `ORDER_HAS_SHIPMENTS`; скасування
  реалізації, потім `UNPOST` 001 — успішно, рухи порожні.

## Доповнення r5 — F-PRC-06 «Знижки й акції» (APE-64, `PROPOSED`)

- Рядки: `manualDiscountPercent` «Ручна знижка, %» (редагується, обмежена роллю — `RegDiscountLimit`),
  `autoDiscountPercent` «Авт. знижка, %» і `discountId` «Умова знижки» (з `RefDiscount`);
  `discountPercent` = ручна + автоматична (≤ 100 %), лише перегляд. Вставка лише `discountPercent`
  (API r3) — ручна знижка.
- Команди «Розрахувати знижки», «Ручна знижка на документ»; проведення перераховує автоматичні знижки.
- Реалізація на підставі замовлення переносить ціну до знижки, знижки й умову рядка.
