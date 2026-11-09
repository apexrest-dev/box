# Інтерфейс у стилі «Такси» (1С:Підприємство 8.3)

Статус: `PROPOSED` (реалізовано 2026-11-08 на запит користувача «зробити дуже схожим на 1С»).
Доповнює `MAIN_APPLICATION_INTERFACE_UK.md`: замість розділів «Довідники / Документи / Звіти»
панель розділів показує підсистеми, як у 1С:УТ 11.

## Елементи й відповідність

| «Такси» 1С 8.3 | Trade (APEX) | Реалізація |
|---|---|---|
| Панель розділів (ліворуч, бліда жовта, іконки + назви) | бокова навігація UT | список `navigation-menu` з `sys_main_menu_section.is_subsystem = 'Y'`; CSS `--tx-panel` |
| Панель функцій поточного розділу (колонки, зелені заголовки груп) | сторінка 2 `SECTION` | `trade_ui.function_panel(section)`; дані — `sys_function_panel` |
| Начальна сторінка + «Поточні справи» | сторінка 1 `HOME` | `trade_ui.function_panel('Main')` + `trade_ui.current_tasks()` |
| Панель відкритих (вкладки з ×) | смуга `.tx-open-tabs` | `trade-taxi.js`, sessionStorage `trade.openTabs` |
| Заголовок форми: ← → ☆ «Вид № від дата (проведено)» | регіон `form-title` | `trade_ui.doc_title`, елемент `P<n>_FORM_TITLE` |
| Командна панель, кнопка за замовчуванням жовта | регіон `actions`, `hot` кнопки | CSS `--tx-default-*` |
| Підпис поля ліворуч з двокрапкою | шаблон `@/optional` / `@/required` | CSS flex `.t-Form-fieldContainer.rel-col` |
| Незаповнене обов'язкове поле — червоне пунктирне підкреслення | `.is-required` | CSS |
| Таблична частина як вкладка «Товари» | IG з класом `tx-tabpart` | CSS |
| «Всього:» праворуч під таблицею, «Коментар:» унизу | регіон `footer` | генератор |
| Список: «Створити» першою, «Пошук (Ctrl+F)», іконки стану, жовтий рядок | IR | `icon_class` у SQL списку; JS dblclick/Enter |
| Звіт з варіантами | перемикач регіонів як вкладки | `regionDisplaySelector` |

## Гарячі клавіші

`Ins` — створити, `F9` — скопіювати, `Ctrl+Enter` — провести і закрити,
`Ctrl+S` — записати, `Ctrl+F` — пошук у списку, подвійний клік / `Enter` — відкрити рядок.

## Файли

- Стиль теми **1C-Taxi** (Theme Roller, Custom CSS); джерело `apex/theme-src/1c-taxi-custom.css` (кольори в `:root`), збірка `apex/gen/build_theme_style.py`.
- `apex/trade/shared-components/static-files/js/trade-taxi.js` — поведінка й локалізація стандартних підписів.
- `db/08_ui_taxi.sql` — підсистеми й панель функцій; `db/09_trade_ui.sql` — пакет `trade_ui`.

Логотипи й торгові марки 1С не використовуються — відтворено лише розміщення й стиль елементів.
