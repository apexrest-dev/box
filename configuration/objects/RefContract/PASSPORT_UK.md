# Паспорт довідника «Договори контрагентів»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувача
  перед реалізацією.
- Ревізія: `r3`.
- Розділ основного меню: `НСІ та адміністрування` (група «Контрагенти»); також з
  панелей функцій `Продажі` і `Закупівлі`.
- Залежності: `RefCounterparty` (власник), `RefPriceType`, `RegCounterpartySettlement`
  (контроль ліміту).
- Використовують: `DocGoodsSale` r3, `DocCustomerOrder`, `DocInvoiceForPayment`,
  `DocCustomerReturn`, `DocCustomerPayment` r3 (договори `WITH_CUSTOMER`);
  `DocGoodsReceipt` r3, `DocSupplierOrder`, `DocSupplierReturn`, `DocSupplierPayment` r3
  (договори `WITH_SUPPLIER`).
- Аналог у 1С:УТ 11: Справочник.ДоговорыКонтрагентов (реквізити «Вид договору», «Вид
  цін», «Строк оплати», «Допустима сума заборгованості»).
- Функції каталогу: `F-NSI-07` (договори), `F-SAL-08` (кредитний ліміт і відстрочка),
  підготовка до `F-REP-10` (`paymentTermDays`), `F-PRC-03` (вид цін за замовчуванням).

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Договори контрагентів |
| Технічне ім'я | `RefContract` |
| Технічний ключ | `Catalog.Contract` |
| Доменний клас / ID-клас | `Contract` / `ContractId` |
| Таблиця БД | `ref_contract` |
| DTO | `ContractDto`, `ContractListItemDto`, `ContractRef` |
| Базовий API | `/api/v1/catalogs/contracts` |
| APEX сторінки | 180 (список), 181 (форма елемента, modal); вкладка «Договори» на сторінці 41 (`OwnedCatalogTable`) |
| PL/SQL | `trade_nsi.save_contract`, `trade_nsi.check_credit_limit` |

Договір фіксує комерційні умови роботи з контрагентом: роль (з покупцем або з
постачальником), вид цін, відстрочку оплати, кредитний ліміт і строк дії. Документи
продажу й закупівлі посилаються на договір і беруть з нього умови за замовчуванням.

- Вид: простий підпорядкований довідник; власник — `RefCounterparty` (обов'язковий,
  незмінний після першого запису).
- Код: TEXT 9, автонумерація `ref_contract_code_seq`, унікальний глобально (а не в
  межах власника — так код однозначно ідентифікує договір у пошуку й звітах),
  редагований.
- Вид видалення: `MARK_FOR_DELETION`.

### 2. Поля

| Поле (camelCase) | Назва | Тип | Розмір/точність | Обов'язкове | Default | Редагованість | Посилання | БД колонка/індекс |
|---|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 hex | так | `rawtohex(sys_guid())` | ні | — | `id`, PK |
| `ownerId` | Контрагент (власник) | reference | UUID | так | контрагент з контексту відкриття | лише до першого запису | `RefCounterparty` | `owner_id varchar2(32)`, FK, index `ref_contract_owner_ix` |
| `code` | Код | String | 1–9 | так | sequence під час запису | так, у `ACTIVE` | — | `code varchar2(9)`, UNIQUE |
| `name` | Найменування | String | 1–255 | так | авто «Договір № {number} від {date}» | так | — | `name varchar2(255)`, index |
| `contractNumber` | Номер договору | String | 0–50 | ні | — | так | — | `contract_number varchar2(50)` |
| `contractDate` | Дата договору (підписання) | Date | день | ні | — | так | — | `contract_date date` |
| `contractKind` | Вид договору | enum `WITH_CUSTOMER`/`WITH_SUPPLIER` | 20 | так | `WITH_CUSTOMER` (або за контекстом документа) | лише якщо договір ніде не використано | — | `contract_kind varchar2(20)`, CHECK, index з `owner_id` |
| `priceTypeId` | Вид цін | reference | UUID | ні | `null` | так; лише для `WITH_CUSTOMER` | `RefPriceType` | `price_type_id varchar2(32)`, FK |
| `paymentTermDays` | Відстрочка оплати, днів | Integer | 0–365 | так | `0` | так | — | `payment_term_days number(3)`, CHECK |
| `creditLimit` | Кредитний ліміт | Number | 19,2 | ні (`null` = без ліміту) | `null` | так; лише для `WITH_CUSTOMER` | — | `credit_limit number(19,2)`, CHECK ≥ 0 |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | ні (у r3 лише UAH) | — | `currency_code varchar2(3)`, CHECK = 'UAH' |
| `validFrom` | Діє з | Date | день | ні (`null` = без обмеження) | `contractDate` | так | — | `valid_from date` |
| `validTo` | Діє по (включно) | Date | день | ні (`null` = безстроково) | `null` | так | — | `valid_to date`, CHECK ≥ `valid_from` |
| `comment` | Коментар | String | 0–1000 | ні | — | так | — | `doc_comment varchar2(1000)` |
| `state` | Стан | `CatalogState` | — | так | `ACTIVE` | лише командами | — | `state`, CHECK, index |
| `version` | Версія | Long | — | так | `0` | ні | — | `version` |
| `createdAt` / `createdBy` | Створено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `created_at`, `created_by` |
| `updatedAt` / `updatedBy` | Змінено / автор | Timestamp / String | UTC / 255 | так | server | ні | користувач APEX | `updated_at`, `updated_by` |

Правила посилань:

- `ownerId`: контрагент має бути `ACTIVE` під час створення; після запису не змінюється
  (`CONTRACT_OWNER_IMMUTABLE`). Помітка контрагента не помічає його договори, але
  договори поміченого контрагента не пропонуються в нових документах.
- `priceTypeId`: нове значення — `ACTIVE` вид цін; для `WITH_SUPPLIER` сервер записує
  `null` (ціни постачальника беруться з `RegSupplierPrice`).
- Документ, що посилається на договір, перевіряє: `contract.ownerId = контрагент шапки`
  (`CONTRACT_OWNER_MISMATCH`), вид договору відповідає ролі документа
  (`CONTRACT_KIND_MISMATCH`), дата документа в межах дії (`CONTRACT_NOT_VALID_ON_DATE`),
  договір `ACTIVE` (`CONTRACT_NOT_ACTIVE`).

### 3. Ієрархія, власник і дочірні структури

- Ієрархії немає. Власник — `RefCounterparty`, системне поле `owner` (`ownerId`).
- Один контрагент може мати кілька договорів обох видів одночасно.
- Табличних частин немає. Документи зберігають `contract_id` у шапці.

### 4. Стани, інваріанти та типізовані команди

Стани: `ACTIVE`, `MARKED_FOR_DELETION`.

1. `ownerId` обов'язковий і незмінний.
2. `code` унікальний глобально; `name` 1–255 після `trim`.
3. `contractKind ∈ {WITH_CUSTOMER, WITH_SUPPLIER}`; змінюється лише, якщо договір не
   використано в жодному документі (`CONTRACT_KIND_CHANGE_FORBIDDEN`).
4. `paymentTermDays` — ціле 0–365.
5. `creditLimit` `null` або ≥ 0 (0 = дозволена лише передоплата); для `WITH_SUPPLIER` —
   завжди `null`.
6. `validFrom ≤ validTo`, якщо обидва задані.
7. `currencyCode = 'UAH'` у r3.
8. Документи для покупця приймають лише `WITH_CUSTOMER`, для постачальника — лише
   `WITH_SUPPLIER`.
9. Фізичного видалення немає.

Команди: `InitializeContract(ownerId, contractKind?)`, `CreateContract`,
`UpdateContract`, `MarkContractForDeletion`, `RestoreContract`; query
`ResolveDefaultContract(ownerId, kind, onDate)`, `CheckCreditLimit(…)`.

#### 4.1. Правило кредитного ліміту для `DocGoodsSale` r3 (`F-SAL-08`)

Виконується в транзакції `PostGoodsSale` після формування рухів, перед commit:

1. Якщо `contract_id is null` або `credit_limit is null` — перевірка не виконується.
2. Блокується рядок контрагента `select … from ref_counterparty where id = :owner for
   update` (серіалізація паралельних проведень одного покупця).
3. `debtBefore` = поточний (на кінець часу, а не на дату документа) залишок
   `RegCounterpartySettlement` `RECEIVABLE` / `UAH` по **контрагенту загалом**, без
   рухів цього документа (для повторного проведення).
4. `debtAfter = debtBefore + totalAmount документа`.
5. `debtAfter > creditLimit` → відмова `CREDIT_LIMIT_EXCEEDED`, транзакція відкочується.
   Рівність дозволена.

Спрощення r3: регістр взаєморозрахунків не має виміру договору, тому ліміт порівнюється
з загальною дебіторкою контрагента. Скасування проведення реалізації, проведення
оплати чи повернення ліміт не перевіряють. Зміна ліміту не впливає на вже проведені
документи. `DocCustomerOrder` перевіряє ліміт лише як попередження (не блокує).

## БЛОК B. UI

### 5. Форми

#### 5.1. Форма списку (сторінка 180)

```text
FORM contractList
HEADER
  title «Договори контрагентів»
  filters: owner (ReferenceField RefCounterparty, перший фільтр), contractKind [Усі|З покупцем|З постачальником],
           validOn (дата, за замовчуванням порожня), showMarked
  commands: Створити | Створити копію (F9) | Змінити (F2) | Помітити на видалення (Del) | Оновити | Пошук (Ctrl+F)
CONTENT
  IR: stateIcon[3] | code[10] | owner[22] | name[28] | contractKind[12] | priceType[12] |
      paymentTermDays[8] | creditLimit[12] | validTo[10]
```

- Відкриття з картки контрагента або з поля документа передає `P180_OWNER_ID`; тоді
  фільтр власника заблоковано й колонка `owner` прихована.
- Без власника список показує всі договори; «Створити» вимагає спочатку вибрати власника
  (`CONTRACT_OWNER_REQUIRED`).
- Сортування: `owner.name ASC, contractDate DESC NULLS LAST, code ASC`.
- Прострочені договори (`validTo < сьогодні`) — сірим курсивом.
- Клавіші `Insert`, `F2`/`Enter`, `F3`, `Delete`, `F9` (копія без коду, з тим самим
  власником) за стандартом.

#### 5.2. Форма елемента (сторінка 181)

```text
FORM contractEditor
HEADER
  ← → ☆ «<name> (Договір контрагента)»
  @saveAndClose[default] | @save | Ще ▾ (Помітити на видалення, Відновити)
CONTENT
  owner[60] (read-only після запису) | contractKind[30]
  contractNumber[30] | contractDate[20] | code[20]
  name[*]
  GROUP «Умови»
    priceType[50] | currency[15] (read-only)
    paymentTermDays[15] | creditLimit[25] (порожнє = «без ліміту»)
  GROUP «Строк дії»
    validFrom[20] | validTo[20]
  QueryTable «Заборгованість контрагента»: direction | balance (з RegCounterpartySettlement), лише перегляд
FOOTER
  comment[100]
  «Службові» (згорнуто): createdAt, createdBy, updatedAt, updatedBy
```

- Для `WITH_SUPPLIER` група «Умови» ховає `priceType` і `creditLimit`.
- Фокус нового договору: `contractNumber`.

#### 5.3. Форма вибору

- Завжди відфільтрована за власником і видом, які передає документ, та за `validOn` =
  дата документа; лише `ACTIVE`.
- Колонки: `code[12] | name[45] | contractDate[15] | priceType[15] | creditLimit[13]`.
- `Insert` створює договір з вже заданими власником і видом.

#### 5.4. Поведінка в документах (для паспортів документів r3)

Після вибору контрагента документ викликає `ResolveDefaultContract(ownerId, kind,
occurredAt)`: якщо рівно один `ACTIVE` чинний договір потрібного виду — підставляється;
якщо кілька або жодного — поле порожнє. Після вибору договору документ продажу
підставляє `priceTypeId` договору в шапку, якщо він не `null`.

### 6. Події введення

| Реквізит | Компонент | Початок | Завершення | Команда | Серверна реакція |
|---|---|---|---|---|---|
| `ownerId` | ReferenceField | STANDARD | commit `CounterpartyRef` | `CreateContract` | `ACTIVE`; заборонено змінювати після запису |
| `code` | TextField | STANDARD | STANDARD | `Create/UpdateContract` | унікальність |
| `name` | TextField | STANDARD | STANDARD | `Create/UpdateContract` | `trim`, 1–255 |
| `contractNumber` | TextField | STANDARD | CUSTOM `onNumberOrDateCommitted` | локально | якщо `name` порожній або досі автоматичний — перебудувати «Договір № 15/24 від 01.03.2026» |
| `contractDate` | DateField | STANDARD | CUSTOM `onNumberOrDateCommitted` | локально | як вище; якщо `validFrom` порожній — підставити дату |
| `contractKind` | RadioGroup | STANDARD | CUSTOM `onKindCommitted` | локально + SAVE | ховає/очищує `priceType`, `creditLimit` для постачальника; SAVE перевіряє інваріант 3 |
| `priceTypeId` | ReferenceField | STANDARD | commit `PriceTypeRef` або очищення | `Create/UpdateContract` | `ACTIVE` |
| `paymentTermDays` | NumberField (ціле) | STANDARD | STANDARD | `Create/UpdateContract` | 0–365 |
| `creditLimit` | NumberField (scale 2) | STANDARD | STANDARD (порожнє = `null`) | `Create/UpdateContract` | ≥ 0, `HALF_UP` |
| `validFrom`, `validTo` | DateField | STANDARD | STANDARD | `Create/UpdateContract` | `validFrom ≤ validTo` |
| `comment` | TextArea | STANDARD | STANDARD | `Create/UpdateContract` | ≤ 1000 |
| `currencyCode`, `state`, `version`, аудит | — | DISABLED | DISABLED | — | — |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Сценарії

#### 7.1. NEW

`InitializeContract(ownerId, contractKind?)`, право `catalog.contract.create`. Без
`ownerId` — `CONTRACT_OWNER_REQUIRED`. Повертає `currencyCode=UAH`, `paymentTermDays=0`,
`creditLimit=null`, `contractKind` з параметра або `WITH_CUSTOMER`.

#### 7.2. SAVE

`CreateContract(...)` — `catalog.contract.create`; `UpdateContract(id, …,
expectedVersion)` — `catalog.contract.update`. Одна транзакція: lock, перевірки,
запис, `trade_core.audit('Catalog.Contract', id, …)` з old/new для `creditLimit`,
`paymentTermDays`, `priceTypeId`.

| Код | Повідомлення |
|---|---|
| `CONTRACT_OWNER_REQUIRED` | Виберіть контрагента, для якого створюється договір. |
| `CONTRACT_OWNER_IMMUTABLE` | Контрагента записаного договору змінити не можна. |
| `CONTRACT_OWNER_NOT_ACTIVE` | Контрагент «ТОВ Ромашка» помічений на видалення. |
| `CONTRACT_KIND_CHANGE_FORBIDDEN` | Вид договору не можна змінити: договір використано в 3 документах. |
| `CONTRACT_PERIOD_INVALID` | Дата «Діє по» (28.02.2026) раніша за «Діє з» (01.03.2026). |
| `CONTRACT_PAYMENT_TERM_INVALID` | Відстрочка має бути цілим числом від 0 до 365 днів. |
| `CONTRACT_CREDIT_LIMIT_NEGATIVE` | Кредитний ліміт не може бути від'ємним. |
| `CATALOG_CODE_DUPLICATE`, `OPTIMISTIC_LOCK_CONFLICT` | стандартні |

Помилки, які повертають документи (визначені тут для спільного використання):

| Код | Повідомлення |
|---|---|
| `CONTRACT_OWNER_MISMATCH` | Договір «…» належить іншому контрагенту «…». |
| `CONTRACT_KIND_MISMATCH` | Документ «Реалізація товарів» потребує договору з покупцем, вибрано договір з постачальником. |
| `CONTRACT_NOT_VALID_ON_DATE` | Договір «…» діє з 01.03.2026 по 31.12.2026, дата документа 05.01.2027. |
| `CONTRACT_NOT_ACTIVE` | Договір «…» помічений на видалення. |
| `CREDIT_LIMIT_EXCEEDED` | Перевищено кредитний ліміт договору «…»: ліміт 10 000,00 грн, борг до проведення 8 500,00, сума документа 2 000,00, борг після 10 500,00, перевищення 500,00. |

#### 7.3. Помітка / відновлення

`MarkContractForDeletion` / `RestoreContract`, право `catalog.contract.delete`.
Помітка не змінює документи, які вже посилаються на договір; повторне проведення
такого документа відхиляється `CONTRACT_NOT_ACTIVE`. Відновлення дозволене, якщо
власник `ACTIVE`.

### 8. Розрахунки

Кредитний ліміт (`creditLimit`, scale 2):

| Ліміт | Борг до | Сума документа | Борг після | Результат |
|---|---|---|---|---|
| `null` | 50 000,00 | 10 000,00 | 60 000,00 | дозволено (ліміту немає) |
| 10 000,00 | 8 000,00 | 2 000,00 | 10 000,00 | дозволено (рівність) |
| 10 000,00 | 8 500,00 | 2 000,00 | 10 500,00 | `CREDIT_LIMIT_EXCEEDED`, перевищення 500,00 |
| 0,00 | 0,00 | 0,01 | 0,01 | `CREDIT_LIMIT_EXCEEDED` (лише передоплата) |
| 0,00 | 0,00 | 0,00 (лише безкоштовні рядки) | 0,00 | дозволено |
| 10 000,00 | 12 000,00 (ліміт знижено після продажів) | 0,01 | 12 000,01 | `CREDIT_LIMIT_EXCEEDED`; вже проведені документи не змінюються |
| 10 000,00 | 9 000,00 (з них 2 000,00 — цей документ, повторне проведення) | 2 500,00 | 7 000 + 2 500 = 9 500,00 | дозволено |

Строк оплати (для `F-REP-10`, r4): `dueDate = trunc(occurredAt) + paymentTermDays`;
документ від 28.02.2026 з відстрочкою 5 днів → 05.03.2026; 0 днів → у день документа.

Дія договору на дату `d` (включно): `(validFrom is null or validFrom ≤ trunc(d)) and
(validTo is null or trunc(d) ≤ validTo)`. Документ 31.12.2026 23:59 при `validTo =
31.12.2026` — чинний.

### 9. Зберігання й API

```sql
create sequence ref_contract_code_seq nocache;
create table ref_contract (
  id varchar2(32) default rawtohex(sys_guid()) not null,
  owner_id varchar2(32) not null,
  code varchar2(9) not null, name varchar2(255) not null,
  contract_number varchar2(50), contract_date date,
  contract_kind varchar2(20) default 'WITH_CUSTOMER' not null,
  price_type_id varchar2(32),
  payment_term_days number(3) default 0 not null,
  credit_limit number(19,2),
  currency_code varchar2(3) default 'UAH' not null,
  valid_from date, valid_to date, doc_comment varchar2(1000),
  state varchar2(20) default 'ACTIVE' not null, version number(19) default 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint ref_contract_pk primary key (id),
  constraint ref_contract_code_uk unique (code),
  constraint ref_contract_kind_ck check (contract_kind in ('WITH_CUSTOMER','WITH_SUPPLIER')),
  constraint ref_contract_term_ck check (payment_term_days between 0 and 365),
  constraint ref_contract_limit_ck check (credit_limit is null or credit_limit >= 0),
  constraint ref_contract_sup_ck check (contract_kind = 'WITH_CUSTOMER' or (credit_limit is null and price_type_id is null)),
  constraint ref_contract_cur_ck check (currency_code = 'UAH'),
  constraint ref_contract_period_ck check (valid_from is null or valid_to is null or valid_from <= valid_to),
  constraint ref_contract_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_contract_owner_fk foreign key (owner_id) references ref_counterparty (id),
  constraint ref_contract_pt_fk foreign key (price_type_id) references ref_price_type (id)
);
create index ref_contract_owner_ix on ref_contract (owner_id, contract_kind, state);
create index ref_contract_name_ix on ref_contract (name);
create index ref_contract_pt_ix on ref_contract (price_type_id);
```

Документи r3 додають `contract_id varchar2(32)` з FK на `ref_contract (id)` та index.

API:

- `GET /api/v1/catalogs/contracts?ownerId=&kind=&validOn=&search=&showMarked=`;
- `GET /api/v1/catalogs/contracts/picker?ownerId=&kind=&validOn=` (`ownerId`, `kind` обов'язкові);
- `GET /api/v1/catalogs/contracts/default?ownerId=&kind=&onDate=`;
- `GET /api/v1/catalogs/contracts/new?ownerId=&kind=`; `GET /api/v1/catalogs/contracts/{id}`;
- `POST /api/v1/catalogs/contracts`; `PUT /api/v1/catalogs/contracts/{id}`;
- `POST /api/v1/catalogs/contracts/{id}/mark-for-deletion`, `…/{id}/restore`;
- `GET /api/v1/catalogs/counterparties/{id}/contracts` (для `OwnedCatalogTable`).

Права: `catalog.contract.read|create|update|delete`.

### 10. Тести й критерії готовності

- Unit: період дії (межі включно), відстрочка 0/365/366, ліміт `null`/0/від'ємний,
  автонайменування з номера й дати.
- Application: незмінність власника; зміна виду використаного договору відхилена;
  для `WITH_SUPPLIER` ліміт і вид цін очищуються; `ResolveDefaultContract` з 0/1/2
  договорами.
- Кредитний ліміт: всі рядки таблиці §8; два паралельні проведення по 1 500,00 при
  вільному ліміті 2 000,00 — одне проходить, друге `CREDIT_LIMIT_EXCEEDED` (lock
  контрагента); unpost не перевіряє ліміт.
- DB: усі CHECK, FK, індекси; спроба `update owner_id` записаного договору відхиляється.
- API: picker без `ownerId` — 400; коди помилок; аудит зміни ліміту з old/new.
- UI: сторінка 180 з фільтром власника; вкладка «Договори» на сторінці 41; документ
  підставляє єдиний договір і вид цін.
- Наскрізний сценарій: покупець з договором ліміт 10 000,00 → реалізація 8 000,00
  (проведено) → реалізація 3 000,00 (`CREDIT_LIMIT_EXCEEDED`, повідомлення з сумами) →
  оплата 2 000,00 → повторне проведення 3 000,00 успішне.

Реалізація дозволена тільки після явного погодження цього паспорта.
