-- Наскрізний сценарій r2: ціни → надходження → реалізація → оплата покупця →
-- переміщення → списання. Усі зміни відкочуються (rollback) наприкінці.
set serveroutput on size unlimited feedback off
declare
  l_tag   varchar2(32) := rawtohex(sys_guid());
  l_wh    varchar2(32); l_wh2 varchar2(32); l_cus varchar2(32); l_sup varchar2(32);
  l_pt    varchar2(32); l_sugar varchar2(32); l_kettle varchar2(32);
  l_ps    varchar2(32) := rawtohex(sys_guid());
  l_ps2   varchar2(32) := rawtohex(sys_guid());
  l_rcp   varchar2(32) := rawtohex(sys_guid());
  l_sale  varchar2(32) := rawtohex(sys_guid());
  l_sale2 varchar2(32) := rawtohex(sys_guid());
  l_pay   varchar2(32) := rawtohex(sys_guid());
  l_pay2  varchar2(32) := rawtohex(sys_guid());
  l_tr    varchar2(32) := rawtohex(sys_guid());
  l_tr2   varchar2(32) := rawtohex(sys_guid());
  l_wo    varchar2(32) := rawtohex(sys_guid());
  l_wo2   varchar2(32) := rawtohex(sys_guid());
  l_num   number;

  function stock (p_wh varchar2, p_prd varchar2) return number is
    r number;
  begin
    select coalesce(sum(quantity), 0) into r from reg_stock_balance_movement where warehouse_id = p_wh and product_id = p_prd;
    return r;
  end;
  function receivable (p_cp varchar2) return number is
    r number;
  begin
    select coalesce(sum(amount), 0) into r from reg_counterparty_settlement_mv where counterparty_id = p_cp and direction = 'RECEIVABLE';
    return r;
  end;
  procedure check_eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure expect_fail (p_name varchar2, p_sql varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
  exception when others then
    dbms_output.put_line('OK   ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
begin
  insert into ref_warehouse (name) values ('Тестовий склад ' || l_tag) returning id into l_wh;
  insert into ref_warehouse (name) values ('Тестовий склад 2 ' || l_tag) returning id into l_wh2;
  insert into ref_counterparty (name) values ('Тестовий покупець ' || l_tag) returning id into l_cus;
  insert into ref_counterparty (name) values ('Тестовий постачальник ' || l_tag) returning id into l_sup;
  insert into ref_price_type (name) values ('Тестова ' || l_tag) returning id into l_pt;
  select id into l_sugar from ref_product where name = 'Цукор білий';
  select id into l_kettle from ref_product where name = 'Чайник електричний';

  -- Ціни: 20,00 сьогодні, 25,00 з завтрашнього дня
  insert into doc_price_setting (id, occurred_at, price_type_id) values (l_ps, sysdate - 1/24, l_pt);
  insert into doc_price_setting_prices (document_id, product_id, price) values (l_ps, l_sugar, 20);
  trade_ops.post_price_setting(l_ps);
  insert into doc_price_setting (id, occurred_at, price_type_id) values (l_ps2, sysdate + 1, l_pt);
  insert into doc_price_setting_prices (document_id, product_id, price) values (l_ps2, l_sugar, 25);
  trade_ops.post_price_setting(l_ps2);
  check_eq('Ціна на сьогодні (зріз останніх)', trade_lines.get_price(l_pt, l_sugar, sysdate), 20);
  check_eq('Ціна на завтра + 1 год', trade_lines.get_price(l_pt, l_sugar, sysdate + 1 + 1/24), 25);

  -- Надходження 10 кг цукру
  insert into doc_goods_receipt (id, supplier_id, warehouse_id, occurred_at) values (l_rcp, l_sup, l_wh, sysdate - 1/24);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_sugar, 10, 15, 0);
  trade_doc.post_goods_receipt(l_rcp);

  -- Реалізація 3 кг без ціни → ціна з регістру
  insert into doc_goods_sale (id, customer_id, warehouse_id, price_type_id) values (l_sale, l_cus, l_wh, l_pt);
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (l_sale, l_sugar, 3);
  select total_amount into l_num from doc_goods_sale where id = l_sale;
  check_eq('Сума реалізації 3 кг × 20,00 (автоціна)', l_num, 60);
  expect_fail('Товар без ціни', 'insert into doc_goods_sale_goods (document_id, product_id, quantity) values (''' || l_sale || ''', ''' || l_kettle || ''', 1)');
  trade_ops.post_goods_sale(l_sale);
  check_eq('Залишок після реалізації', stock(l_wh, l_sugar), 7);
  check_eq('Дебіторська заборгованість', receivable(l_cus), 60);
  select sum(quantity) into l_num from reg_sales_turnover where recorder_id = l_sale;
  check_eq('Регістр «Продажі»: кількість', l_num, 3);

  insert into doc_goods_sale (id, customer_id, warehouse_id, price_type_id) values (l_sale2, l_cus, l_wh, l_pt);
  insert into doc_goods_sale_goods (document_id, product_id, quantity) values (l_sale2, l_sugar, 8);
  expect_fail('Продаж 8 кг при залишку 7', 'begin trade_ops.post_goods_sale(''' || l_sale2 || '''); end;');

  -- Оплата від покупця
  insert into doc_customer_payment (id, customer_id, amount) values (l_pay2, l_cus, 60.01);
  expect_fail('Оплата 60,01 при боргу 60,00', 'begin trade_ops.post_customer_payment(''' || l_pay2 || '''); end;');
  insert into doc_customer_payment (id, customer_id, amount) values (l_pay, l_cus, 50);
  trade_ops.post_customer_payment(l_pay);
  check_eq('Борг покупця після оплати 50,00', receivable(l_cus), 10);
  expect_fail('Скасування оплаченої реалізації', 'begin trade_ops.unpost_goods_sale(''' || l_sale || '''); end;');

  -- Переміщення
  insert into doc_goods_transfer (id, warehouse_from_id, warehouse_to_id) values (l_tr, l_wh, l_wh2);
  insert into doc_goods_transfer_goods (document_id, product_id, quantity) values (l_tr, l_sugar, 2);
  trade_ops.post_goods_transfer(l_tr);
  check_eq('Склад-відправник після переміщення', stock(l_wh, l_sugar), 5);
  check_eq('Склад-отримувач після переміщення', stock(l_wh2, l_sugar), 2);
  expect_fail('Переміщення на той самий склад', 'insert into doc_goods_transfer (id, warehouse_from_id, warehouse_to_id) values (''' || l_tr2 || ''', ''' || l_wh || ''', ''' || l_wh || ''')');

  -- Списання
  insert into doc_goods_write_off (id, warehouse_id, reason) values (l_wo, l_wh, 'Псування');
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (l_wo, l_sugar, 1);
  trade_ops.post_goods_write_off(l_wo);
  check_eq('Залишок після списання', stock(l_wh, l_sugar), 4);
  insert into doc_goods_write_off (id, warehouse_id, reason) values (l_wo2, l_wh, 'Нестача');
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (l_wo2, l_sugar, 4.5);
  expect_fail('Списання 4,5 кг при залишку 4', 'begin trade_ops.post_goods_write_off(''' || l_wo2 || '''); end;');
  expect_fail('Скасування надходження, вже проданого', 'begin trade_doc.unpost_goods_receipt(''' || l_rcp || '''); end;');

  trade_ops.unpost_goods_write_off(l_wo);
  check_eq('Залишок після скасування списання', stock(l_wh, l_sugar), 5);
  expect_fail('Зміна рядка проведеної реалізації', 'update doc_goods_sale_goods set quantity = 1 where document_id = ''' || l_sale || '''');
  rollback;
end;
/
