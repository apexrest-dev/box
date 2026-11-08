# Паспорт регістру залишків «Резерви товарів»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем.
- Ревізія: `r3`.
- Вид: `BALANCE` (накопичувальний регістр залишків, signed resource).
- Розділ меню («Такси»): підсистема `Склад` → група «Звіти»; дублюється в `Продажі` → «Звіти»
  як «Вільні залишки» (режим списку).
- Реєстратори: `DocCustomerOrder` (+ резерв), `DocGoodsSale` r3 (− зняття резерву при
  відвантаженні на підставі), `DocCustomerOrder` у стані `closed = Y` (− закриваючі рухи).
- Аналог 1С: УТ 10.3 `РегистрНакопления.ТоварыВРезервеНаСкладах`; у 1С:УТ 11 — ресурс
  «В резерві» регістрів `СвободныеОстатки` / `ТоварыНаСкладах` (спрощено, без графіка).
- Функції каталогу: `F-SAL-02`, `F-WH-07`, `F-REP-04`, `F-SAL-05`, `F-SRV-02`, `F-SRV-03`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Резерви товарів |
| Технічне ім'я | `RegStockReserve` |
| Об'єкт метаданих | `Register.StockReserve` (kind `ACCUMULATION_REGISTER`) |
| Клас руху | `StockReserveMovement` |
| Таблиця рухів | `reg_stock_reserve_mv` |
| Похідні таблиці | `reg_stock_reserve_tot` (поточні підсумки), `reg_stock_reserve_snap` (місячні знімки) |
| API | `/api/v1/registers/stock-reserves` |
| Сторінка APEX | 220 (форма списку, read-only) |

Регістр фіксує, скільки одиниць товару на складі закріплено за конкретним замовленням
клієнта. Разом із `RegStockBalance` визначає **вільний залишок** — кількість, яку можна
продати, списати або перемістити без порушення чужих резервів.

### 2. Структура руху

| Поле | Роль | Тип | Точність | Джерело | Посилання/БД |
|---|---|---|---|---|---|
| `id` | системне | UUID | 32 hex | server | `id`, PK |
| `period` | системне | DateTime (UTC) | секунди | `header.occurredAt` реєстратора | `period`, index |
| `recorderType` | системне | String | 60 | константа документа | `recorder_type` |
| `recorderId` | системне | UUID | — | `header.id` | `recorder_id`, index |
| `lineNumber` | системне | int | 10 | схема п. 7 | UK з recorder |
| `warehouseId` | вимір | UUID | — | `DocCustomerOrder.warehouseId` | `RefWarehouse`, FK |
| `productId` | вимір | UUID | — | рядок документа | `RefProduct`, FK |
| `customerOrderId` | вимір | UUID | — | ID замовлення (власне або `baseOrderId`) | `doc_customer_order`, FK |
| `quantity` | ресурс | Number | 19,3 | розрахунок п. 7 | signed, одиниця товару |

- Ключ поточного підсумку: `warehouseId + productId + customerOrderId`.
- Унікальність руху: `recorderType + recorderId + lineNumber`.
- Рух з `quantity = 0` не записується.
- Додаткових реквізитів регістру немає (обмеження метамоделі).

### 3. Правила залишку

- Залишок на момент `at` (включно): `Σ quantity` для `period <= at`.
- Оборот за `[from, to)`: прихід `Σ quantity>0`, витрата `Σ |quantity<0|`.
- Від'ємний залишок за ключем заборонений (`RESERVE_NEGATIVE`).
- Перевірки контролю виконуються за **поточними** підсумками (на кінець часу), а не на дату
  документа: резерв — оперативне поняття, ретроспективне резервування не дозволяє обійти
  контроль.
- Поточні підсумки ввімкнені: `reg_stock_reserve_tot` оновлюється в тій самій транзакції.
- Місячні знімки: залишок на кінець календарного місяця за ключем; зміна руху в місяці `M`
  інвалідує знімки `>= M` і запускає `RebuildStockReserveTotals(fromMonth = M)`.
- Закритого періоду в r3 немає (`closed_period_policy = NONE`).
- Похідний показник (не зберігається):

```text
freeStock(warehouse, product) = RegStockBalance.balance(warehouse, product)
                              − Σ RegStockReserve.balance(warehouse, product, *)
```

- **Глобальний інваріант r3**: `freeStock >= 0` для кожної пари (склад, товар) після кожної
  транзакції проведення/скасування будь-якого документа.

## БЛОК B. UI

### 4. Форма списку (сторінка 220)

Режими-вкладки (`regionDisplaySelector`):

1. **Залишки** (за замовчуванням, на поточний момент): `warehouse[20] | product[35] |
   customerOrder[25] «Замовлення № від» | quantity[12] «В резерві»`. Групування
   склад → товар, підсумок за групою і загальний.
2. **Вільні залишки** (F-REP-04): `warehouse[20] | product[35] | stock[12] «Залишок» |
   reserved[12] «В резерві» | free[12] «Вільно»`; рядки з `free = 0` підсвічуються.
3. **Обороти** за період: `warehouse | product | customerOrder | opening[12] | receipt[12]
   «Зарезервовано» | expense[12] «Знято» | closing[12]`.
4. **Рухи**: `period[16] | recorder[30] | lineNumber[5] (hidden) | warehouse | product |
   customerOrder | quantity[12]` (знак «+» зелений, «−» червоний).

Фільтри: період (для «Обороти/Рухи», за замовчуванням поточний місяць), момент «станом на»
(для «Залишки/Вільні залишки», за замовчуванням зараз), склад, товар, замовлення, клієнт
(через шапку замовлення). Подвійний клік / Enter по реєстратору або замовленню відкриває
документ (сторінки 261, 111). Експорт CSV/XLSX стандартним меню IR. Команд
створення/зміни немає; «Створити» відсутня.

### 5. Події введення

Усі поля рухів `DISABLED`. Фільтри: стандартний `INPUT_STARTED/INPUT_COMMITTED`, commit
перезапускає типізований query режиму; регістр не змінюється.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 6. Розрахунки

Приклад 1 (резерв і вільний залишок). Склад «Основний», товар «Кабель» (м, дробний):

| Крок | Подія | Залишок | Резерв | Вільно |
|---|---|---|---|---|
| 1 | Надходження 100,000 | 100,000 | 0 | 100,000 |
| 2 | Замовлення З-1, рядок 30,500, `reserveFlag = Y` | 100,000 | 30,500 | 69,500 |
| 3 | Замовлення З-2, рядок 70,000, `reserveFlag = Y` | — | — | помилка `RESERVE_EXCEEDS_FREE_STOCK` (вільно 69,500) |
| 4 | З-2 виправлено на 69,500 | 100,000 | 100,000 | 0 |
| 5 | Реалізація без підстави 1,000 | — | — | помилка `INSUFFICIENT_FREE_STOCK` |
| 6 | Реалізація на підставі З-1, 20,000 | 80,000 | 80,000 (З-1: 10,500) | 0 |

Крок 6: зняття `min(20,000; 30,500) = 20,000` → З-1 = 10,500, З-2 = 69,500, вільно
`80,000 − 80,000 = 0`. Відвантаження «з власного резерву» не блокується, хоча вільний
залишок нульовий.

Приклад 2 (відвантаження понад резерв). Залишок 90,000; резерви З-1 = 10,500,
З-2 = 74,500; вільно 5,000. Реалізація на підставі З-1 на 12,000: зняття
`min(12,000; 10,500) = 10,500`, решта 1,500 — з вільного залишку. Після запису:
`stockAfter = 78,000`, `reservesOther = 74,500`, `ownRemainingAfter = 0` →
`78,000 − 74,500 − 0 = 3,500 >= 0` — успіх. Та сама реалізація на 16,000:
`74,000 − 74,500 = −0,500` → `INSUFFICIENT_FREE_STOCK` (вільно 5,000, потрібно 5,500 понад резерв).

Приклад 3 (закриття). З-1: зарезервовано 30,500, відвантажено з резерву 20,000, залишок
резерву 10,500. Команда `CLOSE` → повторне проведення записує `+30,500` і закриваючий
`−10,500` → залишок 0, вільний залишок зростає на 10,500.

Округлення: кількість scale 3 `HALF_UP`; для одиниці з `fractional = false` усі величини
цілі, бо цілі вхідні рядки.

### 7. Формування рухів

**DocCustomerOrder** (`recorderType = 'DocCustomerOrder'`), лише рядки з `reserveFlag = Y`
і `RefProduct.productKind = GOODS`:

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `warehouseId` | `header.warehouseId` (обов'язковий) | — |
| `productId` | `Goods.productId` | — |
| `customerOrderId` | `header.id` | — |
| `quantity` | `Goods.quantity` | + |
| `lineNumber` | `Goods.lineNumber` (1..9999) | — |

Якщо `header.closed = Y`, для кожного товару з резервом додається закриваючий рух
`quantity = −(Σ +рядків замовлення + Σ рухів інших реєстраторів за ключем)`, тобто такий,
що робить залишок ключа рівно 0 (якщо результат 0 — рух не пишеться);
`lineNumber = 10000 + k`, де `k` — порядковий номер товару за `min(Goods.lineNumber)`.
Рядки документа обмежені 9999, тож діапазони не перетинаються.

**DocGoodsSale r3** (`recorderType = 'DocGoodsSale'`), лише якщо `header.baseOrderId` не
порожній; рядки групуються за `productId` (послуги пропускаються):

| Вимір/ресурс | Джерело | Знак |
|---|---|---|
| `period` | `header.occurredAt` | — |
| `warehouseId` | `header.warehouseId` (= склад замовлення) | — |
| `productId` | група рядків | — |
| `customerOrderId` | `header.baseOrderId` | — |
| `quantity` | `min(Σ Goods.quantity, R)`, `R` — залишок резерву ключа без рухів цієї реалізації | − |
| `lineNumber` | `min(Goods.lineNumber)` групи | — |

Повторне проведення: `delete where recorder = (type, id)` → обчислення → `insert`, одна
транзакція. Скасування проведення видаляє набір. Перевірки в тій самій транзакції (після
запису, за поточними підсумками):

| Код | Коли | Повідомлення |
|---|---|---|
| `RESERVE_EXCEEDS_FREE_STOCK` | проведення замовлення, `freeStock < 0` | «Недостатньо вільного залишку товару «{товар}» на складі «{склад}» для резерву: потрібно {q}, вільно {free}.» |
| `RESERVE_SERVICE_PRODUCT` | `reserveFlag = Y` для послуги | «Послугу «{товар}» не можна резервувати.» |
| `RESERVE_NEGATIVE` | залишок ключа < 0 (зменшення рядка нижче знятого резерву) | «Резерв товару «{товар}» за замовленням {№} став би від'ємним: {balance}.» |
| `INSUFFICIENT_FREE_STOCK` | реалізація/списання/переміщення, `freeStock < 0` | «Недостатньо вільного залишку товару «{товар}» на складі «{склад}»: потрібно {q}, вільно {free} (з урахуванням резервів інших замовлень).» |
| `BASE_ORDER_WAREHOUSE_MISMATCH` | склад реалізації ≠ склад замовлення | «Склад реалізації має збігатися зі складом замовлення {№}.» |
| `BASE_ORDER_CLOSED` | проведення/повторне проведення/скасування реалізації на підставі закритого замовлення | «Замовлення {№} закрите. Спочатку відкрийте його командою «Відкрити замовлення».» |

**Контроль вільного залишку в інших документах r3.** `DocGoodsSale`, `DocGoodsWriteOff`,
`DocGoodsTransfer` (вихідний склад) після запису своїх рухів перевіряють для кожного
(склад, товар) документа:

```text
stockAfter − Σ reserve(wh, product, order ≠ baseOrderId) − ownRemainingAfter >= 0
```

де `ownRemainingAfter` — залишок резерву власного `baseOrderId` після зняття (для
списання/переміщення `baseOrderId` немає, тож віднімаються всі резерви). Математично це
рівносильне інваріанту `freeStock >= 0`; бо `−min(q, R)` знімає власний резерв першим,
відвантаження «з резерву» свого замовлення ніколи не блокується чужими резервами. Той самий
`INSUFFICIENT_FREE_STOCK` перевіряється при скасуванні/повторному проведенні документів,
що збільшували залишок (`DocGoodsReceipt`, `DocSurplusPosting`, `DocCustomerReturn`,
вхідна сторона `DocGoodsTransfer`).

Серіалізація: кожен документ, що змінює `RegStockBalance` або `RegStockReserve`, блокує
`ref_warehouse ... for update` (наявний патерн r1), а реалізація на підставі — також
`doc_customer_order where id = baseOrderId for update`. Порядок: замовлення → склад.

### 8. Зберігання, запити й API

```text
reg_stock_reserve_mv
  id varchar2(32) PK, period date NOT NULL,
  recorder_type varchar2(60), recorder_id varchar2(32), line_number number(10) NOT NULL,
  warehouse_id varchar2(32) FK ref_warehouse, product_id varchar2(32) FK ref_product,
  customer_order_id varchar2(32) FK doc_customer_order,
  quantity number(19,3) NOT NULL CHECK (quantity <> 0)
  UK reg_stock_reserve_mv_uk (recorder_type, recorder_id, line_number)
  IX (period); IX (warehouse_id, product_id, customer_order_id, period); IX (customer_order_id)
reg_stock_reserve_tot  PK (warehouse_id, product_id, customer_order_id), quantity CHECK >= 0
reg_stock_reserve_snap PK (month_end, warehouse_id, product_id, customer_order_id), quantity
```

Тригер `reg_stock_reserve_biud` блокує DML поза `trade_core.g_internal`. Queries:
`ListStockReserveMovements(from, to, filters)`, `GetStockReserveTurnovers(from, to,
groupBy)`, `GetStockReserveBalances(at, filters)`, `GetFreeStock(at, warehouseId?,
productId?)` (також для форми підбору F-SRV-02 і QueryTable картки товару),
`RebuildStockReserveTotals(fromMonth)` (адміністратор). Сортування стабільне: `period,
recorder_id, line_number`. Права: `read` для всіх ролей; запис лише пакетом проведення.

### 9. Тести й готовність

1. Резерв у межах вільного залишку; рівно на межі (вільно 0) — успіх; на 0,001 більше — помилка.
2. Два рядки одного товару з резервом сумуються в перевірці.
3. Відвантаження менше/рівне/більше резерву; зняття = `min`.
4. Реалізація без підстави і списання не можуть «з'їсти» чужий резерв.
5. Скасування надходження, що зробить `freeStock < 0`, відхиляється.
6. `CLOSE` → резерв 0; `REOPEN` → резерв відновлюється з перевіркою вільного залишку.
7. Повторне проведення не дублює рухи; unpost видаляє набір; rebuild = поточні підсумки.
8. Конкурентність: дві сесії резервують останні 10 одиниць — друга чекає на lock складу й
   отримує `RESERVE_EXCEEDS_FREE_STOCK`; немає deadlock при порядку замовлення → склад.
9. Прямий `insert` у таблицю поза проведенням відхиляється тригером; UI read-only.
