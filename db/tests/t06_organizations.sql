-- F-NSI-09 «Організації»: окремі взаєморозрахунки й продажі двох організацій. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_def varchar2(32); l_b varchar2(32); l_uom varchar2(32); l_wh varchar2(32); l_cus varchar2(32); l_sup varchar2(32); l_p varchar2(32);
  l_rcp varchar2(32); l_sale_b varchar2(32); l_sale_d varchar2(32); l_pay varchar2(32); l_x varchar2(32);
  l_n number; l_s varchar2(4000); l_html clob;

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
  function recv (p_org varchar2) return number is r number;
  begin
    select coalesce(sum(amount), 0) into r from reg_counterparty_settlement_mv
     where counterparty_id = l_cus and direction = 'RECEIVABLE' and organization_id = p_org;
    return r;
  end;
  function payable (p_org varchar2) return number is r number;
  begin
    select coalesce(sum(amount), 0) into r from reg_counterparty_settlement_mv
     where counterparty_id = l_sup and direction = 'PAYABLE' and organization_id = p_org;
    return r;
  end;
begin
  l_def := trade_org.default_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T6 склад ' || t) returning id into l_wh;
  insert into ref_counterparty (name) values ('T6 покупець ' || t) returning id into l_cus;
  insert into ref_counterparty (name) values ('T6 постачальник ' || t) returning id into l_sup;
  insert into ref_product (name, unit_of_measure_id) values ('T6 Товар ' || t, l_uom) returning id into l_p;

  -- ---------------------------------------------------------------- довідник
  fails('ЄДРПОУ юрособи — 8 цифр', 'ORGANIZATION_EDRPOU',
        'insert into ref_organization (name, org_kind, edrpou) values (''T6 X'', ''LEGAL'', ''1234'')');
  fails('ІПН ФОП — 10 цифр', 'ORGANIZATION_IPN',
        'insert into ref_organization (name, org_kind, edrpou) values (''T6 X'', ''INDIVIDUAL'', ''12345678'')');
  fails('Платник ПДВ без ІПН', 'ORGANIZATION_VAT_NUMBER',
        'insert into ref_organization (name, vat_payer) values (''T6 X'', ''Y'')');
  fails('Некоректний IBAN', 'ORGANIZATION_IBAN',
        'insert into ref_organization (name, iban) values (''T6 X'', ''DE12345'')');
  insert into ref_organization (name, org_kind, edrpou, iban, director_name)
  values ('T6 ФОП ' || t, 'INDIVIDUAL', '1234567890', 'ua32 3052 9900 0002 6001 2345 6789 0', 'Т6 Директор')
  returning id into l_b;
  select iban into l_s from ref_organization where id = l_b;
  eqs('IBAN нормалізується', l_s, 'UA323052990000026001234567890');
  select count(*) into l_n from ref_organization where code like '0%' and id = l_b;
  eq('Автокод організації', l_n, 1);

  -- одна організація за замовчуванням
  update ref_organization set is_default = 'Y' where id = l_b;
  select count(*) into l_n from ref_organization where is_default = 'Y';
  eq('Лише одна організація за замовчуванням', l_n, 1);
  eqs('default_org = нова', case when trade_org.default_org = l_b then 'так' else 'ні' end, 'так');
  fails('Не можна помітити організацію за замовчуванням', 'ORGANIZATION_DEFAULT_MARKED',
        'begin trade_core.mark_for_deletion(''REF_ORGANIZATION'', ''' || l_b || '''); end;');
  update ref_organization set is_default = 'Y' where id = l_def;
  eqs('Повернення основної організації', case when trade_org.default_org = l_def then 'так' else 'ні' end, 'так');

  -- ---------------------------------------------------------------- документи: організація за замовчуванням
  insert into doc_goods_receipt (supplier_id, warehouse_id, occurred_at) values (l_sup, l_wh, sysdate - 5) returning id into l_rcp;
  select organization_id into l_x from doc_goods_receipt where id = l_rcp;
  eqs('Порожня організація → за замовчуванням', case when l_x = l_def then 'так' else 'ні' end, 'так');
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_p, 20, 100, 0);
  trade_doc.post_goods_receipt(l_rcp);

  -- надходження в організацію B
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_b, l_sup, l_wh, sysdate - 4.5) returning id into l_x;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_x, 1, l_p, 10, 100, 0);
  trade_doc.post_goods_receipt(l_x);
  eq('Кредиторка основної організації', payable(l_def), 2000);
  eq('Кредиторка організації B', payable(l_b), 1000);

  -- переплата постачальнику в розрізі організації: загальний борг 3000, у B — 1000
  -- r4 F-PUR-05: оплата рухає кошти — організації B потрібне джерело (каса з залишком)
  insert into ref_cash_desk (name, organization_id) values ('T6 Каса B ' || t, l_b) returning id into l_x;
  trade_cash.set_opening_balance('CASH_DESK', l_x, sysdate - 30, 5000);
  insert into doc_supplier_payment (organization_id, supplier_id, amount, occurred_at, payment_form, cash_desk_id)
  values (l_b, l_sup, 1500, sysdate - 4, 'CASH', l_x) returning id into l_pay;
  fails('Оплата B понад борг B (загальний борг більший)', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        'begin trade_doc.post_supplier_payment(''' || l_pay || '''); end;');
  update doc_supplier_payment set amount = 1000 where id = l_pay;
  trade_doc.post_supplier_payment(l_pay);
  eq('Кредиторка B після оплати', payable(l_b), 0);
  eq('Кредиторка основної не змінилась', payable(l_def), 2000);

  -- ---------------------------------------------------------------- продажі в двох організаціях
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_b, l_cus, l_wh, sysdate - 3) returning id into l_sale_b;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale_b, l_p, 4, 150);
  trade_ops.post_goods_sale(l_sale_b);
  insert into doc_goods_sale (customer_id, warehouse_id, occurred_at) values (l_cus, l_wh, sysdate - 2.9) returning id into l_sale_d;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale_d, l_p, 2, 200);
  trade_ops.post_goods_sale(l_sale_d);
  eq('Дебіторка B', recv(l_b), 600);
  eq('Дебіторка основної', recv(l_def), 400);
  select coalesce(sum(amount), 0) into l_n from reg_sales_turnover where organization_id = l_b and counterparty_id = l_cus;
  eq('RegSales: продажі B', l_n, 600);
  select coalesce(sum(amount), 0) into l_n from v_sales where organization_id = l_def and recorder_id = l_sale_d;
  eq('v_sales: відбір за основною', l_n, 400);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = l_sale_b and organization_id = l_b;
  eq('RegStockCost: собівартість продажу B', l_n, 1);
  select coalesce(sum(gross_profit), 0) into l_n from v_gross_profit where organization_id = l_b and recorder_id = l_sale_b;
  eq('Валовий прибуток B', l_n, 200);
  select count(*) into l_n from v_settlement_balance where counterparty_id = l_cus and direction = 'RECEIVABLE';
  eq('Залишки взаєморозрахунків — окремо за організаціями', l_n, 2);

  insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at) values (l_def, l_cus, 500, sysdate - 2) returning id into l_pay;
  fails('Оплата покупця в основну понад її борг', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        'begin trade_ops.post_customer_payment(''' || l_pay || '''); end;');
  -- r4 F-SAL-07: оплата рухає кошти — джерело організації B (каса B)
  update doc_customer_payment set organization_id = l_b, payment_form = 'CASH', cash_desk_id = l_x where id = l_pay;
  trade_ops.post_customer_payment(l_pay);
  eq('Дебіторка B після оплати', recv(l_b), 100);
  fails('Проведений документ: організацію не змінити', 'лише для читання',
        'update doc_customer_payment set organization_id = ''' || l_def || ''' where id = ''' || l_pay || '''');

  -- ---------------------------------------------------------------- копія й підстава
  l_x := trade_ops.copy_goods_sale(l_sale_b);
  select organization_id into l_s from doc_goods_sale where id = l_x;
  eqs('Копія зберігає організацію', case when l_s = l_b then 'так' else 'ні' end, 'так');
  l_x := trade_r3.customer_return_from_sale(l_sale_b);
  select organization_id into l_s from doc_customer_return where id = l_x;
  eqs('Повернення на підставі — організація реалізації', case when l_s = l_b then 'так' else 'ні' end, 'так');
  update doc_customer_return set organization_id = l_def where id = l_x;
  select organization_id into l_s from doc_customer_return where id = l_x;
  eqs('Організацію документа на підставі не змінити', case when l_s = l_b then 'так' else 'ні' end, 'так');

  -- ---------------------------------------------------------------- друк
  l_html := trade_print.document_html('SALE_INVOICE', l_sale_b);
  eq('Друк: реквізити організації B', case when instr(l_html, 'T6 ФОП ' || t) > 0 and instr(l_html, 'РНОКПП 1234567890') > 0 then 1 else 0 end, 1);
  eq('Друк: підпис керівника B', case when instr(l_html, 'Т6 Директор') > 0 then 1 else 0 end, 1);
  l_html := trade_print.document_html('SALE_INVOICE', l_sale_d);
  eq('Друк: інша організація — інші реквізити', case when instr(l_html, 'T6 ФОП ' || t) = 0 then 1 else 0 end, 1);

  -- ---------------------------------------------------------------- помічена організація
  trade_core.mark_for_deletion('REF_ORGANIZATION', l_b);
  fails('Помічена організація не пропонується в нових документах', 'помічене на видалення',
        'insert into doc_supplier_order (organization_id, supplier_id, warehouse_id) values (''' || l_b || ''', ''' || l_sup || ''', ''' || l_wh || ''')');
  rollback;
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
