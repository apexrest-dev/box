-- F-TAX-01 «ПДВ і податкові накладні»: ставки ПДВ, режим цін (включає / зверху) у документах, ПДВ і «Всього»
-- рядків, підсумки й борг з ПДВ, організація / постачальник не платник → без ПДВ, повернення з режимом підстави,
-- копіювання, друк «у т. ч. ПДВ», податкова накладна за першою подією (відвантаження, передоплата, часткове
-- покриття), проведення й регістр ПДВ, ЄРПН, отримана ПН, реєстр, XML, меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); l_acc varchar2(32); l_wh varchar2(32); l_uom varchar2(32);
  l_p1 varchar2(32); l_p2 varchar2(32); l_sup varchar2(32); l_sup2 varchar2(32); l_c1 varchar2(32); l_c2 varchar2(32); l_c3 varchar2(32);
  l_pt_in varchar2(32); l_pt_ex varchar2(32);
  rc varchar2(32); rc2 varchar2(32); s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); s4 varchar2(32); s5 varchar2(32);
  cr varchar2(32); p1 varchar2(32); p2 varchar2(32); x varchar2(32); n1 varchar2(32); n2 varchar2(32); n3 varchar2(32); n4 varchar2(32);
  l_n number; l_a number; l_b number; l_s varchar2(4000); l_c clob; l_iban varchar2(34);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    savepoint before_fail;
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
    rollback to before_fail;
  exception when others then
    trade_core.g_internal := false;
    rollback to before_fail;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  function hdr (p_tab varchar2, p_id varchar2, p_col varchar2) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate 'select to_char(' || p_col || ') from ' || p_tab || ' where id = :i' into l using p_id;
    return l;
  end;
  function ln (p_tab varchar2, p_doc varchar2, p_prd varchar2, p_col varchar2) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate 'select to_char(' || p_col || ') from ' || p_tab || ' where document_id = :d and product_id = :p' into l using p_doc, p_prd;
    return l;
  end;
  function debt (p_org varchar2, p_cp varchar2, p_dir varchar2 default 'RECEIVABLE') return number is
  begin
    return trade_cash_doc.counterparty_debt(p_org, p_cp, p_dir);
  end;
  function sale (p_org varchar2, p_cp varchar2, p_pt varchar2, p_qty number, p_price number, p_date date, p_post boolean default true,
                 p_prd varchar2 default null) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id, occurred_at)
    values (p_org, p_cp, l_wh, p_pt, p_date) returning id into l;
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l, coalesce(p_prd, l_p1), p_qty, p_price);
    if p_post then trade_ops.post_goods_sale(l); end if;
    return l;
  end;
  function tax_count (p_base varchar2) return number is
    l number;
  begin
    select count(*) into l from doc_tax_invoice where base_doc_id = p_base;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- довідники
  select count(*) into l_n from ref_vat_rate where code in ('VAT20', 'VAT7', 'VAT0', 'EXEMPT', 'NOVAT');
  eq('Ставки ПДВ 20 / 7 / 0 / звільнено / без ПДВ', l_n, 5);
  select count(*) into l_n from ref_vat_rate where (code = 'VAT20' and rate = 20 and erpn_code = '20') or (code = 'VAT0' and erpn_code = '901')
                                                   or (code = 'EXEMPT' and erpn_code = '903');
  eq('Коди ставок ЄРПН', l_n, 3);
  l_s := '322001' || lpad('2323' || substr(to_char(abs(dbms_random.random)), 1, 6), 19, '0');
  l_iban := 'UA' || lpad(98 - mod(to_number(l_s || '301000'), 97), 2, '0') || l_s;
  insert into ref_organization (name, org_kind, edrpou, vat_payer, vat_number, director_name)
  values ('T23 ТОВ ' || t, 'LEGAL', '23232323', 'Y', '232323232323', 'Директор Т23') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T23 ФОП неплатник ' || t, 'LEGAL', '23232324') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T23 склад ' || t) returning id into l_wh;
  insert into ref_product (name, unit_of_measure_id, uktzed_code) values ('T23 Олія ' || t, l_uom, '1512191000') returning id into l_p1;
  insert into ref_product (name, unit_of_measure_id, vat_rate_code) values ('T23 Ліки ' || t, l_uom, 'VAT7') returning id into l_p2;
  eqs('Ставка товару за замовчуванням — 20 %', hdr('ref_product', l_p1, 'vat_rate_code'), 'VAT20');
  fails('Ставка «без ПДВ» для товару заборонена', 'REF_PRODUCT_VAT_CK',
        'update ref_product set vat_rate_code = ''NOVAT'' where id = ''' || l_p1 || '''');
  insert into ref_counterparty (name, vat_payer, vat_number, edrpou) values ('T23 постачальник-платник ' || t, 'Y', '111111111111', '11111111')
    returning id into l_sup;
  insert into ref_counterparty (name) values ('T23 постачальник ФОП ' || t) returning id into l_sup2;
  insert into ref_counterparty (name, vat_payer, vat_number, edrpou) values ('T23 покупець-платник ' || t, 'Y', '222222222222', '22222222')
    returning id into l_c1;
  insert into ref_counterparty (name) values ('T23 покупець-неплатник ' || t) returning id into l_c2;
  insert into ref_counterparty (name, vat_payer, vat_number) values ('T23 покупець 3 ' || t, 'Y', '333333333333') returning id into l_c3;
  fails('ІПН платника ПДВ — 12 цифр', 'COUNTERPARTY_VAT_NUMBER',
        'update ref_counterparty set vat_payer = ''Y'', vat_number = ''123'' where id = ''' || l_c2 || '''');
  eqs('Неплатник: ІПН очищується', hdr('ref_counterparty', l_c2, 'vat_number'), null);
  insert into ref_price_type (name) values ('T23 роздріб ' || t) returning id into l_pt_in;
  insert into ref_price_type (name, price_includes_vat) values ('T23 опт без ПДВ ' || t, 'N') returning id into l_pt_ex;
  eqs('Вид цін: «ціна включає ПДВ» за замовчуванням', hdr('ref_price_type', l_pt_in, 'price_includes_vat'), 'Y');

  -- ---------------------------------------------------------------- надходження: постачальник платник / неплатник
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 30)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (rc, l_p1, 100, 60);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (rc, l_p2, 50, 107);
  eqs('Надходження: режим «ціна включає ПДВ»', hdr('doc_goods_receipt', rc, 'price_includes_vat'), 'Y');
  eqs('Надходження: ставка з товару (20 %)', ln('doc_goods_receipt_goods', rc, l_p1, 'vat_rate_code'), 'VAT20');
  eq('Надходження: ПДВ рядка 6000 × 20/120', to_number(ln('doc_goods_receipt_goods', rc, l_p1, 'vat_amount')), 1000);
  eq('Надходження: ПДВ рядка 7 % (5350 × 7/107)', to_number(ln('doc_goods_receipt_goods', rc, l_p2, 'vat_amount')), 350);
  eq('Надходження: Всього = сума (включає)', to_number(hdr('doc_goods_receipt', rc, 'total_amount')), 11350);
  eq('Надходження: сума ПДВ шапки', to_number(hdr('doc_goods_receipt', rc, 'vat_amount')), 1350);
  update doc_goods_receipt set price_includes_vat = 'N' where id = rc;
  eq('ПДВ зверху: ПДВ рядка 6000 × 20 %', to_number(ln('doc_goods_receipt_goods', rc, l_p1, 'vat_amount')), 1200);
  eq('ПДВ зверху: Всього рядка', to_number(ln('doc_goods_receipt_goods', rc, l_p1, 'amount_with_vat')), 7200);
  eq('ПДВ зверху: підсумок документа = сума + ПДВ', to_number(hdr('doc_goods_receipt', rc, 'total_amount')), 6000 + 1200 + 5350 + 374.5);
  trade_doc.post_goods_receipt(rc);
  eq('Кредиторка постачальнику — з ПДВ', debt(l_org, l_sup, 'PAYABLE'), 12924.5);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup2, l_wh, sysdate - 29)
    returning id into rc2;
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (rc2, l_p1, 10, 50);
  eqs('Постачальник не платник ПДВ → без ПДВ', ln('doc_goods_receipt_goods', rc2, l_p1, 'vat_rate_code'), 'NOVAT');
  eq('Постачальник не платник: ПДВ 0', to_number(hdr('doc_goods_receipt', rc2, 'vat_amount')), 0);
  trade_doc.post_goods_receipt(rc2);

  -- ---------------------------------------------------------------- реалізація: режим з виду цін, ставки, перерахунок
  s1 := sale(l_org, l_c1, l_pt_in, 10, 120, sysdate - 20, false);
  eqs('Реалізація: режим з виду цін (включає)', hdr('doc_goods_sale', s1, 'price_includes_vat'), 'Y');
  eq('Реалізація: ПДВ 1200 × 20/120', to_number(hdr('doc_goods_sale', s1, 'vat_amount')), 200);
  update doc_goods_sale_goods set vat_rate_code = 'VAT7' where document_id = s1;
  eq('Ручна ставка 7 %: ПДВ 1200 × 7/107', to_number(hdr('doc_goods_sale', s1, 'vat_amount')), 78.5);
  update doc_goods_sale_goods set product_id = l_p2, base_price = 100 where document_id = s1;
  eqs('Зміна товару: ставка з нового товару', ln('doc_goods_sale_goods', s1, l_p2, 'vat_rate_code'), 'VAT7');
  update doc_goods_sale_goods set product_id = l_p1, base_price = 120, vat_rate_code = 'VAT20' where document_id = s1;
  update doc_goods_sale set price_type_id = l_pt_ex where id = s1;
  eqs('Новий вид цін «без ПДВ» → режим «ПДВ зверху»', hdr('doc_goods_sale', s1, 'price_includes_vat'), 'N');
  eq('ПДВ зверху: підсумок 1200 + 240', to_number(hdr('doc_goods_sale', s1, 'total_amount')), 1440);
  update doc_goods_sale set price_type_id = l_pt_in, price_includes_vat = 'Y' where id = s1;
  eq('Повернули «включає»: підсумок 1200', to_number(hdr('doc_goods_sale', s1, 'total_amount')), 1200);
  trade_ops.post_goods_sale(s1);
  eq('Дебіторка = підсумок з ПДВ', debt(l_org, l_c1), 1200);
  s2 := sale(l_org, l_c1, l_pt_ex, 5, 100, sysdate - 18);
  eq('Реалізація «ПДВ зверху»: підсумок 500 + 100', to_number(hdr('doc_goods_sale', s2, 'total_amount')), 600);
  eq('Дебіторка зростає на суму з ПДВ', debt(l_org, l_c1), 1800);
  select count(*) into l_n from reg_sales_turnover where recorder_id = s2 and amount = 500;
  eq('Продажі (RegSales) — сума рядка без ПДВ (режим «зверху»)', l_n, 1);
  x := sale(l_org2, l_c1, l_pt_in, 1, 100, sysdate - 18, false);
  eqs('Організація не платник ПДВ → без ПДВ', ln('doc_goods_sale_goods', x, l_p1, 'vat_rate_code'), 'NOVAT');
  update doc_goods_sale set organization_id = l_org where id = x;
  eqs('Зміна організації на платника → ставка з товару', ln('doc_goods_sale_goods', x, l_p1, 'vat_rate_code'), 'VAT20');
  delete from doc_goods_sale where id = x;
  -- копіювання
  x := trade_ops.copy_goods_sale(s2);
  trade_vat.copy_lines('DocGoodsSale', s2, x);
  eqs('Копія: режим цін джерела', hdr('doc_goods_sale', x, 'price_includes_vat'), 'N');
  eq('Копія: підсумок з ПДВ', to_number(hdr('doc_goods_sale', x, 'total_amount')), 600);
  delete from doc_goods_sale where id = x;
  -- друк
  l_c := trade_print.document_html('SALE_INVOICE', s1);
  eq('Друк «включає»: «У тому числі ПДВ»', sign(instr(l_c, 'У тому числі ПДВ')), 1);
  l_c := trade_print.document_html('SALE_INVOICE', s2);
  eq('Друк «зверху»: «Всього з ПДВ»', sign(instr(l_c, 'Всього з ПДВ')), 1);
  l_c := trade_print.document_html('RECEIPT_NOTE', rc2);
  eq('Друк без ПДВ: «Без ПДВ»', sign(instr(l_c, 'Без ПДВ')), 1);

  -- ---------------------------------------------------------------- повернення від клієнта: режим і ставки підстави
  cr := trade_r3.customer_return_from_sale(s2);
  update doc_customer_return_goods set quantity = 2 where document_id = cr;
  eqs('Повернення: режим підстави («зверху»)', hdr('doc_customer_return', cr, 'price_includes_vat'), 'N');
  eq('Повернення: сума з ПДВ 200 + 40', to_number(hdr('doc_customer_return', cr, 'total_amount')), 240);
  trade_r3.post_customer_return(cr);
  eq('Дебіторка після повернення', debt(l_org, l_c1), 1560);

  -- ---------------------------------------------------------------- ПН за першою подією: відвантаження
  eq('Зобов''язання: перша подія — відвантаження', trade_tax.liability_increase(0, 0, 1000, 0), 1000);
  eq('Оплата після відвантаження зобов''язання не створює', trade_tax.liability_increase(1000, 0, 0, 800), 0);
  eq('Передоплата понад відвантаження', trade_tax.liability_increase(1000, 800, 0, 700), 500);
  eq('Відвантаження, покрите передоплатою', trade_tax.liability_increase(0, 1000, 600, 0), 0);
  eq('Відвантаження, частково покрите', trade_tax.liability_increase(600, 1000, 600, 0), 200);
  select count(*), sum(base_amount), sum(remaining_amount) into l_n, l_a, l_b from table(trade_tax.events(p_org => l_org, p_cp => l_c1));
  eq('Події покупця: 2 відвантаження', l_n, 2);
  eq('База першої події = 1200 + 600', l_a, 1800);
  n1 := trade_tax.create_from_base('DocGoodsSale', s1);
  eqs('ПН: видана, перша подія — відвантаження', hdr('doc_tax_invoice', n1, 'direction || event_kind'), 'ISSUEDSHIPMENT');
  eqs('ПН: дата = дата відвантаження', hdr('doc_tax_invoice', n1, 'to_char(occurred_at, ''DD.MM.YYYY'')'), to_char(sysdate - 20, 'DD.MM.YYYY'));
  eq('ПН: сума з ПДВ', to_number(hdr('doc_tax_invoice', n1, 'total_amount')), 1200);
  eq('ПН: обсяг без ПДВ', to_number(hdr('doc_tax_invoice', n1, 'amount_without_vat')), 1000);
  select max(id) into x from doc_tax_invoice_goods where document_id = n1;
  eqs('ПН: рядок — опис, код УКТ ЗЕД, од.', hdr('doc_tax_invoice_goods', x,
      'substr(description, 1, 8) || ''/'' || uktzed_code || ''/'' || unit_name'), 'T23 Олія/1512191000/шт');
  eqs('ПН: покупець-платник — без типу причини', hdr('doc_tax_invoice', n1, 'not_issued_reason'), null);
  fails('Друга ПН на ту саму подію', 'TAX_INVOICE_EXISTS', 'declare x varchar2(32); begin x := trade_tax.create_from_base(''DocGoodsSale'', ''' || s1 || '''); end;');
  trade_tax.post(n1);
  select count(*), sum(base_amount), sum(vat_amount) into l_n, l_a, l_b from reg_vat_mv where recorder_id = n1 and direction = 'LIABILITY';
  eq('Регістр ПДВ: зобов''язання (рядків)', l_n, 1);
  eq('Регістр ПДВ: база', l_a, 1000);
  eq('Регістр ПДВ: ПДВ', l_b, 200);
  eqs('ПН: ІПН продавця й покупця', hdr('doc_tax_invoice', n1, 'seller_vat_number || ''/'' || buyer_vat_number'), '232323232323/222222222222');
  select max(remaining_amount) into l_a from table(trade_tax.events(p_doc_id => s1));
  eq('Залишок події після ПН', l_a, 0);
  fails('Проведену ПН змінювати не можна', 'DOCUMENT_READ_ONLY', 'update doc_tax_invoice set doc_comment = ''x'' where id = ''' || n1 || '''');
  -- ЄРПН
  fails('Реєстрація без номера', 'TAX_ERPN_NUMBER', 'begin trade_tax.set_erpn(''' || n1 || ''', ''REGISTERED''); end;');
  trade_tax.set_erpn(n1, 'SENT');
  fails('Надіслану в ЄРПН ПН не скасувати', 'TAX_INVOICE_IN_ERPN', 'begin trade_tax.unpost(''' || n1 || '''); end;');
  trade_tax.set_erpn(n1, 'REGISTERED', '9123456789', trunc(sysdate - 19));
  eqs('ЄРПН: зареєстровано з номером', hdr('doc_tax_invoice', n1, 'erpn_status || '' '' || erpn_reg_number'), 'REGISTERED 9123456789');
  fails('Зареєстровану не повернути в «не надіслано»', 'TAX_ERPN_REGISTERED', 'begin trade_tax.set_erpn(''' || n1 || ''', ''NOT_SENT''); end;');
  eqs('Строк реєстрації: складена 10.11 → 30.11', to_char(trade_tax.erpn_deadline(date '2026-11-10'), 'DD.MM'), '30.11');
  eqs('Строк реєстрації: складена 20.11 → 15.12', to_char(trade_tax.erpn_deadline(date '2026-11-20'), 'DD.MM'), '15.12');
  -- оплата після відвантаження — ПН не потрібна
  insert into ref_bank_account (organization_id, iban, bank_name, is_default) values (l_org, l_iban, 'T23 Банк', 'Y') returning id into l_acc;
  insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at) values (l_org, l_c1, 1000, sysdate - 15) returning id into p1;
  trade_ops.post_customer_payment(p1);
  fails('Оплата після відвантаження: зобов''язання немає', 'TAX_NO_LIABILITY',
        'declare x varchar2(32); begin x := trade_tax.create_from_base(''DocCustomerPayment'', ''' || p1 || '''); end;');
  -- ПН з «ПДВ зверху» на неплатника; generate для решти подій періоду
  n2 := trade_tax.create_from_base('DocGoodsSale', s2);
  eq('ПН за реалізацією «зверху»: сума з ПДВ', to_number(hdr('doc_tax_invoice', n2, 'total_amount')), 600);
  eq('ПН за реалізацією «зверху»: ПДВ', to_number(hdr('doc_tax_invoice', n2, 'vat_amount')), 100);
  delete from doc_tax_invoice where id = n2;
  s3 := sale(l_org, l_c2, l_pt_in, 3, 240, sysdate - 16);
  l_n := trade_tax.generate(sysdate - 25, sysdate, l_org, 'Y');
  eq('Сформовано ПН за подіями періоду (s2, s3)', l_n, 2);
  select max(id) into n3 from doc_tax_invoice where base_doc_id = s3;
  eqs('ПН на неплатника: тип причини 02', hdr('doc_tax_invoice', n3, 'not_issued_reason || status'), '02POSTED');
  eqs('ПН на неплатника: ІПН 100000000000', hdr('doc_tax_invoice', n3, 'buyer_vat_number'), '100000000000');
  eq('Повторне формування — нічого', trade_tax.generate(sysdate - 25, sysdate, l_org, 'Y'), 0);

  -- ---------------------------------------------------------------- передоплата (імітація авансу: рух оплати без відвантаження)
  insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at) values (l_org, l_c3, 1200, sysdate - 12) returning id into p2;
  trade_core.g_internal := true;
  update doc_customer_payment set status = 'POSTED' where id = p2;
  insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, organization_id, counterparty_id, direction, currency_code, amount)
  values (sysdate - 12, 'DocCustomerPayment', p2, 1, l_org, l_c3, 'RECEIVABLE', 'UAH', -1200);
  trade_core.g_internal := false;
  n4 := trade_tax.create_from_base('DocCustomerPayment', p2);
  eqs('ПН на передоплату', hdr('doc_tax_invoice', n4, 'event_kind'), 'PREPAYMENT');
  eq('ПН на передоплату: ПДВ 1200 × 20/120', to_number(hdr('doc_tax_invoice', n4, 'vat_amount')), 200);
  trade_tax.post(n4);
  -- реалізація 1500 після передоплати 1200: зобов'язання лише на непокриту частину
  s4 := sale(l_org, l_c3, l_pt_in, 15, 100, sysdate - 10);
  select max(base_amount) into l_a from table(trade_tax.events(p_doc_id => s4));
  eq('Частково покрите відвантаження: база 1500 − 1200', l_a, 300);
  x := trade_tax.create_from_base('DocGoodsSale', s4);
  eq('ПН на непокриту частину', to_number(hdr('doc_tax_invoice', x, 'total_amount')), 300);
  select count(*) into l_n from doc_tax_invoice_goods where document_id = x and description like '%частина%' and quantity = 1;
  eq('ПН на частину: один рядок за ставкою', l_n, 1);
  update doc_tax_invoice_goods set price = price + 100 where document_id = x;
  eq('Ручна зміна рядка: перерахунок ПДВ 20 % від обсягу', to_number(hdr('doc_tax_invoice', x, 'vat_amount')), 70);
  fails('ПН понад базу першої події', 'TAX_INVOICE_EXCEEDS_BASE', 'begin trade_tax.post(''' || x || '''); end;');
  update doc_tax_invoice_goods set price = price - 100 where document_id = x;
  trade_tax.post(x);
  eq('ПН на частину проведено', to_number(hdr('doc_tax_invoice', x, 'decode(status, ''POSTED'', 1, 0)')), 1);

  -- ---------------------------------------------------------------- отримана ПН (податковий кредит)
  n2 := trade_tax.create_from_base('DocGoodsReceipt', rc);
  eqs('Отримана ПН', hdr('doc_tax_invoice', n2, 'direction'), 'RECEIVED');
  eq('Отримана ПН: ПДВ = ПДВ надходження', to_number(hdr('doc_tax_invoice', n2, 'vat_amount')), 1574.5);
  fails('Отримана ПН без номера постачальника', 'TAX_EXT_NUMBER', 'begin trade_tax.post(''' || n2 || '''); end;');
  update doc_tax_invoice set ext_number = '1515' where id = n2;
  trade_tax.post(n2);
  select sum(vat_amount) into l_a from reg_vat_mv where recorder_id = n2 and direction = 'CREDIT';
  eq('Податковий кредит', l_a, 1574.5);
  fails('Постачальник не платник — ПН не буде', 'TAX_SUPPLIER_NOT_VAT_PAYER',
        'declare x varchar2(32); begin x := trade_tax.create_from_base(''DocGoodsReceipt'', ''' || rc2 || '''); end;');
  x := sale(l_org2, l_c1, l_pt_in, 1, 100, sysdate - 8);
  fails('Організація не платник ПДВ', 'TAX_ORG_NOT_VAT_PAYER',
        'declare x varchar2(32); begin x := trade_tax.create_from_base(''DocGoodsSale'', ''' || x || '''); end;');
  fails('Розрахунок коригування — окремий етап', 'TAX_CORRECTION_NOT_SUPPORTED',
        'insert into doc_tax_invoice (organization_id, counterparty_id, invoice_kind) values (''' || l_org || ''', ''' || l_c1 || ''', ''RK'')');
  -- ручна ПН: рядок з описом, ставка «без ПДВ» заборонена
  insert into doc_tax_invoice (organization_id, counterparty_id) values (l_org, l_c1) returning id into x;
  insert into doc_tax_invoice_goods (document_id, description, quantity, price, vat_rate_code) values (x, 'Послуга доставки', 1, 500, 'VAT20');
  eq('Ручна ПН: ПДВ 500 × 20 %', to_number(hdr('doc_tax_invoice', x, 'vat_amount')), 100);
  fails('Рядок «без ПДВ» у ПН', 'TAX_LINE_NOVAT',
        'insert into doc_tax_invoice_goods (document_id, description, quantity, price, vat_rate_code) values (''' || x || ''', ''x'', 1, 1, ''NOVAT'')');
  fails('Скасування непроведеної', 'DOCUMENT_NOT_POSTED', 'begin trade_tax.unpost(''' || x || '''); end;');
  delete from doc_tax_invoice where id = x;
  -- скасування проведення
  trade_tax.unpost(n4);
  select count(*) into l_n from reg_vat_mv where recorder_id = n4;
  eq('Скасування: рухи ПДВ видалено', l_n, 0);
  trade_tax.post(n4);

  -- ---------------------------------------------------------------- друк, XML, реєстр
  eqs('Форма друку ПН за замовчуванням', trade_print.default_form(n1), 'TAX_INVOICE');
  l_c := trade_print.document_html('TAX_INVOICE', n1);
  eq('Друк ПН: заголовок', sign(instr(l_c, 'ПОДАТКОВА НАКЛАДНА')), 1);
  eq('Друк ПН: код УКТ ЗЕД', sign(instr(l_c, '1512191000')), 1);
  eq('Друк ПН: стан ЄРПН', sign(instr(l_c, 'Зареєстровано')), 1);
  l_c := trade_tax.erpn_xml(n1);
  eq('XML: J1201016', sign(instr(l_c, 'J1201016')), 1);
  eq('XML: ІПН покупця', sign(instr(l_c, '<HKBUY>222222222222</HKBUY>')), 1);
  eq('XML: ПДВ 20 %', sign(instr(l_c, '<R03G7>200.00</R03G7>')), 1);
  eq('XML: рядок товару з кодом ставки', sign(instr(l_c, '<RXXXXG008 ROWNUM="1">20</RXXXXG008>')), 1);
  fails('XML лише для виданих', 'TAX_XML_ISSUED_ONLY', 'declare c clob; begin c := trade_tax.erpn_xml(''' || n2 || '''); end;');
  l_c := trade_tax.register_html(sysdate - 40, sysdate, l_org);
  eq('Реєстр: кредит більший — ПДВ до відшкодування', sign(instr(l_c, 'до відшкодування')), 1);
  select sum(case direction when 'LIABILITY' then vat_amount else -vat_amount end) into l_a
    from reg_vat_mv where organization_id = l_org;
  eq('Регістр ПДВ: зобов''язання − кредит (200 + 100 + 120 + 200 + 50 − 1574.5)', l_a, 200 + 100 + 120 + 200 + 50 - 1574.5);
  eq('Реєстр: сума в HTML', sign(instr(l_c, to_char(abs(l_a), 'FM999G999G999G990D00'))), 1);
  select count(*) into l_n from v_tax_invoice_list where organization_id = l_org and erpn_deadline is not null;
  eq('Список ПН: строки реєстрації виданих', l_n, 5);
  select count(*) into l_n from table(trade_tax.events(sysdate - 40, sysdate, l_org)) where remaining_amount > 0;
  eq('Події без ПН у періоді', l_n, 0);

  -- ---------------------------------------------------------------- метадані
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'DocTaxInvoice' and list_page_id = 620 and form_page_id = 621 and auth_scheme = 'Роль: податковий облік')
      or (tech_name = 'TaxInvoiceRegister' and list_page_id = 630 and kind = 'REPORT');
  eq('Об''єкти меню', l_n, 2);
  select count(*) into l_n from user_triggers where trigger_name in ('DOC_TAX_INVOICE_EVLOG', 'DOC_GOODS_SALE_GOODS_VAT', 'DOC_GOODS_SALE_VAT')
     and status = 'ENABLED';
  eq('Тригери журналу й ПДВ', l_n, 3);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (620, 621, 630);
  eq('Сторінки 620/621, 630', l_n, 3);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
