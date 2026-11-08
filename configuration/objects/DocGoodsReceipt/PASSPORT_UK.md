# Паспорт документа «Прибуткова накладна»

## 0. Стан паспорта

- Статус: `AGREED`.
- Погодження: користувач явно погодив паспорт 2026-11-03.
- Ревізія: `r1`.
- Розділ основного меню: `Документи`.
- Залежності: `RefWarehouse`, `RefCounterparty`, `RefProduct`,
  `RegStockBalance`, `RegCounterpartySettlement`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

Технічне ім'я `DocGoodsReceipt`, клас/ID `GoodsReceipt/GoodsReceiptId`, таблиця
`doc_goods_receipt`, DTO `GoodsReceiptDto`, API `/api/v1/documents/goods-receipts`.
Документ фіксує отримання товару від постачальника та виникнення боргу перед ним.

### 2. Поля шапки

| Поле | Назва | Тип | Розмір | Обов'язкове | Редагування | Посилання/БД |
|---|---|---|---|---|---|---|
| `id` | ID | UUID | — | так | ні | PK |
| `number` | Номер | String | 9 | так | DRAFT | UNIQUE |
| `occurredAt` | Дата | Instant | seconds | так | DRAFT | index |
| `supplierId` | Постачальник | UUID | — | так | DRAFT | `RefCounterparty`, FK |
| `warehouseId` | Склад | UUID | — | так | DRAFT | `RefWarehouse`, FK |
| `currencyCode` | Валюта | String | 3 | так | у r1 read-only | default `UAH` |
| `totalAmount` | Всього | BigDecimal | 19,2 | так | ні | stored calculation |
| `comment` | Коментар | String | 1000 | ні | DRAFT | — |
| `status` | Статус | enum | — | так | командами | DRAFT/POSTED |
| `version` і аудит | Службові | — | — | так | ні | optimistic/audit |

### 3. Таблична частина `Goods`

Таблиця `doc_goods_receipt_goods`, клас `GoodsReceiptLine`, стабільний UUID та
`lineNumber`.

| Поле | Назва | Тип | Точність | Обов'язкове | Редагування | Посилання |
|---|---|---|---|---|---|---|
| `id` | ID рядка | UUID | — | так | ні | — |
| `lineNumber` | N | int | — | так | порядком | — |
| `productId` | Товар | UUID | — | так | DRAFT | `RefProduct` |
| `quantity` | Кількість | BigDecimal | 19,3 | так | DRAFT | > 0 |
| `price` | Ціна | BigDecimal | 19,2 | так | DRAFT | >= 0 |
| `amount` | Сума | BigDecimal | 19,2 | так | ні | calculated |

Один товар може повторюватися різними рядками. Додавання, копіювання,
переміщення і видалення рядка виконуються лише методами документа.

### 4. Статуси й життєвий цикл

`DRAFT -> POSTED` командою `PostGoodsReceipt`; `POSTED -> DRAFT` командою
`UnpostGoodsReceipt`. У `POSTED` шапка й рядки read-only. Фізичне видалення
проведеного документа заборонене. F9 створює нову чернетку без ID, номера,
аудиту й рухів.

## БЛОК B. UI

### 5. Форми

Три форми: список, документ, вибір. Компонування:

```text
HEADER
  actions: Провести і закрити | Записати | Провести | Скасувати проведення
  number[20] | occurredAt[20] | warehouse[60]
  supplier[60] | currency[20]
CONTENT
  TAB Товари
    commands: Додати | Підбір | Оновити
    GoodsTable: product[55] | quantity[15] | price[15] | amount[15]
    totalAmount
FOOTER
  comment[100]
```

### 6. Події введення

`number`, `occurredAt`, `supplier`, `warehouse`, `comment` — standard commit у
типізовану команду зміни шапки. `product` — commit reference; `quantity` і
`price` — `ChangeGoodsReceiptLineQuantity/Price(lineId, value, version)` з
поверненням перерахованого рядка і документа. `amount/totalAmount` — disabled.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Обов'язкові сценарії

`InitializeGoodsReceipt`, `SaveGoodsReceipt`, `PostGoodsReceipt`,
`UnpostGoodsReceipt`, `CopyGoodsReceipt`. Усі змінні команди перевіряють права,
expectedVersion та статус. Проведення й рухи — одна транзакція з idempotency key.

### 8. Розрахунки

- `line.amount = quantity * price`, scale 2, `HALF_UP`, stored, вручну не змінюється;
- `totalAmount = SUM(line.amount)`, scale 2, `HALF_UP`, stored;
- `null` quantity/price під час незавершеного UI-вводу не надсилається; сервер
  приймає лише повне коректне значення;
- приклад: `2,500 × 12,34 = 30,85`; рядки 30,85 і 10,00 дають 40,85.

Якщо одиниця товару не дозволяє дробову кількість, `quantity` має цілу частину.

### 9. Проведення й регістри

Для кожного рядка `RegStockBalance`:

```text
period <- occurredAt
warehouseId <- header.warehouseId
productId <- Goods.productId
quantity <- +Goods.quantity
```

Один рух `RegCounterpartySettlement`:

```text
period <- occurredAt
counterpartyId <- header.supplierId
direction <- PAYABLE
currencyCode <- header.currencyCode
amount <- +totalAmount
```

Повторне проведення атомарно замінює рухи; unpost видаляє обидва набори.

### 10. Зберігання й API

Окремі таблиці шапки/рядків, FK, constraints та індекси в SQLite/PostgreSQL.
API list/get/initialize/create/update/post/unpost/copy. Права:
`read/create/update/post/unpost`. Аудіюються запис, проведення й скасування.

### 11. Тести й готовність

Формули й дробність, статуси, optimistic locking, атомарні рухи у два регістри,
repeat/unpost, обидві СУБД, API/права/аудит і наскрізний сценарій надходження.
