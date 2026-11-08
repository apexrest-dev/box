-- =============================================================================
-- Trade r2 — представлення, основне меню, демо-дані
-- =============================================================================

create or replace view v_recorder as
select 'DocGoodsReceipt' recorder_type, d.id recorder_id,
       'Прибуткова накладна ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') recorder_name, 51 page_id
  from doc_goods_receipt d
union all
select 'DocSupplierPayment', d.id, 'Оплата постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 61
  from doc_supplier_payment d
union all
select 'DocPriceSetting', d.id, 'Встановлення цін ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 101
  from doc_price_setting d
union all
select 'DocGoodsSale', d.id, 'Реалізація товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 111
  from doc_goods_sale d
union all
select 'DocCustomerPayment', d.id, 'Оплата від покупця ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 121
  from doc_customer_payment d
union all
select 'DocGoodsTransfer', d.id, 'Переміщення товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 131
  from doc_goods_transfer d
union all
select 'DocGoodsWriteOff', d.id, 'Списання товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 141
  from doc_goods_write_off d;

-- «Ціни номенклатури»: зріз останніх (діючі ціни)
create or replace view v_product_price_current as
select pt.id price_type_id, pt.name price_type_name, p.id product_id, p.code product_code, p.name product_name,
       u.short_name unit_name, x.price, x.period
  from (select price_type_id, product_id,
               max(price)  keep (dense_rank last order by period, id) price,
               max(period) period
          from reg_product_price
         where period <= sysdate
         group by price_type_id, product_id) x
  join ref_price_type pt on pt.id = x.price_type_id
  join ref_product p on p.id = x.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id;

-- «Ціни номенклатури»: історія записів
create or replace view v_product_price_history as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       pt.name price_type_name, p.name product_name, u.short_name unit_name, m.price
  from reg_product_price m
  join ref_price_type pt on pt.id = m.price_type_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

-- «Продажі»: записи регістру оборотів
create or replace view v_sales as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       c.name counterparty_name, w.name warehouse_name, p.name product_name, u.short_name unit_name,
       m.quantity, m.amount
  from reg_sales_turnover m
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

-- -----------------------------------------------------------------------------
-- Основне меню: нові об'єкти r2
-- -----------------------------------------------------------------------------
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RefPriceType', 'CATALOG', 'Види цін', id, 90, 50 from sys_main_menu_section where tech_name = 'Catalogs';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocPriceSetting', 'DOCUMENT', 'Встановлення цін номенклатури', id, 100, 5 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocGoodsSale', 'DOCUMENT', 'Реалізація товарів', id, 110, 30 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocCustomerPayment', 'DOCUMENT', 'Оплати від покупців', id, 120, 40 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocGoodsTransfer', 'DOCUMENT', 'Переміщення товарів', id, 130, 50 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'DocGoodsWriteOff', 'DOCUMENT', 'Списання товарів', id, 140, 60 from sys_main_menu_section where tech_name = 'Documents';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RegProductPrice', 'INFORMATION_REGISTER', 'Ціни номенклатури', id, 150, 30 from sys_main_menu_section where tech_name = 'Reports';
insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, sort_order)
select 'RegSales', 'ACCUMULATION_REGISTER', 'Продажі', id, 160, 40 from sys_main_menu_section where tech_name = 'Reports';

-- -----------------------------------------------------------------------------
-- Демо-дані
-- -----------------------------------------------------------------------------
insert into ref_price_type (name) values ('Роздрібна');
insert into ref_price_type (name) values ('Оптова');
insert into ref_counterparty (name) values ('ТОВ «Покупець»');

commit;
