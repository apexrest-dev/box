# Паспорт довідника «Групи номенклатури»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувача
  перед реалізацією.
- Ревізія: `r3`.
- Розділ основного меню: `НСІ та адміністрування` (група панелі функцій «Номенклатура»).
- Залежності: немає (самопосилання `parent`). Залежні об'єкти: `RefProduct` r3
  (`groupId`), див. `configuration/objects/RefProduct/PASSPORT_R3_UK.md`.
- Аналог у 1С:УТ 11: групи справочника «Номенклатура» / Справочник.ВидыНоменклатуры
  (у Trade групи винесено в окремий ієрархічний довідник, а не в групи самого товару).
- Функції каталогу: `F-NSI-02` (групи номенклатури, ієрархія), частково `F-NSI-01`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Групи номенклатури |
| Технічне ім'я | `RefProductGroup` |
| Технічний ключ | `Catalog.ProductGroup` |
| Доменний клас | `ProductGroup` |
| ID-клас | `ProductGroupId` |
| Таблиця БД | `ref_product_group` |
| DTO елемента / рядка / вузла | `ProductGroupDto` / `ProductGroupListItemDto` / `ProductGroupTreeNodeDto` |
| Базовий API | `/api/v1/catalogs/product-groups` |
| APEX сторінки | 170 (список: дерево + список), 171 (форма елемента, modal dialog) |
| PL/SQL | пакет `trade_nsi` (процедури `save_product_group`, `check_group_hierarchy`) |

Довідник класифікує номенклатуру деревом груп («Побутова хімія → Миючі засоби →
Для посуду»). Групи використовуються для відбору й групування списку товарів,
звітів і форм підбору. Елементами дерева є тільки групи; товари посилаються на
групу через `RefProduct.groupId` і не є вузлами цього довідника.

- Вид: ієрархічний довідник (за `CATALOG_PASSPORT_UK.md` — завжди з групами;
  кожен елемент тут є групою й може мати дочірні групи).
- Власник: відсутній.
- Код: TEXT, 9 символів, автонумерація `ref_product_group_code_seq`
  (`000000001…`), унікальний глобально, редагований вручну.
- Вид видалення: `MARK_FOR_DELETION`; фізичного видалення немає.
- Максимальна глибина дерева: 5 рівнів (корінь — рівень 1).

### 2. Поля

| Поле (camelCase) | Назва | Тип | Розмір/точність | Обов'язкове | Default | Редагованість | Посилання | БД колонка/індекс |
|---|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 hex | так | `rawtohex(sys_guid())` | ні | — | `id varchar2(32)`, PK |
| `code` | Код | String | 1–9 | так | наступне значення sequence під час запису | так, у `ACTIVE` | — | `code varchar2(9)`, UNIQUE `ref_product_group_code_uk` |
| `name` | Найменування | String | 1–255 після `trim` | так | — | так, у `ACTIVE` | — | `name varchar2(255)`, index `ref_product_group_name_ix`; UNIQUE серед активних сестер (див. §9) |
| `parentId` | Батьківська група | reference | UUID | ні (`null` = корінь) | група, виділена в дереві списку під час NEW | так, у `ACTIVE` | `RefProductGroup` (self) | `parent_id varchar2(32)`, FK, index `ref_product_group_parent_ix` |
| `sortOrder` | Порядок | Integer | 0–99999 | так | `0` | так, у `ACTIVE` | — | `sort_order number(5)`, CHECK ≥ 0 |
| `state` | Стан | `CatalogState` | — | так | `ACTIVE` | лише командами | — | `state varchar2(20)`, CHECK, index |
| `version` | Версія | Long | — | так | `0` | ні | — | `version number(19)` |
| `createdAt` | Створено | Timestamp | UTC, секунди | так | server clock | ні | — | `created_at timestamp` |
| `createdBy` | Автор створення | String | 255 | так | `trade_core.current_user_name` | ні | користувач APEX | `created_by varchar2(255)` |
| `updatedAt` | Змінено | Timestamp | UTC, секунди | так | server clock | ні | — | `updated_at timestamp` |
| `updatedBy` | Автор зміни | String | 255 | так | `trade_core.current_user_name` | ні | користувач APEX | `updated_by varchar2(255)` |

Розрахункові поля для читання (не зберігаються): `level` (1–5), `path`
(«Побутова хімія / Миючі засоби»), `childGroupCount`, `productCount`.

Правила посилання `parentId`:

- `null` означає кореневу групу; окремого системного вузла «Корінь» у таблиці немає;
- нове значення має посилатися на групу в стані `ACTIVE`;
- група не може бути батьком сама собі й не може бути вибрана батьком, якщо вона є
  нащадком редагованої групи (цикл);
- глибина після запису: `level(нового батька) + 1 + висота піддерева редагованої
  групи − 1 ≤ 5`;
- історичне посилання на помічену батьківську групу залишається дійсним і
  відображається закресленим;
- у UI — `ReferenceField<ProductGroupRef>` з деревоподібною формою вибору.

### 3. Ієрархія, власник і дочірні структури

- Ієрархія: самопосилання `parent_id`; рівень 1 — корені, рівень 5 — максимальний.
- Переміщення групи (зміна `parentId`) переносить усе піддерево; товари груп не
  змінюються, бо посилаються на конкретну групу.
- Власника й табличних частин немає.
- Сортування сестер: `sortOrder ASC`, потім `name ASC`, потім `code ASC`.

### 4. Стани, інваріанти та типізовані команди

Стани: `ACTIVE`, `MARKED_FOR_DELETION`.

Інваріанти:

1. `code` унікальний серед усіх груп (будь-якого стану); автокод не перевикористовується.
2. `name` після `trim` має 1–255 символів.
3. Серед груп `ACTIVE` з однаковим `parentId` (включно з `null`) найменування
   унікальне без урахування регістру.
4. Граф `parent_id` ациклічний.
5. Глибина будь-якого вузла ≤ 5.
6. `parentId` нової або зміненої групи посилається на `ACTIVE` групу або `null`.
7. Помітка групи на видалення **не** помічає товари групи й **не** помічає дочірні
   групи; вона лише виключає групу з вибору для нових посилань.
8. Помічена група не редагується (крім команди `RestoreProductGroup`).
9. Фізичне видалення відсутнє в UI й API.

Типізовані команди: `InitializeProductGroup(parentId?)`, `CreateProductGroup`,
`UpdateProductGroup`, `MoveProductGroup(id, newParentId, expectedVersion)`,
`MarkProductGroupForDeletion`, `RestoreProductGroup`.

## БЛОК B. UI

### 5. Форми

#### 5.1. Форма списку (сторінка 170)

Пропонований стандарт ієрархічного списку (заповнює заглушку
`configuration/ui/LIST_HIERARCHICAL_CATALOG_UK.md`; до її погодження діє цей опис):

```text
FORM productGroupList
HEADER
  title «Групи номенклатури»
  commands: Створити | Створити копію (F9) | Змінити (F2) | Перемістити в групу |
            Помітити на видалення (Del) | Оновити | Пошук (Ctrl+F)
  filter: showMarked [Показувати помічені], за замовчуванням вимкнено
CONTENT
  LEFT  tree[30%]  APEX Tree, вузол «Усі групи» + дерево ACTIVE груп
  RIGHT list[70%]  IR дочірніх груп виділеного вузла:
        stateIcon[3] | code[12] | name[45] | sortOrder[10] | childGroupCount[12] | productCount[18]
FOOTER
  path виділеного вузла («Усі групи / Побутова хімія»)
```

- Початкове сортування правої частини: `sortOrder ASC, name ASC, code ASC`.
- Вибір вузла дерева оновлює праву частину (partial refresh, `P170_PARENT_ID`).
- Пошук `Ctrl+F` у правій частині шукає за `code`/`name` у всьому дереві; у
  результатах показується колонка `path[40]`.
- Клавіші: `Insert` — нова група з `parentId` = виділений вузол; `F2`/`Enter`/
  подвійний клік — відкрити; `F3` — відкрити read-only; `Delete` — помітити/зняти
  помітку; `F9` — копія з тим самим `parentId` і порожнім кодом.
- Перетягування вузла в дереві = `MoveProductGroup` з підтвердженням.

#### 5.2. Форма елемента (сторінка 171, modal)

```text
FORM productGroupEditor
HEADER
  ← → ☆ «Група номенклатури: <name> (Група номенклатури)»
  @saveAndClose[default] | @save | Ще ▾ (Помітити на видалення, Відновити)
CONTENT
  code[20] | name[*]
  parent[70] (ReferenceField, tree picker) | sortOrder[15]
  QueryTable «Підгрупи»: code[20] | name[60] | productCount[20]   (лише перегляд)
FOOTER
  read-only: createdAt, createdBy, updatedAt, updatedBy (згорнута група «Службові»)
```

- Початковий фокус нової групи: `name`. Код порожній до запису.
- Для поміченої групи всі поля read-only, банер «Помічено на видалення».

#### 5.3. Форма вибору

- Дерево `ACTIVE` груп з пошуком; колонки вузла `name` і `code` у тултипі.
- Недоступні для вибору (сірі): сама група й її нащадки під час вибору батька.
- `Enter`/подвійний клік — вибрати, `Esc` — скасувати, `Insert` — створити підгрупу
  (за правом `catalog.product-group.create`).

### 6. Події введення

| Реквізит | Компонент | Початок | Завершення | Команда | Серверна реакція |
|---|---|---|---|---|---|
| `code` | TextField | STANDARD | STANDARD | `Create/UpdateProductGroup` | `trim`, формат, унікальність під час SAVE |
| `name` | TextField | STANDARD | STANDARD | `Create/UpdateProductGroup` | `trim`, довжина, унікальність серед сестер під час SAVE |
| `parentId` | ReferenceField (tree) | STANDARD reference search | CUSTOM `onParentCommitted`: commit типізованого `ProductGroupRef` або очищення | `CheckProductGroupParent(id, parentId)` (query) | Повертає `allowed`, `newLevel`, помилку циклу/глибини одразу після вибору; остаточно перевіряється під час SAVE |
| `sortOrder` | NumberField (ціле) | STANDARD | STANDARD | `Create/UpdateProductGroup` | Ціле 0–99999 |
| `state`, `version`, аудит | — | DISABLED | DISABLED | — | — |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

Усі помилки повертаються як `raise_application_error(-20100, '[КОД] повідомлення')`.

#### 7.1. NEW

- `InitializeProductGroup(parentId?)`, право `catalog.product-group.create`.
- Повертає `code=null`, `name=''`, `parentId` (якщо переданий і `ACTIVE`), `sortOrder=0`.

#### 7.2. SAVE (створення / зміна / переміщення)

- `CreateProductGroup(code?, name, parentId?, sortOrder, idempotencyKey)` —
  право `catalog.product-group.create`;
  `UpdateProductGroup(id, code, name, parentId?, sortOrder, expectedVersion)` і
  `MoveProductGroup` — право `catalog.product-group.update`.
- Транзакція: `SELECT … FOR UPDATE` редагованої групи; перевірка батька через
  `CONNECT BY` від нового батька до кореня; обчислення висоти піддерева; insert/update;
  `trade_core.audit('Catalog.ProductGroup', id, 'CREATE'|'UPDATE'|'MOVE', old→new parent)`.

| Код | Повідомлення |
|---|---|
| `CATALOG_NAME_REQUIRED` | Заповніть найменування групи. |
| `CATALOG_CODE_DUPLICATE` | Код «000000012» уже використовується групою «Миючі засоби». |
| `PRODUCT_GROUP_NAME_DUPLICATE` | У групі «Побутова хімія» вже є підгрупа «Миючі засоби». |
| `PRODUCT_GROUP_CYCLE` | Неможливо перемістити групу «Миючі засоби» в її підгрупу «Для посуду». |
| `PRODUCT_GROUP_MAX_DEPTH_EXCEEDED` | Перевищено максимальну глибину ієрархії 5: після переміщення рівень стане 6. |
| `PRODUCT_GROUP_PARENT_NOT_ACTIVE` | Батьківська група «Архів» помічена на видалення. |
| `CATALOG_ITEM_MARKED` | Помічену на видалення групу не можна змінювати. Спочатку відновіть її. |
| `OPTIMISTIC_LOCK_CONFLICT` | Групу змінив інший користувач. Перечитайте дані. |

#### 7.3. Помітка на видалення

- `MarkProductGroupForDeletion(id, expectedVersion)`, право `catalog.product-group.delete`.
- Змінює тільки стан цієї групи. UI попереджає: «Група містить 3 підгрупи й 42 товари.
  Вони не будуть помічені й залишаться в групі.»
- Наслідки: група зникає з вибору (`parentId` нових груп, `RefProduct.groupId`); запис
  товару з такою групою, яку не змінювали, дозволений (історичне посилання), але
  вибір її заново — ні (`PRODUCT_GROUP_NOT_ACTIVE`).

#### 7.4. Відновлення

- `RestoreProductGroup(id, expectedVersion)`, право `catalog.product-group.delete`.
- Перевіряється унікальність найменування серед `ACTIVE` сестер
  (`PRODUCT_GROUP_NAME_DUPLICATE`); помічений батько не блокує відновлення.

### 8. Розрахунки

- `level`: корінь = 1; `level(x) = level(parent) + 1`. Обчислюється `CONNECT BY`.
- Висота піддерева `h`: група без підгруп має `h = 1`.
- Перевірка переміщення: `level(newParent) + h ≤ 5` (для `newParent = null`
  `level = 0`).
  - Приклад 1: батько рівня 3, група з однією підгрупою (`h = 2`) → `3 + 2 = 5` — дозволено.
  - Приклад 2: батько рівня 4, `h = 2` → `6` — `PRODUCT_GROUP_MAX_DEPTH_EXCEEDED`.
  - Приклад 3: `newParent = null`, `h = 5` → `0 + 5 = 5` — дозволено.
- `productCount` — кількість `ACTIVE` товарів, у яких `group_id` = група (без
  підгруп); у списку з прапорцем «З підгрупами» — по всьому піддереву.
- `path` — найменування від кореня через « / », максимум 5 сегментів.

### 9. Зберігання й API

```sql
create table ref_product_group (
  id varchar2(32) default rawtohex(sys_guid()) not null,
  code varchar2(9) not null, name varchar2(255) not null,
  parent_id varchar2(32), sort_order number(5) default 0 not null,
  state varchar2(20) default 'ACTIVE' not null, version number(19) default 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint ref_product_group_pk primary key (id),
  constraint ref_product_group_code_uk unique (code),
  constraint ref_product_group_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_product_group_sort_ck check (sort_order >= 0),
  constraint ref_product_group_self_ck check (parent_id is null or parent_id <> id),
  constraint ref_product_group_parent_fk foreign key (parent_id) references ref_product_group (id)
);
create index ref_product_group_parent_ix on ref_product_group (parent_id, sort_order, name);
create index ref_product_group_name_ix on ref_product_group (name);
create index ref_product_group_state_ix on ref_product_group (state);
create unique index ref_product_group_sib_uk on ref_product_group (
  case when state = 'ACTIVE' then nvl(parent_id, '#ROOT') end,
  case when state = 'ACTIVE' then upper(name) end);
create sequence ref_product_group_code_seq nocache;
```

Цикли й глибина контролюються в `trade_nsi.check_group_hierarchy` (не тригером, щоб
уникнути mutating table) і повторно — `compound trigger` як захист від прямих DML.

API:

- `GET /api/v1/catalogs/product-groups?parentId=&search=&showMarked=` — список;
- `GET /api/v1/catalogs/product-groups/tree?showMarked=` — дерево;
- `GET /api/v1/catalogs/product-groups/picker?excludeSubtreeOf=` — вибір;
- `GET /api/v1/catalogs/product-groups/new?parentId=`;
- `GET /api/v1/catalogs/product-groups/{id}`;
- `POST /api/v1/catalogs/product-groups`, `PUT /api/v1/catalogs/product-groups/{id}`;
- `POST /api/v1/catalogs/product-groups/{id}/move`;
- `POST /api/v1/catalogs/product-groups/{id}/mark-for-deletion`, `…/{id}/restore`.

Права: `catalog.product-group.read|create|update|delete`.

### 10. Тести й критерії готовності

- Unit: `trim` назви; унікальність сестер без регістру («Миючі» = «МИЮЧІ»); однакова
  назва в різних батьків дозволена; самопосилання відхиляється.
- Application: переміщення A→нащадок A дає `PRODUCT_GROUP_CYCLE`; ланцюг 5 рівнів
  записується, 6-й — `PRODUCT_GROUP_MAX_DEPTH_EXCEEDED`; переміщення піддерева
  висотою 2 під вузол рівня 4 відхиляється; optimistic lock.
- DB: CHECK, FK, функціональний unique index (два помічені «Архів» в одного батька
  дозволені, два активні — ні); прямий `update parent_id` із циклом відхиляє тригер.
- Помітка: група з 2 товарами помічається, товари лишаються `ACTIVE` з тим самим
  `group_id`; група зникає з picker; відновлення повертає її.
- API: коди помилок і HTTP 409/422, права, аудит `MOVE` з old/new parent.
- UI: дерево на сторінці 170, `Insert` створює підгрупу виділеного вузла, перетягування,
  фільтр «Показувати помічені», tree picker блокує нащадків.
- Наскрізний сценарій: створити «Побутова хімія → Миючі засоби», призначити товар
  групі «Миючі засоби» в `RefProduct` r3, відібрати список товарів за групою «Побутова
  хімія» з підгрупами, помітити групу й переконатися, що товар не помічено.

Реалізація дозволена тільки після явного погодження цього паспорта.
