# Паспорт документа «Повернення від клієнта»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`; реалізація до погодження не виконується.
- Ревізія: `r3`.
- Розділ меню (Taxi): `Продажі` → група «Продажі» (після «Реалізація товарів»);
  дублюється в `Склад` → «Складські операції» лише як посилання на список.
- Залежності: `DocGoodsSale` (r3, проведений документ-підстава), `RefCounterparty`,
  `RefWarehouse`, `RefProduct` r3 (`productKind`), `RefContract` (лише копіювання з
  підстави), `RegStockBalance`, `RegCounterpartySettlement`, `RegSales`, `RegStockCost`.
- Аналог у 1С:УТ 11: Документ.ВозвратТоваровОтКлиента (спрощено: без повернення коштів,
  без серій, без «акта про розбіжності»).
- Функції каталогу: `F-SAL-06` (основна), `F-SRV-01` (введення на підставі
  «Реалізація → Повернення»), `F-WH-09` (відновлення собівартості), `F-REP-03`/`F-REP-06`
  (сторно продажів і собівартості).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Повернення від клієнта (список — «Повернення від клієнтів») |
| Технічне ім'я | `DocCustomerReturn` |
| Технічний ключ | `Document.DocCustomerReturn` |
| Клас / ID | `CustomerReturn` / `CustomerReturnId` |
| Клас рядка | `CustomerReturnLine` / `CustomerReturnLineId` |
| Таблиці | `doc_customer_return`, `doc_customer_return_goods` |
| DTO | `CustomerReturnDto`, `CustomerReturnLineDto`, `CustomerReturnListItemDto` |
| API | `/api/v1/documents/customer-returns` |
| Сторінки APEX | 280 — список, 281 — форма документа |
| Нумерація | `doc_customer_return_num_seq`, 9 цифр із провідними нулями (`000000001`), присвоюється під час першого запису, унікальна, не перевикористовується, ручна зміна в `DRAFT` дозволена з перевіркою унікальності |
| Дата | `occurredAt`, `DATETIME` з точністю до секунди, бізнес-зона Europe/Kyiv |
| Підстава | `DocGoodsSale` у статусі `POSTED`, обов'язкова (`baseSaleId`); введення без підстави в r3 не підтримується |
| Видалення | чернетку — фізично командою «Видалити»; проведений документ не видаляється |
| recorder_type | `DocCustomerReturn` |

Документ фіксує повернення раніше відвантаженого клієнту товару на склад: товар
повертається в залишок, дебіторська заборгованість клієнта зменшується, продажі й
собівартість продажу сторнуються пропорційно поверненій кількості.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування (по статусах) | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ніколи | PK `id` |
| `number` | Номер | String | 9 | так | sequence під час запису | DRAFT | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | поточний момент (`sysdate`) | DRAFT | `occurred_at`, index |
| `baseSaleId` | Реалізація (підстава) | ref `DocGoodsSale` | 32 | так | з команди «Створити на підставі» | DRAFT, лише поки немає рядків | `base_sale_id`, FK, index |
| `customerId` | Клієнт | ref `RefCounterparty` | 32 | так | `baseSale.customerId` | ніколи (завжди з підстави) | `customer_id`, FK, index |
| `contractId` | Договір | ref `RefContract` | 32 | ні | `baseSale.contractId` | ніколи | `contract_id`, FK |
| `warehouseId` | Склад | ref `RefWarehouse` | 32 | так | `baseSale.warehouseId` | DRAFT | `warehouse_id`, FK |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | ніколи в r3 | `currency_code`, CHECK = 'UAH' |
| `returnReason` | Причина повернення | String | 255 | ні | — | DRAFT | `return_reason` |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ніколи (розрахунок) | `total_amount`, stored |
| `comment` | Коментар | String | 1000 | ні | — | DRAFT | `doc_comment` |
| `status` | Статус | enum | 10 | так | `DRAFT` | лише командами | CHECK (`DRAFT`,`POSTED`) |
| `version` | Версія | Long | 19 | так | 0 | ніколи | optimistic lock |
| `createdAt/By`, `updatedAt/By` | Аудит | — | — | так | server | ніколи | службові |

Правила шапки:

- Договір під час `POST` повторно перевіряється спільними правилами `RefContract`: власник = контрагент документа (`CONTRACT_OWNER_MISMATCH`), вид договору відповідає операції — з покупцем (`CONTRACT_KIND_MISMATCH`).
- `customerId`, `contractId` завжди дорівнюють значенням підстави; сервер перезаписує їх
  під час кожного запису (захист від підміни через API).
- `warehouseId` можна змінити: клієнт може повернути товар на інший склад (наприклад,
  склад браку). Новий склад має бути `ACTIVE`.
- `occurredAt >= baseSale.occurredAt`, інакше `RETURN_DATE_BEFORE_BASE`.
- Зміна `baseSaleId` дозволена лише в порожньому документі; інакше `BASE_CHANGE_WITH_LINES`.

### 3. Таблична частина `Goods` («Товари»)

Таблиця `doc_customer_return_goods`, клас `CustomerReturnLine`, стабільний UUID рядка
(`lineId`), `lineNumber` — порядок (перенумеровується після видалення/переміщення).
Один рядок підстави може бути лише в одному рядку повернення (UNIQUE
`document_id + base_sale_line_id`).

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ніколи | PK `id` |
| `lineNumber` | N | int | 10 | так | наступний | порядком | `line_number` |
| `baseSaleLineId` | Рядок реалізації | UUID | 32 | так | з підбору | ніколи після додавання | `base_sale_line_id`, FK → `doc_goods_sale_goods(id)` |
| `productId` | Товар | ref `RefProduct` | 32 | так | з рядка підстави | ніколи | `product_id`, FK |
| `quantity` | Кількість | Decimal | 19,3 | так | повертаємий залишок | DRAFT | `quantity`, CHECK > 0 |
| `price` | Ціна | Decimal | 19,2 | так | ціна рядка підстави | ніколи | `price`, CHECK >= 0 |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ніколи | `amount`, stored |
| `soldQuantity` | Продано | Decimal | 19,3 | — | з підстави | ніколи | transient |
| `returnableQuantity` | Можна повернути | Decimal | 19,3 | — | розрахунок | ніколи | transient |

Додавання рядка можливе лише вибором рядка підстави (форма «Підбір з реалізації» або
команда `FILL_FROM_BASE`); довільний товар додати не можна. Копіювання рядка (F9) у
межах документа заборонене, бо порушує унікальність `baseSaleLineId`.

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Редагованість |
|---|---|---|---|---|---|
| — | `NEW` (на підставі) | `DRAFT` (не записано) | `document.customer-return.create` | підстава `POSTED` | шапка й рядки за §2–3 |
| `DRAFT` | `SAVE` | `DRAFT` | `document.customer-return.update` | версія збігається | шапка й рядки |
| `DRAFT` | `POST` | `POSTED` | `document.customer-return.post` | §7.3 | read-only |
| `POSTED` | `POST` (повторно) | `POSTED` | `document.customer-return.post` | §7.3 | read-only |
| `POSTED` | `UNPOST` | `DRAFT` | `document.customer-return.unpost` | §7.4 | шапка й рядки |
| `DRAFT` | `DELETE` | — | `document.customer-return.delete` | немає рухів | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `document.customer-return.create` | підстава ще `POSTED` | — |

У `POSTED` шапка й рядки read-only (тригер `doc_customer_return_ro_trg`, як у r2).
Фізичне видалення проведеного документа заборонене (`DOCUMENT_POSTED_READ_ONLY`).

Зміна суміжного об'єкта `DocGoodsSale` r3: скасування проведення реалізації заборонене,
поки існує хоча б одне `POSTED` повернення з `baseSaleId` = цій реалізації — помилка
`BASE_HAS_POSTED_RETURNS` «Реалізацію №… не можна скасувати: за нею проведено
повернення №…». Чернетки повернень не блокують.

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 280)

- IR, сортування `occurredAt DESC, number DESC`.
- Колонки: `stateIcon[4]` (проведено / чернетка) | `number[12]` | `occurredAt[16]` |
  `customer[30]` | `warehouse[20]` | `baseSale[22]` («Реалізація № … від …», посилання) |
  `totalAmount[14]` праворуч | `returnReason[20]`.
- Фільтри: період, клієнт, склад, статус, «Реалізація».
- Команди: `Створити` (відкриває вибір проведеної реалізації, потім форму на її
  підставі) | `Скопіювати (F9)` | `Провести` | `Скасувати проведення` | `Пошук (Ctrl+F)` |
  `Друк ▾`. Подвійний клік / `Enter` відкриває документ.

#### 5.2. Форма документа (сторінка 281)

```text
FORM customerReturnEditor  title: «Повернення від клієнта № <number> від <occurredAt> (проведено)»

HEADER
  actions: [Провести і закрити]* | Записати | Провести | Скасувати проведення |
           Створити на підставі ▾ (порожнє в r3, зарезервовано) |
           Друк ▾ (Накладна на повернення) | Ще ▾ (Скопіювати F9, Структура підпорядкованості, Рухи документа)
  number[20] | occurredAt[22]
  baseSale[50] (ReferenceField, Choice = проведені реалізації; кнопка «Відкрити»)
  customer[50] (read-only) | contract[30] (read-only, прихований якщо null)
  warehouse[40]
  returnReason[100]
CONTENT
  scanInput[30] «Штрихкод» (над вкладкою «Товари», Ctrl+Shift+B; лише DRAFT)
  TAB Товари (N)
    commands: Додати (вибір рядка реалізації) | Заповнити за реалізацією | Видалити | ↑ ↓
    GoodsTable: lineNumber[5] | product[40] | soldQuantity[12] | returnableQuantity[12] |
                quantity[12]* | price[12] | amount[14]
    total: «Всього: <totalAmount> UAH»
  TAB Рухи (лише POSTED)
    QueryTable postingMovements «Рухи документа»
      query: GetDocumentMovements(recorderType='DocCustomerReturn', recorderId)
      columns: register[20] | lineNumber[6] | warehouse[20] | product[30] | counterparty[20] |
               quantity[12] | amount[14] | costAmount[14]
      refresh: ON_OPEN, AFTER_POSTING
FOOTER
  comment[100] | author (updatedBy, read-only)
```

`*` — редаговане поле рядка; `Провести і закрити` — кнопка за замовчуванням (жовта).
Колонки `soldQuantity`, `returnableQuantity` розраховуються сервером на момент
відкриття форми / виконання команди.

#### 5.3. Форма вибору рядків підстави («Підбір з реалізації»)

Модальна таблиця рядків `baseSale`: `lineNumber | product | soldQuantity |
alreadyReturned | returnableQuantity | price`; показує лише рядки з
`returnableQuantity > 0`, яких ще немає в документі. Множинний вибір чекбоксами,
кнопка «Перенести в документ» додає рядки з `quantity = returnableQuantity`.

#### 5.4. Форма вибору документа

Колонки `number[12] | occurredAt[16] | customer[30] | totalAmount[14]`, лише `POSTED`.
Використовується в майбутньому «Поверненні коштів покупцю» (r4).

### 6. Події введення

| Поле | Компонент | INPUT_COMMITTED → команда | Залежності | Сервер перераховує | Повертає | Помилка / фокус |
|---|---|---|---|---|---|---|
| `number` | TextField | `ChangeCustomerReturnHeader(number)` | — | — | поле | `DOCUMENT_NUMBER_NOT_UNIQUE`, фокус лишається |
| `occurredAt` | DateTimeField | `ChangeCustomerReturnHeader(occurredAt)` | baseSale | `returnableQuantity` усіх рядків | документ | `RETURN_DATE_BEFORE_BASE` |
| `baseSaleId` | ReferenceField | `ChangeCustomerReturnBase(baseSaleId)` | рядки мають бути порожні | customer, contract, warehouse | документ | `BASE_NOT_POSTED`, `BASE_CHANGE_WITH_LINES` |
| `customerId` | ReferenceField (disabled) | — | — | — | — | — |
| `contractId` | ReferenceField (disabled) | — | — | — | — | — |
| `warehouseId` | ReferenceField | `ChangeCustomerReturnHeader(warehouseId)` | — | — | поле | `REFERENCE_NOT_ACTIVE` |
| `returnReason` | TextField | `ChangeCustomerReturnHeader(returnReason)` | — | — | поле | довжина > 255 |
| `comment` | TextArea | `ChangeCustomerReturnHeader(comment)` | — | — | поле | довжина > 1000 |
| `totalAmount` | NumberField (disabled) | — | — | — | — | — |
| `scanInput` (форма) | TextField | `LookupBarcode(barcode)` → `AddOrIncrementLineByBarcode(documentId, productId, unitQuantity, expectedVersion)` | `RegBarcode` | quantity, amount, totalAmount | рядок + підсумок | `BARCODE_NOT_FOUND`, `BARCODE_PRODUCT_NOT_IN_BASE`; поле очищується, фокус лишається |
| `line.baseSaleLineId` | ChoiceCell | `AddCustomerReturnLines(baseSaleLineIds[])` | baseSale | product, price, quantity, amount, totalAmount | документ | `BASE_LINE_ALREADY_IN_DOCUMENT`, `NOTHING_TO_RETURN` |
| `line.productId` | ReferenceCell (disabled) | — | — | — | — | — |
| `line.quantity` | NumberCell | `ChangeCustomerReturnLineQuantity(lineId, quantity, version)` | returnable, дробність одиниці | amount, totalAmount | рядок + підсумок | `RETURN_EXCEEDS_SOLD`, `QUANTITY_NOT_FRACTIONAL`, `QUANTITY_MUST_BE_POSITIVE`; фокус на клітинці |
| `line.price` | NumberCell (disabled) | — | — | — | — | — |
| `line.amount` | NumberCell (disabled) | — | — | — | — | — |

Перевищення під час вводу кількості повертається як попередження з підсвіткою клітинки
(значення приймається в чернетку); остаточна блокувальна перевірка — під час `POST`.

Сканер: Товар має бути серед рядків реалізації-підстави: наявний рядок повернення → `quantity += unitQuantity`; рядок підстави ще не в документі → додається з `quantity = unitQuantity`; товару немає в підставі → `BARCODE_PRODUCT_NOT_IN_BASE` «Товару «…» немає в реалізації-підставі.»

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Спільне для всіх змінних команд: перевірка права, `expectedVersion` (інакше
`OPTIMISTIC_LOCK_CONFLICT` «Документ змінено іншим користувачем. Оновіть форму.»),
статус `DRAFT` для змін (інакше `DOCUMENT_POSTED_READ_ONLY` «Проведений документ не
можна змінювати. Скасуйте проведення.»), `idempotencyKey` для `POST`/`UNPOST`/`COPY`/
`FILL_FROM_BASE` (повтор того самого ключа повертає попередній результат), запис у
`sys_audit_log` (`CREATE`, `UPDATE`, `POST`, `UNPOST`, `COPY`, `DELETE`).

#### 7.1. NEW — `InitializeCustomerReturn(baseSaleId)`

- Право `document.customer-return.create`; підстава в `POSTED`, інакше `BASE_NOT_POSTED`
  «Повернення можна ввести лише на підставі проведеної реалізації.»
- Повертає незаписану чернетку: `occurredAt = now`, customer/contract/warehouse з
  підстави, рядки = результат `FILL_FROM_BASE` (усі рядки з `returnableQuantity > 0`).
- Якщо повертати нічого — `NOTHING_TO_RETURN` «За реалізацією №… весь товар уже
  повернено.»

#### 7.2. SAVE — `SaveCustomerReturn(dto, expectedVersion)`

- Транзакція: lock шапки `FOR UPDATE`, перевірка статусу/версії, заміна рядків за
  `lineId` (merge), перерахунок `amount`, `totalAmount`, `version + 1`, аудит.
- Валідації: обов'язкові поля, `occurredAt >= baseSale.occurredAt`, кожен
  `baseSaleLineId` належить `baseSaleId` (`BASE_LINE_FOREIGN`), унікальність рядка
  підстави, дробність. Перевищення повертаємого — лише попередження.

#### 7.3. POST — `PostCustomerReturn(id, expectedVersion, idempotencyKey)`

1. `select … from doc_customer_return where id = :id for update`; версія.
2. `require_lines` → `NO_LINES` «Неможливо провести документ без рядків у табличній
   частині «Товари».»
3. Lock підстави `doc_goods_sale … for update` (серіалізує паралельні повернення за
   однією реалізацією); підстава `POSTED` (`BASE_NOT_POSTED`).
4. Lock `ref_counterparty(customerId)`, `ref_warehouse(warehouseId)`.
5. Перевірка повертаємої кількості для кожного рядка:
   `returnable = base.quantity − Σ quantity рядків інших POSTED повернень з тим самим
   baseSaleLineId`; якщо `quantity > returnable` → `RETURN_EXCEEDS_SOLD` «Рядок N:
   товар «…» — повертається 5,000 шт, а можна повернути не більше 3,000 шт (продано
   10,000, уже повернено 7,000).»
6. `delete_movements('DocCustomerReturn', id)`; вставка рухів §9.
7. Перевірки в тій самій транзакції: `RegCounterpartySettlement` RECEIVABLE клієнта ≥ 0
   (§9.2), `RegStockCost` за ключами ≥ 0 (формально не може стати від'ємним при `+`).
8. `status = POSTED`, `version + 1`, аудит `POST`. Будь-яка помилка — rollback усього.

#### 7.4. UNPOST — `UnpostCustomerReturn(id, expectedVersion, idempotencyKey)`

- `require_posted` (`DOCUMENT_NOT_POSTED` «Документ не проведено.»), lock складу.
- Видаляє рухи, потім `check_free_stock(warehouseId, products)` (інваріант `RegStockBalance − Σ RegStockReserve ≥ 0` за поточними підсумками `*_tot`): якщо повернений товар уже
  продано/списано/переміщено або зарезервовано, вільний залишок стане від'ємним → `INSUFFICIENT_FREE_STOCK` «Недостатньо вільного
  товару «…» на складі «…»: не вистачає 2,000 шт (залишок 3,000, резерв 5,000).» Повторне проведення (repost) виконує ту саму перевірку після видалення старих рухів. Аналогічно `RegStockCost`
  (`STOCK_COST_NEGATIVE`).
- RECEIVABLE після скасування лише зростає — перевірка не потрібна.
- `status = DRAFT`, аудит `UNPOST`.

#### 7.5. COPY (F9) — `CopyCustomerReturn(id)`

Нова чернетка з тим самим `baseSaleId`, `warehouseId`, `returnReason`, `comment` та
рядками (`baseSaleLineId`, `quantity`); без ID, номера, аудиту, статусу й рухів;
`occurredAt = now`. Ціни й суми перечитуються з підстави. Перевищення не блокує копію,
але показується попередженням.

#### 7.6. FILL_FROM_BASE — `FillCustomerReturnFromBase(id, expectedVersion, mode)`

- `mode = REPLACE` (кнопка «Заповнити за реалізацією», з підтвердженням очищення) або
  `ADD_MISSING` (додає лише відсутні рядки підстави).
- Для кожного рядка підстави з `returnable > 0`: `productId`, `price`,
  `quantity = returnable`, `baseSaleLineId`; порядок — `lineNumber` підстави.
- Порожній результат → `NOTHING_TO_RETURN`.

#### 7.7. Довідник помилок

Усі помилки піднімаються через `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error(-20100, …)`); код — UPPER_SNAKE на початку тексту в квадратних дужках, попередження (warning) повертаються як повідомлення APEX без rollback.

| Код | Повідомлення |
|---|---|
| `BASE_NOT_POSTED` | Повернення можна ввести лише на підставі проведеної реалізації. |
| `BASE_CHANGE_WITH_LINES` | Щоб змінити реалізацію-підставу, спочатку очистіть табличну частину. |
| `BASE_LINE_FOREIGN` | Рядок N не належить реалізації-підставі. |
| `BASE_LINE_ALREADY_IN_DOCUMENT` | Рядок реалізації вже додано в повернення (рядок N). |
| `RETURN_DATE_BEFORE_BASE` | Дата повернення не може бути раніше дати реалізації (…). |
| `RETURN_EXCEEDS_SOLD` | Рядок N: можна повернути не більше X (продано Y, уже повернено Z). |
| `NOTHING_TO_RETURN` | За реалізацією №… весь товар уже повернено. |
| `SETTLEMENT_NEGATIVE_RECEIVABLE` | Повернення на суму … перевищує заборгованість клієнта «…» (…). Повернення коштів покупцю в r3 не підтримується. |
| `BARCODE_NOT_FOUND` | Штрихкод «…» не знайдено. |
| `BARCODE_PRODUCT_NOT_IN_BASE` | Товару «…» немає в документі-підставі. |
| `INSUFFICIENT_FREE_STOCK` | Недостатньо вільного товару «…» на складі «…»: не вистачає … (залишок …, резерв …). |
| `STOCK_COST_NEGATIVE` | Вартість запасу товару «…» на складі «…» стане від'ємною. |
| `NO_LINES`, `DOCUMENT_NOT_POSTED`, `DOCUMENT_POSTED_READ_ONLY`, `OPTIMISTIC_LOCK_CONFLICT`, `PERMISSION_DENIED`, `QUANTITY_NOT_FRACTIONAL` | спільні повідомлення r2 |

### 8. Розрахунки

- `returnable(line) = baseLine.quantity − Σ quantity(POSTED returns, same baseSaleLineId,
  id ≠ current)`, scale 3; transient.
- `amount`: якщо `quantity + alreadyReturnedQty = baseLine.quantity` (рядок повертається
  до кінця) → `amount = baseLine.amount − Σ amount попередніх POSTED повернень рядка`
  (залишковий метод, без «копійок» розбіжності); інакше `round(quantity × price, 2)`
  `HALF_UP`. Stored, вручну не змінюється.
- `totalAmount = Σ amount`, scale 2.
- `costAmount` (лише в русі `RegStockCost`, transient у формі): `saleCost` — сума руху
  `RegStockCost` реалізації за рядком підстави (абсолютне значення; recorder =
  DocGoodsSale, lineNumber = baseLine.lineNumber); якщо рядок закривається повністю —
  `saleCost − Σ cost попередніх повернень рядка`; інакше
  `round(saleCost × quantity / baseLine.quantity, 2)`.
- `null`: `quantity` з UI не надсилається порожнім; порожня клітинка = відміна вводу.
  `price` не може бути null (копіюється з підстави, де вона NOT NULL).

Приклади:

| Продано | Ціна | Сума продажу | Собів. продажу | Повернення 1 | Повернення 2 |
|---|---|---|---|---|---|
| 3,000 | 33,33 | 99,99 | 60,00 | 1,000 → 33,33; cost 20,00 | 2,000 → 99,99 − 33,33 = 66,66; cost 60,00 − 20,00 = 40,00 |
| 7,000 | 10,00 | 70,00 | 45,50 | 2,000 → 20,00; cost round(45,50×2/7)=13,00 | 5,000 → 50,00; cost 32,50 |

### 9. Проведення й регістри

Запис у регістри — лише всередині проведення під прапором `trade_core.g_internal`; похідні таблиці підсумків `*_tot` і знімків `*_snap` регістрів залишків оновлюються в тій самій транзакції. Порядок блокувань: рядок документа-підстави → `ref_counterparty` → `ref_warehouse` (`FOR UPDATE`).

Нумерація рухів: `lineNumber` руху = `lineNumber` рядка документа для
`RegStockBalance`, `RegSales`, `RegStockCost`; `RegCounterpartySettlement` — один рух
з `lineNumber = 1`. `period = occurredAt` для всіх рухів.

#### 9.1. RegStockBalance (лише `productKind = GOODS`)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **+** |

#### 9.2. RegCounterpartySettlement

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `counterpartyId` | `header.customerId` | — |
| `direction` | `RECEIVABLE` | — |
| `currencyCode` | `UAH` | — |
| `amount` | `header.totalAmount` | **−** |

**Рішення щодо від'ємної дебіторки: заборонено.** Якщо після руху залишок RECEIVABLE
клієнта < 0 (клієнт уже оплатив реалізацію), проведення відхиляється з
`SETTLEMENT_NEGATIVE_RECEIVABLE`. Обґрунтування:

1. Погоджений паспорт `RegCounterpartySettlement` (AGREED) забороняє від'ємний
   залишок; §2.3 дорожньої карти підтверджує заборону для r3.
2. Аванс клієнта як від'ємна дебіторка зламав би вже реалізовані перевірки
   `DocCustomerPayment` («переплата покупця») і `DocGoodsSale` unpost, а також звіт
   взаєморозрахунків (від'ємна дебіторка ≠ кредиторка).
3. Повернення коштів/залік авансу потребує окремого документа («Повернення коштів
   покупцю», r4) з власним рухом PAYABLE/RECEIVABLE.

Обхід у r3: скасувати проведення (або зменшити) оплату покупця, провести повернення,
потім повторно провести оплату на залишок. Те саме рішення застосовано в
`DocSupplierReturn` (`SETTLEMENT_NEGATIVE_PAYABLE`).

#### 9.3. RegSales (усі рядки, включно з `SERVICE`)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `counterpartyId` | `header.customerId` | — |
| `warehouseId` | `baseSale.warehouseId` (склад продажу, не повернення — щоб оборот за складом продажу коректно зменшувався) | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **−** |
| `amount` | `line.amount` | **−** |

#### 9.4. RegStockCost (лише `GOODS`)

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `warehouseId` | `header.warehouseId` | — |
| `productId` | `line.productId` | — |
| `quantity` | `line.quantity` | **+** |
| `costAmount` | `costAmount` за §8 (собівартість рядка продажу пропорційно) | **+** |

Повернення не перераховує середню ковзну собівартість за правилами надходження, а
відновлює саме ту вартість, що була списана реалізацією (див. паспорт `RegStockCost`).

#### 9.5. Повторне проведення й скасування

Повторне проведення атомарно видаляє й заново формує всі чотири набори в одній
транзакції. `UNPOST` видаляє набори і перевіряє `RegStockBalance`/`RegStockCost` ≥ 0
(§7.4). Пакет `trade_ops.delete_movements` доповнюється `reg_stock_cost_mv`.

### 10. Зберігання й API

```text
doc_customer_return
  PK id; UNIQUE doc_number; FK base_sale_id → doc_goods_sale(id);
  FK customer_id → ref_counterparty; FK contract_id → ref_contract;
  FK warehouse_id → ref_warehouse; CHECK status IN ('DRAFT','POSTED');
  CHECK currency_code = 'UAH'; CHECK total_amount >= 0
  INDEX (occurred_at), (customer_id), (base_sale_id)
doc_customer_return_goods
  PK id; FK document_id → doc_customer_return ON DELETE CASCADE;
  FK base_sale_line_id → doc_goods_sale_goods(id); FK product_id → ref_product;
  CHECK quantity > 0; CHECK price >= 0;
  UNIQUE (document_id, base_sale_line_id); INDEX (document_id, line_number);
  INDEX (base_sale_line_id)  -- розрахунок «уже повернено»
```

Тригер read-only у `POSTED` (як `doc_goods_sale`), пакет `trade_ops`:
`post_customer_return`, `unpost_customer_return`, `copy_customer_return`,
`fill_customer_return(p_id, p_mode)`.

| Метод | Шлях | Призначення |
|---|---|---|
| GET | `/api/v1/documents/customer-returns` | список (фільтри period, customerId, warehouseId, status, baseSaleId) |
| GET | `…/new?baseSaleId=` | `InitializeCustomerReturn` |
| GET | `…/{id}` | документ із transient-полями |
| POST | `…` | створити |
| PUT | `…/{id}` | записати |
| POST | `…/{id}/post`, `…/{id}/unpost`, `…/{id}/copy`, `…/{id}/fill-from-base` | команди |
| GET | `…/{id}/movements` | рухи |
| GET | `…/{id}/print/return-note` | друк «Накладна на повернення» (PDF): реквізити, підстава, таблиця товарів, сума словами, підписи |

### 11. Тести й готовність

- Unit: формули §8 (залишковий метод, пропорційна собівартість), повертаємий залишок.
- Проведення: 4 регістри, знаки, `SERVICE` без складських рухів, repost без дублів.
- Конкурентність: два повернення за однією реалізацією проводяться паралельно — друге
  отримує `RETURN_EXCEEDS_SOLD` (lock підстави).
- Заборони: від'ємна дебіторка, unpost після продажу поверненого, unpost реалізації з
  проведеним поверненням (`BASE_HAS_POSTED_RETURNS`).
- UI: створення з форми реалізації, підбір, read-only у `POSTED`, вкладка «Рухи».

Наскрізний сценарій:

1. Надходження: товар «Кабель» 10,000 м × 20,00 на склад «Основний» → `RegStockCost`
   10,000 / 200,00.
2. Реалізація №1 клієнту «Альфа»: 6,000 м × 35,00 = 210,00 → RECEIVABLE 210,00,
   Sales +6/210,00, StockCost −6/120,00, залишок 4,000.
3. Оплата від «Альфа» 100,00 → RECEIVABLE 110,00.
4. Повернення №1 на підставі реалізації №1: 2,000 м → amount 70,00, cost 40,00. Проведення:
   Stock +2 → 6,000; RECEIVABLE 40,00; Sales 4/140,00; StockCost 6/120,00.
5. Повернення №2: 4,000 м (повертаємо 6 − 2 = 4,000, ліміт не перевищено) → amount
   140,00 → RECEIVABLE 40,00 − 140,00 = −100,00 → `SETTLEMENT_NEGATIVE_RECEIVABLE`.
   Зменшуємо до 1,000 м: amount 35,00, cost 20,00; RECEIVABLE 5,00; залишок 7,000.
6. Повернення №3 на 4,000 м → `RETURN_EXCEEDS_SOLD` (можна 3,000: продано 6, повернено 3).
7. Реалізація №2 продає 7,000 м (залишок 0); спроба `UNPOST` повернення №1 →
   `INSUFFICIENT_FREE_STOCK` «Недостатньо вільного товару «Кабель» на складі «Основний»: не вистачає 2,000 м.»
8. Спроба `UNPOST` реалізації №1 → `BASE_HAS_POSTED_RETURNS`.
