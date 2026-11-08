# Паспорт регістру залишків «Вартість запасів (собівартість)»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`. Реалізація до погодження заборонена.
- Ревізія: `r3`.
- Вид: накопичувальний регістр залишків (`register_kind = BALANCE`, signed resources).
- Технічне ім'я: `RegStockCost`; технічний ключ `Register.StockCost`.
- Розділ меню (підсистема «Такси»): `Warehouse` «Склад», колонка 2 «Звіти» — «Вартість запасів»;
  звіт «Валовий прибуток» — `Sales` «Продажі», колонка 2 «Звіти».
- Реєстратори: `DocGoodsReceipt` r3, `DocGoodsSale` r3, `DocSupplierReturn`, `DocCustomerReturn`,
  `DocGoodsTransfer` r3, `DocGoodsWriteOff` r3, `DocSurplusPosting`.
- Залежності: `RefWarehouse`, `RefProduct` r3 (`productKind = GOODS`), `RegStockBalance`,
  `RegSales` (звіт), `sys_company_settings.min_markup_percent` (контроль націнки).
- Аналог у 1С:УТ 11: `РегистрНакопления.СебестоимостьТоваров` / `ВыручкаИСебестоимостьПродаж`
  (спрощено: середня ковзна в момент проведення замість помісячного розрахунку).
- Функції каталогу: F-WH-09, F-REP-06, F-PRC-05.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Вартість запасів (собівартість) |
| Клас руху | `StockCostMovement` |
| Таблиця рухів | `reg_stock_cost_mv` |
| Похідні таблиці | `reg_stock_cost_tot` (поточні підсумки), `reg_stock_cost_snap` (місячні знімки), `reg_stock_cost_recalc` (позначки перерахунку) |
| API | `/api/v1/registers/stock-costs`; звіт `/api/v1/reports/gross-profit` |
| Сторінка APEX | 250 (рухи / обороти / залишки / валовий прибуток) |
| Метод оцінки | середня ковзна (moving weighted average) по ключу `warehouseId + productId` |
| Валюта | `UAH`, scale 2, `HALF_UP` |

Регістр зберігає кількість і вартість запасу товарів (`GOODS`) у розрізі складу. Кількість
синхронна з `RegStockBalance` (ті самі документи, ті самі `lineNumber`); вартість — основа
собівартості продажу та валового прибутку. Послуги в регістр не потрапляють.

### 2. Структура руху

| Поле | Роль | Назва | Тип | Точність | Джерело | БД |
|---|---|---|---|---|---|---|
| `id` | системне | ID | UUID | 32 | server | PK |
| `period` | системне | Період | DateTime | seconds | `occurredAt` документа | index |
| `recorderType/Id` | системне | Реєстратор | String/UUID | 60/32 | документ | index |
| `lineNumber` | системне | N | Integer | 10 | рядок (схема розд. 7) | UNIQUE з recorder |
| `postingSeq` | системне | Порядок запису | Integer | 19 | sequence `reg_stock_cost_seq` під час вставки | index |
| `warehouseId` | вимір | Склад | reference | 32 | документ | FK `ref_warehouse` |
| `productId` | вимір | Товар | reference | 32 | рядок | FK `ref_product` |
| `quantity` | ресурс | Кількість | Decimal signed | 19,3 | рядок | — |
| `costAmount` | ресурс | Вартість | Decimal signed, UAH | 19,2 | алгоритм розд. 6 | — |

Ключ підсумку: `warehouseId + productId`. Порядок рухів («момент»): `period, postingSeq, lineNumber`.
`postingSeq` перевидається при кожному повторному проведенні реєстратора.

### 3. Правила залишку

- Залишок на момент `at`: `Q(at) = Σ quantity`, `C(at) = Σ costAmount` за рухами з `period <= at`
  (для обчислення під час проведення — без рухів самого реєстратора).
- Середня собівартість: `avgCost = C / Q`, обчислюється з повною точністю (не округлюється
  до множення); при `Q = 0` — не визначена.
- Від'ємні залишки заборонені: `Q >= 0`, `C >= 0`; при `Q = 0` має бути `C = 0`
  (`COST_BALANCE_INCONSISTENT`). `Q > 0, C = 0` допустимо (безкоштовне надходження).
- Узгодженість: `Q` поточних підсумків = залишку `RegStockBalance` по тому самому ключу
  (`COST_QUANTITY_MISMATCH`, внутрішня помилка проведення).
- Поточні підсумки увімкнені (`reg_stock_cost_tot`, оновлюються в транзакції проведення);
  місячні знімки — на кінець місяця; зміна минулого періоду інвалідує пізніші знімки ключа.
- Закриття періоду в r3 відсутнє: перерахунок дозволений з будь-якої дати.
- Помилки — `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error -20100`);
  рядки `SERVICE` будь-якого документа в регістр не пишуться; запис у `reg_stock_cost_mv`, `_tot`,
  `_snap` — лише під `trade_core.g_internal`.

## БЛОК B. UI

### 4. Форма списку (сторінка 250, `LIST_ACCUMULATION_REGISTER_UK.md`)

Режими-вкладки (`regionDisplaySelector`): `Рухи` | `Обороти` | `Залишки` | `Валовий прибуток`.

- **Рухи:** `period[14] | recorder[26] | lineNumber[5] | warehouse[16] | product[26] | quantity[10] |
  costAmount[12] | unitCost[10]` (`unitCost = round(costAmount/quantity, 2)`, transient).
- **Обороти** за `[from, to)`: `warehouse | product | Q на початок | C на початок | прихід Q/C |
  розхід Q/C | Q на кінець | C на кінець`.
- **Залишки** на дату: `warehouse | product | quantity | costAmount | avgCost[12]` (`round(C/Q, 2)`),
  підсумок `costAmount` по складу.
- **Валовий прибуток** (розд. 8): групування «За товарами» / «За покупцями» / «За документами».

Фільтри: період (default — поточний місяць), склад, товар, група `RefProductGroup`, вид
реєстратора. Подвійний клік на реєстраторі відкриває документ. Банер-попередження, якщо для
вибраних ключів є позначки `reg_stock_cost_recalc`: «Собівартість потребує перерахунку з
05.11.2026 (3 позиції). [Перерахувати]».

Команди: `Оновити` | `Перерахувати собівартість…` (право `register.stock-cost.rebuild`) |
`Експорт` | `Ще`. Діалог перерахунку: `warehouseId` (необов'язковий), `productId`
(необов'язковий), `fromDate` (default — найраніша позначка), прапорець «Лише позначені».
Поля рухів — disabled; прямого створення/зміни рухів немає. Фільтри мають стандартний
`INPUT_STARTED/INPUT_COMMITTED` і формують типізований query `GetStockCost{Movements|Turnovers|Balances}`.

### 5. Події введення

| Елемент | Команда / query | Реакція |
|---|---|---|
| фільтр періоду | `GetStockCostMovements(from, to, filters)` | перезапит |
| фільтр складу/товару/групи | той самий query | перезапит, банер позначок |
| `Перерахувати собівартість…` → `Перерахувати` | `RebuildStockCost(warehouseId?, productId?, fromDate?, onlyMarked, idempotencyKey)` | результат: ключів, рухів змінено, нова дата позначок |
| поля руху | — | disabled |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 6. Алгоритм собівартості

**Надходження з фіксованою вартістю** (джерело задає суму): `costAmount = +сума джерела`.

**Вибуття** кількості `q` при залишку на момент `Q`, `C` (рядки одного документа по ключу
обробляються послідовно за `lineNumber`, залишок оновлюється після кожного рядка):

```text
if q = Q            -> cost = C                       -- «останній отримує залишок»: C стає рівно 0
elif 0 < q < Q      -> cost = round(C × q / Q, 2)
elif Q > 0, q > Q   -> cost = round(C / Q × q, 2) + позначка перерахунку (лише для проведення в минулому)
elif Q <= 0         -> cost = round(lastAvg × q, 2), lastAvg — середня останнього руху з Q > 0, інакше 0;
                       позначка перерахунку
costAmount = −cost
```

Два останні випадки можливі лише для документа «заднім числом» (перевірка `RegStockBalance` у r1/r2
ведеться за поточними підсумками). Після вставки перевіряються поточні підсумки (розд. 3).

Приклад округлення (`Q = 3`, `C = 10,00`): вибуття 1 → `10/3 = 3,333… → 3,33` (лишається 2 / 6,67);
вибуття 1 → `6,67/2 = 3,335 → 3,34` (1 / 3,33); вибуття 1 → `q = Q` → 3,33 (0 / 0,00). Разом 10,00.

### 7. Формування рухів (реєстратори, матриця 2.2)

Для всіх: `period <- header.occurredAt`, `recorder <- документ`, лише рядки `productKind = GOODS`.

| Реєстратор | `warehouseId` | `lineNumber` | `quantity` | `costAmount` |
|---|---|---|---|---|
| `DocGoodsReceipt` r3 | `header.warehouseId` | `Goods.lineNumber` | `+q` | `+Goods.amount` |
| `DocGoodsSale` r3 | `header.warehouseId` | `Goods.lineNumber` | `−q` | `−cost` (розд. 6) |
| `DocSupplierReturn` | `header.warehouseId` | `Goods.lineNumber` | `−q` | `−cost` (розд. 6) |
| `DocGoodsWriteOff` r3 | `header.warehouseId` | `Goods.lineNumber` | `−q` | `−cost` (розд. 6) |
| `DocGoodsTransfer` r3, вибуття | `warehouseFromId` | `Goods.lineNumber` | `−q` | `−cost` (розд. 6) |
| `DocGoodsTransfer` r3, надходження | `warehouseToId` | `1000000 + Goods.lineNumber` | `+q` | `+cost` того самого рядка |
| `DocCustomerReturn` | `header.warehouseId` | `Goods.lineNumber` | `+q` | `+returnCost` (нижче) |
| `DocSurplusPosting` | `header.warehouseId` | `Goods.lineNumber` | `+q` | `+round(q × Goods.price, 2)` |

`returnCost` для рядка повернення з `baseSaleLineId` (рядок `DocGoodsSale`): `S` = `−costAmount`
руху `RegStockCost` реалізації з `lineNumber` цього рядка, `N` = кількість рядка реалізації,
`R/Rc` = кількість/вартість, уже повернена іншими проведеними поверненнями цього рядка:
`якщо R + q = N → returnCost = S − Rc, інакше round(S × q / N, 2)`. Приклад: продано 4 шт із
собівартістю 416,00; повернення 1 → 104,00; потім 3 → `416,00 − 104,00 = 312,00`.

`DocSurplusPosting.price` (default у документі): `round(avgCost, 2)` складу/товару на дату документа,
якщо `Q > 0`; інакше `round(lastAvg, 2)`; інакше 0 — оператор може змінити.

Приклад переміщення: «Основний» `Q = 8`, `C = 832,00`; переміщення 2 → «Основний» `−2 / −208,00`
(`lineNumber 1`), «Філія» `+2 / +208,00` (`lineNumber 1000001`).

Усі рухи формуються в тій самій транзакції, що й рухи `RegStockBalance` документа, після
`lock_warehouse` (для переміщення — обох складів, у порядку зростання `id`). Повторне проведення
атомарно замінює набір реєстратора; скасування видаляє набір і перевіряє правила розд. 3.

### 8. Ретроспективні зміни й перерахунок

**Політика r3:** проведення, повторне проведення чи скасування документа з моментом, раніше за
останній рух ключа, **не перераховує** пізніші документи автоматично. Натомість у тій самій
транзакції:

1. для кожного зачепленого ключа, де існує рух іншого реєстратора з `(period, postingSeq)` пізніше
   за момент документа, виконується `merge` у `reg_stock_cost_recalc(warehouse_id, product_id,
   from_period = least(існуюча, period), reason_recorder_type/id, marked_at, marked_by)`;
2. інвалідуються знімки ключа з місяця `from_period`;
3. документ отримує warning `COST_RECALC_REQUIRED` «Собівартість пізніших документів по товару
   «X» потребує перерахунку з 03.11.2026».

**Команда `REBUILD_COST`** `RebuildStockCost(warehouseId?, productId?, fromDate?, onlyMarked,
idempotencyKey)`, право `register.stock-cost.rebuild`:

1. визначити набір ключів (позначені або за фільтром) і `fromDate` (параметр або `from_period`);
2. `lock_warehouse` для всіх складів набору (за зростанням `id`);
3. для кожного ключа взяти `Q, C` на момент перед `fromDate` і пройти рухи `period >= fromDate` за
   моментом: фіксовані надходження (`Receipt`, `SurplusPosting`) — без змін; вибуття — перерахунок за
   розд. 6; залежні надходження (`Transfer` надходження, `CustomerReturn`) — з актуальної вартості
   джерела;
4. якщо змінилась вартість вибуття переміщення — ключ складу-отримувача додається в набір з датою
   руху (каскад); якщо змінилась собівартість рядка реалізації — ключ повернень за цим рядком;
   цикл до вичерпання набору (ліміт 10 000 ключів, інакше `COST_REBUILD_TOO_LARGE`);
5. оновити `cost_amount` рухів (`g_internal`), `reg_stock_cost_tot`, знімки; видалити оброблені
   позначки; `C < 0` на будь-якому моменті → `COST_REBUILD_NEGATIVE` «Від'ємна вартість «X» на складі
   «Y» на 05.11.2026: перевірте документи» і відкат усієї транзакції;
6. аудит `REBUILD_COST` (ключів, рухів змінено, `fromDate`). Повтор з тим самим ключем — збережений
   результат. Кількості й `RegStockBalance` не змінюються.

Приклад: 01.11 надходження 10 × 100,00 (`C = 1 000,00`); 05.11 реалізація 5 → собівартість 500,00;
08.11 проведено надходження від 03.11: 10 × 130,00 = 1 300,00 → позначка з 03.11, підсумки
`Q = 15`, `C = 1 800,00`. `REBUILD_COST`: на 05.11 `Q = 20`, `C = 2 300,00`, `avg = 115,00` →
собівартість реалізації 575,00; підсумки `Q = 15`, `C = 1 725,00`.

**Міграція r3:** для наявних r1/r2 документів (`DocGoodsReceipt`, `DocGoodsSale`, `DocGoodsTransfer`,
`DocGoodsWriteOff`) скрипт створює рухи з нульовою вартістю вибуття та виконує `REBUILD_COST` з
найранішої дати по всіх ключах.

### 9. Валовий прибуток (F-REP-06)

Query `GetGrossProfit(from, to, groupBy, warehouseId?, customerId?, productGroupId?)`, період `[from, to)`:

```text
revenue      = Σ RegSales.amount                     (DocGoodsSale +, DocCustomerReturn −)
costOfSales  = −Σ RegStockCost.costAmount             для recorderType ∈ {DocGoodsSale, DocCustomerReturn}
grossProfit  = revenue − costOfSales
marginPct    = round(grossProfit / revenue × 100, 2)       (null, якщо revenue = 0)
markupPct    = round(grossProfit / costOfSales × 100, 2)   (null, якщо costOfSales = 0)
```

З'єднання виручки й собівартості — за `recorderType + recorderId + lineNumber` (рядкові рухи
`RegSales` і `RegStockCost` мають однаковий `lineNumber`); покупець — із `RegSales.counterpartyId`;
рядки послуг мають собівартість 0. Колонки: `group[30] | quantity | revenue | costOfSales |
grossProfit | marginPct | markupPct`; рядок «Разом». Позначки перерахунку в періоді — банер.

Приклад: надходження 10 × 100,00 і 5 × 112,00 (`Q = 15`, `C = 1 560,00`, `avg = 104,00`).
Реалізація A: 4 × 150,00 = 600,00, собівартість `round(1560 × 4/15) = 416,00` (11 / 1 144,00).
Реалізація B: 3 × 150,00 = 450,00, собівартість `1144 × 3/11 = 312,00` (8 / 832,00) + послуга
«Доставка» 90,00 (собівартість 0). Повернення 1 шт з A: виручка −150,00, собівартість −104,00.

| Показник | Значення |
|---|---|
| revenue | 600,00 + 450,00 + 90,00 − 150,00 = 990,00 |
| costOfSales | 416,00 + 312,00 − 104,00 = 624,00 |
| grossProfit | 366,00 |
| marginPct | 366 / 990 = 36,97 % |
| markupPct | 366 / 624 = 58,65 % |

### 10. Контроль мінімальної націнки (F-PRC-05)

Правило виконується сервером у `DocGoodsSale` r3 (зміна ціни/товару рядка й `POST`) і
`DocCustomerOrder` (зміна ціни/товару/знижки рядка):

```text
effectivePrice = round(price × (1 − discountPercent/100), 2)     (для реалізації discount = 0)
avgCost        = C / Q поточних підсумків (warehouseId, productId); Q = 0 -> lastAvg; немає -> перевірка пропускається
threshold      = round(avgCost × (1 + min_markup_percent / 100), 2)   (default min_markup_percent = 0)
effectivePrice < threshold  -> warning PRICE_BELOW_COST
```

Повідомлення: «Ціна «Фарба» 100,00 нижча за мінімально допустиму 104,00 (собівартість 104,00,
мін. націнка 0 %).» Попередження не блокує запис і проведення, повертається у `warnings[]` і
записується в аудит проведення. Приклад: `avg = 104,00`, націнка 10 % → поріг 114,40; ціна 110,00 —
попередження, 115,00 — ні. Собівартість у повідомленні показується лише з правом
`register.stock-cost.read`, інакше текст «Ціна нижча за мінімально допустиму».

### 11. Зберігання й API

```text
reg_stock_cost_mv: id PK, period date, recorder_type varchar2(60), recorder_id varchar2(32),
  line_number number(10), posting_seq number(19), warehouse_id FK, product_id FK,
  quantity number(19,3), cost_amount number(19,2);
  UNIQUE (recorder_type, recorder_id, line_number);
  index (warehouse_id, product_id, period, posting_seq), (period), (recorder_type, recorder_id)
reg_stock_cost_tot: PK (warehouse_id, product_id), quantity, cost_amount,
  CHECK (quantity >= 0 and cost_amount >= 0 and (quantity > 0 or cost_amount = 0))
reg_stock_cost_snap: PK (month_end, warehouse_id, product_id), quantity, cost_amount
reg_stock_cost_recalc: PK (warehouse_id, product_id), from_period, reason_recorder_type/id, marked_at, marked_by
```

Тригер `reg_stock_cost_mv_biud`: запис лише при `trade_core.g_internal`. Пакет `trade_cost`:
`outflow_cost(w, p, at, q)`, `add_movement(...)`, `mark_recalc(w, p, at)`, `check_totals(keys)`,
`rebuild(w, p, from)`, `avg_cost(w, p)`; викликається з `trade_ops.post_*`.

API (лише читання, крім rebuild): `GET /movements`, `GET /turnovers`, `GET /balances?at=`,
`GET /recalc-marks`, `POST /rebuild`; `GET /api/v1/reports/gross-profit`. Права:
`register.stock-cost.read`, `register.stock-cost.rebuild`, `report.gross-profit.read`.

### 12. Тести й готовність

- Unit: формула вибуття (усі випадки розд. 6), приклад 10,00/3, `returnCost`, поріг націнки.
- Рухи кожного реєстратора розд. 7, `lineNumber` переміщення `1000000+`, лише `GOODS`.
- Інваріанти: `Q`/`C` ≥ 0, `Q = 0 ⇒ C = 0`, узгодженість з `RegStockBalance`.
- Повторне проведення/скасування, позначки перерахунку для документа «заднім числом»,
  `REBUILD_COST` (приклад розд. 8, каскад через переміщення), idempotency, конкурентність
  (блокування складів), міграція r1/r2.
- Звіт валового прибутку — приклад розд. 9 до копійки; групування; порожній період.
- UI: режими, банер позначок, діалог перерахунку, права, експорт.
- Наскрізний сценарій: приклад розд. 9 + переміщення 2 шт на «Філія» (208,00) + списання 1 шт на
  «Філія» (104,00) → залишки «Основний» 7 / 728,00 (після повернення 1 шт: 9 − 2 = 7), «Філія»
  1 / 104,00; валовий прибуток 366,00.
