# Паспорт довідника «Товари»

## 0. Стан паспорта

- Статус: `AGREED`.
- Ревізія: `r1`.
- Погодження: користувач явно погодив паспорт 2026-11-03.
- Пов'язані ADR: `docs/adr/0001-platform-and-module-structure.md`, `docs/adr/0002-database-and-migrations.md`, `docs/adr/0003-javafx-client-and-api-boundary.md`.
- Залежний паспорт: `docs/objects/RefUnitOfMeasure/PASSPORT_UK.md`.

## БЛОК A. СТРУКТУРА

### 1. Ідентичність і призначення

| Параметр | Значення |
|---|---|
| Українська назва | Товари |
| Технічне ім'я об'єкта | `RefProduct` |
| Доменний клас | `Product` |
| Тип ID | `ProductId` |
| Таблиця БД | `ref_product` |
| DTO елемента | `ProductDto` |
| DTO рядка списку | `ProductListItemDto` |
| Базовий API | `/api/v1/catalogs/products` |
| Розділ інтерфейсу | Довідники |

Довідник зберігає товари, які використовуватимуться в документах і регістрах.
Перша версія містить тільки базові реквізити товару та обов'язкову одиницю виміру.

- Вид: простий, неієрархічний довідник.
- Групи: не підтримуються у першій версії.
- Власник: відсутній.
- Код: текстовий, максимальна довжина 9, унікальний, автоматично формується зі
  збереженням початкових нулів і може бути змінений вручну.
- Вид видалення: `MARK_FOR_DELETION`.

### 2. Поля

| Поле Java / ім'я метаданих | Назва | Тип | Розмір | Обов'язкове | Default | Редагованість | Посилання | БД/API/індекс |
|---|---|---|---|---|---|---|---|---|
| `id` | ID | UUID | — | так | application generated | ні | — | `id`, PK |
| `code` | Код | String | до 9 | так | server sequence | так | — | `code`, UNIQUE |
| `name` | Найменування | String | 255 | так | — | так | — | `name`, index |
| `unitOfMeasureId` / `UnitOfMeasure` | Одиниця виміру | reference | UUID | так | немає | так | `RefUnitOfMeasure` | `unit_of_measure_id`, FK, index |
| `state` | Стан | `CatalogState` | — | так | `ACTIVE` | лише командами | — | `state`, index |
| `version` | Версія | Long | — | так | `0` | ні | — | `version` |
| `createdAt` | Створено | Instant | UTC | так | server clock | ні | — | `created_at` |
| `createdBy` | Автор створення | UUID | — | так | current user | ні | користувач | `created_by` |
| `updatedAt` | Змінено | Instant | UTC | так | server clock | ні | — | `updated_at` |
| `updatedBy` | Автор зміни | UUID | — | так | current user | ні | користувач | `updated_by` |

Правила посилання `unitOfMeasureId`:

- цільовий об'єкт має існувати до запису товару;
- для нового вибору доступні тільки одиниці виміру зі станом `ACTIVE`;
- помітка одиниці виміру на видалення не руйнує вже записані товари;
- історичне посилання продовжує відображатися й відкриватися;
- під час зміни товару сервер повторно перевіряє існування і стан вибраної одиниці;
- у домені використовується `UnitOfMeasureId`, у БД — зовнішній ключ, у UI —
  стандартний `ReferenceField<UnitOfMeasureRef>`.

### 3. Ієрархія, власник і дочірні структури

- Полів `parent` і `owner` немає.
- Табличних частин і дочірніх сутностей у першій версії немає.
- Штрих-коди, характеристики, ціни й залишки не включаються до цього паспорта та
  додаватимуться окремими погодженими об'єктами або ревізіями.

### 4. Стани, інваріанти та команди

Стани: `ACTIVE` і `MARKED_FOR_DELETION`.

Інваріанти:

- автоматичний код складається з 9 цифр і не перевикористовується;
- ручний код містить від 1 до 9 символів і є унікальним;
- `name` після обрізання має довжину 1–255 символів;
- `unitOfMeasureId` обов'язково посилається на чинну одиницю виміру;
- помічений на видалення товар не пропонується для нових посилань;
- фізичне видалення через API або UI відсутнє.

Типізовані команди:

- `InitializeProduct`;
- `CreateProduct`;
- `UpdateProduct`;
- `MarkProductForDeletion`;
- `RestoreProduct`.

## БЛОК B. UI

### 5. Форми

Створюються три форми Java-кодом без FXML і без автогенерації.

#### 5.1. Форма списку

- Правило: `docs/ui/LIST_SIMPLE_CATALOG_UK.md`.
- Колонки: `code[20] | name[55] | unitOfMeasure[25]`.
- Початкове сортування: `name ASC`, потім `code ASC`.
- Команди: створити, відкрити, помітити на видалення, відновити, оновити.
- Клавіші: `Insert`, `F2`, `F3`, `Delete`, `F9` за стандартним правилом.

#### 5.2. Форма елемента

```text
FORM productEditor

HEADER
  @save | @saveAndClose

CONTENT
  code[20] | name[*]
  unitOfMeasure[100]
```

- Початковий фокус нового товару: `name`.
- Код нового товару порожній до запису, якщо оператор не ввів його вручну.
- `unitOfMeasure` використовує стандартний `ReferenceField` з кнопками
  `Вибрати` і `Відкрити`, контекстним пошуком, `F4`, `Ctrl+Shift+F4`, `F8` та `Insert`.
- `F8`/`Insert` у полі одиниці відкриває форму нової одиниці виміру тільки за
  наявності права `catalog.unit-of-measure.create`.
- Закриття зміненої форми: записати, не записувати або скасувати.

#### 5.3. Форма вибору

- Колонки: `code[20] | name[55] | unitOfMeasure[25]`.
- Показує лише `ACTIVE`.
- Пошук виконується за кодом, найменуванням і відображуваною назвою одиниці.
- Подвійний клік або `Enter` підтверджує вибір, `Esc` скасовує.

### 6. Події введення реквізитів

| Реквізит | Компонент | Початок | Завершення | Команда | Серверна реакція |
|---|---|---|---|---|---|
| `code` | TextField | standard | standard | `CreateProduct` / `UpdateProduct` | Формат, довжина й унікальність під час запису |
| `name` | TextField | standard | standard | `CreateProduct` / `UpdateProduct` | Нормалізація й валідація під час запису |
| `unitOfMeasureId` | ReferenceField | standard reference search | commit типізованого `UnitOfMeasureRef` | `CreateProduct` / `UpdateProduct` | Перевірка ID, стану цілі й права читання |

Непідтверджений текст поля одиниці не є значенням і не передається як ID.

## БЛОК C. БІЗНЕС-ЛОГІКА

### 7. Обов'язкові сценарії довідника

#### 7.1. Ініціалізація

- Запит: `InitializeProduct`.
- Право: `catalog.product.create`.
- Повертає порожні `code`, `name`, `unitOfMeasure=null`, `version=0` і capabilities.

#### 7.2. Створення

- Команда: `CreateProduct(code, name, unitOfMeasureId, idempotencyKey)`.
- Право: `catalog.product.create`.
- Сервер перевіряє або виділяє код, завантажує активну одиницю виміру,
  створює товар і аудит в одній транзакції.

#### 7.3. Зміна

- Команда: `UpdateProduct(id, code, name, unitOfMeasureId, expectedVersion)`.
- Право: `catalog.product.update`.
- Сервер перевіряє optimistic lock та активність вибраної одиниці виміру.
- Конфлікт повертає `OPTIMISTIC_LOCK_CONFLICT`.

#### 7.4. Помітка й відновлення

- `MarkProductForDeletion(id, expectedVersion)`;
- `RestoreProduct(id, expectedVersion)`;
- право: `catalog.product.delete`.

### 8. Розрахункові поля й бізнес-логіка

Розрахункових полів у першій версії немає. Одиниця виміру є збереженим
обов'язковим посиланням, а не розрахунковим UI-полем.

### 9. Зберігання й API

Таблиця `ref_product` містить усі поля розділу 2:

- PK `id`, UNIQUE `code`;
- FK `unit_of_measure_id -> ref_unit_of_measure(id)` з `ON DELETE RESTRICT`;
- індекси `name`, `state`, `unit_of_measure_id`;
- переносимий лічильник кодів для SQLite і PostgreSQL;
- optimistic locking через `version`.

API:

- `GET /api/v1/catalogs/products`;
- `GET /api/v1/catalogs/products/picker`;
- `GET /api/v1/catalogs/products/new`;
- `GET /api/v1/catalogs/products/{id}`;
- `POST /api/v1/catalogs/products`;
- `PUT /api/v1/catalogs/products/{id}`;
- `POST /api/v1/catalogs/products/{id}/mark-for-deletion`;
- `POST /api/v1/catalogs/products/{id}/restore`.

### 10. Тести й критерії готовності

- Unit: код, назва, обов'язкова одиниця, переходи станів.
- Application: ініціалізація, створення, зміна одиниці, idempotency, optimistic lock.
- SQLite/PostgreSQL: міграції, FK, автонумерація, пошук і сортування.
- API: DTO, валідація відсутньої/неактивної одиниці, права, аудит і помилки.
- JavaFX: список, картка, picker, `ReferenceField`, кнопки й клавіші посилання.
- Наскрізний сценарій: створити одиницю виміру, створити товар із нею, змінити
  товар, знайти та вибрати його, помітити й відновити.

Реалізація дозволена тільки після явного погодження цього паспорта.

## Доповнення r5 (F-NSI-10, APE-63, `PROPOSED`)

| Поле | Назва | Тип | Default | Правила |
|---|---|---|---|---|
| `useCharacteristics` | Використовувати характеристики | Y/N | N | облік у розрізі `RefProductCharacteristic`; змінюється лише за нульового залишку |
| `useSeries` | Облік серій | Y/N | N | облік у розрізі `RefProductSeries`, FEFO; змінюється лише за нульового залишку |
| `shelfLifeDays` | Термін придатності, днів | int > 0 | — | типовий «Придатний до» нових серій |

Послуги ознак не мають. Деталі — паспорти `RefProductCharacteristic`, `RefProductSeries`.
