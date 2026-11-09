# Паспорт обробки «EDI: обмін з торговими мережами»

## 0. Стан паспорта

- Статус: `PROPOSED` — підготовлено 2026-11-08, потребує явного погодження користувачем
  для переведення в `AGREED` (реалізовано за загальним дорученням користувача, APE-118).
- Ревізія: `r7` («Інтеграції й платформа»).
- Розділ меню (Taxi): `Продажі` → «EDI»; список «Звіти».
- Залежності: `RefOrganization` / `RefCounterparty` (GLN), `RefDeliveryPoint`, `RegBarcode`, `RefProduct`,
  `DocCustomerOrder`, `DocGoodsSale` (ПДВ — `RefVatRate`), `RefPriceType`, `RefContract`.
- Аналог у 1С:УТ 11: «Обмен с контрагентами» / EDI (1С:EDI, «Обмен с EDI-провайдерами»): ORDERS → Заказ клиента,
  ORDRSP, DESADV, INVOICE, RECADV.
- Функції каталогу: `F-INT-04`.

## Межі (scope)

Реалізовано провайдеро-незалежний шар без звернення до зовнішніх сервісів і без реєстрації в них:

| Входить | Не входить (окремі задачі) |
|---|---|
| Журнал повідомлень і рядків, стани, аудит | Адаптери EDIN / Вчасно.EDI / M.E.Doc / Kasta (API, токени, КЕП) |
| XML «EDI-XML 1.0» у структурі EDIN / Вчасно.EDI | Повний EANCOM / UN-EDIFACT, COMDOC, DECLAR, IFTMIN, ORDCHG |
| Завантаження вхідного файлу ORDERS / RECADV на сторінці | Автоматичне отримання вхідних з провайдера (job) |
| ORDERS → чернетка замовлення клієнта | Автопроведення / автопідтвердження за правилами |
| ORDRSP, DESADV, INVOIC з документів | Коригування / претензії за RECADV |
| Вивантаження XML, «Надіслати» через підключаємий провайдер (STUB — імітація, FILE — ручна передача) | Квитанції доставки / прочитання від провайдера |
| GLN організацій, контрагентів, точок доставки; штрихкоди упаковок | Регістр кодів товарів покупця (код покупця зберігається в повідомленні й повертається в DESADV / INVOIC) |

## БЛОК A. СТРУКТУРА

| Параметр | Значення |
|---|---|
| Технічне ім'я | `EdiExchange` (обробка) |
| Таблиці | `sys_edi_message` (повідомлення), `sys_edi_message_line` (рядки вхідних), `sys_edi_provider` (провайдери) |
| Пакет | `trade_edi` (db/47) |
| Сторінка APEX | 700 — вхідний файл, картка повідомлення з діями, журнал EDI-повідомлень |
| Права | «Роль: продажі» (Менеджер з продажу, адміністратор); команди в замовленні клієнта (261) і реалізації (111) — так само |

Повідомлення:

| Поле | Назва | Правила |
|---|---|---|
| `msgNo` | № | послідовність `sys_edi_message_seq` |
| `direction` | Напрям | IN / OUT |
| `msgType` | Тип | ORDERS, RECADV (вхідні); ORDRSP, DESADV, INVOIC (вихідні) |
| `status` | Стан | IN: NEW → PROCESSED (ORDERS — після створення замовлення, RECADV — одразу після звірки) / ERROR; OUT: GENERATED → SENT; будь-яке не оброблене / не надіслане → CANCELLED |
| `docNumber`, `docDate` | № і дата документа | NUMBER, DATE |
| `orderNumber`, `orderDate`, `deliveryDate`, `desadvNumber` | Замовлення мережі, дата поставки, № DESADV | ORDERNUMBER (у ORDERS = NUMBER), DELIVERYDATE, DESADVNUMBER / DELIVERYNOTENUMBER |
| GLN | Відправник, отримувач, постачальник, покупець, точка доставки | HEAD/SENDER, RECIPIENT, SUPPLIER, BUYER, DELIVERYPLACE |
| `organizationId`, `counterpartyId`, `deliveryPointId` | Зіставлені об'єкти | за GLN |
| `customerOrderId`, `saleId`, `refMessageId` | Пов'язані документи / повідомлення | ORDERS → замовлення; ORDRSP → ORDERS; INVOIC → DESADV; RECADV → DESADV і реалізація |
| `actionCode` | Відповідь ORDRSP | 29 прийнято, 4 зі змінами, 27 відхилено |
| `lineCount`, `errorCount`, `diffCount` | Рядки, помилки, розбіжності RECADV | — |
| `totalAmount`, `vatAmount` | Сума, ПДВ | — |
| `payload`, `fileName` | XML, ім'я файлу | вихідні: `<ТИП>_<№>_<YYYYMMDDHH24MISS>.xml` |
| `providerCode`, `extId`, `sentAt` | Провайдер, ідентифікатор, надіслано | — |

Рядок вхідного: № позиції, штрихкод, код покупця / постачальника, опис, кількість, одиниця, ціна (з ПДВ), ставка,
прийнято (RECADV), товар, кратність упаковки, кількість товару (= кількість × кратність), спосіб зіставлення
(BARCODE / SUPPLIER_CODE), стан OK / WARNING / ERROR, повідомлення.

Провайдер: код, назва, процедура надсилання (`p_id in varchar2, p_ext_id out varchar2`), за замовчуванням.
`STUB` (за замовчуванням) — `trade_edi.stub_send`; `FILE` — без процедури.

### Формат EDI-XML (вхідне ORDERS, приклад)

```xml
<ORDER>
  <DOCUMENTNAME>220</DOCUMENTNAME><NUMBER>PO-1001</NUMBER><DATE>2026-11-08</DATE>
  <DELIVERYDATE>2026-11-10</DELIVERYDATE><CURRENCY>UAH</CURRENCY><INFO>коментар</INFO>
  <HEAD>
    <SUPPLIER>4820001000009</SUPPLIER><BUYER>4820005000005</BUYER><DELIVERYPLACE>4820005000012</DELIVERYPLACE>
    <SENDER>4820005000005</SENDER><RECIPIENT>4820001000009</RECIPIENT>
    <POSITION>
      <POSITIONNUMBER>1</POSITIONNUMBER><PRODUCT>4820001000016</PRODUCT><PRODUCTIDBUYER>100501</PRODUCTIDBUYER>
      <PRODUCTIDSUPPLIER>BK-001</PRODUCTIDSUPPLIER><DESCRIPTION>Цукор білий 1 кг</DESCRIPTION>
      <ORDEREDQUANTITY>10</ORDEREDQUANTITY><ORDERUNIT>PCE</ORDERUNIT><ORDERPRICE>32.50</ORDERPRICE><VAT>20</VAT>
    </POSITION>
  </HEAD>
</ORDER>
```

Вихідні: `ORDRSP` (NUMBER, DATE, ORDERNUMBER, ORDERDATE, DELIVERYDATE, ACTION, HEAD, POSITION: PRODUCT, PRODUCTIDBUYER,
PRODUCTIDSUPPLIER, DESCRIPTION, PRICE, PRODUCTTYPE 1 / 2 / 3, ORDRSPUNIT, ORDEREDQUANTITY, ACCEPTEDQUANTITY);
`DESADV` (+ DELIVERYNOTENUMBER, HEAD/PACKINGSEQUENCE/POSITION: DELIVEREDQUANTITY, DELIVEREDUNIT, ORDEREDQUANTITY, PRICE,
PRICEWITHVAT, TAXRATE); `INVOICE` (DOCUMENTNAME 380, POSITION: INVOICEDQUANTITY, UNIT, UNITPRICE без ПДВ, TAXRATE,
AMOUNT, TAXAMOUNT, AMOUNTWITHVAT; SUMMARY). Вхідне `RECADV`: NUMBER, DATE, ORDERNUMBER, DESADVNUMBER, POSITION:
PRODUCT, PRODUCTIDSUPPLIER, DELIVERQUANTITY, ACCEPTEDQUANTITY, PRICE. Числа — з крапкою (кома приймається), дати —
YYYY-MM-DD (приймається й DD.MM.YYYY, YYYYMMDD), кодування UTF-8 (Windows-1251 — за декларацією XML).

## БЛОК B. ЛОГІКА (`trade_edi`, db/47)

- GLN: `gln_with_check`, `is_valid_gln`, `normalize_gln`, `check_gln` (`GLN_FORMAT`, `GLN_CHECKSUM`).
- `load_file` / `load_xml` — запис повідомлення й розбір: некоректний XML, непідтримуваний корінь (вхідні — лише ORDER
  / ORDERS і RECADV), номер і дата, організація (SUPPLIER, інакше RECIPIENT), точка доставки, покупець (BUYER / SENDER або
  власник точки; розбіжність — помилка), валюта UAH, дубль уже обробленого ORDERS того самого покупця й номера — помилка
  шапки (стан ERROR, `error_text`). Рядки: штрихкод (кратність упаковки), далі код постачальника = артикул / код;
  не знайдено, помічено на видалення, кількість ≤ 0, некоректне число — помилка рядка. Жодного зіставленого рядка — ERROR.
  `EDI_FILE_EMPTY`, `EDI_FILE_TOO_BIG` (10 МБ).
- `reprocess` — повторне зіставлення вхідного NEW / ERROR (`EDI_NOT_REPROCESSABLE`).
- `create_order` — лише NEW ORDERS (`EDI_NOT_ORDERS`, `EDI_ALREADY_PROCESSED`, `EDI_HAS_ERRORS`, `EDI_NO_LINES`):
  чернетка `DocCustomerOrder` (організація, покупець, склад і вид цін точки доставки / перший склад і вид цін договору,
  дата відвантаження = DELIVERYDATE, точка доставки, № і дата мережі, коментар «EDI ORDERS № …»), рядки — товар і
  кількість товару, ціна за видом цін (інакше з файлу / кратність; немає — рядок ERROR), розбіжність ціни — WARNING;
  аудит `CREATE_BASED_ON`; `p_post = 'Y'` — одразу провести.
- `ordrsp_from_order` — з проведеного замовлення (`EDI_ORDER_NOT_POSTED`): прийнята кількість розподіляється за
  товаром між рядками ORDERS; нестача — «змінено», нуль — «відхилено», не зіставлені рядки ORDERS — «відхилено»,
  товари замовлення поза ORDERS — додані позиції; ACTION 29 / 4 / 27.
- `desadv_from_sale`, `invoic_from_sale` — з проведеної реалізації (`EDI_SALE_NOT_POSTED`, `EDI_NO_LINES`), точка доставки
  — із замовлення-підстави (інакше єдина точка покупця), GLN організації й покупця / точки обов'язкові (`EDI_GLN_MISSING`).
  Не надіслане повідомлення того самого типу й документа перегенеровується, надіслане — нове.
- RECADV: пошук DESADV (GENERATED / SENT) за номером і покупцем, інакше проведеної реалізації за номером; розбіжності
  «відвантажено ≠ прийнято» за товарами → `diff_count`, таблиця звірки в картці.
- `send` — лише OUT GENERATED (`EDI_NOT_OUTGOING`, `EDI_NOT_GENERATED`, `EDI_PROVIDER_UNKNOWN`): динамічний виклик
  процедури провайдера (`dbms_assert.qualified_sql_name`), стан SENT, провайдер, ідентифікатор; `stub_send` — без
  мережі (`EDI_PROVIDER_REJECTED` для порожнього). `cancel` (`EDI_NOT_CANCELLABLE`), `download` (XML-файл, аудит PRINT).
- `message_html` — картка: шапка з розшифровкою GLN, посилання на замовлення / реалізацію / пов'язане повідомлення,
  помилки, рядки, звірка RECADV, XML. Демо / тести: `sample_orders_xml`, `sample_recadv_xml`, `load_sample`.
- Аудит `sys_audit_log` (object_type `EDI`): EDI_LOAD, EDI_REPROCESS, EDI_GENERATE, EDI_SEND, EDI_CANCEL, PRINT.

## БЛОК C. UI

Сторінка 700: «Вхідний файл» (XML, «Завантажити», «Демо-файл ORDERS»), «Повідомлення» (картка; дії за станом:
«Створити замовлення клієнта» → перехід у замовлення 261, «Повторити зіставлення», «Надіслати провайдеру»,
«Вивантажити XML», «Імітувати RECADV мережі» для DESADV, «Скасувати», «Закрити»), «Журнал EDI-повідомлень» (IR з
відборами й вивантаженням, відкриття картки). Команди документів: замовлення клієнта 261 — «EDI: підтвердження ORDRSP»;
реалізація 111 — «EDI: відвантаження DESADV», «EDI: рахунок INVOIC» (відкривають картку на сторінці 700). Поля GLN —
контрагент (41) і організація (331); замовлення клієнта — точка доставки, № і дата замовлення мережі.

## БЛОК D. ТЕСТИ

`db/tests/t28_edi.sql` (137 перевірок): GLN і точки доставки, розбір і зіставлення ORDERS (штрихкод, упаковка, код
постачальника, коми в числах, сутності XML, BLOB з BOM, кирилиця), помилки шапки (XML, тип, GLN постачальника, точки,
покупця, дубль), повторне зіставлення, замовлення з ORDERS (склад, вид цін, ціни, попередження, аудит), ORDRSP (стани
позицій, ACTION, перегенерація, надсилання STUB, повторне надсилання, скасування), DESADV, INVOIC (суми й ПДВ =
реалізації, FILE), RECADV (звірка, розбіжності, невідомий DESADV), HTML, журнал, меню.
