# Паспорт регістру залишків «Замовлення клієнтів»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем.
- Ревізія: `r3`.
- Вид: `BALANCE` (накопичувальний регістр залишків, signed resources).
- Розділ меню («Такси»): підсистема `Продажі` → група «Звіти» («Замовлення клієнтів» і звіт
  «Аналіз замовлень клієнтів»).
- Реєстратори: `DocCustomerOrder` (+ замовлено; − закриваючі рухи при `closed = Y`),
  `DocGoodsSale` r3 (− відвантажено, якщо заповнено `baseOrderId`).
- Аналог 1С:УТ 11: `РегистрНакопления.ЗаказыКлиентов` (спрощено: без графіка відвантаження,
  без характеристик і серій).
- Функції каталогу: `F-SAL-01`, `F-SAL-05`, `F-REP-05`, `F-SRV-01`, `F-SRV-03`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Замовлення клієнтів |
| Технічне ім'я | `RegCustomerOrders` |
| Об'єкт метаданих | `Register.CustomerOrders` (kind `ACCUMULATION_REGISTER`) |
| Клас руху | `CustomerOrdersMovement` |
| Таблиця рухів | `reg_customer_orders_mv` |
| Похідні таблиці | `reg_customer_orders_tot` (поточні), `reg_customer_orders_snap` (місячні) |
| API | `/api/v1/registers/customer-orders` |
| Сторінка APEX | 230 |

Регістр зберігає **невідвантажений залишок** кожного замовлення клієнта за товарами — у
кількості й у сумі за цінами замовлення. Залишок використовується для заповнення реалізації
на підставі, для контролю перевідвантаження і для звіту «Аналіз замовлень клієнтів».

### 2. Структура руху

| Поле | Роль | Тип | Точність | Джерело | Посилання/БД |
|---|---|---|---|---|---|
| `id` | системне | UUID | 32 hex | server | PK |
| `period` | системне | DateTime UTC | секунди | `header.occurredAt` | index |
| `recorderType` / `recorderId` | системне | String(60) / UUID | — | реєстратор | index |
| `lineNumber` | системне | int | 10 | схема п. 7 | UK з recorder |
| `customerOrderId` | вимір | UUID | — | `header.id` замовлення або `baseOrderId` | `doc_customer_order`, FK |
| `productId` | вимір | UUID | — | рядок | `RefProduct`, FK |
| `quantity` | ресурс | Number | 19,3 | рядок / розрахунок | signed, одиниця товару |
| `amount` | ресурс | Number | 19,2 | рядок / розрахунок | signed, UAH, ціни замовлення |

- Ключ поточного підсумку: `customerOrderId + productId`.
- Унікальність: `recorderType + recorderId + lineNumber`.
- Рух, у якому `quantity = 0` і `amount = 0`, не записується.
- Клієнт, склад, валюта не є вимірами: вони однозначно визначаються шапкою замовлення й
  доступні в запитах через join.

### 3. Правила залишку

- Залишок на момент `at` (включно) — `Σ quantity`, `Σ amount` для `period <= at`.
- Оборот `[from, to)`: «Замовлено» — `Σ` позитивних, «Відвантажено/закрито» — `Σ |від'ємних|`.
- Від'ємний залишок `quantity` або `amount` заборонений.
- Інваріант узгодженості: `quantity = 0 ⇒ amount = 0` (`ORDER_AMOUNT_RESIDUAL`, перевірка
  цілісності; забезпечується алгоритмом п. 6).
- Контроль — за поточними підсумками. Поточні підсумки й місячні знімки — як у
  `RegStockReserve`: зміна місяця `M` інвалідує знімки `>= M`, rebuild від `M`.
- **Стан виконання замовлення** (похідний, не зберігається, показується у списку
  замовлень сторінки 260 і в звіті):

| Стан | Умова | Іконка |
|---|---|---|
| `OPEN` «До відвантаження» | `POSTED`, `closed = N`, є ключ із `quantity > 0` | відкрита коробка |
| `SHIPPED` «Відвантажено» | `POSTED`, `closed = N`, усі залишки = 0 (автозакриття) | галочка |
| `CLOSED` «Закрито» | `POSTED`, `closed = Y` | замок |
| — | `DRAFT` | стандартна іконка чернетки |

Автозакриття — похідний прапорець `fullyShipped`, а не запис у `closed`: проведення
реалізації не змінює чужий документ, а скасування реалізації автоматично повертає стан `OPEN`.

## БЛОК B. UI

### 4. Форма списку (сторінка 230)

1. **Залишки** (за замовчуванням, станом на зараз): `customerOrder[25] «Замовлення» |
   customer[25] «Клієнт» | product[30] | quantity[12] «Залишок, к-сть» | amount[14]
   «Залишок, сума»`. Групування замовлення → товар, підсумки за групою й загальний.
2. **Аналіз замовлень клієнтів** (F-REP-05) за період дат замовлень: `customerOrder[22] |
   customer[22] | product[26] | ordered[11] «Замовлено» | shipped[11] «Відвантажено» |
   closedQty[11] «Закрито без відвантаження» | remaining[11] «Залишок» | orderedAmount[13] |
   shippedAmount[13] | remainingAmount[13] | state[10]`; `shipped%` в підсумку групи.
3. **Обороти** `[from, to)`: прихід/витрата/початковий/кінцевий залишок за ключем.
4. **Рухи**: `period[16] | recorder[30] | customerOrder | product | quantity | amount`.

Фільтри: період, «станом на», клієнт, замовлення, товар, склад (з шапки), стан виконання,
«лише з залишком» (за замовчуванням увімкнено в «Залишки»). Подвійний клік відкриває
реєстратор або замовлення (261, 111). Експорт IR. Команд зміни немає.

### 5. Події введення

Поля рухів `DISABLED`; фільтри — стандартний lifecycle, commit перезапускає query.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 6. Розрахунки

Сума відвантаження в регістрі обчислюється **за цінами замовлення**, а не реалізації:

```text
Rq, Ra = залишок ключа (order, product) без рухів поточного реєстратора
q      = Σ Goods.quantity реалізації за товаром
якщо q = Rq:  amount = Ra                       -- повне відвантаження забирає залишок суми
інакше:       amount = round(q × Ra / Rq, 2, HALF_UP)
```

Приклад 1. Замовлення: 10 шт × 33,33 = 333,30. Реалізація Р-1 на 3 шт:
`round(3 × 333,30 / 10) = 99,99` → залишок 7 шт / 233,31. Р-2 на 7 шт = повний залишок →
`amount = 233,31` → залишок 0 / 0,00.

Приклад 2 (повтор товару). Рядки 4 × 10,00 = 40,00 і 6 × 12,50 = 75,00 → ключ 10 / 115,00.
Відвантаження 5 → `round(5 × 115,00 / 10) = 57,50`; залишок 5 / 57,50.

Приклад 3 (перевідвантаження). Залишок 5 шт, реалізація на 6 → `ORDER_OVERSHIPMENT`.

Приклад 4 (закриття). Замовлено 10 / 333,30, відвантажено 3 / 99,99. `CLOSE` →
закриваючий рух `−7 / −233,31`, стан `CLOSED`; у звіті «Закрито без відвантаження» = 7.

Інваріант `quantity = 0 ⇒ amount = 0` тримається, бо кількість стає нульовою лише в
момент проведення, яке за правилом `q = Rq` забирає весь залишок суми.

### 7. Формування рухів

**DocCustomerOrder** (`recorderType = 'DocCustomerOrder'`), усі рядки (товари й послуги):

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `customerOrderId` | `header.id` | — |
| `productId` | `Goods.productId` | — |
| `quantity` | `Goods.quantity` | + |
| `amount` | `Goods.amount` | + |
| `lineNumber` | `Goods.lineNumber` (1..9999) | — |

При `header.closed = Y` для кожного товару — закриваючий рух
`−(Σ +рядків + Σ рухів інших реєстраторів)` за кількістю і сумою (залишок ключа → 0),
`lineNumber = 10000 + k` (k — номер товару за `min(Goods.lineNumber)`); нульові не пишуться.

**DocGoodsSale r3** (`recorderType = 'DocGoodsSale'`), лише при `header.baseOrderId`;
рядки групуються за `productId`:

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `customerOrderId` | `header.baseOrderId` | — |
| `productId` | група | — |
| `quantity` | `Σ Goods.quantity` групи | − |
| `amount` | алгоритм п. 6 | − |
| `lineNumber` | `min(Goods.lineNumber)` групи | — |

Повторне проведення атомарно замінює набір; скасування видаляє. Серіалізація:
`select ... from doc_customer_order where id = :orderId for update` до обчислення `Rq/Ra`.
Перевірки в тій самій транзакції:

| Код | Коли | Повідомлення |
|---|---|---|
| `ORDER_OVERSHIPMENT` | `q > Rq` (у т. ч. товар відсутній у замовленні, `Rq = 0`) | «Перевищено невідвантажений залишок замовлення {№} за товаром «{товар}»: залишок {Rq}, відвантажується {q}.» |
| `BASE_ORDER_NOT_POSTED` | `baseOrderId` вказує на `DRAFT` | «Замовлення-підстава {№} не проведене.» |
| `BASE_ORDER_CLOSED` | проведення або скасування реалізації на підставі `closed = Y` | «Замовлення {№} закрите. Спочатку відкрийте його командою «Відкрити замовлення».» |
| `BASE_ORDER_CUSTOMER_MISMATCH` | `sale.customerId ≠ order.customerId` | «Покупець реалізації не збігається з клієнтом замовлення {№}.» |
| `BASE_ORDER_WAREHOUSE_MISMATCH` | `sale.warehouseId ≠ order.warehouseId` | «Склад реалізації має збігатися зі складом замовлення {№}.» |
| `ORDER_HAS_SHIPMENTS` | скасування проведення замовлення, за яким є реалізації | «Неможливо скасувати проведення: за замовленням {№} є відвантаження ({список}).» |
| `ORDER_QUANTITY_BELOW_SHIPPED` | повторне проведення зменшує кількість нижче відвантаженої | «Кількість товару «{товар}» у замовленні ({q}) менша за вже відвантажену ({shipped}).» |
| `ORDER_AMOUNT_RESIDUAL` | після запису `quantity = 0`, `amount ≠ 0` | «Порушено цілісність залишку замовлення {№}: сума {a} при нульовій кількості.» |

Команди замовлення: `CloseCustomerOrder(id, expectedVersion)` встановлює `closed = Y` і
повторно проводить (рухи цього регістру й `RegStockReserve`); `ReopenCustomerOrder`
встановлює `closed = N` і повторно проводить (з перевіркою вільного залишку для резерву).
Закриття дозволене лише для `POSTED`; скасування проведення закритого замовлення дозволене
(`closed` не блокує), якщо немає відвантажень.

«Заповнити за замовленням» у реалізації (F-SRV-01, F-SAL-05): рядки = ключі з
`quantity > 0`, кількість = залишок, ціна = `Ra / Rq` (округл. 2), `reserve` не копіюється.

### 8. Зберігання, запити й API

```text
reg_customer_orders_mv
  id varchar2(32) PK, period date NOT NULL,
  recorder_type varchar2(60), recorder_id varchar2(32), line_number number(10) NOT NULL,
  customer_order_id varchar2(32) NOT NULL FK doc_customer_order,
  product_id varchar2(32) NOT NULL FK ref_product,
  quantity number(19,3) NOT NULL, amount number(19,2) NOT NULL,
  CHECK (quantity <> 0 OR amount <> 0)
  UK (recorder_type, recorder_id, line_number)
  IX (period); IX (customer_order_id, product_id, period); IX (product_id)
reg_customer_orders_tot  PK (customer_order_id, product_id), quantity >= 0, amount >= 0
reg_customer_orders_snap PK (month_end, customer_order_id, product_id), quantity, amount
```

Тригер `reg_customer_orders_biud` — DML лише при `trade_core.g_internal`. Queries:
`ListCustomerOrdersMovements`, `GetCustomerOrdersTurnovers(from, to, groupBy)`,
`GetCustomerOrdersBalances(at, filters)`, `GetCustomerOrderRemaining(orderId)` (для
заповнення реалізації), `GetCustomerOrderState(orderId)` / колонка `state` у view списку
замовлень, `AnalyzeCustomerOrders(from, to, filters)`, `RebuildCustomerOrdersTotals(fromMonth)`.
Права: `read`; запис лише проведенням.

### 9. Тести й готовність

1. Замовлення 2 рядки → 2 рухи «+»; повтор товару сумується в залишку.
2. Часткове, повне і повторне часткове відвантаження; суми за прикладами 1–2.
3. Перевідвантаження на 0,001 → `ORDER_OVERSHIPMENT`; товар поза замовленням → та сама помилка.
4. Скасування реалізації повертає залишок і стан `OPEN`.
5. `CLOSE`/`REOPEN`; реалізація на підставі закритого → `BASE_ORDER_CLOSED`.
6. Скасування замовлення з відвантаженнями → `ORDER_HAS_SHIPMENTS`.
7. Інваріант `quantity = 0 ⇒ amount = 0` у будь-якій послідовності post/unpost/repost (property-тест).
8. Конкурентність: дві реалізації на останні 5 шт одного замовлення — друга чекає lock
   замовлення й отримує `ORDER_OVERSHIPMENT`.
9. Rebuild = поточні підсумки; прямий DML відхиляється; UI read-only.
