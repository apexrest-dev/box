# Паспорт довідника «Номенклатура — ревізія r3»

Паспорт зміни. Базовий погоджений паспорт `PASSPORT_UK.md` (r1, «Товари») залишається
чинним у всьому, що тут не змінено. Цей документ описує лише дельту r3 і правила
сумісності.

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувача
  перед реалізацією.
- Ревізія: `r3` (базова — `r1`, `AGREED` 2026-11-03).
- Розділ основного меню: `НСІ та адміністрування` (група «Номенклатура»); також
  доступний з панелі функцій розділів `Продажі`, `Закупівлі`, `Склад`.
- Українська назва об'єкта змінюється з «Товари» на «Номенклатура», бо довідник тепер
  містить і послуги.
- Залежності: `RefUnitOfMeasure`, `RefProductGroup` (новий), `RegBarcode` (новий,
  пошук за штрихкодом).
- Аналог у 1С:УТ 11: Справочник.Номенклатура (реквізити «Артикул», «Тип номенклатури
  Товар/Послуга», «Опис», «Вага»).
- Функції каталогу: `F-NSI-02` (відбір за групою), `F-NSI-03` (вид товар/послуга),
  `F-NSI-04` (артикул і штрихкоди), `F-NSI-01` (розширення).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність (зміни)

| Параметр | r1 | r3 |
|---|---|---|
| Українська назва | Товари | Номенклатура |
| Технічне ім'я / ключ | `RefProduct` / `Catalog.Product` | без змін |
| Доменний клас / ID-клас | `Product` / `ProductId` | без змін |
| Таблиця | `ref_product` | без змін + 5 колонок |
| DTO | `ProductDto`, `ProductListItemDto` | ті самі + нові поля; новий `ProductLookupResultDto` |
| API base | `/api/v1/catalogs/products` | без змін + `/lookup` |
| APEX сторінки | 20 (список), 21 (елемент) | ті самі, перебудовані (дерево груп на 20) |
| PL/SQL | `trade_core` | `trade_nsi.save_product`, `trade_nsi.lookup_product` |

Вид довідника не змінюється: простий (не ієрархічний) — ієрархію дає окремий
`RefProductGroup`, на який товар посилається необов'язковим `groupId`.

### 2. Поля

Нові поля виділено **жирним**; решта — з r1 без змін.

| Поле (camelCase) | Назва | Тип | Розмір/точність | Обов'язкове | Default | Редагованість | Посилання | БД колонка/індекс |
|---|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 hex | так | `rawtohex(sys_guid())` | ні | — | `id`, PK |
| `code` | Код | String | 1–9 | так | sequence `ref_product_code_seq` | так, у `ACTIVE` | — | `code`, UNIQUE |
| `name` | Найменування | String | 1–255 | так | — | так, у `ACTIVE` | — | `name`, index |
| **`productKind`** | Вид номенклатури | enum `GOODS`/`SERVICE` | 10 | так | `GOODS` | так, з обмеженням §4.5 | — | `product_kind varchar2(10)`, CHECK, index `ref_product_kind_ix` |
| **`groupId`** | Група | reference | UUID | ні | виділена група дерева списку | так, у `ACTIVE` | `RefProductGroup` | `group_id varchar2(32)`, FK, index `ref_product_group_ix` |
| **`article`** | Артикул | String | 0–50 після `trim` | ні | `null` | так, у `ACTIVE` | — | `article varchar2(50)`, UNIQUE серед `ACTIVE` (функц. індекс) |
| `unitOfMeasureId` | Одиниця виміру | reference | UUID | так | немає | так, у `ACTIVE` | `RefUnitOfMeasure` | `unit_of_measure_id`, FK, index |
| **`weightKg`** | Вага одиниці, кг | Number | 19,3 | ні | `null` | так, лише для `GOODS` | — | `weight_kg number(19,3)`, CHECK ≥ 0 |
| **`description`** | Опис | String (multiline) | 0–1000 | ні | `null` | так, у `ACTIVE` | — | `description varchar2(1000)` |
| `state` | Стан | `CatalogState` | — | так | `ACTIVE` | лише командами | — | `state`, index |
| `version` | Версія | Long | — | так | `0` | ні | — | `version` |
| `createdAt` / `createdBy` | Створено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `created_at`, `created_by` |
| `updatedAt` / `updatedBy` | Змінено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `updated_at`, `updated_by` |

Правила нових полів:

- `groupId`: нове значення — лише `ACTIVE` група; `null` = «Без групи». Збережене
  посилання на помічену групу лишається дійсним і може бути збережене повторно без змін;
  вибрати помічену групу заново не можна (`PRODUCT_GROUP_NOT_ACTIVE`).
- `article`: `trim`, порожній рядок перетворюється на `null`; дозволені будь-які
  друковані символи без переносів рядка; регістр зберігається, порівняння — без
  урахування регістру.
- **Рішення щодо унікальності артикула**: унікальний серед `ACTIVE` товарів (без
  урахування регістру). Обґрунтування: артикул використовується для пошуку в документах
  (`lookup`) і має однозначно визначати товар, інакше сканер/пошук повертає
  неоднозначний результат; водночас помічені на видалення (виведені з асортименту)
  позиції не блокують передачу артикула новому товару. Відновлення поміченого товару з
  дублікатом артикула відхиляється (`PRODUCT_ARTICLE_DUPLICATE`).
- `weightKg`: для `SERVICE` завжди `null` (сервер очищує під час SAVE).
- `description`: зберігається як є (перенос рядків дозволений), `trim` лише країв.

### 3. Ієрархія, власник і дочірні структури

- Власника й табличних частин немає.
- Групування — через `groupId` → `RefProductGroup` (до 5 рівнів).
- Штрихкоди зберігаються не в довіднику, а в `RegBarcode` (кілька кодів на товар,
  з кількістю в упаковці). На формі елемента вони показуються `QueryTable`.

### 4. Стани, інваріанти та типізовані команди

Стани без змін: `ACTIVE`, `MARKED_FOR_DELETION`.

Інваріанти r1 зберігаються. Додаються:

1. `product_kind ∈ {GOODS, SERVICE}`, не `null`.
2. `article` унікальний серед `ACTIVE` без урахування регістру; `null` не порівнюється.
3. `groupId` при зміні посилається на `ACTIVE` групу.
4. `SERVICE ⇒ weight_kg is null`.
5. Зміна `productKind` дозволена тільки, якщо товар не використано в жодному рядку
   жодного документа (будь-якого статусу) і немає рухів `RegStockBalance`,
   `RegStockReserve`, `RegStockCost`; інакше `PRODUCT_KIND_CHANGE_FORBIDDEN`.
6. Послуга не має залишків: для `SERVICE` ніколи не формуються рухи `RegStockBalance`,
   `RegStockReserve`, `RegStockCost`, і для неї не задається `RegReorderPolicy`.

Команди r1 (`InitializeProduct`, `CreateProduct`, `UpdateProduct`,
`MarkProductForDeletion`, `RestoreProduct`) отримують нові параметри; додається
query `LookupProduct(text, context)`.

#### 4.1. Політика рядків-послуг у документах r3 (обов'язкова для паспортів документів)

| Документ | Рядок `SERVICE` | Поведінка |
|---|---|---|
| `DocGoodsReceipt` r3 | дозволено | `PAYABLE` і `RegSupplierPrice` — так; `RegStockBalance`, `RegStockCost` — **пропуск** |
| `DocSupplierReturn` | дозволено | `PAYABLE −` — так; склад/вартість — пропуск |
| `DocSupplierOrder` | дозволено | `RegSupplierOrders +` — так |
| `DocCustomerOrder` | дозволено | `RegCustomerOrders +` — так; резерв — пропуск, прапорець резерву рядка read-only |
| `DocGoodsSale` r3 | дозволено | `RECEIVABLE`, `RegSales` — так; `RegStockBalance`, `RegStockReserve`, `RegStockCost` — пропуск; контроль залишку не виконується |
| `DocCustomerReturn` | дозволено | `RECEIVABLE −`, `RegSales −` — так; склад/вартість — пропуск |
| `DocInvoiceForPayment`, `DocPriceSetting` | дозволено | рухів складу немає |
| `DocGoodsTransfer`, `DocGoodsWriteOff`, `DocInventoryCount`, `DocSurplusPosting` | **заборонено** | помилка `PRODUCT_SERVICE_NOT_ALLOWED` під час SAVE рядка й POST; picker фільтрує `productKind = GOODS` |
| `RegReorderPolicy` | **заборонено** | `PRODUCT_SERVICE_NOT_ALLOWED` |

Повідомлення: «Рядок 3: «Доставка» — послуга й не може бути в документі «Переміщення
товарів».»

## БЛОК B. UI

### 5. Форми

#### 5.1. Форма списку (сторінка 20)

```text
FORM productList
HEADER
  title «Номенклатура»
  commands: Створити | Створити копію (F9) | Змінити (F2) | Помітити на видалення (Del) |
            Перемістити в групу | Оновити | Пошук (Ctrl+F)
  filters: productKind [Усі | Товари | Послуги]; showMarked; withSubgroups [З підгрупами] = так
  search: рядок пошуку «Код, найменування, артикул або штрихкод»
CONTENT
  LEFT  groupTree[25%]  «Усі» / дерево ACTIVE груп / «Без групи»
  RIGHT list[75%]  IR:
        stateIcon[3] | kindIcon[3] | code[12] | article[15] | name[40] | unitOfMeasure[10] | group[17]
```

- Сортування: `name ASC, code ASC`.
- Вибір вузла дерева фільтрує список `group_id` (з підгрупами — по піддереву через
  `CONNECT BY`). «Без групи» — `group_id is null`.
- Пошук виконує `LookupProduct` (§8.2); точний збіг штрихкоду/артикула відкриває рядок
  виділеним.
- Клавіші: `Insert` — новий товар у виділеній групі, `F2`/`Enter` — відкрити, `F3` —
  перегляд, `Delete` — помітка/зняття, `F9` — копія без коду й **без артикула**
  (артикул унікальний), штрихкоди не копіюються.
- «Перемістити в групу» — масова зміна `groupId` виділених рядків через tree picker,
  кожен рядок — окремий `UpdateProduct` з `expectedVersion`.

#### 5.2. Форма елемента (сторінка 21)

```text
FORM productEditor
HEADER
  ← → ☆ «<name> (Номенклатура)»
  @saveAndClose[default] | @save | Ще ▾ (Помітити на видалення, Відновити)
CONTENT
  productKind[30] (RadioGroup: Товар | Послуга)
  code[20] | article[30] | name[*]
  group[60] (ReferenceField, tree picker)
  unitOfMeasure[40] | weightKg[20] (прихований для SERVICE)
  TAB «Опис»       description[100] (TextArea, 4 рядки, лічильник 0/1000)
  TAB «Штрихкоди»  QueryTable RegBarcode: barcode[45] | unitQuantity[20] | updatedAt[25]
                   commands: Додати | Змінити | Видалити (лише після першого запису товару)
FOOTER
  «Службові» (згорнуто): createdAt, createdBy, updatedAt, updatedBy
```

- Фокус нового елемента: `name`. `productKind` для нового — `GOODS`.
- `productKind` read-only, якщо сервер повертає `capabilities.kindChangeAllowed = false`
  (тултип «Номенклатуру вже використано в документах»).
- Вкладка «Штрихкоди» пише в `RegBarcode` незалежно від запису картки (див. паспорт
  `RegBarcode`).

#### 5.3. Форма вибору

- Колонки: `code[12] | article[15] | name[45] | unitOfMeasure[10] | group[18]`; ліворуч
  дерево груп; лише `ACTIVE`.
- Контекст документа передає `kindFilter` (`GOODS` для складських документів).
- Пошук — `LookupProduct`; `Enter` — вибір, `Esc` — скасування.

### 6. Події введення

| Реквізит | Компонент | Початок | Завершення | Команда | Серверна реакція |
|---|---|---|---|---|---|
| `code` | TextField | STANDARD | STANDARD | `Create/UpdateProduct` | формат, унікальність під час SAVE |
| `name` | TextField | STANDARD | STANDARD | `Create/UpdateProduct` | `trim`, 1–255 |
| `productKind` | RadioGroup | STANDARD | CUSTOM `onKindCommitted` | локальна реакція UI + SAVE | UI ховає/очищує `weightKg`; SAVE перевіряє §4 інв. 5 |
| `article` | TextField | STANDARD | CUSTOM `onArticleCommitted` | `CheckProductArticle(id, article)` (query) | одразу попереджає про дублікат (`PRODUCT_ARTICLE_DUPLICATE` з кодом/назвою власника); остаточно — під час SAVE |
| `groupId` | ReferenceField (tree) | STANDARD reference search | commit `ProductGroupRef` або очищення | `Create/UpdateProduct` | стан групи `ACTIVE` |
| `unitOfMeasureId` | ReferenceField | STANDARD | commit `UnitOfMeasureRef` | `Create/UpdateProduct` | як у r1 |
| `weightKg` | NumberField (scale 3) | STANDARD | STANDARD | `Create/UpdateProduct` | ≥ 0, scale 3 `HALF_UP` |
| `description` | TextArea | STANDARD | STANDARD | `Create/UpdateProduct` | ≤ 1000 символів |
| `state`, `version`, аудит | — | DISABLED | DISABLED | — | — |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

#### 7.1. NEW

`InitializeProduct(groupId?)`, право `catalog.product.create`. Повертає
`productKind=GOODS`, `groupId` (якщо `ACTIVE`), решту порожніми, capabilities
`kindChangeAllowed=true`.

#### 7.2. SAVE

- `CreateProduct(code?, name, productKind, groupId?, article?, unitOfMeasureId,
  weightKg?, description?, idempotencyKey)` — `catalog.product.create`;
- `UpdateProduct(id, …, expectedVersion)` — `catalog.product.update`.
- Транзакція: lock рядка; перевірки r1; нормалізація артикула; перевірка групи;
  перевірка зміни виду (запит `exists` по `doc_*_goods.product_id` і рухах складу);
  запис; аудит з переліком змінених полів.

| Код | Повідомлення |
|---|---|
| `PRODUCT_ARTICLE_DUPLICATE` | Артикул «AB-100» уже має товар 000000017 «Мило рідке 500 мл». |
| `PRODUCT_GROUP_NOT_ACTIVE` | Група «Архів» помічена на видалення й не може бути вибрана. |
| `PRODUCT_KIND_CHANGE_FORBIDDEN` | Вид номенклатури не можна змінити: її використано в 4 документах. |
| `PRODUCT_WEIGHT_NEGATIVE` | Вага не може бути від'ємною. |
| `PRODUCT_DESCRIPTION_TOO_LONG` | Опис довший за 1000 символів (1024). |
| `PRODUCT_SERVICE_NOT_ALLOWED` | Рядок N: «…» — послуга й не може бути в документі «…». (для документів) |
| `OPTIMISTIC_LOCK_CONFLICT` | Елемент змінив інший користувач. |

#### 7.3. Помітка / відновлення

Як у r1 (`catalog.product.delete`). Відновлення додатково перевіряє унікальність
артикула. Помітка товару не видаляє його штрихкоди, але `LookupProduct` повертає
помічений товар з `state=MARKED_FOR_DELETION`, і документи відхиляють такий рядок.

### 8. Розрахунки й пошук

#### 8.1. Вага

`weightKg` scale 3 `HALF_UP`: введення `0,12345` → `0,123`; `0,0005` → `0,001`;
`null` — вага невідома (не нуль). Вага рядка документа (для друку накладної) =
`quantity × weightKg`, якщо `weightKg` не `null`: `2,500 × 0,750 = 1,875` кг.

#### 8.2. `LookupProduct(text, kindFilter?)`

Порядок (перший непорожній крок повертає результат):

1. `trim(text)`; порожній → порожній результат.
2. Точний збіг `reg_barcode.barcode = text` → товар + `unitQuantity` (`matchType=BARCODE`).
3. Точний збіг `upper(article) = upper(text)` серед `ACTIVE` (`ARTICLE`).
4. Точний збіг `code` (`CODE`).
5. `upper(name|article|code) like upper(text)||'%'` або `instr(upper(name), upper(text)) > 0`,
   максимум 50 рядків, сортування за `name` (`TEXT`).

Приклад: `4820000000017` (штрихкод упаковки 6 шт) → товар «Вода 1,5 л», `unitQuantity=6`;
`ab-100` → товар з артикулом `AB-100`.

### 9. Зберігання, міграція й API

#### 9.1. Міграція `db/10_r3_schema.sql` (ідемпотентна)

```sql
alter table ref_product add (
  group_id     varchar2(32),
  product_kind varchar2(10) default 'GOODS' not null,
  article      varchar2(50),
  weight_kg    number(19,3),
  description  varchar2(1000));
alter table ref_product add constraint ref_product_kind_ck check (product_kind in ('GOODS','SERVICE'));
alter table ref_product add constraint ref_product_weight_ck
  check (weight_kg is null or (weight_kg >= 0 and product_kind = 'GOODS'));
alter table ref_product add constraint ref_product_group_fk
  foreign key (group_id) references ref_product_group (id);
create index ref_product_group_ix on ref_product (group_id);
create index ref_product_kind_ix  on ref_product (product_kind);
create unique index ref_product_article_uk on ref_product (
  case when state = 'ACTIVE' and article is not null then upper(article) end);
```

- Наявні рядки отримують `product_kind = 'GOODS'` через `default … not null` (Oracle
  заповнює значення метаданими без перезапису рядків); `group_id`, `article`,
  `weight_kg`, `description` — `null`.
- `RefProductGroup` створюється раніше в тому самому скрипті.
- Перевірка після міграції: `select count(*) from ref_product where product_kind <> 'GOODS'` = 0.
- У `sys_metadata_object` назва `RefProduct` змінюється на «Номенклатура».

#### 9.2. Зворотна сумісність

- Нові поля в DTO необов'язкові: `POST` без `productKind` створює `GOODS`; `PUT` без
  нового поля **не змінює** його значення (клієнти r1/r2 не стирають артикул/групу).
- Відповіді додають поля; клієнти r1/r2 їх ігнорують.
- Документи r1/r2 продовжують працювати: усі наявні товари — `GOODS`, тож поведінка
  проведення не змінюється, доки не створено послугу.
- Picker r1 (`/picker`) залишається й за замовчуванням повертає обидва види.

#### 9.3. API

- `GET /api/v1/catalogs/products?groupId=&withSubgroups=&kind=&search=&showMarked=`;
- `GET /api/v1/catalogs/products/picker?kind=&groupId=&search=`;
- `GET /api/v1/catalogs/products/lookup?text=&kind=` → `ProductLookupResultDto[]`
  (`productId, code, name, article, productKind, unitOfMeasure, state, matchType, unitQuantity`);
- `GET /api/v1/catalogs/products/{id}/barcodes` (read model з `RegBarcode`);
- решта endpoint-ів r1 без змін.

### 10. Тести й критерії готовності

- Unit: нормалізація артикула (`"  ab-1 "` → `ab-1`, `""` → `null`); `SERVICE` очищує вагу.
- Application: два `ACTIVE` товари з `AB-1`/`ab-1` — другий відхиляється; помічений +
  активний з тим самим артикулом — дозволено; відновлення поміченого — відхилено; зміна
  `GOODS→SERVICE` після одного рядка в чернетці реалізації — `PRODUCT_KIND_CHANGE_FORBIDDEN`.
- DB: міграція на копії бази r2 — усі рядки `GOODS`, FK на групу, функціональний індекс.
- Документи: реалізація з товаром 2 шт і послугою «Доставка» 150,00 — `RegStockBalance`
  отримує 1 рух, `RegSales` 2, `RECEIVABLE` = повна сума; списання з послугою —
  `PRODUCT_SERVICE_NOT_ALLOWED`.
- API: `PUT` без `article` зберігає наявний артикул; `lookup` повертає порядок кроків §8.2.
- UI: дерево груп на сторінці 20, «З підгрупами», пошук за штрихкодом, вкладка «Штрихкоди».
- Наскрізний сценарій: створити групу, товар з артикулом і штрихкодом, послугу; знайти
  товар у реалізації скануванням штрихкоду; провести; перевірити залишок лише товару.

Реалізація дозволена тільки після явного погодження цього паспорта.
