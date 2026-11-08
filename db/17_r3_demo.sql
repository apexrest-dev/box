-- =============================================================================
-- Trade r3 — демонстраційні дані (магазин продуктів і техніки).
-- Документи проводяться штатними процедурами (усі перевірки діють).
-- =============================================================================
set serveroutput on
declare
  l_wh  varchar2(32); l_wh2 varchar2(32);
  l_retail varchar2(32); l_whole varchar2(32);
  l_kg varchar2(32); l_pcs varchar2(32); l_l varchar2(32);
  l_sup1 varchar2(32); l_sup2 varchar2(32); l_cus1 varchar2(32); l_cus2 varchar2(32);
  g_food varchar2(32); g_groc varchar2(32); g_oil varchar2(32); g_tech varchar2(32); g_small varchar2(32); g_srv varchar2(32);
  p_sugar varchar2(32); p_oil varchar2(32); p_kettle varchar2(32); p_flour varchar2(32);
  p_rice varchar2(32); p_buck varchar2(32); p_micro varchar2(32); p_toast varchar2(32); p_deliv varchar2(32);
  c_cus1 varchar2(32); c_cus2 varchar2(32); c_sup1 varchar2(32); c_sup2 varchar2(32);
  d varchar2(32); o1 varchar2(32); o2 varchar2(32); so varchar2(32); s1 varchar2(32); r1 varchar2(32); inv varchar2(32); x varchar2(32);

  function ean13 (p12 varchar2) return varchar2 is
    s pls_integer := 0;
  begin
    for i in 1 .. 12 loop s := s + to_number(substr(p12, i, 1)) * case when mod(i, 2) = 0 then 3 else 1 end; end loop;
    return p12 || mod(10 - mod(s, 10), 10);
  end;
  function prod (p_name varchar2, p_uom varchar2, p_group varchar2, p_article varchar2, p_kind varchar2 default 'GOODS') return varchar2 is
    l varchar2(32);
  begin
    insert into ref_product (name, unit_of_measure_id, group_id, article, product_kind)
    values (p_name, p_uom, p_group, p_article, p_kind) returning id into l;
    return l;
  end;
  procedure bc (p12 varchar2, p_prd varchar2, p_qty number default 1) is
    l_code varchar2(13) := ean13(p12);
  begin
    insert into reg_barcode (barcode, product_id, unit_quantity) values (l_code, p_prd, p_qty);
  end;
  procedure line (p_tab varchar2, p_doc varchar2, p_prd varchar2, p_qty number, p_price number) is
  begin
    execute immediate 'insert into ' || p_tab || ' (document_id, product_id, quantity, price) values (:d, :p, :q, :c)'
      using p_doc, p_prd, p_qty, p_price;
  end;
begin
  -- Реквізити підприємства
  merge into sys_company_settings t using (select 'X' id from dual) s on (t.id = s.id)
  when not matched then insert (id, name, edrpou, iban, bank_name, address, phone, director_name, accountant_name, min_markup_percent)
  values ('X', 'ТОВ «Трейд Демо»', '12345678', 'UA213223130000026007233566001', 'АТ «Демо Банк»',
          'м. Київ, вул. Хрещатик, 1', '+380 44 000 00 00', 'Петренко П. П.', 'Сидоренко О. О.', 10);

  select id into l_wh  from ref_warehouse where name = 'Основний склад';
  select id into l_wh2 from ref_warehouse where name = 'Склад магазину';
  select id into l_retail from ref_price_type where name = 'Роздрібна';
  select id into l_whole  from ref_price_type where name = 'Оптова';
  select id into l_kg  from ref_unit_of_measure where short_name = 'кг';
  select id into l_pcs from ref_unit_of_measure where short_name = 'шт';
  select id into l_l   from ref_unit_of_measure where short_name = 'л';
  select id into l_sup1 from ref_counterparty where name = 'ТОВ «Постачальник»';
  select id into l_sup2 from ref_counterparty where name = 'ФОП Іваненко І. І.';
  select id into l_cus1 from ref_counterparty where name = 'ТОВ «Покупець»';
  insert into ref_counterparty (name) values ('ТОВ «Магазин Колосок»') returning id into l_cus2;

  -- Групи номенклатури
  insert into ref_product_group (name, sort_order) values ('Продукти харчування', 10) returning id into g_food;
  insert into ref_product_group (name, parent_id, sort_order) values ('Бакалія', g_food, 10) returning id into g_groc;
  insert into ref_product_group (name, parent_id, sort_order) values ('Олії', g_food, 20) returning id into g_oil;
  insert into ref_product_group (name, sort_order) values ('Побутова техніка', 20) returning id into g_tech;
  insert into ref_product_group (name, parent_id, sort_order) values ('Дрібна техніка для кухні', g_tech, 10) returning id into g_small;
  insert into ref_product_group (name, sort_order) values ('Послуги', 30) returning id into g_srv;

  -- Номенклатура: наявна + нова
  select id into p_sugar  from ref_product where name = 'Цукор білий';
  select id into p_oil    from ref_product where name = 'Олія соняшникова';
  select id into p_kettle from ref_product where name = 'Чайник електричний';
  select id into p_flour  from ref_product where name = 'Борошно пшеничне';
  update ref_product set group_id = g_groc, article = 'BK-001' where id = p_sugar;
  update ref_product set group_id = g_groc, article = 'BK-002' where id = p_flour;
  update ref_product set group_id = g_oil,  article = 'OL-001' where id = p_oil;
  update ref_product set group_id = g_small, article = 'KT-100', weight_kg = 1.2 where id = p_kettle;
  p_rice  := prod('Рис довгозернистий', l_kg, g_groc, 'BK-003');
  p_buck  := prod('Гречка ядриця', l_kg, g_groc, 'BK-004');
  p_micro := prod('Мікрохвильова піч', l_pcs, g_small, 'KT-200');
  p_toast := prod('Тостер', l_pcs, g_small, 'KT-300');
  p_deliv := prod('Доставка по місту', l_pcs, g_srv, 'SRV-01', 'SERVICE');

  -- Штрихкоди
  bc('482000100001', p_sugar);
  bc('482000100002', p_flour);
  bc('482000100003', p_rice);
  bc('482000100004', p_buck);
  bc('482000100005', p_oil);
  bc('482000200001', p_kettle);
  bc('482000200002', p_micro);
  bc('482000200003', p_toast);
  bc('482000100010', p_sugar, 10);   -- мішок 10 кг

  -- Договори
  insert into ref_contract (owner_id, name, contract_number, contract_date, contract_kind, price_type_id, payment_term_days, credit_limit, valid_from)
  values (l_cus1, 'Договір поставки (роздріб)', 'П-15/2026', date '2026-01-15', 'WITH_CUSTOMER', l_retail, 14, 50000, date '2026-01-15') returning id into c_cus1;
  insert into ref_contract (owner_id, name, contract_number, contract_date, contract_kind, price_type_id, payment_term_days, credit_limit, valid_from)
  values (l_cus2, 'Договір оптового постачання', 'О-03/2026', date '2026-03-01', 'WITH_CUSTOMER', l_whole, 30, 100000, date '2026-03-01') returning id into c_cus2;
  insert into ref_contract (owner_id, name, contract_number, contract_date, contract_kind, payment_term_days)
  values (l_sup1, 'Договір закупівлі продуктів', 'З-07/2026', date '2026-02-01', 'WITH_SUPPLIER', 7) returning id into c_sup1;
  insert into ref_contract (owner_id, name, contract_number, contract_date, contract_kind, payment_term_days)
  values (l_sup2, 'Договір закупівлі техніки', 'З-11/2026', date '2026-02-10', 'WITH_SUPPLIER', 10) returning id into c_sup2;

  -- Ціни продажу
  insert into doc_price_setting (occurred_at, price_type_id, doc_comment) values (sysdate - 10, l_retail, 'Роздрібні ціни r3') returning id into d;
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_flour, 32);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_rice, 68);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_buck, 55);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_oil, 85);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_micro, 3999);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_toast, 1299);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_deliv, 150);
  trade_ops.post_price_setting(d);
  insert into doc_price_setting (occurred_at, price_type_id, doc_comment) values (sysdate - 10, l_whole, 'Оптові ціни r3') returning id into d;
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_sugar, 18);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_flour, 27);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_rice, 58);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_buck, 46);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_oil, 72);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_micro, 3600);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_toast, 1150);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_kettle, 560);
  insert into doc_price_setting_prices (document_id, product_id, price) values (d, p_deliv, 120);
  trade_ops.post_price_setting(d);

  -- Параметри забезпечення запасів (Основний склад)
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id, lead_time_days) values (l_wh, p_rice, 50, 200, l_sup1, 3);
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id, lead_time_days) values (l_wh, p_buck, 50, 200, l_sup1, 3);
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id, lead_time_days) values (l_wh, p_flour, 40, 150, l_sup1, 3);
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id, lead_time_days) values (l_wh, p_micro, 3, 10, l_sup2, 7);
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id, lead_time_days) values (l_wh, p_toast, 5, 15, l_sup2, 7);

  -- Закупівля: замовлення постачальникам → надходження
  insert into doc_supplier_order (occurred_at, supplier_id, contract_id, warehouse_id, expected_date, doc_comment)
  values (sysdate - 9, l_sup1, c_sup1, l_wh, trunc(sysdate - 7), 'Поповнення бакалії') returning id into so;
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_rice, 150, 45);
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_buck, 120, 36);
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_flour, 100, 21);
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_oil, 60, 58);
  trade_r3.post_supplier_order(so);
  x := trade_r3.receipt_from_order(so);
  update doc_goods_receipt set occurred_at = sysdate - 7 where id = x;
  update doc_goods_receipt_goods set quantity = 100 where document_id = x and product_id = p_rice;   -- частково
  trade_doc.post_goods_receipt(x);
  r1 := x;

  insert into doc_supplier_order (occurred_at, supplier_id, contract_id, warehouse_id, expected_date, doc_comment)
  values (sysdate - 8, l_sup2, c_sup2, l_wh, trunc(sysdate - 6), 'Техніка до сезону') returning id into so;
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_micro, 8, 2950);
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_toast, 12, 880);
  line('DOC_SUPPLIER_ORDER_GOODS', so, p_kettle, 10, 420);
  trade_r3.post_supplier_order(so);
  x := trade_r3.receipt_from_order(so);
  update doc_goods_receipt set occurred_at = sysdate - 6 where id = x;
  trade_doc.post_goods_receipt(x);

  -- Продажі: замовлення клієнта з резервом → часткова реалізація → рахунок
  insert into doc_customer_order (occurred_at, customer_id, warehouse_id, shipment_date, doc_comment)
  values (sysdate - 5, l_cus2, l_wh, trunc(sysdate - 3), 'Оптове замовлення') returning id into o1;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, discount_percent, reserve_flag) values (o1, p_rice, 40, null, 5, 'Y');
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, discount_percent, reserve_flag) values (o1, p_buck, 30, null, 5, 'Y');
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (o1, p_micro, 2, null, 'Y');
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (o1, p_deliv, 1, null, 'N');
  trade_r3.post_customer_order(o1);
  x := trade_r3.invoice_from_order(o1);
  update doc_invoice_for_payment set occurred_at = sysdate - 5 + 1/24 where id = x;
  trade_r3.issue_invoice(x);
  s1 := trade_r3.sale_from_order(o1);
  update doc_goods_sale set occurred_at = sysdate - 4 where id = s1;
  update doc_goods_sale_goods set quantity = 25 where document_id = s1 and product_id = p_rice;   -- частково, решта в резерві
  trade_ops.post_goods_sale(s1);

  insert into doc_customer_order (occurred_at, customer_id, contract_id, warehouse_id, shipment_date)
  values (sysdate - 3, l_cus1, c_cus1, l_wh, trunc(sysdate + 2)) returning id into o2;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (o2, p_toast, 3, null, 'Y');
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (o2, p_kettle, 2, 650, 'N');
  trade_r3.post_customer_order(o2);

  -- Роздрібна реалізація без замовлення
  insert into doc_goods_sale (occurred_at, customer_id, warehouse_id, price_type_id, contract_id)
  values (sysdate - 2, l_cus1, l_wh, l_retail, c_cus1) returning id into x;
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (x, p_flour, 12);
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (x, p_oil, 6);
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (x, p_toast, 2);
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (x, p_deliv, 1);
  trade_ops.post_goods_sale(x);

  -- Повернення від клієнта (1 тостер)
  d := trade_r3.customer_return_from_sale(x);
  update doc_customer_return set occurred_at = sysdate - 1, return_reason = 'Брак: не вмикається' where id = d;
  delete from doc_customer_return_goods where document_id = d and product_id <> p_toast;
  update doc_customer_return_goods set quantity = 1 where document_id = d;
  trade_r3.post_customer_return(d);

  -- Оплата від покупця за оптове замовлення
  insert into doc_customer_payment (occurred_at, customer_id, amount, doc_comment) values (sysdate - 3, l_cus2, 5000, 'Часткова оплата рахунку') returning id into d;
  trade_ops.post_customer_payment(d);

  -- Повернення постачальнику (5 кг олії — пошкоджена тара)
  d := trade_r3.supplier_return_from_receipt(r1);
  update doc_supplier_return set occurred_at = sysdate - 6, return_reason = 'Пошкоджена тара' where id = d;
  delete from doc_supplier_return_goods where document_id = d and product_id <> p_oil;
  update doc_supplier_return_goods set quantity = 5 where document_id = d;
  trade_r3.post_supplier_return(d);

  -- Інвентаризація Основного складу → надлишки й недостачі
  insert into doc_inventory_count (occurred_at, warehouse_id, responsible_person) values (sysdate - 1 + 2/24, l_wh, 'Коваленко М. В.') returning id into inv;
  trade_r3.fill_with_book_balances(inv);
  update doc_inventory_count_goods set actual_quantity = book_quantity where document_id = inv;
  update doc_inventory_count_goods set actual_quantity = book_quantity + 2 where document_id = inv and product_id = p_buck;
  update doc_inventory_count_goods set actual_quantity = book_quantity - 3 where document_id = inv and product_id = p_flour;
  trade_r3.post_inventory_count(inv);
  x := trade_r3.surplus_from_inventory(inv);
  trade_r3.post_surplus_posting(x);
  x := trade_r3.write_off_from_inventory(inv);
  trade_ops.post_goods_write_off(x);

  -- Чернетка замовлення постачальнику «за потребою»
  insert into doc_supplier_order (occurred_at, supplier_id, contract_id, warehouse_id, expected_date, doc_comment)
  values (sysdate, l_sup2, c_sup2, l_wh, trunc(sysdate + 7), 'Сформовано за потребою') returning id into so;
  begin
    trade_r3.fill_by_reorder_policy(so);
  exception when others then dbms_output.put_line('Потреби немає: ' || sqlerrm);
  end;

  commit;
  dbms_output.put_line('Демо-дані r3 завантажено.');
end;
/
