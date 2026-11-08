-- =============================================================================
-- Trade r3 — представлення звітів, реєстратори, основне меню й панель функцій
-- =============================================================================

create or replace view v_recorder as
select 'DocGoodsReceipt' recorder_type, d.id recorder_id,
       'Прибуткова накладна ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') recorder_name, 51 page_id
  from doc_goods_receipt d
union all select 'DocSupplierPayment', d.id, 'Оплата постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 61 from doc_supplier_payment d
union all select 'DocPriceSetting', d.id, 'Встановлення цін ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 101 from doc_price_setting d
union all select 'DocGoodsSale', d.id, 'Реалізація товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 111 from doc_goods_sale d
union all select 'DocCustomerPayment', d.id, 'Оплата від покупця ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 121 from doc_customer_payment d
union all select 'DocGoodsTransfer', d.id, 'Переміщення товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 131 from doc_goods_transfer d
union all select 'DocGoodsWriteOff', d.id, 'Списання товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 141 from doc_goods_write_off d
union all select 'DocCustomerOrder', d.id, 'Замовлення клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 261 from doc_customer_order d
union all select 'DocSupplierOrder', d.id, 'Замовлення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 271 from doc_supplier_order d
union all select 'DocCustomerReturn', d.id, 'Повернення від клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 281 from doc_customer_return d
union all select 'DocSupplierReturn', d.id, 'Повернення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 291 from doc_supplier_return d
union all select 'DocInventoryCount', d.id, 'Інвентаризація ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 301 from doc_inventory_count d
union all select 'DocSurplusPosting', d.id, 'Оприбуткування надлишків ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 311 from doc_surplus_posting d;

-- Вільні залишки: залишок − резерви
create or replace view v_free_stock as
select w.id warehouse_id, w.name warehouse_name, p.id product_id, p.code product_code, p.name product_name, u.short_name unit_name,
       coalesce(s.qty, 0) stock_qty, coalesce(r.qty, 0) reserved_qty, coalesce(s.qty, 0) - coalesce(r.qty, 0) free_qty
  from (select warehouse_id, product_id, sum(quantity) qty from reg_stock_balance_movement group by warehouse_id, product_id) s
  full join (select warehouse_id, product_id, sum(quantity) qty from reg_stock_reserve_mv group by warehouse_id, product_id) r
    on r.warehouse_id = s.warehouse_id and r.product_id = s.product_id
  join ref_warehouse w on w.id = coalesce(s.warehouse_id, r.warehouse_id)
  join ref_product p on p.id = coalesce(s.product_id, r.product_id)
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 where coalesce(s.qty, 0) <> 0 or coalesce(r.qty, 0) <> 0;

-- Резерви за замовленнями
create or replace view v_stock_reserve as
select o.id order_id, o.doc_number order_number, c.name customer_name, w.name warehouse_name, p.name product_name,
       u.short_name unit_name, sum(m.quantity) reserved_qty
  from reg_stock_reserve_mv m
  join doc_customer_order o on o.id = m.customer_order_id
  join ref_counterparty c on c.id = o.customer_id
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by o.id, o.doc_number, c.name, w.name, p.name, u.short_name
having sum(m.quantity) <> 0;

-- Аналіз замовлень клієнтів: замовлено / відвантажено / залишок
create or replace view v_customer_orders_analysis as
select o.id order_id, o.doc_number order_number, o.occurred_at, o.shipment_date, c.name customer_name, p.name product_name,
       u.short_name unit_name,
       sum(case when m.recorder_type = 'DocCustomerOrder' and m.line_number < 10000 then m.quantity else 0 end) ordered_qty,
       -sum(case when m.recorder_type = 'DocGoodsSale' then m.quantity else 0 end) shipped_qty,
       sum(m.quantity) remaining_qty,
       sum(m.amount) remaining_amount,
       case when o.closed = 'Y' then 'Закрите'
            when sum(sum(m.quantity)) over (partition by o.id) = 0 then 'Відвантажене'
            else 'До виконання' end order_state
  from reg_customer_orders_mv m
  join doc_customer_order o on o.id = m.customer_order_id
  join ref_counterparty c on c.id = o.customer_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by o.id, o.doc_number, o.occurred_at, o.shipment_date, o.closed, c.name, p.name, u.short_name;

create or replace view v_supplier_orders_analysis as
select o.id order_id, o.doc_number order_number, o.occurred_at, o.expected_date, s.name supplier_name, p.name product_name,
       u.short_name unit_name,
       sum(case when m.recorder_type = 'DocSupplierOrder' and m.line_number < 10000 then m.quantity else 0 end) ordered_qty,
       -sum(case when m.recorder_type = 'DocGoodsReceipt' then m.quantity else 0 end) received_qty,
       sum(m.quantity) remaining_qty,
       sum(m.amount) remaining_amount,
       case when o.closed = 'Y' then 'Закрите'
            when sum(sum(m.quantity)) over (partition by o.id) = 0 then 'Отримане'
            else 'До виконання' end order_state
  from reg_supplier_orders_mv m
  join doc_supplier_order o on o.id = m.supplier_order_id
  join ref_counterparty s on s.id = o.supplier_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by o.id, o.doc_number, o.occurred_at, o.expected_date, o.closed, s.name, p.name, u.short_name;

-- Ціни постачальників: зріз останніх
create or replace view v_supplier_price_current as
select s.name supplier_name, p.code product_code, p.name product_name, u.short_name unit_name, x.price, x.period
  from (select supplier_id, product_id,
               max(price) keep (dense_rank last order by period, id) price, max(period) period
          from reg_supplier_price group by supplier_id, product_id) x
  join ref_counterparty s on s.id = x.supplier_id
  join ref_product p on p.id = x.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id;

-- Вартість запасів (середня ковзна)
create or replace view v_stock_cost_balance as
select w.name warehouse_name, p.code product_code, p.name product_name, u.short_name unit_name,
       sum(m.quantity) quantity, sum(m.cost_amount) cost_amount,
       case when sum(m.quantity) > 0 then round(sum(m.cost_amount) / sum(m.quantity), 2) end avg_cost
  from reg_stock_cost_mv m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by w.name, p.code, p.name, u.short_name
having sum(m.quantity) <> 0 or sum(m.cost_amount) <> 0;

-- Валовий прибуток: виручка (RegSales) − собівартість продажу (RegStockCost) по рядках реєстратора
create or replace view v_gross_profit as
select s.period, s.recorder_type, s.recorder_id, r.recorder_name, r.page_id,
       c.name customer_name, p.name product_name, u.short_name unit_name,
       s.quantity, s.amount revenue,
       coalesce(-cm.cost_amount, 0) cost,
       s.amount - coalesce(-cm.cost_amount, 0) gross_profit
  from reg_sales_turnover s
  left join reg_stock_cost_mv cm
    on cm.recorder_type = s.recorder_type and cm.recorder_id = s.recorder_id and cm.line_number = s.line_number
  join ref_counterparty c on c.id = s.counterparty_id
  join ref_product p on p.id = s.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join v_recorder r on r.recorder_type = s.recorder_type and r.recorder_id = s.recorder_id;

-- Потреба в закупівлі за мін/макс
create or replace view v_purchase_need as
select x.*,
       case when x.available_qty <= x.min_quantity
            then case when x.fractional = 'N' then ceil(x.max_quantity - x.available_qty) else x.max_quantity - x.available_qty end
            else 0 end need_qty
  from (select rp.id policy_id, w.name warehouse_name, p.name product_name, u.short_name unit_name, u.fractional,
               rp.min_quantity, rp.max_quantity, sup.name supplier_name,
               coalesce((select sum(quantity) from reg_stock_balance_movement m where m.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0) stock_qty,
               coalesce((select sum(quantity) from reg_stock_reserve_mv m where m.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0) reserved_qty,
               coalesce((select sum(m.quantity) from reg_supplier_orders_mv m join doc_supplier_order o on o.id = m.supplier_order_id
                          where o.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0) on_order_qty,
               coalesce((select sum(quantity) from reg_stock_balance_movement m where m.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0)
             - coalesce((select sum(quantity) from reg_stock_reserve_mv m where m.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0)
             + coalesce((select sum(m.quantity) from reg_supplier_orders_mv m join doc_supplier_order o on o.id = m.supplier_order_id
                          where o.warehouse_id = rp.warehouse_id and m.product_id = rp.product_id), 0) available_qty
          from reg_reorder_policy rp
          join ref_warehouse w on w.id = rp.warehouse_id
          join ref_product p on p.id = rp.product_id
          join ref_unit_of_measure u on u.id = p.unit_of_measure_id
          left join ref_counterparty sup on sup.id = rp.preferred_supplier_id
         where rp.reorder_method = 'MIN_MAX') x;

-- Група з повним шляхом
create or replace view v_product_group_path as
select id, code, name, parent_id, state, level group_level,
       substr(sys_connect_by_path(name, ' / '), 4) full_path
  from ref_product_group
 start with parent_id is null
 connect by prior id = parent_id;

-- -----------------------------------------------------------------------------
-- Основне меню й панель функцій r3
-- -----------------------------------------------------------------------------
declare
  procedure obj (p_tech varchar2, p_kind varchar2, p_name varchar2, p_section varchar2, p_list number, p_form number, p_sort number) is
  begin
    insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order)
    select p_tech, p_kind, p_name, id, p_list, p_form, p_sort from sys_main_menu_section where tech_name = p_section;
  end;
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_object varchar2, p_sort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_sort, p_imp
      from sys_main_menu_section s, sys_metadata_object o where s.tech_name = p_section and o.tech_name = p_object;
  end;
begin
  obj('RefProductGroup', 'CATALOG', 'Групи номенклатури', 'Catalogs', 170, 171, 60);
  obj('RefContract', 'CATALOG', 'Договори контрагентів', 'Catalogs', 180, 181, 70);
  obj('RegBarcode', 'INFORMATION_REGISTER', 'Штрихкоди номенклатури', 'Reports', 190, null, 50);
  obj('RegSupplierPrice', 'INFORMATION_REGISTER', 'Ціни постачальників', 'Reports', 200, null, 60);
  obj('RegReorderPolicy', 'INFORMATION_REGISTER', 'Параметри забезпечення запасів', 'Reports', 210, null, 70);
  obj('RegStockReserve', 'ACCUMULATION_REGISTER', 'Резерви та вільні залишки', 'Reports', 220, null, 80);
  obj('RegCustomerOrders', 'ACCUMULATION_REGISTER', 'Аналіз замовлень клієнтів', 'Reports', 230, null, 90);
  obj('RegSupplierOrders', 'ACCUMULATION_REGISTER', 'Аналіз замовлень постачальникам', 'Reports', 240, null, 100);
  obj('RegStockCost', 'ACCUMULATION_REGISTER', 'Вартість запасів і валовий прибуток', 'Reports', 250, null, 110);
  obj('DocCustomerOrder', 'DOCUMENT', 'Замовлення клієнтів', 'Documents', 260, 261, 70);
  obj('DocSupplierOrder', 'DOCUMENT', 'Замовлення постачальникам', 'Documents', 270, 271, 80);
  obj('DocCustomerReturn', 'DOCUMENT', 'Повернення від клієнтів', 'Documents', 280, 281, 90);
  obj('DocSupplierReturn', 'DOCUMENT', 'Повернення постачальникам', 'Documents', 290, 291, 100);
  obj('DocInventoryCount', 'DOCUMENT', 'Інвентаризація товарів', 'Documents', 300, 301, 110);
  obj('DocSurplusPosting', 'DOCUMENT', 'Оприбуткування надлишків', 'Documents', 310, 311, 120);
  obj('DocInvoiceForPayment', 'DOCUMENT', 'Рахунки на оплату', 'Documents', 320, 321, 130);

  -- Продажі
  fp('Sales', 'Продажі', 1, 5, 'DocCustomerOrder', 5, 'Y');
  fp('Sales', 'Продажі', 1, 10, 'DocInvoiceForPayment', 15);
  fp('Sales', 'Продажі', 1, 10, 'DocCustomerReturn', 30);
  fp('Sales', 'Звіти', 2, 10, 'RegCustomerOrders', 30);
  fp('Sales', 'Звіти', 2, 10, 'RegStockCost', 40);
  fp('Sales', 'Звіти', 2, 10, 'RegStockReserve', 50);
  fp('Sales', 'НСІ', 3, 10, 'RefContract', 30);
  -- Закупівлі
  fp('Purchases', 'Закупівлі', 1, 10, 'DocSupplierOrder', 5, 'Y');
  fp('Purchases', 'Закупівлі', 1, 10, 'DocSupplierReturn', 30);
  fp('Purchases', 'Звіти', 2, 10, 'RegSupplierOrders', 20);
  fp('Purchases', 'Звіти', 2, 10, 'RegSupplierPrice', 30);
  fp('Purchases', 'Звіти', 2, 10, 'RegReorderPolicy', 40);
  fp('Purchases', 'НСІ', 3, 10, 'RefContract', 20);
  -- Склад
  fp('Warehouse', 'Складські операції', 1, 10, 'DocInventoryCount', 30);
  fp('Warehouse', 'Складські операції', 1, 10, 'DocSurplusPosting', 40);
  fp('Warehouse', 'Звіти', 2, 10, 'RegStockReserve', 20);
  fp('Warehouse', 'Звіти', 2, 10, 'RegStockCost', 30);
  fp('Warehouse', 'НСІ', 3, 10, 'RegReorderPolicy', 30);
  fp('Warehouse', 'НСІ', 3, 10, 'RegBarcode', 40);
  -- Ціноутворення
  fp('Pricing', 'Звіти', 2, 10, 'RegSupplierPrice', 20);
  -- НСІ
  fp('Reference', 'Номенклатура', 1, 10, 'RefProductGroup', 15);
  fp('Reference', 'Номенклатура', 1, 10, 'RegBarcode', 30);
  fp('Reference', 'Партнери', 1, 20, 'RefContract', 20);
  fp('Reference', 'Склади', 1, 30, 'RegReorderPolicy', 20);
  -- Головне
  fp('Main', 'Продажі', 1, 10, 'DocCustomerOrder', 5);
  fp('Main', 'Склад', 1, 25, 'DocInventoryCount', 10);
  fp('Main', 'Звіти', 2, 10, 'RegStockCost', 40);
end;
/
commit;
