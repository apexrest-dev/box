-- Неблокувальні попередження r3. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_wh varchar2(32); l_cus varchar2(32); l_sup varchar2(32); l_p varchar2(32); l_uom varchar2(32);
  l_rcp varchar2(32); l_ord varchar2(32); l_x varchar2(32); l_inv varchar2(32);
  w varchar2(4000); n number;
  procedure has (p_name varchar2, p_text varchar2, p_part varchar2) is
  begin
    dbms_output.put_line(case when instr(p_text, p_part) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || substr(p_text, 1, 140));
  end;
begin
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T5 склад ' || t) returning id into l_wh;
  insert into ref_counterparty (name) values ('T5 покупець ' || t) returning id into l_cus;
  insert into ref_counterparty (name) values ('T5 постачальник ' || t) returning id into l_sup;
  insert into ref_product (name, unit_of_measure_id) values ('T5 Товар ' || t, l_uom) returning id into l_p;

  -- Надходження понад замовлення
  insert into doc_supplier_order (supplier_id, warehouse_id, occurred_at) values (l_sup, l_wh, sysdate - 5) returning id into l_ord;
  insert into doc_supplier_order_goods (document_id, product_id, quantity, price) values (l_ord, l_p, 10, 100);
  trade_r3.post_supplier_order(l_ord);
  l_rcp := trade_r3.receipt_from_order(l_ord);
  update doc_goods_receipt set occurred_at = sysdate - 4 where id = l_rcp;
  update doc_goods_receipt_goods set quantity = 12 where document_id = l_rcp;
  trade_warn.clear; trade_doc.post_goods_receipt(l_rcp); w := trade_warn.take;
  has('Надходження понад замовлення (не блокує)', w, 'понад замовлення');

  -- Продаж нижче собівартості (собівартість 100,00)
  insert into doc_goods_sale (customer_id, warehouse_id, occurred_at) values (l_cus, l_wh, sysdate - 3) returning id into l_x;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_x, l_p, 1, 90);
  trade_warn.clear; trade_ops.post_goods_sale(l_x); w := trade_warn.take;
  has('Ціна нижча за собівартість', w, 'нижча за собівартість');

  -- Інвентаризація, потім документ заднім числом
  insert into doc_inventory_count (warehouse_id, occurred_at) values (l_wh, sysdate - 1) returning id into l_inv;
  trade_r3.fill_with_book_balances(l_inv);
  update doc_inventory_count_goods set actual_quantity = book_quantity where document_id = l_inv;
  trade_r3.post_inventory_count(l_inv);
  insert into doc_goods_write_off (warehouse_id, reason, occurred_at) values (l_wh, 'Псування', sysdate - 3.5) returning id into l_x;
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (l_x, l_p, 1);
  trade_warn.clear; trade_ops.post_goods_write_off(l_x); w := trade_warn.take;
  has('Документ до інвентаризації', w, 'раніше проведеної інвентаризації');
  has('Ретроспективна зміна собівартості', w, 'потребує перерахунку');
  select count(*) into n from reg_stock_cost_recalc where warehouse_id = l_wh;
  dbms_output.put_line(case when n = 1 then 'OK  ' else 'FAIL' end || ' Позначка перерахунку: ' || n);

  -- Нульова оцінка надлишків
  insert into doc_surplus_posting (warehouse_id, reason) values (l_wh, 'Знайдено') returning id into l_x;
  insert into doc_surplus_posting_goods (document_id, product_id, quantity, price) values (l_x, l_p, 1, 0);
  trade_warn.clear; trade_r3.post_surplus_posting(l_x); w := trade_warn.take;
  has('Нульова оцінка надлишків', w, 'нульовою вартістю');

  trade_r3.rebuild_stock_cost;
  select count(*) into n from reg_stock_cost_recalc;
  dbms_output.put_line(case when n = 0 then 'OK  ' else 'FAIL' end || ' Перерахунок знімає позначки: ' || n);
  rollback;
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
