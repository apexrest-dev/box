-- =============================================================================
-- Trade — представлення для форм списків/звітів і початкові дані
-- =============================================================================

-- Відображувана назва реєстратора (для переходу до документа)
create or replace view v_recorder as
select 'DocGoodsReceipt' recorder_type, d.id recorder_id,
       'Прибуткова накладна ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') recorder_name,
       51 page_id
  from doc_goods_receipt d
union all
select 'DocSupplierPayment', d.id,
       'Оплата постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'),
       61
  from doc_supplier_payment d;

-- «Товари на складах»: рухи
create or replace view v_stock_movement as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       m.line_number, m.warehouse_id, w.name warehouse_name,
       m.product_id, p.name product_name, u.short_name unit_name, m.quantity
  from reg_stock_balance_movement m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

-- «Товари на складах»: поточні залишки (похідні від рухів)
create or replace view v_stock_balance as
select m.warehouse_id, w.name warehouse_name, m.product_id, p.code product_code, p.name product_name,
       u.short_name unit_name, sum(m.quantity) balance
  from reg_stock_balance_movement m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by m.warehouse_id, w.name, m.product_id, p.code, p.name, u.short_name
having sum(m.quantity) <> 0;

-- «Взаєморозрахунки»: рухи
create or replace view v_settlement_movement as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       m.counterparty_id, c.name counterparty_name,
       m.direction, case m.direction when 'PAYABLE' then 'Кредиторська' else 'Дебіторська' end direction_name,
       m.currency_code, m.amount
  from reg_counterparty_settlement_mv m
  join ref_counterparty c on c.id = m.counterparty_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

-- «Взаємо­розрахунки»: залишки
create or replace view v_settlement_balance as
select m.counterparty_id, c.code counterparty_code, c.name counterparty_name, m.direction,
       case m.direction when 'PAYABLE' then 'Кредиторська' else 'Дебіторська' end direction_name,
       m.currency_code, sum(m.amount) balance
  from reg_counterparty_settlement_mv m
  join ref_counterparty c on c.id = m.counterparty_id
 group by m.counterparty_id, c.code, c.name, m.direction, m.currency_code
having sum(m.amount) <> 0;

-- Основне меню з об'єктами (для домашньої сторінки й навігації)
create or replace view v_main_menu as
select s.tech_name section_tech_name, s.name section_name, s.sort_order section_sort,
       o.tech_name object_tech_name, o.name object_name, o.kind, o.list_page_id, o.sort_order object_sort
  from sys_main_menu_section s
  join sys_metadata_object o on o.section_id = s.id
 where s.is_visible = 'Y';

-- -----------------------------------------------------------------------------
-- Початкові дані: розділи основного меню й належність об'єктів
-- -----------------------------------------------------------------------------
insert into sys_main_menu_section (tech_name, name, sort_order) values ('Catalogs',  'Довідники',    10);
insert into sys_main_menu_section (tech_name, name, sort_order) values ('Documents', 'Документи',    20);
insert into sys_main_menu_section (tech_name, name, sort_order) values ('Reports',   'Звіти',        30);
insert into sys_main_menu_section (tech_name, name, sort_order, is_visible) values ('Settings', 'Налаштування', 40, 'N');

insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RefUnitOfMeasure', 'CATALOG', 'Одиниці виміру', id, 10, 10 from sys_main_menu_section where tech_name = 'Catalogs';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RefProduct', 'CATALOG', 'Товари', id, 20, 20 from sys_main_menu_section where tech_name = 'Catalogs';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RefWarehouse', 'CATALOG', 'Склади', id, 30, 30 from sys_main_menu_section where tech_name = 'Catalogs';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RefCounterparty', 'CATALOG', 'Контрагенти', id, 40, 40 from sys_main_menu_section where tech_name = 'Catalogs';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocGoodsReceipt', 'DOCUMENT', 'Прибуткові накладні', id, 50, 10 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocSupplierPayment', 'DOCUMENT', 'Оплати постачальникам', id, 60, 20 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RegStockBalance', 'ACCUMULATION_REGISTER', 'Товари на складах', id, 70, 10 from sys_main_menu_section where tech_name = 'Reports';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RegCounterpartySettlement', 'ACCUMULATION_REGISTER', 'Взаєморозрахунки', id, 80, 20 from sys_main_menu_section where tech_name = 'Reports';

-- -----------------------------------------------------------------------------
-- Демонстраційні дані довідників
-- -----------------------------------------------------------------------------
insert into ref_unit_of_measure (name, short_name, fractional) values ('Штука', 'шт', 'N');
insert into ref_unit_of_measure (name, short_name, fractional) values ('Кілограм', 'кг', 'Y');
insert into ref_unit_of_measure (name, short_name, fractional) values ('Літр', 'л', 'Y');

insert into ref_product (name, unit_of_measure_id) select 'Цукор білий', id from ref_unit_of_measure where short_name = 'кг';
insert into ref_product (name, unit_of_measure_id) select 'Олія соняшникова', id from ref_unit_of_measure where short_name = 'л';
insert into ref_product (name, unit_of_measure_id) select 'Чайник електричний', id from ref_unit_of_measure where short_name = 'шт';

insert into ref_warehouse (name) values ('Основний склад');
insert into ref_warehouse (name) values ('Склад магазину');

insert into ref_counterparty (name) values ('ТОВ «Постачальник»');
insert into ref_counterparty (name) values ('ФОП Іваненко І. І.');

commit;
