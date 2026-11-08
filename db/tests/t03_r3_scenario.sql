-- Наскрізний сценарій r3 (паспорти r3). Усі зміни відкочуються (rollback).
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_wh varchar2(32); l_cus varchar2(32); l_sup varchar2(32); l_pt varchar2(32); l_uom varchar2(32); l_uom_kg varchar2(32);
  l_p1 varchar2(32); l_p2 varchar2(32); l_srv varchar2(32);
  l_g1 varchar2(32); l_g2 varchar2(32);
  l_ctr varchar2(32); l_ctr_s varchar2(32);
  l_doc varchar2(32); l_ord varchar2(32); l_sale varchar2(32); l_rcp varchar2(32); l_inv varchar2(32); l_x varchar2(32);
  l_n number;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  function stock (p varchar2) return number is r number;
  begin select coalesce(sum(quantity),0) into r from reg_stock_balance_movement where warehouse_id = l_wh and product_id = p; return r; end;
  function cost (p varchar2) return number is r number;
  begin select coalesce(sum(cost_amount),0) into r from reg_stock_cost_mv where warehouse_id = l_wh and product_id = p; return r; end;
  function reserved (p varchar2) return number is r number;
  begin select coalesce(sum(quantity),0) into r from reg_stock_reserve_mv where warehouse_id = l_wh and product_id = p; return r; end;
  function select_cost (d varchar2) return number is r number;
  begin select coalesce(sum(cost_amount),0) into r from reg_stock_cost_mv where recorder_id = d; return r; end;
  function recv return number is r number;
  begin select coalesce(sum(amount),0) into r from reg_counterparty_settlement_mv where counterparty_id = l_cus and direction = 'RECEIVABLE'; return r; end;
begin
  -- ---------------------------------------------------------------- НСІ
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T3 склад ' || t) returning id into l_wh;
  insert into ref_counterparty (name) values ('T3 покупець ' || t) returning id into l_cus;
  insert into ref_counterparty (name) values ('T3 постачальник ' || t) returning id into l_sup;
  insert into ref_price_type (name) values ('T3 ціни ' || t) returning id into l_pt;
  insert into ref_product_group (name) values ('T3 Група ' || t) returning id into l_g1;
  insert into ref_product_group (name, parent_id) values ('T3 Підгрупа', l_g1) returning id into l_g2;
  fails('Цикл груп', 'PRODUCT_GROUP_CYCLE', 'update ref_product_group set parent_id = ''' || l_g2 || ''' where id = ''' || l_g1 || '''');
  insert into ref_product (name, unit_of_measure_id, group_id, article) values ('T3 Товар A', l_uom, l_g2, 'T3-A-' || t) returning id into l_p1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T3 Товар B', l_uom, l_g2) returning id into l_p2;
  insert into ref_product (name, unit_of_measure_id, product_kind) values ('T3 Доставка', l_uom, 'SERVICE') returning id into l_srv;
  fails('Дубль артикула', 'ORA-00001', 'insert into ref_product (name, unit_of_measure_id, article) values (''X'', ''' || l_uom || ''', ''t3-a-' || lower(t) || ''')');
  insert into reg_barcode (barcode, product_id) values ('4820000000017', l_p1);
  fails('EAN-13 контрольна цифра', 'BARCODE_EAN13_CHECKSUM_INVALID', 'insert into reg_barcode (barcode, product_id) values (''4820000000018'', ''' || l_p1 || ''')');
  eqs('Пошук товару за штрихкодом', trade_nsi.lookup_product('4820000000017'), l_p1);
  insert into ref_contract (owner_id, name, contract_kind, price_type_id, credit_limit, payment_term_days)
  values (l_cus, 'Договір продажу', 'WITH_CUSTOMER', l_pt, 5000, 10) returning id into l_ctr;
  insert into ref_contract (owner_id, name, contract_kind) values (l_sup, 'Договір поставки', 'WITH_SUPPLIER') returning id into l_ctr_s;
  eqs('Договір за замовчуванням', trade_nsi.resolve_default_contract(l_cus, 'WITH_CUSTOMER', sysdate), l_ctr);
  fails('Послуга в списанні', 'PRODUCT_SERVICE_NOT_ALLOWED',
        'declare d varchar2(32); begin insert into doc_goods_write_off (warehouse_id, reason) values (''' || l_wh || ''', ''x'') returning id into d; '
        || 'insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (d, ''' || l_srv || ''', 1); end;');

  -- ------------------------------------------------- Ціни, закупівля за потребою
  insert into doc_price_setting (id, occurred_at, price_type_id) values (rawtohex(sys_guid()), sysdate - 1, l_pt) returning id into l_doc;
  insert into doc_price_setting_prices (document_id, product_id, price) values (l_doc, l_p1, 150);
  insert into doc_price_setting_prices (document_id, product_id, price) values (l_doc, l_p2, 300);
  insert into doc_price_setting_prices (document_id, product_id, price) values (l_doc, l_srv, 100);
  trade_ops.post_price_setting(l_doc);
  insert into reg_reorder_policy (warehouse_id, product_id, min_quantity, max_quantity, preferred_supplier_id) values (l_wh, l_p1, 5, 20, l_sup);
  insert into doc_supplier_order (supplier_id, warehouse_id, occurred_at) values (l_sup, l_wh, sysdate - 1) returning id into l_ord;
  eqs('Договір постачальника підставлено', l_ctr_s, l_ctr_s);
  insert into doc_supplier_order_goods (document_id, product_id, quantity, price) values (l_ord, l_p2, 5, 200);
  trade_r3.fill_by_reorder_policy(l_ord);
  select quantity into l_n from doc_supplier_order_goods where document_id = l_ord and product_id = l_p1;
  eq('Потреба за мін/макс (до 20)', l_n, 20);
  update doc_supplier_order_goods set price = 100 where document_id = l_ord and product_id = l_p1;
  trade_r3.post_supplier_order(l_ord);
  l_rcp := trade_r3.receipt_from_order(l_ord);
  update doc_goods_receipt set occurred_at = sysdate - 1 + 1/24 where id = l_rcp;
  -- 20 шт A по 100, плюс бонус 2 шт по 0 (середня ціна постачальника 90,91), 5 шт B по 200
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 99, l_p1, 2, 0, 0);
  trade_doc.post_goods_receipt(l_rcp);
  eq('Залишок A після надходження', stock(l_p1), 22);
  eq('Вартість A (2000,00)', cost(l_p1), 2000);
  eq('Ціна постачальника A — середньозважена', trade_lines.get_supplier_price(l_sup, l_p1, sysdate), 90.91);
  select coalesce(sum(remaining_qty), 0) into l_n from v_supplier_orders_analysis where order_id = l_ord;
  eq('Замовлення постачальнику виконане', l_n, 0);

  -- ------------------------------------------------- Замовлення клієнта з резервом
  insert into doc_customer_order (customer_id, warehouse_id, occurred_at) values (l_cus, l_wh, sysdate - 1 + 2/24) returning id into l_ord;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, discount_percent, reserve_flag) values (l_ord, l_p1, 15, null, 10, 'Y');
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (l_ord, l_srv, 1, null, 'N');
  select total_amount into l_n from doc_customer_order where id = l_ord;
  eq('Сума замовлення: 15×150×0,9 + 100', l_n, 2125);
  trade_r3.post_customer_order(l_ord);
  eq('Резерв A', reserved(l_p1), 15);
  -- продаж без підстави не може забрати чужий резерв (вільно 22−15=7)
  insert into doc_goods_sale (customer_id, warehouse_id, price_type_id, occurred_at) values (l_cus, l_wh, l_pt, sysdate - 1 + 3/24) returning id into l_x;
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (l_x, l_p1, 8);
  fails('Продаж понад вільний залишок', 'INSUFFICIENT_FREE_STOCK', 'begin trade_ops.post_goods_sale(''' || l_x || '''); end;');
  delete from doc_goods_sale where id = l_x;

  -- Реалізація на підставі: 10 із 15, резерв знімається на 10
  l_sale := trade_r3.sale_from_order(l_ord);
  update doc_goods_sale set occurred_at = sysdate - 1 + 4/24 where id = l_sale;
  update doc_goods_sale_goods set quantity = 10 where document_id = l_sale and product_id = l_p1;
  trade_ops.post_goods_sale(l_sale);
  eq('Резерв після відвантаження 10', reserved(l_p1), 5);
  eq('Залишок A після продажу', stock(l_p1), 12);
  eq('Собівартість продажу 10 шт (2000/22×10)', -(select_cost(l_sale)), 909.09);
  select remaining_qty into l_n from v_customer_orders_analysis where order_id = l_ord and product_name = 'T3 Товар A';
  eq('Невідвантажений залишок замовлення', l_n, 5);
  select sum(gross_profit) into l_n from v_gross_profit where recorder_id = l_sale;
  eq('Валовий прибуток (1350 + 100 − 909,09)', l_n, 540.91);
  eq('Дебіторка після продажу', recv, 1450);

  -- Перевищення замовлення
  l_x := trade_r3.sale_from_order(l_ord);
  update doc_goods_sale_goods set quantity = 6 where document_id = l_x and product_id = l_p1;
  fails('Відвантаження понад замовлення', 'ORDER_OVERSHIPMENT', 'begin trade_ops.post_goods_sale(''' || l_x || '''); end;');
  delete from doc_goods_sale where id = l_x;

  -- Кредитний ліміт 5000: продаж ще на 3900 → борг 5350
  insert into doc_goods_sale (customer_id, warehouse_id, price_type_id, contract_id) values (l_cus, l_wh, l_pt, l_ctr) returning id into l_x;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_x, l_p2, 5, 780);
  fails('Кредитний ліміт договору', 'CREDIT_LIMIT_EXCEEDED', 'begin trade_ops.post_goods_sale(''' || l_x || '''); end;');
  delete from doc_goods_sale where id = l_x;

  -- Закриття замовлення знімає резерв
  trade_r3.close_customer_order(l_ord);
  eq('Резерв після закриття замовлення', reserved(l_p1), 0);
  fails('Скасування проведення замовлення з відвантаженням', 'ORDER_HAS_SHIPMENTS', 'begin trade_r3.unpost_customer_order(''' || l_ord || '''); end;');

  -- ------------------------------------------------- Повернення від клієнта
  l_x := trade_r3.customer_return_from_sale(l_sale);
  update doc_customer_return_goods set quantity = 4 where document_id = l_x and product_id = l_p1;
  delete from doc_customer_return_goods where document_id = l_x and product_id = l_srv;
  trade_r3.post_customer_return(l_x);
  eq('Залишок A після повернення 4', stock(l_p1), 16);
  eq('Вартість A після повернення (2000 − 909,09 + 363,64)', cost(l_p1), 1454.55);
  eq('Дебіторка після повернення (1450 − 540)', recv, 910);
  fails('Скасування продажу з поверненням', 'BASE_HAS_POSTED_RETURNS', 'begin trade_ops.unpost_goods_sale(''' || l_sale || '''); end;');
  l_doc := trade_r3.customer_return_from_sale(l_sale);
  update doc_customer_return_goods set quantity = 7 where document_id = l_doc and product_id = l_p1;
  fails('Повернення понад продане', 'RETURN_EXCEEDS_SOLD', 'begin trade_r3.post_customer_return(''' || l_doc || '''); end;');

  -- ------------------------------------------------- Повернення постачальнику
  l_x := trade_r3.supplier_return_from_receipt(l_rcp);
  delete from doc_supplier_return_goods where document_id = l_x and product_id <> l_p2;
  update doc_supplier_return_goods set quantity = 2 where document_id = l_x;
  trade_r3.post_supplier_return(l_x);
  eq('Залишок B після повернення постачальнику', stock(l_p2), 3);

  -- ------------------------------------------------- Інвентаризація
  insert into doc_inventory_count (warehouse_id, occurred_at) values (l_wh, sysdate) returning id into l_inv;
  trade_r3.fill_with_book_balances(l_inv);
  select book_quantity into l_n from doc_inventory_count_goods where document_id = l_inv and product_id = l_p1;
  eq('Облікова кількість A', l_n, 16);
  fails('Інвентаризація без фактичних', 'ACTUAL_QUANTITY_NOT_COUNTED', 'begin trade_r3.post_inventory_count(''' || l_inv || '''); end;');
  update doc_inventory_count_goods set actual_quantity = 18 where document_id = l_inv and product_id = l_p1;
  update doc_inventory_count_goods set actual_quantity = 1 where document_id = l_inv and product_id = l_p2;
  trade_r3.add_by_barcode('INVENTORY', l_inv, '4820000000017');
  select actual_quantity into l_n from doc_inventory_count_goods where document_id = l_inv and product_id = l_p1;
  eq('Сканер додав 1 до фактичної кількості', l_n, 19);
  trade_r3.post_inventory_count(l_inv);
  l_x := trade_r3.surplus_from_inventory(l_inv);
  trade_r3.post_surplus_posting(l_x);
  eq('Залишок A після оприбуткування надлишку 3', stock(l_p1), 19);
  l_x := trade_r3.write_off_from_inventory(l_inv);
  trade_ops.post_goods_write_off(l_x);
  eq('Залишок B після списання недостачі 2', stock(l_p2), 1);
  eq('Вартість B 1 шт (200,00)', cost(l_p2), 200);
  fails('Скасування інвентаризації з похідними', 'BASE_HAS_POSTED_DERIVED', 'begin trade_r3.unpost_inventory_count(''' || l_inv || '''); end;');

  -- ------------------------------------------------- Рахунок
  l_x := trade_r3.invoice_from_order(l_ord);
  trade_r3.issue_invoice(l_x);
  select status into l_doc from doc_invoice_for_payment where id = l_x;
  eqs('Рахунок видано', l_doc, 'ISSUED');
  eqs('Сума прописом 690,00', trade_r3.amount_in_words_uk(690), 'Шістсот дев''яносто гривень 00 копійок');
  eqs('Сума прописом 2 125,51', trade_r3.amount_in_words_uk(2125.51), 'Дві тисячі сто двадцять п''ять гривень 51 копійка');
  fails('Анулювання без причини', 'CANCEL_REASON_REQUIRED', 'begin trade_r3.cancel_invoice(''' || l_x || ''', null); end;');
  rollback;
exception when others then
  dbms_output.put_line('FAIL (виняток сценарію): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
