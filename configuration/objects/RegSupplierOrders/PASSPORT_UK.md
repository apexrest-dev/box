# Паспорт регістру залишків «Замовлення постачальникам»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем.
- Ревізія: `r3`.
- Вид: `BALANCE` (накопичувальний регістр залишків, signed resources).
- Розділ меню («Такси»): підсистема `Закупівлі` → група «Звіти» («Замовлення постачальникам»,
  режим «Аналіз замовлень постачальникам»).
- Реєстратори: `DocSupplierOrder` (+ замовлено; − закриваючі рухи при `closed = Y`),
  `DocGoodsReceipt` r3 (− отримано, якщо заповнено `baseOrderId`).
- Аналог 1С:УТ 11: `РегистрНакопления.ЗаказыПоставщикам` (без графіка поставки й характеристик).
- Функції каталогу: `F-PUR-01`, `F-PUR-03`, `F-PUR-06`, `F-REP-07`, `F-SRV-01`, `F-SRV-03`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Замовлення постачальникам |
| Технічне ім'я | `RegSupplierOrders` |
| Об'єкт метаданих | `Register.SupplierOrders` (kind `ACCUMULATION_REGISTER`) |
| Клас руху | `SupplierOrdersMovement` |
| Таблиця рухів | `reg_supplier_orders_mv` |
| Похідні таблиці | `reg_supplier_orders_tot`, `reg_supplier_orders_snap` |
| API | `/api/v1/registers/supplier-orders` |
| Сторінка APEX | 240 |

Регістр зберігає **ще не отриманий** залишок кожного замовлення постачальнику за товарами
(кількість і сума за цінами замовлення). Використовується для заповнення надходження на
підставі (F-PUR-03), у розрахунку «Потреба в закупівлі» як «очікується надходження»
(F-PUR-06, F-REP-07) і для аналізу виконання замовлень.

### 2. Структура руху

| Поле | Роль | Тип | Точність | Джерело | Посилання/БД |
|---|---|---|---|---|---|
| `id` | системне | UUID | 32 hex | server | PK |
| `period` | системне | DateTime UTC | секунди | `header.occurredAt` | index |
| `recorderType` / `recorderId` | системне | String(60) / UUID | — | реєстратор | index |
| `lineNumber` | системне | int | 10 | схема п. 7 | UK з recorder |
| `supplierOrderId` | вимір | UUID | — | `header.id` або `baseOrderId` | `doc_supplier_order`, FK |
| `productId` | вимір | UUID | — | рядок | `RefProduct`, FK |
| `quantity` | ресурс | Number | 19,3 | рядок / розрахунок | signed |
| `amount` | ресурс | Number | 19,2 | рядок / розрахунок | signed, UAH, ціни замовлення |

- Ключ підсумку: `supplierOrderId + productId`; унікальність руху — `recorderType +
  recorderId + lineNumber`; нульові рухи не пишуться.
- Постачальник і склад визначаються шапкою `DocSupplierOrder` (`supplierId`, `warehouseId`).

### 3. Правила залишку

- Залишок на `at` (включно) — `Σ` рухів `period <= at`; оборот `[from, to)`.
- Від'ємний залишок `quantity`/`amount` заборонений; `quantity = 0 ⇒ amount = 0`.
- Контроль за поточними підсумками; знімки місячні, зміна місяця `M` інвалідує знімки `>= M`.
- **Перевищення замовлення (over-receipt) дозволене**: надходження може містити більше, ніж
  залишок замовлення, а також товари, яких у замовленні немає. У регістр списується лише
  `min(отримано, залишок)`; надлишок у цей регістр **не пишеться**.

Обґрунтування: постачальники часто відвантажують кратно упаковці або з невеликим
перевищенням; фактичний прихід уже коректно відображають `RegStockBalance`,
`RegCounterpartySettlement` і `RegStockCost`, а цей регістр відповідає лише на питання
«що ще очікується». Від'ємний залишок означав би «очікується мінус», що зламало б
«Потребу в закупівлі». Надлишок не втрачається: звіт показує його як різницю між рядками
надходжень і рухами регістру. UI надходження показує попередження (не блокує)
`RECEIPT_EXCEEDS_ORDER`: «Отримано понад замовлення {№}: «{товар}» +{excess}.»

- Стан виконання замовлення (похідний, для списку сторінки 270): `OPEN` «Очікується»,
  `RECEIVED` «Отримано» (усі залишки 0, `closed = N`), `CLOSED` «Закрито» (`closed = Y`).

## БЛОК B. UI

### 4. Форма списку (сторінка 240)

1. **Залишки** (станом на зараз): `supplierOrder[25] | supplier[25] | warehouse[18] |
   expectedDate[12] «Очікується» | product[30] | quantity[12] | amount[14]`. Групування
   постачальник → замовлення; рядки з `expectedDate < сьогодні` — червоним («прострочено»).
2. **Аналіз замовлень постачальникам**: `supplierOrder | supplier | product | ordered |
   received «Отримано за замовленням» | overReceived «Понад замовлення» | closedQty
   «Закрито» | remaining | orderedAmount | remainingAmount | state`.
3. **Обороти** `[from, to)`; 4. **Рухи** `period | recorder | supplierOrder | product |
   quantity | amount`.

Фільтри: період, «станом на», постачальник, склад, замовлення, товар, стан, «лише
прострочені». Подвійний клік відкриває реєстратор/замовлення (271, сторінка форми
надходження). Експорт IR. Команд зміни немає.

### 5. Події введення

Поля рухів `DISABLED`; фільтри — стандартний lifecycle без зміни регістру.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 6. Розрахунки

```text
Rq, Ra = залишок (order, product) без рухів поточного реєстратора
q      = Σ Goods.quantity надходження за товаром
w      = min(q, Rq)                         -- списується з замовлення
amount = (w = Rq) ? Ra : round(w × Ra / Rq, 2, HALF_UP)
excess = q − w                              -- лише для звіту/попередження
```

Приклад 1. Замовлення: 100 шт × 12,50 = 1 250,00. Надходження Н-1: 60 шт →
`w = 60`, `amount = round(60 × 1 250,00 / 100) = 750,00` → залишок 40 / 500,00.
Н-2: 45 шт → `w = 40`, `amount = 500,00`, `excess = 5` → залишок 0, стан `RECEIVED`,
у звіті «Понад замовлення» = 5, попередження `RECEIPT_EXCEEDS_ORDER`.

Приклад 2. Замовлення 3 кг × 33,33 = 99,99; надходження 1,250 кг →
`round(1,250 × 99,99 / 3) = 41,66` (41,6625) → залишок 1,750 / 58,33.

Приклад 3 (закриття). Залишок 40 / 500,00, `CLOSE` → рух `−40 / −500,00`, «Потреба в
закупівлі» більше не враховує ці 40 шт як очікувані.

### 7. Формування рухів

**DocSupplierOrder** (`recorderType = 'DocSupplierOrder'`), усі рядки:

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `supplierOrderId` | `header.id` | — |
| `productId` | `Goods.productId` | — |
| `quantity` / `amount` | `Goods.quantity` / `Goods.amount` | + |
| `lineNumber` | `Goods.lineNumber` (1..9999) | — |

При `header.closed = Y` — закриваючий рух на товар `−(Σ +рядків + Σ рухів інших
реєстраторів)` за кількістю й сумою, `lineNumber = 10000 + k` (k — номер товару за
`min(Goods.lineNumber)`).

**DocGoodsReceipt r3** (`recorderType = 'DocGoodsReceipt'`), лише при `header.baseOrderId`;
групування рядків за `productId`:

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `supplierOrderId` | `header.baseOrderId` | — |
| `productId` | група | — |
| `quantity` | `w = min(Σ Goods.quantity, Rq)`; якщо `w = 0` — рух не пишеться | − |
| `amount` | алгоритм п. 6 | − |
| `lineNumber` | `min(Goods.lineNumber)` групи | — |

Атомарна заміна при повторному проведенні, видалення при скасуванні; lock
`doc_supplier_order where id = baseOrderId for update` перед обчисленням `Rq/Ra`.

| Код | Коли | Повідомлення |
|---|---|---|
| `BASE_ORDER_NOT_POSTED` | замовлення-підстава в `DRAFT` | «Замовлення-підстава {№} не проведене.» |
| `BASE_ORDER_CLOSED` | проведення/скасування надходження на підставі закритого замовлення | «Замовлення {№} закрите. Спочатку відкрийте його командою «Відкрити замовлення».» |
| `BASE_ORDER_SUPPLIER_MISMATCH` | `receipt.supplierId ≠ order.supplierId` | «Постачальник надходження не збігається з постачальником замовлення {№}.» |
| `BASE_ORDER_WAREHOUSE_MISMATCH` | `receipt.warehouseId ≠ order.warehouseId` | «Склад надходження має збігатися зі складом замовлення {№}.» |
| `ORDER_HAS_RECEIPTS` | скасування проведення замовлення з надходженнями | «Неможливо скасувати проведення: за замовленням {№} є надходження ({список}).» |
| `ORDER_QUANTITY_BELOW_RECEIVED` | повторне проведення зменшує кількість нижче отриманої | «Кількість товару «{товар}» у замовленні ({q}) менша за вже отриману ({received}).» |
| `ORDER_AMOUNT_RESIDUAL` | `quantity = 0`, `amount ≠ 0` після запису | «Порушено цілісність залишку замовлення {№}.» |
| `RECEIPT_EXCEEDS_ORDER` | `excess > 0` (попередження, не помилка) | див. п. 3 |

Примітка до повторного проведення замовлення: оскільки надходження списують лише `w`,
зменшення рядка замовлення до значення, меншого за вже списане, дає від'ємний залишок і
відхиляється `ORDER_QUANTITY_BELOW_RECEIVED`; збільшення рядка після надходження з
надлишком не перераховує старі надходження (їхній `w` зафіксований на момент проведення;
актуалізація — повторним проведенням надходження).

Команди: `CloseSupplierOrder(id, expectedVersion)` / `ReopenSupplierOrder(...)` —
встановлюють `closed` і повторно проводять замовлення. «Заповнити за замовленням» у
надходженні: ключі з `quantity > 0`, кількість = залишок, ціна = `Ra / Rq` (2 знаки).

### 8. Зберігання, запити й API

```text
reg_supplier_orders_mv
  id varchar2(32) PK, period date NOT NULL,
  recorder_type varchar2(60), recorder_id varchar2(32), line_number number(10) NOT NULL,
  supplier_order_id varchar2(32) NOT NULL FK doc_supplier_order,
  product_id varchar2(32) NOT NULL FK ref_product,
  quantity number(19,3) NOT NULL, amount number(19,2) NOT NULL,
  CHECK (quantity <> 0 OR amount <> 0)
  UK (recorder_type, recorder_id, line_number)
  IX (period); IX (supplier_order_id, product_id, period); IX (product_id)
reg_supplier_orders_tot  PK (supplier_order_id, product_id), quantity >= 0, amount >= 0
reg_supplier_orders_snap PK (month_end, supplier_order_id, product_id)
```

Тригер `reg_supplier_orders_biud` — DML лише при `trade_core.g_internal`. Queries:
`ListSupplierOrdersMovements`, `GetSupplierOrdersTurnovers`, `GetSupplierOrdersBalances(at)`,
`GetSupplierOrderRemaining(orderId)`, `GetOpenSupplierOrderQuantity(warehouseId,
productId)` = `Σ tot.quantity` join `doc_supplier_order` за `warehouse_id`, `status =
'POSTED'` (використовує `RegReorderPolicy`), `AnalyzeSupplierOrders(from, to)`,
`RebuildSupplierOrdersTotals(fromMonth)`. Права: `read`.

### 9. Тести й готовність

1. Часткове, повне, надлишкове надходження (приклад 1); товар поза замовленням не пише рух.
2. Скасування надходження повертає залишок; повторне проведення не дублює.
3. `CLOSE` обнуляє залишок і прибирає кількість з «Потреби в закупівлі»; `REOPEN` відновлює.
4. Невідповідність постачальника/складу; підстава в `DRAFT`/закрита.
5. Скасування замовлення з надходженнями відхиляється.
6. Конкурентність: два надходження на одне замовлення серіалізуються lock замовлення;
   сумарне списання не перевищує замовленого.
7. Rebuild, обидва режими звіту, прямий DML відхиляється, UI read-only.
