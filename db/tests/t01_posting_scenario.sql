-- Наскрізний сценарій паспортів DocGoodsReceipt / DocSupplierPayment / регістрів.
-- Усі зміни відкочуються (rollback) наприкінці.
set serveroutput on size unlimited feedback off
declare
  l_doc varchar2(32) := rawtohex(sys_guid());
  l_pay varchar2(32) := rawtohex(sys_guid());
  l_pay2 varchar2(32) := rawtohex(sys_guid());
  l_sup varchar2(32); l_wh varchar2(32); l_sugar varchar2(32); l_kettle varchar2(32);
  l_total number; l_bal number; l_stock number; l_copy varchar2(32);
  procedure check_eq(p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure expect_fail(p_name varchar2, p_sql varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
  exception when others then
    dbms_output.put_line('OK   ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
begin
  -- окремий контрагент, щоб не залежати від наявних рухів
  insert into ref_counterparty (name) values ('Тестовий постачальник ' || l_doc) returning id into l_sup;
  select id into l_wh from ref_warehouse where name = 'Основний склад';
  select id into l_sugar from ref_product where name = 'Цукор білий';
  select id into l_kettle from ref_product where name = 'Чайник електричний';

  insert into doc_goods_receipt (id, supplier_id, warehouse_id) values (l_doc, l_sup, l_wh);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_doc, 1, l_sugar, 2.5, 12.34, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_doc, 2, l_kettle, 1, 10, 0);
  select total_amount into l_total from doc_goods_receipt where id = l_doc;
  check_eq('Всього накладної 2,500×12,34 + 10,00', l_total, 40.85);

  expect_fail('Дробова кількість для «шт»', 'insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (''' || l_doc || ''', 3, ''' || l_kettle || ''', 1.5, 1, 0)');

  trade_doc.post_goods_receipt(l_doc);
  trade_doc.post_goods_receipt(l_doc);
  select sum(quantity) into l_stock from reg_stock_balance_movement where recorder_id = l_doc;
  check_eq('Кількість у регістрі після повторного проведення', l_stock, 3.5);
  select balance into l_bal from v_settlement_balance where counterparty_id = l_sup;
  check_eq('Кредиторська заборгованість', l_bal, 40.85);

  expect_fail('Зміна рядка проведеного документа', 'update doc_goods_receipt_goods set price = 1 where document_id = ''' || l_doc || '''');
  expect_fail('Видалення проведеного документа', 'delete from doc_goods_receipt where id = ''' || l_doc || '''');
  expect_fail('Прямий запис у регістр', 'delete from reg_stock_balance_movement');
  expect_fail('Фізичне видалення товару', 'delete from ref_product where id = ''' || l_sugar || '''');

  insert into doc_supplier_payment (id, supplier_id, amount) values (l_pay, l_sup, 30);
  trade_doc.post_supplier_payment(l_pay);
  select balance into l_bal from v_settlement_balance where counterparty_id = l_sup;
  check_eq('Заборгованість після оплати 30,00', l_bal, 10.85);

  insert into doc_supplier_payment (id, supplier_id, amount) values (l_pay2, l_sup, 10.86);
  expect_fail('Переплата 10,86 при боргу 10,85', 'begin trade_doc.post_supplier_payment(''' || l_pay2 || '''); end;');
  expect_fail('Скасування накладної, вже частково оплаченої', 'begin trade_doc.unpost_goods_receipt(''' || l_doc || '''); end;');

  trade_doc.unpost_supplier_payment(l_pay);
  trade_doc.unpost_goods_receipt(l_doc);
  select count(*) into l_stock from reg_stock_balance_movement where recorder_id = l_doc;
  check_eq('Рухів після скасування проведення', l_stock, 0);
  l_copy := trade_doc.copy_goods_receipt(l_doc);
  select total_amount into l_total from doc_goods_receipt where id = l_copy;
  check_eq('Копія (F9): підсумок', l_total, 40.85);
  delete from doc_goods_receipt where id = l_copy;
  check_eq('Видалення чернетки з рядками', sql%rowcount, 1);
  rollback;
end;
/
