# Паспорт регістру відомостей «Параметри забезпечення запасів»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем.
- Ревізія: `r3`.
- Вид: інформаційний регістр, `NON_PERIODIC`, `INDEPENDENT` (записи вводяться користувачем
  типізованими командами з форми списку).
- Розділ меню («Такси»): підсистема `Склад` → група «Звіти» («Параметри забезпечення
  запасів»); у `Закупівлі` → «Звіти» — пункт «Потреба в закупівлі» (той самий об'єкт,
  сторінка 210, відкривається у режимі «Потреба»).
- Реєстраторів немає.
- Аналог 1С:УТ 11: налаштування забезпечення потреб складу з методом «По мін/макс»
  (`РегистрСведений.ПараметрыОбеспеченияПотребностей` / «Точка заказа» в УТ 10.3), спрощено.
- Функції каталогу: `F-WH-08`, `F-PUR-06`, `F-REP-07`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Параметри забезпечення запасів |
| Технічне ім'я | `RegReorderPolicy` |
| Об'єкт метаданих | `Register.ReorderPolicy` (kind `INFORMATION_REGISTER`) |
| Клас запису | `ReorderPolicyRecord` |
| Таблиця | `reg_reorder_policy` |
| API | `/api/v1/registers/reorder-policies` |
| Сторінка APEX | 210 (форма списку; діалог запису — модальний регіон тієї ж сторінки) |

Регістр задає для пари (склад, товар) мінімальний і максимальний рівень запасу, метод
поповнення, бажаного постачальника і термін поставки. На його основі розраховується
«Потреба в закупівлі» і заповнюються замовлення постачальникам.

### 2. Структура запису

| Поле | Назва | Роль | Тип | Точність | Обов'язкове | Посилання/БД |
|---|---|---|---|---|---|---|
| `id` | ID | системне | UUID | — | так | PK, `HIDDEN` |
| `version` | Версія | системне | Long | — | так | optimistic lock, `HIDDEN` |
| `createdAt/By`, `updatedAt/By` | Аудит | системне | timestamp/String | — | так | `READ_ONLY_OPTIONAL` |
| `warehouseId` | Склад | вимір | UUID | — | так | `RefWarehouse`, FK |
| `productId` | Товар | вимір | UUID | — | так | `RefProduct`, FK, `productKind = GOODS` |
| `minQuantity` | Мінімальний запас | ресурс | Number | 19,3 | так | `>= 0` |
| `maxQuantity` | Максимальний запас | ресурс | Number | 19,3 | так | `>= minQuantity` |
| `reorderMethod` | Метод забезпечення | ресурс | enum | — | так, default `MIN_MAX` | `MIN_MAX` / `NONE` |
| `preferredSupplierId` | Основний постачальник | ресурс | UUID | — | ні | `RefCounterparty`, FK |
| `leadTimeDays` | Термін поставки, дн. | ресурс | int | 3,0 | так, default 0 | `0..365` |

- Унікальність: `warehouseId + productId` (`REORDER_POLICY_DUPLICATE`).
- Інваріанти (перевіряються сервером під час `NEW/SAVE`):

| Код | Правило | Повідомлення |
|---|---|---|
| `REORDER_NEGATIVE_QUANTITY` | `minQuantity >= 0` і `maxQuantity >= 0` | «Мінімальний і максимальний запас не можуть бути від'ємними.» |
| `REORDER_MIN_GT_MAX` | `minQuantity <= maxQuantity` | «Мінімальний запас ({min}) не може перевищувати максимальний ({max}).» |
| `REORDER_MAX_REQUIRED` | для `MIN_MAX`: `maxQuantity > 0` | «Для методу «Мін/макс» максимальний запас має бути більшим за нуль.» |
| `REORDER_SERVICE_PRODUCT` | `RefProduct.productKind <> SERVICE` | «Для послуги «{товар}» параметри забезпечення не задаються.» |
| `REORDER_QUANTITY_NOT_INTEGER` | для одиниці з `fractional = false` — цілі min/max | «Одиниця «{од}» не допускає дробової кількості.» |
| `REORDER_LEAD_TIME_RANGE` | `leadTimeDays` ціле `0..365` | «Термін поставки має бути від 0 до 365 днів.» |
| `REORDER_POLICY_DUPLICATE` | немає іншого запису (склад, товар) | «Для товару «{товар}» на складі «{склад}» параметри вже задано.» |
| `REF_NOT_ACTIVE` | нове посилання на `ACTIVE` склад/товар/контрагента | «Не можна вибрати об'єкт, помічений на видалення.» |
| `VERSION_CONFLICT` | `expectedVersion = version` | «Запис змінено іншим користувачем. Оновіть форму.» |

### 3. Правила зрізу

Неперіодичний: діє рівно один (поточний) запис для пари; історії немає, аудит фіксує зміни
(`sys_audit_log`, дія `CREATE/UPDATE/DELETE` з попередніми й новими значеннями). Повторний
запис того самого ключа — лише через `SAVE` наявного запису; `NEW` з наявним ключем →
`REORDER_POLICY_DUPLICATE`. Видалення фізичне (`DELETE`), бо регістр — налаштування, на
які не посилаються документи. Помітка товару/складу на видалення не видаляє запис, але
такі пари виключаються з розрахунку потреби.

## БЛОК B. UI

### 4. Форма списку (сторінка 210)

**Режим «Параметри»** (IR, редагований через команди): командна панель `Створити (Ins) |
Змінити (F2) | Видалити (Del) | Скопіювати (F9) | Оновити`; колонки `warehouse[20] |
product[35] | unit[8] | minQuantity[12] | maxQuantity[12] | reorderMethod[12] |
preferredSupplier[25] | leadTimeDays[8] | updatedAt[16] (optional)`. Фільтри: склад, товар,
група товарів, постачальник, метод. Подвійний клік / F2 — модальний діалог запису
(`warehouse | product`, `minQuantity | maxQuantity`, `reorderMethod`, `preferredSupplier |
leadTimeDays`; кнопки `Записати і закрити | Скасувати`).

**Режим «Потреба в закупівлі»** (F-REP-07, read-only QueryTable `PurchaseNeed`):
`warehouse[18] | product[30] | stock[11] «Залишок» | reserved[11] «Резерв» |
openOrders[11] «Очікується» | available[11] «Доступно» | min[10] | max[10] | need[11]
«Потреба» | supplier[20] | supplierPrice[11] | needAmount[12] «Сума» | expectedDate[11]`.
Фільтри: склад, постачальник, «лише з потребою > 0» (default так). Групування за
постачальником; рядки без постачальника — група «Не вказано». Команда «Створити замовлення
постачальнику» для виділених рядків одного складу й постачальника → `InitializeSupplierOrder`
чернетка (рядки: товар, `quantity = need`, ціна з `RegSupplierPrice`). Експорт IR.

### 5. Події введення (діалог запису)

| Поле | Компонент | INPUT_STARTED | INPUT_COMMITTED | Серверна дія |
|---|---|---|---|---|
| `warehouse` | ReferenceField `RefWarehouse` | standard | вибір зі списку `ACTIVE` | лише в `NEW`; у `SAVE` read-only (вимір ключа) |
| `product` | ReferenceField `RefProduct`, відбір `productKind = GOODS`, `ACTIVE` | standard | вибір; клієнт показує одиницю | лише в `NEW`; перевірка `REORDER_SERVICE_PRODUCT` |
| `minQuantity` | NumericField 19,3 (scale за дробністю одиниці) | standard | число `>= 0` | валідація в `NEW/SAVE` |
| `maxQuantity` | NumericField 19,3 | standard | число `>= 0` | `REORDER_MIN_GT_MAX` у `NEW/SAVE` |
| `reorderMethod` | RadioGroup `Мін/макс | Не забезпечувати` | standard | вибір | при `NONE` поля min/max лишаються, але не використовуються |
| `preferredSupplier` | ReferenceField `RefCounterparty` | standard | вибір або очищення | `REF_NOT_ACTIVE` |
| `leadTimeDays` | NumericField ціле 3,0 | standard | ціле `0..365` | `REORDER_LEAD_TIME_RANGE` |
| аудит, `id`, `version` | — | `DISABLED` | `DISABLED` | — |

Commit поля не пише в БД; запис відбувається лише командою.

Типізовані команди:

- `NEW` — `CreateReorderPolicy(warehouseId, productId, minQuantity, maxQuantity,
  reorderMethod, preferredSupplierId?, leadTimeDays, idempotencyKey)` → DTO з `id`, `version=0`.
- `SAVE` — `UpdateReorderPolicy(id, minQuantity, maxQuantity, reorderMethod,
  preferredSupplierId?, leadTimeDays, expectedVersion)`; вимірювання не змінюються (для зміни
  ключа — видалити й створити).
- `DELETE` — `DeleteReorderPolicy(id, expectedVersion)`; підтвердження «Видалити параметри
  забезпечення для «{товар}» на «{склад}»?».
- F9 копіює запис у діалог `NEW` без `id` і без `product` (ключ має бути новим).

## БЛОК C. БІЗНЕС-ЛОГІКА

### 6. Розрахунок «Потреби в закупівлі»

Для кожного запису з `reorderMethod = MIN_MAX`, активними складом і товаром:

```text
stock     = RegStockBalance.balance(warehouseId, productId)            -- поточний
reserved  = Σ RegStockReserve.balance(warehouseId, productId, *)
openOrders= Σ RegSupplierOrders.balance(order, productId)
            для order: DocSupplierOrder POSTED, header.warehouseId = warehouseId
available = stock − reserved + openOrders
need      = available < minQuantity ? maxQuantity − available : 0
need      = fractional ? CEIL(need, 3 знаки) : CEIL(need)             -- округлення вгору
supplier  = preferredSupplierId
price     = RegSupplierPrice.latestAt(supplier, productId, now)  (null, якщо немає)
needAmount= round(need × price, 2, HALF_UP)
expectedDate = trunc(sysdate) + leadTimeDays
```

Умова порогу строга: при `available = minQuantity` потреби немає. Округлення вгору
гарантує, що замовлена кількість доводить доступний запас щонайменше до `max`; оскільки
вхідні величини мають scale 3, а для одиниць з `fractional = false` — цілі, `CEIL` змінює результат лише
у захисних випадках.

| № | Од. | min | max | stock | reserved | openOrders | available | need |
|---|---|---|---|---|---|---|---|---|
| 1 | шт | 10 | 50 | 12 | 5 | 0 | 7 | 43 |
| 2 | шт | 10 | 50 | 12 | 5 | 10 | 17 | 0 (17 ≥ 10) |
| 3 | шт | 10 | 50 | 15 | 5 | 0 | 10 | 0 (не < min) |
| 4 | кг | 2,500 | 20,000 | 3,125 | 1,000 | 0 | 2,125 | 17,875 |
| 5 | шт | 0 | 30 | 0 | 0 | 0 | 0 | 0 (0 не < 0) |
| 6 | шт | 1 | 30 | 0 | 0 | 0 | 0 | 30 |
| 7 | шт | 10 | 50 | 3 | 0 | 0 | 3 | `NONE` → не розраховується |

Приклад 1 з ціною: постачальник «Альфа», `latestAt = 20,83` → `needAmount = 43 × 20,83 =
895,69`; `leadTimeDays = 3`, сьогодні 08.11.2026 → очікується 11.11.2026.

Приклад 5: при `min = 0` потреба не виникає ніколи (у r3 `available >= 0` завдяки
інваріанту вільного залишку), тож `min = 0` фактично вимикає поповнення; для явного
вимкнення UI радить метод `NONE` (підказка в діалозі, не помилка).

**Заповнення замовлення постачальнику за потребою** (`DocSupplierOrder`, команда
«Заповнити за потребою», параметри шапки `supplierId`, `warehouseId`): рядки з потребою
> 0 для `preferredSupplierId = header.supplierId` (опція «включно з товарами без
постачальника»), `quantity = need`, `price = RegSupplierPrice.latestAt(header.supplierId,
product, header.occurredAt)`; `expectedDate` шапки = `max(occurredAt + leadTimeDays)` по
рядках, якщо поле порожнє. Наявні рядки того самого товару не дублюються (кількість
замінюється з підтвердженням).

### 7. Формування записів

Реєстраторів немає. Записи змінюються лише командами п. 5 у транзакції: перевірка прав →
lock `select ... for update` запису (для `SAVE/DELETE`) → валідація п. 2 → DML під
`trade_core.g_internal` → аудит. Тригер `reg_reorder_policy_biud` відхиляє DML поза
командним пакетом (`trade_ops.save_reorder_policy` / `delete_reorder_policy`) і
перевіряє інваріанти повторно (захист від прямого SQL).

### 8. Зберігання, запити й API

```text
reg_reorder_policy
  id                    varchar2(32)  PK
  warehouse_id          varchar2(32)  NOT NULL FK ref_warehouse
  product_id            varchar2(32)  NOT NULL FK ref_product
  min_quantity          number(19,3)  NOT NULL CHECK (min_quantity >= 0)
  max_quantity          number(19,3)  NOT NULL CHECK (max_quantity >= 0)
  reorder_method        varchar2(10)  default 'MIN_MAX' NOT NULL CHECK in ('MIN_MAX','NONE')
  preferred_supplier_id varchar2(32)  FK ref_counterparty, nullable
  lead_time_days        number(3)     default 0 NOT NULL CHECK (between 0 and 365)
  version number(19), created_at/by, updated_at/by
  CHECK (min_quantity <= max_quantity)
  UK reg_reorder_policy_uk (warehouse_id, product_id)
  IX (product_id); IX (preferred_supplier_id)
```

Queries: `ListReorderPolicies(filters, sort = warehouse.name, product.name, page)`,
`GetReorderPolicy(id)`, `GetPurchaseNeed(warehouseId?, supplierId?, onlyPositive)` →
DTO `PurchaseNeedRow(warehouseId, productId, stock, reserved, openOrders, available, min,
max, need, supplierId, supplierPrice, needAmount, expectedDate)`, стабільний ключ рядка —
`warehouseId + productId`. API: `GET /reorder-policies`, `POST` (NEW), `PUT /{id}` (SAVE),
`DELETE /{id}`, `GET /reorder-policies/purchase-need`. Права: `read` — усі ролі;
`create/update/delete` — закупівельник, адміністратор.

### 9. Тести й готовність

1. Інваріанти: `min > max`, від'ємні, `max = 0` для `MIN_MAX`, дробні для штук, послуга,
   дублікат ключа, `leadTimeDays = 366`.
2. Optimistic lock: дві сесії змінюють запис — друга отримує `VERSION_CONFLICT`.
3. Паралельний `NEW` того самого ключа — другий отримує `REORDER_POLICY_DUPLICATE` (UK).
4. Розрахунок потреби — усі рядки таблиці п. 6, включно з межею `available = min`.
5. Резерв і відкриті замовлення змінюють потребу; закрите замовлення постачальнику —
   більше не враховується.
6. «Створити замовлення постачальнику» і «Заповнити за потребою» створюють `DRAFT` з
   правильними кількостями й цінами.
7. Аудит `CREATE/UPDATE/DELETE`; прямий DML відхиляється; read-only для ролей без прав.
