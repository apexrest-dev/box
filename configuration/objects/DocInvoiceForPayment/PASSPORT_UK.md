# Паспорт документа «Рахунок на оплату покупцю»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED`. Реалізація до погодження заборонена.
- Ревізія: `r3`.
- Розділ меню (підсистема «Такси»): `Sales` «Продажі», група «Продажі», після «Замовлення клієнта».
- Залежності: `RefCounterparty`, `RefContract` (вид `WITH_CUSTOMER`, `paymentTermDays`),
  `RefPriceType`, `RefProduct` r3, `RegProductPrice`, `DocCustomerOrder` (підстава),
  константи власної організації `sys_company_settings` (до появи `RefOrganization` r4, F-NSI-09).
- Аналог у 1С:УТ 11: `Документ.СчетНаОплатуКлиенту` (без графіка оплати, ПДВ і контролю оплат).
- Функції каталогу: F-SAL-03, F-SRV-01, F-PRC-03.

### 0.1. Відхилення від обов'язкових команд `POST/UNPOST`

Рахунок не формує рухів жодного регістру (рядок `DocInvoiceForPayment` матриці 2.2 порожній), тому
стан «проведено» підмінено бізнес-станами `DRAFT` (чернетка) / `ISSUED` (видано покупцю) /
`CANCELLED` (анульовано). Обов'язкові команди шаблону зіставлено так:

| Команда шаблону | Команда рахунку | Зміст |
|---|---|---|
| `POST` | `ISSUE` «Видати» | фіксує рахунок: `DRAFT → ISSUED`, read-only, присвоюється `issuedAt` |
| `UNPOST` | `RETURN_TO_DRAFT` «Повернути в чернетку» | `ISSUED → DRAFT`, знову редагований |
| — | `CANCEL` «Анулювати» | `DRAFT/ISSUED → CANCELLED`, причина обов'язкова |
| — | `RESTORE` «Відновити» | `CANCELLED → DRAFT` |

Кнопки форми підписуються «Видати і закрити | Записати | Видати | Повернути в чернетку»; технічно
вони займають місця `Провести і закрити | Записати | Провести | Скасувати проведення`, щоб
генератор форм «Такси» лишався єдиним. Транзакції, аудит і idempotency — як у `POST/UNPOST`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Рахунок на оплату покупцю |
| Технічне ім'я | `DocInvoiceForPayment` |
| Технічний ключ | `Document.InvoiceForPayment` |
| Клас / ID | `InvoiceForPayment` / `InvoiceForPaymentId` |
| Таблиці | `doc_invoice_for_payment`, `doc_invoice_for_payment_goods` |
| DTO | `InvoiceForPaymentDto`, `InvoiceForPaymentLineDto`, `InvoiceForPaymentListItemDto` |
| API | `/api/v1/documents/invoices-for-payment` |
| Сторінки APEX | 320 — список, 321 — форма документа |
| Нумерація | 9 цифр, `doc_invoice_for_payment_num_seq`, під час першого запису, унікальна, редагована в `DRAFT` |
| Дата | `occurredAt`, DateTime (секунди, Oracle `date`); на друку — лише дата |
| Підстава | `DocCustomerOrder` (необов'язкова, поле `baseOrderId`) |
| Рухи | немає (`posting_required = false`) |
| Видалення | `DRAFT` — фізично; `ISSUED/CANCELLED` — заборонено |

Документ фіксує виставлений покупцю рахунок і друкує форму «Рахунок на оплату». Оплати покупця
(`DocCustomerPayment`) у r3 з рахунком не зв'язуються. З r4 (F-SAL-07, APE-57) оплата від покупця може посилатися на рахунок (`invoiceId`), а рахунок має
обчислюваний стан оплати «Не оплачено» / «Частково оплачено» / «Оплачено» — див. паспорт `DocCustomerPayment`, R4.5.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Default | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | 32 | так | server | ні | PK |
| `number` | Номер | String | 9 | так | sequence | `DRAFT` | `doc_number`, UNIQUE |
| `occurredAt` | Дата | DateTime | seconds | так | `sysdate` | `DRAFT` | `occurred_at`, index |
| `customerId` | Покупець | reference | 32 | так | з підстави | `DRAFT` | `RefCounterparty`, FK |
| `contractId` | Договір | reference | 32 | ні | з підстави / `ResolveDefaultContract(customerId, WITH_CUSTOMER, occurredAt)` | `DRAFT` | `RefContract`, FK |
| `baseOrderId` | Замовлення клієнта | reference | 32 | ні | з підстави | `DRAFT` | `DocCustomerOrder`, FK, index |
| `priceTypeId` | Вид цін | reference | 32 | ні | `contract.priceTypeId` | `DRAFT` | `RefPriceType`, FK |
| `paymentDueDate` | Оплатити до | Date | day | так | `trunc(occurredAt) + coalesce(contract.paymentTermDays, 0)` | `DRAFT` | `payment_due_date` |
| `currencyCode` | Валюта | String | 3 | так | `UAH` | read-only | CHECK |
| `totalAmount` | Всього | Decimal | 19,2 | так | 0 | ні | stored |
| `issuedAt` | Видано | DateTime | seconds | ні | — | ні (команда `ISSUE`) | `issued_at` |
| `cancelReason` | Причина анулювання | String | 255 | для `CANCELLED` | — | ні (команда `CANCEL`) | `cancel_reason` |
| `comment` | Коментар | String | 1000 | ні | — | `DRAFT` | `doc_comment` |
| `status` | Статус | enum | — | так | `DRAFT` | командами | `DRAFT/ISSUED/CANCELLED` |
| `version`, аудит | Службові | — | — | так | server | ні | optimistic/audit |

### 3. Таблична частина `Goods` «Товари та послуги»

Таблиця `doc_invoice_for_payment_goods`, клас `InvoiceForPaymentLine`, стабільний `lineId`, `lineNumber`.

| Поле | Назва | Тип | Точність | Обов'язкове | Default | Редагування | Обмеження |
|---|---|---|---|---|---|---|---|
| `lineId` | ID рядка | UUID | 32 | так | server | ні | PK |
| `lineNumber` | N | Integer | 10 | так | max+1 | порядком | — |
| `productId` | Номенклатура | reference | 32 | так | — | `DRAFT` | `GOODS`/`SERVICE`, `ACTIVE` |
| `quantity` | Кількість | Decimal | 19,3 | так | 1 | `DRAFT` | > 0, дробність |
| `price` | Ціна | Decimal | 19,2 | так | `RegProductPrice` / з замовлення | `DRAFT` | >= 0 |
| `discountPercent` | Знижка, % | Decimal | 5,2 | так | 0 | `DRAFT` | 0..100 |
| `amount` | Сума | Decimal | 19,2 | так | розрахунок | ні | stored |

### 4. Статуси й життєвий цикл

| Початковий | Команда | Наступний | Право | Умови | Шапка / рядки |
|---|---|---|---|---|---|
| — | `NEW` | `DRAFT` | `document.invoice-for-payment.create` | — | редаговані |
| `DRAFT` | `SAVE` | `DRAFT` | `...update` | валідація | редаговані |
| `DRAFT` | `ISSUE` | `ISSUED` | `...issue` | є рядки, `totalAmount > 0` | read-only |
| `ISSUED` | `ISSUE` | `ISSUED` | `...issue` | idempotent, без змін | read-only |
| `ISSUED` | `RETURN_TO_DRAFT` | `DRAFT` | `...issue` | — | редаговані |
| `DRAFT`, `ISSUED` | `CANCEL` | `CANCELLED` | `...cancel` | причина 1–255 | read-only |
| `CANCELLED` | `RESTORE` | `DRAFT` | `...cancel` | — | редаговані |
| `DRAFT` | `DELETE` | — | `...delete` | — | — |
| будь-який | `COPY` (F9) | новий `DRAFT` | `...create` | — | — |

## БЛОК B. UI

### 5. Форми

#### 5.1. Список (сторінка 320)

Колонки: `icon[4] | number[10] | occurredAt[12] | customer[26] | contract[14] | baseOrder[12] |
paymentDueDate[10] | totalAmount[12] | status[10] | comment[*]`.
Іконки: `fa-file-o` — `DRAFT`; `fa-paper-plane` (зелена) — `ISSUED`; `fa-ban` (сіра,
закреслений рядок) — `CANCELLED`; `ISSUED` з `paymentDueDate < trunc(sysdate)` — червона дата.
Фільтри: період, покупець, статус, замовлення клієнта. Команди: `Створити` | `Скопіювати (F9)` |
`Видати` | `Повернути в чернетку` | `Анулювати` | `Друк ▾` | `Пошук (Ctrl+F)` | `Ще`.

#### 5.2. Форма документа (сторінка 321)

```text
FORM invoiceForPayment  title: «Рахунок на оплату 000000031 від 08.11.2026 (видано)»
HEADER
  actions: [Видати і закрити]* | Записати | Видати | Повернути в чернетку
           | Створити на підставі ▾ (—, у r3 порожнє, кнопка прихована)
           | Друк ▾ (Рахунок на оплату) | Ще ▾ (Анулювати…, Відновити, Скопіювати F9, Журнал змін)
  row1: number[15] | occurredAt[20] | paymentDueDate[15] | status[20, ro]
  row2: customer[45] | contract[35]
  row3: baseOrder[45, посилання з кнопкою «Відкрити»] | priceType[35]
CONTENT
  scanInput[40] «Штрихкод» (над вкладкою, Ctrl+Shift+B; лише DRAFT)
  TAB «Товари та послуги» (DocumentLineTable)
    commands: Додати | Підбір | Заповнити за замовленням | Заповнити ціни | ↑ | ↓ | Видалити | Ще
    columns: lineNumber[4] | product[40] | unit[6, ro] | quantity[10] | price[12]
             | discountPercent[8] | amount[14, ro]
    footer: «Всього:» totalAmount; рядок «Сума прописом:» (transient, read-only)
FOOTER
  comment[100]
  cancelReason[100, видиме лише в CANCELLED]
```

«Анулювати…» відкриває діалог з обов'язковим полем «Причина» (TextField 255) і кнопками
`Анулювати` | `Скасувати`. QueryTable немає (рахунок не залежить від залишків).

#### 5.3. Форма вибору

`number[12] | occurredAt[12] | customer[30] | totalAmount[12] | status[10]`; показує `ISSUED`
(за замовчуванням) і `DRAFT`. У r3 на рахунок посилань з інших об'єктів немає; форма потрібна для
відбору журналу й майбутнього зв'язку з оплатою.

### 6. Події введення

Команди містять `documentId`, `expectedVersion`, рядкові — `lineId`; відповідь — повний
`InvoiceForPaymentDto` + `warnings[]`.

| Реквізит | Компонент | Команда | Серверна реакція / перераховано |
|---|---|---|---|
| `number` | TextField | `ChangeInvoiceForPaymentNumber(id, value, version)` | формат, унікальність |
| `occurredAt` | DateTimeField | `ChangeInvoiceForPaymentDate(id, value, version)` | `paymentDueDate = trunc(value) + termDays` (з інформацією про зміну) |
| `customerId` | ReferenceField | `ChangeInvoiceForPaymentCustomer(id, customerId, version)` | якщо `baseOrderId` задано і клієнт інший — `BASE_ORDER_CUSTOMER_MISMATCH`; `ResolveDefaultContract` (лише якщо чинний договір рівно один); `paymentDueDate` |
| `contractId` | ReferenceField (owner, `WITH_CUSTOMER`) | `ChangeInvoiceForPaymentContract(id, contractId, version)` | `CONTRACT_OWNER_MISMATCH`, `CONTRACT_KIND_MISMATCH`, `CONTRACT_NOT_VALID_ON_DATE`; `priceTypeId`, `paymentDueDate` |
| `baseOrderId` | ReferenceField (відбір `POSTED` замовлень клієнта) | `ChangeInvoiceForPaymentBaseOrder(id, orderId, version)` | лише посилання; рядки — командою `FILL_BY_ORDER` |
| `priceTypeId` | ReferenceField | `ChangeInvoiceForPaymentPriceType(id, value, version)` | лише значення |
| `paymentDueDate` | DateField | `ChangeInvoiceForPaymentDueDate(id, value, version)` | `>= trunc(occurredAt)`, інакше `DUE_DATE_BEFORE_INVOICE_DATE`; ручне значення перезаписується наступною зміною дати/договору |
| `comment` | TextArea | `ChangeInvoiceForPaymentComment(id, value, version)` | ≤ 1000 |
| `status`, `issuedAt`, `cancelReason` | — | лише команди розд. 4 | без mutation |
| `Goods.productId` | ReferenceTableCell | `ChangeInvoiceForPaymentLineProduct(lineId, productId, version)` | ціна з `RegProductPrice`; `amount`, `totalAmount` |
| `Goods.quantity` | NumericCell 19,3 | `ChangeInvoiceForPaymentLineQuantity(lineId, value, version)` | дробність; `amount`, `totalAmount` |
| `Goods.price` | NumericCell 19,2 | `ChangeInvoiceForPaymentLinePrice(lineId, value, version)` | `>= 0`; `amount`, `totalAmount` |
| `Goods.discountPercent` | NumericCell 5,2 | `ChangeInvoiceForPaymentLineDiscount(lineId, value, version)` | 0..100; `amount`, `totalAmount` |
| `Goods.amount` | — | disabled | — |
| `Goods.lineNumber` | — | `MoveInvoiceForPaymentLine(lineId, direction, version)` | перенумерація |
| `scanInput` | TextField (transient) | `LookupBarcode(code)` → `AddOrIncrementLineByBarcode(docId, productId, unitQuantity, expectedVersion)` | `RegBarcode`; +`unitQuantity` або новий рядок з автоціною; `BARCODE_NOT_FOUND` |

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Обов'язкові сценарії

Спільне: право, статус, `expectedVersion` (`OPTIMISTIC_LOCK_CONFLICT`), `idempotencyKey`, аудит
`sys_audit_log`; помилки — `trade_core.fail('[CODE] Українське повідомлення')` (`raise_application_error -20100`).

- **NEW** `InitializeInvoiceForPayment(baseRef?)`; без підстави — `occurredAt=sysdate`,
  `paymentDueDate=trunc(sysdate)`, порожні рядки.
- **CREATE_BASED_ON** з `DocCustomerOrder` (`CreateBasedOnCustomerOrder(id, 'DocInvoiceForPayment')`,
  описано в паспорті замовлення): замовлення `POSTED` (`BASE_ORDER_NOT_POSTED` «Рахунок можна
  створити лише на підставі проведеного замовлення»); копіюються `customerId, contractId,
  priceTypeId`, `baseOrderId = order.id`; усі рядки замовлення (`GOODS` і `SERVICE`) з тими самими
  `productId, quantity, price, discountPercent`, нові `lineId`, порядок `lineNumber` збережено;
  `paymentDueDate = trunc(sysdate) + coalesce(contract.paymentTermDays, 0)`. Кілька рахунків на одне
  замовлення дозволені; якщо вже є `ISSUED` рахунок за цим замовленням — warning
  `INVOICE_ALREADY_EXISTS` «За замовленням уже видано рахунок № …».
- **FILL_BY_ORDER** `FillInvoiceForPaymentByOrder(id, version)` — `DRAFT`, `baseOrderId` заданий
  (`BASE_ORDER_REQUIRED`); замінює рядки рядками замовлення як вище.
- **FILL_PRICES** `FillInvoiceForPaymentPrices(id, version)` — ціни з `RegProductPrice` за
  `priceTypeId` на `occurredAt` (`PRICE_TYPE_REQUIRED`).
- **SAVE** `SaveInvoiceForPayment(dto, expectedVersion, idempotencyKey)` — `DRAFT`; валідації:
  обов'язкові поля, `REF_NOT_ACTIVE`, `CONTRACT_OWNER_MISMATCH`, `CONTRACT_KIND_MISMATCH`,
  `CONTRACT_NOT_VALID_ON_DATE`, `BASE_ORDER_CUSTOMER_MISMATCH` «Покупець рахунку відрізняється від клієнта замовлення»,
  `DUE_DATE_BEFORE_INVOICE_DATE` «Дата «Оплатити до» не може бути раніше дати рахунку»,
  `QUANTITY_NOT_POSITIVE`, `QUANTITY_FRACTION_NOT_ALLOWED`, `PRICE_REQUIRED`,
  `DISCOUNT_OUT_OF_RANGE`. У `ISSUED/CANCELLED` — `INVOICE_READ_ONLY` «Рахунок видано або
  анульовано: зміни заборонені. Поверніть його в чернетку».
- **ISSUE** (замість `POST`) `IssueInvoiceForPayment(id, expectedVersion, idempotencyKey)` —
  `select for update`; `DOCUMENT_HAS_NO_LINES`; `INVOICE_TOTAL_ZERO` «Сума рахунку має бути більшою
  за нуль»; повторна валідація SAVE; `status=ISSUED`, `issuedAt=sysdate`; аудит `ISSUE`. Повтор на
  `ISSUED` — без змін.
- **RETURN_TO_DRAFT** (замість `UNPOST`) `ReturnInvoiceForPaymentToDraft(id, expectedVersion)` —
  лише `ISSUED` (`INVOICE_NOT_ISSUED`); `status=DRAFT`, `issuedAt=null`; аудит `RETURN_TO_DRAFT`.
- **CANCEL** `CancelInvoiceForPayment(id, reason, expectedVersion)` — `DRAFT/ISSUED`; причина
  1–255 після trim (`CANCEL_REASON_REQUIRED`); `status=CANCELLED`; аудит `CANCEL` з причиною.
  **RESTORE** `RestoreInvoiceForPayment(id, expectedVersion)` — `CANCELLED → DRAFT`,
  `cancelReason=null`; аудит.
- **COPY** `CopyInvoiceForPayment(id)` — нова чернетка без `id/number/status/issuedAt/cancelReason/
  аудиту`, `baseOrderId` копіюється, `occurredAt=sysdate`, `paymentDueDate` перераховано.
- **DELETE** `DeleteInvoiceForPayment(id, expectedVersion)` — лише `DRAFT` (`INVOICE_NOT_DRAFT`).

### 8. Розрахунки

- `amount = round(quantity × price × (1 − discountPercent/100), 2)`, `HALF_UP`, stored;
  `totalAmount = Σ amount` — та сама формула, що й у `DocCustomerOrder`, тому рахунок на підставі
  має рівно ту саму суму, що й замовлення.
- `paymentDueDate = trunc(occurredAt) + coalesce(contract.paymentTermDays, 0)`; приклад: дата
  08.11.2026 14:20, відстрочка 5 днів → 13.11.2026; без договору → 08.11.2026; відстрочка 0 → та сама дата.
- Приклад рядків: «Плитка 30×30» 2 × 250,00 = 500,00; «Доставка» (послуга) 1 × 200,00, знижка
  5 % = 190,00 → `totalAmount = 690,00`.
- `null`: як у замовленні; рахунок з нульовою сумою можна записати, але не видати.

**Сума прописом** (transient, сервер `trade_print.amount_in_words_uk(amount)`): гривні — жіночий
рід (одна, дві), тисячі — жіночий (одна тисяча, дві тисячі), мільйони/мільярди — чоловічий (один,
два); форма слова за двома останніми цифрами: 11–14 → «гривень/тисяч/мільйонів»; остання цифра 1 →
«гривня/тисяча/мільйон», 2–4 → «гривні/тисячі/мільйони», інакше → «гривень/тисяч/мільйонів»;
копійки — завжди двома цифрами з формою «копійка/копійки/копійок» за тим самим правилом; перша
літера велика; нульові розряди пропускаються.

| Сума | Прописом |
|---|---|
| 690,00 | Шістсот дев'яносто гривень 00 копійок |
| 1 221,52 | Одна тисяча двісті двадцять одна гривня 52 копійки |
| 2 000 002,01 | Два мільйони дві гривні 01 копійка |
| 11,05 | Одинадцять гривень 05 копійок |
| 5 000,00 | П'ять тисяч гривень 00 копійок |
| 0,50 | Нуль гривень 50 копійок |

### 9. Проведення й регістри

Рухів немає: `ISSUE/RETURN_TO_DRAFT/CANCEL/RESTORE` змінюють лише `status`, `issuedAt`,
`cancelReason` і журнал аудиту. Статус замовлення-підстави не змінюється; контроль оплати рахунку,
резервування за рахунком і дебіторка за рахунком у r3 відсутні (дебіторка виникає лише реалізацією).

### 10. Зберігання, API й друк

```text
doc_invoice_for_payment: id PK, doc_number UK, occurred_at, customer_id FK, contract_id FK NULL,
  base_order_id FK doc_customer_order NULL, price_type_id FK NULL, payment_due_date date NOT NULL,
  currency_code CHECK='UAH', total_amount number(19,2), issued_at date NULL, cancel_reason varchar2(255),
  doc_comment, status CHECK in ('DRAFT','ISSUED','CANCELLED'), version, audit;
  CHECK (payment_due_date >= trunc(occurred_at)); CHECK (status <> 'ISSUED' or issued_at is not null);
  CHECK (status <> 'CANCELLED' or cancel_reason is not null)
  indexes: (occurred_at), (customer_id, occurred_at), (base_order_id), (status, payment_due_date)
doc_invoice_for_payment_goods: id PK, document_id FK ON DELETE CASCADE, line_number, product_id FK,
  quantity number(19,3) CHECK > 0, price number(19,2) CHECK >= 0,
  discount_percent number(5,2) DEFAULT 0 CHECK between 0 and 100, amount number(19,2);
  index (document_id, line_number)
sys_company_settings (один рядок, id = 'DEFAULT'): name, edrpou varchar2(10), iban varchar2(29),
  bank_name, address, phone, director_name, accountant_name
```

Тригери: `doc_invoice_for_payment_biud` (нумерація, read-only при `status <> 'DRAFT'` крім
службового запису, захист `status/issued_at/cancel_reason`, заборона видалення не-`DRAFT`), compound
`..._goods_ct` (check_editable за `DRAFT`, check_goods, автоціна, amount, renumber, total). Пакет
`trade_ops`: `issue_/return_to_draft_/cancel_/restore_/copy_invoice_for_payment`.

API: `GET /`, `GET /picker`, `GET /new`, `GET /{id}`, `POST /`, `PUT /{id}`, `DELETE /{id}`,
`POST /{id}/issue|return-to-draft|cancel|restore|copy|fill-by-order|fill-prices|lines/by-barcode`,
`GET /{id}/print/invoice?format=html|pdf`. Права: `document.invoice-for-payment.read/create/update/
delete/issue/cancel`.

**Друкована форма «Рахунок на оплату»** (A4 книжкова, HTML → PDF):

```text
Постачальник: <sys_company_settings.name>, ЄДРПОУ <edrpou>
  IBAN <iban> у <bank_name>; адреса <address>; тел. <phone>
Покупець:     <customer.name> (код <customer.code>)
Договір:      <contract.name> від <contract дата>   (рядок відсутній без договору)
Замовлення:   № <order.number> від <order.date>      (рядок відсутній без підстави)

            РАХУНОК НА ОПЛАТУ № <number> від <occurredAt: dd.MM.yyyy>
┌───┬──────────────────────────┬──────┬──────────┬──────────┬────────┬────────────┐
│ № │ Товари (роботи, послуги) │ Од.  │ Кількість│   Ціна   │Знижка %│    Сума    │
├───┼──────────────────────────┼──────┼──────────┼──────────┼────────┼────────────┤
│ 1 │ Плитка 30×30             │ м²   │    2,000 │   250,00 │        │     500,00 │
│ 2 │ Доставка                 │ посл.│    1,000 │   200,00 │   5,00 │     190,00 │
└───┴──────────────────────────┴──────┴──────────┴──────────┴────────┴────────────┘
                                                    Разом:               690,00
                                                    Без ПДВ
Всього найменувань 2, на суму 690,00 грн
Шістсот дев'яносто гривень 00 копійок
Оплатити до: 13.11.2026
Виписав(ла): ______________ <updatedBy>        Керівник: ______________ <director_name>
```

Кількість — 3 знаки, ціни/суми — 2 знаки з розділювачем тисяч (пробіл) і десятковою комою;
колонка «Знижка %» друкується лише, якщо хоча б один рядок має знижку > 0. Для `DRAFT` — водяний
знак «ЧЕРНЕТКА», для `CANCELLED` — «АНУЛЬОВАНО». Друк аудіюється (`PRINT`).

### 11. Тести й готовність

- Unit: формула `amount`; `paymentDueDate` (5/0/null днів); сума прописом — усі приклади розд. 8 і
  граничні 1,00 / 2,00 / 5,00 / 11,00 / 21,00 / 1 000 000,00 / 0,01.
- Application: NEW/SAVE/ISSUE/RETURN_TO_DRAFT/CANCEL/RESTORE/COPY/DELETE, idempotency ISSUE,
  optimistic lock, на підставі замовлення (`BASE_ORDER_NOT_POSTED`, `INVOICE_ALREADY_EXISTS`).
- БД: CHECK-и статусів, тригер read-only, FK на замовлення, відсутність будь-яких рухів регістрів.
- API/UI: права `issue/cancel`, підписи кнопок, діалог анулювання, друк HTML/PDF, водяні знаки.
- Наскрізний сценарій: замовлення клієнта (2 × 250,00; доставка 200,00 −5 %) проведено →
  «Створити на підставі → Рахунок на оплату» → сума 690,00, договір із відстрочкою 5 днів →
  «Оплатити до 13.11.2026» → `ISSUE` → друк із «Шістсот дев'яносто гривень 00 копійок» →
  `RETURN_TO_DRAFT`, зміна кількості плитки на 3 → 940,00 → `ISSUE` → `CANCEL` з причиною
  «Покупець відмовився» → `RESTORE` → `DRAFT`.
