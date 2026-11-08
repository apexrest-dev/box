# Паспорт довідника «Склади»

## 0. Стан паспорта

- Статус: `AGREED`.
- Погодження: користувач явно погодив паспорт 2026-11-03.
- Ревізія: `r1`.
- Розділ основного меню: `Довідники`.
- Залежні паспорти: `RegStockBalance`, `DocGoodsReceipt`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Склади |
| Технічне ім'я | `RefWarehouse` |
| Клас / ID | `Warehouse` / `WarehouseId` |
| Таблиця | `ref_warehouse` |
| DTO / API | `WarehouseDto` / `/api/v1/catalogs/warehouses` |

Простий неієрархічний і непідпорядкований довідник місць зберігання товару. Код
текстовий, 9 символів, унікальний, автоматичний із можливістю ручної зміни.
Вид видалення — `MARK_FOR_DELETION`.

### 2. Поля

| Поле | Назва | Тип | Розмір | Обов'язкове | Редагування | БД |
|---|---|---|---|---|---|---|
| `id` | ID | UUID | — | так | ні | PK |
| `code` | Код | String | 9 | так | до запису/у `ACTIVE` | UNIQUE |
| `name` | Найменування | String | 255 | так | у `ACTIVE` | index |
| `state` | Стан | `CatalogState` | — | так | командами | index |
| `version` | Версія | long | — | так | ні | optimistic lock |
| `createdAt/createdBy` | Створено/автор | Instant/UUID | — | так | ні | audit |
| `updatedAt/updatedBy` | Змінено/автор | Instant/UUID | — | так | ні | audit |

### 3. Ієрархія і дочірні структури

Ієрархії, власника, груп і табличних частин немає.

### 4. Стани, інваріанти та команди

Стани: `ACTIVE`, `MARKED_FOR_DELETION`. Найменування після `trim` — 1–255
символів. Код — 1–9 символів, унікальний; автоматичний код має 9 цифр.
Команди: `InitializeWarehouse`, `CreateWarehouse`, `UpdateWarehouse`,
`MarkWarehouseForDeletion`, `RestoreWarehouse`.

## БЛОК B. UI

### 5. Форми

Три форми: список, елемент, вибір. У формі елемента — `code[25] | name[75]`.
Список і вибір містять `Код`, `Найменування`, `Стан`. Вигляд поки є
функціональним прототипом; остаточне оформлення визначає спільна UI-бібліотека.

### 6. Події введення

| Реквізит | Компонент | Початок | Завершення | Команда |
|---|---|---|---|---|
| `code` | `TextField` | standard | standard | create/update warehouse |
| `name` | `TextField` | standard | standard | create/update warehouse |
| системні read-only | label | disabled | disabled | — |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Ініціалізація повертає запропонований код і capabilities. Запис перевіряє права,
унікальність, версію та аудит у транзакції. Помічений склад не пропонується для
нових документів, але історичні посилання зберігаються.

### 8. Розрахунки

Розрахункових полів немає.

### 9. Зберігання й API

Flyway-міграція однаково створює таблицю, sequence, індекси й constraints у
SQLite/PostgreSQL. API: list, picker, initialize, get, create, update, mark, restore.
Права: `read/create/update/delete`. Усі зміни аудіюються.

### 10. Тести й готовність

Доменні інваріанти; API, права, optimistic locking; міграції двох СУБД; пошук,
вибір, помітка і відновлення; використання в прибутковій накладній.

## Доповнення r5 (F-WH-11, APE-65, `PROPOSED`)

| Поле | Назва | Тип | Default | Правила |
|---|---|---|---|---|
| `useOrderScheme` | Ордерна схема | Y/N | N | документи менеджера пишуть `RegGoodsOrderScheme`; фактичне приймання / відпуск — `DocGoodsReceiptOrder` / `DocGoodsIssueOrder`; вимикається лише без незакритих розпоряджень і чернеток ордерів (`ORDER_SCHEME_IN_USE`) |
| `useStorageBins` | Адресне зберігання (комірки) | Y/N | N | лише за ордерною схемою (`STORAGE_BINS_REQUIRE_ORDERS`, check `ref_warehouse_bins_ord_ck`); вмикається за нульового залишку складу (`STORAGE_BINS_STOCK_NOT_ZERO`), вимикається за порожніх комірок (`STORAGE_BINS_IN_USE`); комірка в рядках ордерів обов'язкова |

Склади без ознак працюють як у r1–r4. Деталі — паспорти `RefStorageBin`, `RegGoodsOrderScheme`,
`DocGoodsReceiptOrder`, `DocGoodsIssueOrder`. Перевірки — тригер `ref_warehouse_ord_biu`
(`trade_order_scheme.check_warehouse`, db/40).
