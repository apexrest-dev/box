-- F-RET-01 «Роздрібні продажі»: каси ККМ (RefCashRegister, перевірки), чек ККМ (DocRetailReceipt) —
-- роздрібна ціна, сума й ПДВ рядків, підсумки; РМК — сканер («N*код»), +/−/×, оплата готівкою /
-- карткою / змішана, решта, контроль оплати; проведення: RegStockBalance, RegStockCost, RegSales
-- (роздрібний покупець), RegCashBalance (каса / рахунок); FEFO-серії; ПРРО-заглушка (фіскальний номер,
-- лічильник, JSON, заборона скасування); нефіскальна каса — скасування й повторне проведення;
-- друк чека, перерахунок собівартості, реєстратор, журнал, меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); l_wh varchar2(32); l_whord varchar2(32); l_uom varchar2(32); l_sup varchar2(32);
  l_desk varchar2(32); l_desk2 varchar2(32); l_deskusd varchar2(32); l_bank varchar2(32); l_pt varchar2(32);
  l_a varchar2(32); l_b varchar2(32); l_srv varchar2(32); l_m varchar2(32); s1 varchar2(32); s2 varchar2(32);
  l_reg varchar2(32); l_reg2 varchar2(32); l_cp varchar2(32);
  r1 varchar2(32); r2 varchar2(32); ps varchar2(32);
  k1 varchar2(32); k2 varchar2(32); k3 varchar2(32); k4 varchar2(32); k5 varchar2(32); x varchar2(32); l_line varchar2(32);
  l_n number; l_s varchar2(4000); l_c clob; l_v number; l_iban varchar2(40);

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
    savepoint before_fail;
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
    rollback to before_fail;
  exception when others then
    trade_core.g_internal := false;
    rollback to before_fail;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  function stock (p_prd varchar2) return number is begin return trade_r3.stock_qty(l_wh, p_prd); end;
  function cost (p_prd varchar2) return number is
    l number;
  begin
    select coalesce(sum(cost_amount), 0) into l from reg_stock_cost_tot where warehouse_id = l_wh and product_id = p_prd;
    return l;
  end;
  function cash (p_place varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_tot where place_id = p_place;
    return l;
  end;
  function hdr (p_id varchar2, p_col varchar2) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate 'select to_char(' || p_col || ') from doc_retail_receipt where id = :i' into l using p_id;
    return l;
  end;
  function mv (p_tab varchar2, p_id varchar2) return number is
    l number;
  begin
    execute immediate 'select count(*) from ' || p_tab || ' where recorder_type = ''DocRetailReceipt'' and recorder_id = :i' into l using p_id;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  l_s := '322001' || lpad('2424' || substr(to_char(abs(dbms_random.random)), 1, 6), 19, '0');
  l_iban := 'UA' || lpad(98 - mod(to_number(l_s || '301000'), 97), 2, '0') || l_s;
  insert into ref_organization (name, org_kind, edrpou, vat_payer, vat_number, address)
  values ('T24 ТОВ ' || t, 'LEGAL', '24242424', 'Y', '242424242424', 'м. Київ, вул. Тестова, 24') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T24 ФОП ' || t, 'LEGAL', '24242425') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T24 магазин ' || t) returning id into l_wh;
  insert into ref_warehouse (name, use_order_scheme) values ('T24 ордерний ' || t, 'Y') returning id into l_whord;
  insert into ref_cash_desk (name, organization_id) values ('T24 каса ' || t, l_org) returning id into l_desk;
  insert into ref_cash_desk (name, organization_id) values ('T24 каса ФОП ' || t, l_org2) returning id into l_desk2;
  insert into ref_cash_desk (name, organization_id, currency_code) values ('T24 каса USD ' || t, l_org, 'USD') returning id into l_deskusd;
  insert into ref_bank_account (organization_id, iban, bank_name) values (l_org, l_iban, 'T24 Банк') returning id into l_bank;
  insert into ref_price_type (name) values ('T24 роздріб ' || t) returning id into l_pt;
  insert into ref_product (name, unit_of_measure_id, vat_rate_code, article) values ('T24 Кава ' || t, l_uom, 'VAT20', 'T24A' || substr(t, 1, 6)) returning id into l_a;
  insert into ref_product (name, unit_of_measure_id, vat_rate_code) values ('T24 Хліб ' || t, l_uom, 'VAT7') returning id into l_b;
  insert into ref_product (name, unit_of_measure_id, product_kind) values ('T24 Пакування ' || t, l_uom, 'SERVICE') returning id into l_srv;
  insert into ref_product (name, unit_of_measure_id, use_series) values ('T24 Молоко ' || t, l_uom, 'Y') returning id into l_m;
  insert into reg_barcode (barcode, product_id) values ('T24-' || substr(t, 1, 10), l_a);
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('M-1', l_m, trunc(sysdate) - 5, trunc(sysdate) + 3) returning id into s1;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('M-2', l_m, trunc(sysdate) - 1, trunc(sysdate) + 9) returning id into s2;
  insert into ref_counterparty (name) values ('T24 постачальник ' || t) returning id into l_sup;
  -- Залишки: Кава 10 × 60 (600), Хліб 20 × 10 (200), Молоко M-1 2 × 20, M-2 5 × 22
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 2)
    returning id into r1;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r1, 1, l_a, 10, 60, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r1, 2, l_b, 20, 10, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount, series_id) values (r1, 3, l_m, 2, 20, 0, s1);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount, series_id) values (r1, 4, l_m, 5, 22, 0, s2);
  trade_doc.post_goods_receipt(r1);
  eq('Підготовка: Кава вартість', cost(l_a), 600);
  -- Роздрібні ціни: Кава 120, Хліб 21.40, Пакування 5, Молоко 40
  ps := rawtohex(sys_guid());
  insert into doc_price_setting (id, occurred_at, price_type_id) values (ps, sysdate - 1, l_pt);
  insert into doc_price_setting_prices (document_id, product_id, price) values (ps, l_a, 120);
  insert into doc_price_setting_prices (document_id, product_id, price) values (ps, l_b, 21.4);
  insert into doc_price_setting_prices (document_id, product_id, price) values (ps, l_srv, 5);
  insert into doc_price_setting_prices (document_id, product_id, price) values (ps, l_m, 40);
  trade_ops.post_price_setting(ps);

  -- ---------------------------------------------------------------- каси ККМ
  l_cp := trade_retail.retail_customer;
  select count(*) into l_n from ref_counterparty where id = l_cp and name = 'Роздрібний покупець' and vat_payer = 'N';
  eq('Контрагент «Роздрібний покупець»', l_n, 1);
  eqs('Роздрібний покупець не дублюється', trade_retail.retail_customer, l_cp);
  insert into ref_cash_register (name, cash_desk_id, warehouse_id, bank_account_id, price_type_id, is_fiscal, fiscal_number)
  values ('T24 ККМ ' || t, l_desk, l_wh, l_bank, l_pt, 'Y', '24' || lpad(substr(to_char(abs(dbms_random.random)), 1, 8), 8, '0'))
  returning id into l_reg;
  select organization_id || '|' || customer_id || '|' || prro_provider || '|' || fiscal_seq || '|' || nvl2(code, 'code', '-')
    into l_s from ref_cash_register where id = l_reg;
  eqs('Каса ККМ: організація з каси, роздрібний покупець, STUB, лічильник 0', l_s, l_org || '|' || l_cp || '|STUB|0|code');
  insert into ref_cash_register (name, cash_desk_id, warehouse_id, price_type_id, is_fiscal)
  values ('T24 ККМ нефіскальна ' || t, l_desk, l_wh, l_pt, 'N') returning id into l_reg2;
  fails('Фіскальна каса без ФН', 'PRRO_FISCAL_NUMBER_REQUIRED',
        'insert into ref_cash_register (name, cash_desk_id, warehouse_id, is_fiscal) values (''X'', ''' || l_desk || ''', ''' || l_wh || ''', ''Y'')');
  fails('ФН не 10 цифр', 'CASH_REGISTER_FISCAL_NUMBER',
        'insert into ref_cash_register (name, cash_desk_id, warehouse_id, fiscal_number) values (''X'', ''' || l_desk || ''', ''' || l_wh || ''', ''12345'')');
  fails('Ордерний склад', 'CASH_REGISTER_ORDER_WAREHOUSE',
        'insert into ref_cash_register (name, cash_desk_id, warehouse_id, is_fiscal) values (''X'', ''' || l_desk || ''', ''' || l_whord || ''', ''N'')');
  fails('Каса не в UAH', 'CASH_REGISTER_DESK_CURRENCY',
        'insert into ref_cash_register (name, cash_desk_id, warehouse_id, is_fiscal) values (''X'', ''' || l_deskusd || ''', ''' || l_wh || ''', ''N'')');
  fails('Каса іншої організації', 'CASH_REGISTER_DESK_ORG',
        'insert into ref_cash_register (name, organization_id, cash_desk_id, warehouse_id, is_fiscal) values (''X'', ''' || l_org2 || ''', ''' || l_desk || ''', ''' || l_wh || ''', ''N'')');
  fails('Рахунок іншої організації', 'CASH_REGISTER_BANK_ACCOUNT',
        'insert into ref_cash_register (name, cash_desk_id, warehouse_id, bank_account_id, is_fiscal) values (''X'', ''' || l_desk2 || ''', ''' || l_wh || ''', ''' || l_bank || ''', ''N'')');
  update ref_cash_register set fiscal_seq = 99 where id = l_reg;
  select fiscal_seq into l_n from ref_cash_register where id = l_reg;
  eq('Лічильник фіскальних чеків захищений', l_n, 0);
  fails('Фізичне видалення каси ККМ', 'Фізичне видалення', 'delete from ref_cash_register where id = ''' || l_reg || '''');
  eqs('Каса ККМ за замовчуванням — активна', case when trade_retail.default_register is not null then 'Y' end, 'Y');

  -- ---------------------------------------------------------------- РМК: сканер і кошик
  k1 := trade_retail.scan(l_reg, null, 'T24A' || substr(t, 1, 6));
  eqs('Сканер створює чек на касі ККМ', hdr(k1, 'cash_register_id || ''|'' || warehouse_id || ''|'' || cash_desk_id || ''|'' || organization_id || ''|'' || customer_id || ''|'' || status'),
      l_reg || '|' || l_wh || '|' || l_desk || '|' || l_org || '|' || l_cp || '|DRAFT');
  eqs('Повторне сканування того ж чека', trade_retail.scan(l_reg, k1, 'T24A' || substr(t, 1, 6)), k1);
  select listagg(quantity || ':' || price || ':' || amount || ':' || vat_rate_code || ':' || vat_amount, ',') within group (order by line_number)
    into l_s from doc_retail_receipt_goods where document_id = k1;
  eqs('Рядок: 2 × 120 = 240, ПДВ 20 % = 40', l_s, '2:120:240:VAT20:40');
  select max(barcode) into l_s from reg_barcode where product_id = l_a;
  x := trade_retail.scan(l_reg, k1, '3*' || l_s);
  select quantity into l_n from doc_retail_receipt_goods where document_id = k1 and product_id = l_a;
  eq('«3*штрихкод» додає 3', l_n, 5);
  trade_retail.add_product(k1, l_b, 2);
  trade_retail.add_product(k1, l_srv, 1);
  eqs('Підсумок чека (5×120 + 2×21.40 + 5)', hdr(k1, 'total_amount || ''|'' || vat_amount'), '647.8|' || (100 + 2.8 + 0.83));
  fails('Невідомий штрихкод', 'BARCODE_NOT_FOUND', 'declare x varchar2(32); begin x := trade_retail.scan(''' || l_reg || ''', ''' || k1 || ''', ''NO-SUCH-' || t || '''); end;');
  fails('Кількість у скануванні 0', 'RETAIL_SCAN_QTY', 'declare x varchar2(32); begin x := trade_retail.scan(''' || l_reg || ''', ''' || k1 || ''', ''0*' || l_s || '''); end;');
  fails('Кількість у скануванні — не число', 'RETAIL_SCAN_QTY', 'declare x varchar2(32); begin x := trade_retail.scan(''' || l_reg || ''', ''' || k1 || ''', ''аб*' || l_s || '''); end;');
  select id into l_line from doc_retail_receipt_goods where document_id = k1 and product_id = l_b;
  trade_retail.change_qty(l_line, 1);
  trade_retail.change_qty(l_line, -2);
  select quantity into l_n from doc_retail_receipt_goods where id = l_line;
  eq('+1 / −2 до рядка', l_n, 1);
  trade_retail.change_qty(l_line, -1);
  select count(*) into l_n from doc_retail_receipt_goods where id = l_line;
  eq('Кількість 0 — рядок видаляється', l_n, 0);
  select id into l_line from doc_retail_receipt_goods where document_id = k1 and product_id = l_srv;
  trade_retail.delete_line(l_line);
  select listagg(line_number, ',') within group (order by line_number) into l_s from doc_retail_receipt_goods where document_id = k1;
  eqs('Лишився один рядок', l_s, '1');
  eq('Підсумок 600', trade_retail.receipt_total(k1), 600);
  l_c := trade_retail.cart_html(k1);
  eq('Кошик: товар, кнопки, «До сплати»', case when instr(l_c, 'T24 Кава') > 0 and instr(l_c, 'LINE_DEL') > 0 and instr(l_c, 'До сплати') > 0
                                                then 1 else 0 end, 1);
  eq('Порожній кошик', case when instr(trade_retail.cart_html(null), 'Чек порожній') > 0 then 1 else 0 end, 1);
  insert into ref_product (name, unit_of_measure_id) values ('T24 Без ціни ' || t, l_uom) returning id into x;
  fails('Товар без роздрібної ціни', 'RETAIL_PRICE_NOT_SET', 'begin trade_retail.add_product(''' || k1 || ''', ''' || x || ''', 1); end;');
  fails('Чек повернення — окреме завдання', 'RETAIL_RETURN_NOT_SUPPORTED',
        'insert into doc_retail_receipt (cash_register_id, receipt_kind) values (''' || l_reg || ''', ''RETURN'')');

  -- ---------------------------------------------------------------- оплата
  fails('Недостатньо готівки', 'RETAIL_UNDERPAID', 'begin trade_retail.pay(''' || k1 || ''', 500, null); end;');
  fails('Картка понад суму', 'RETAIL_CARD_EXCEEDS_TOTAL', 'begin trade_retail.pay(''' || k1 || ''', null, 700); end;');
  fails('Від''ємна оплата', 'RETAIL_PAYMENT_NEGATIVE', 'begin trade_retail.pay(''' || k1 || ''', -1, null); end;');
  fails('Оплата без чека', 'NO_LINES', 'begin trade_retail.pay(null, 100, null); end;');
  l_v := cash(l_desk);
  trade_warn.clear;
  trade_retail.pay(k1, 1000, null);
  eqs('Оплата готівкою: проведено, решта 400', hdr(k1, 'status || ''|'' || paid_cash || ''|'' || nvl(to_char(paid_card), ''-'') || ''|'' || change_amount'),
      'POSTED|1000|-|400');
  eq('Склад: Кава −5', stock(l_a), 5);
  eq('Собівартість: Кава 600 − 300', cost(l_a), 300);
  select cost_amount into l_n from doc_retail_receipt_goods where document_id = k1;
  eq('Собівартість рядка чека', l_n, 300);
  select count(*) into l_n from reg_sales_turnover
   where recorder_id = k1 and counterparty_id = l_cp and warehouse_id = l_wh and product_id = l_a and quantity = 5 and amount = 600
     and organization_id = l_org;
  eq('Продажі: роздрібний покупець, організація', l_n, 1);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = k1 and organization_id = l_org and cost_amount = -300;
  eq('Собівартість: організація руху', l_n, 1);
  eq('Каса: + 600 (без решти)', cash(l_desk) - l_v, 600);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = k1 and operation_kind = 'RETAIL_SALE' and content like 'Чек ККМ № %';
  eq('Рух коштів: вид операції й зміст', l_n, 1);
  -- ПРРО-заглушка
  select d.fiscal_status || '|' || case when d.fiscal_number like r.fiscal_number || '.000001' then 'fn' end || '|'
         || case when d.fiscal_url like 'https://cabinet.tax.gov.ua/cashregs/check?fn=' || r.fiscal_number || '%sm=600.00' then 'url' end
         || '|' || case when d.fiscal_at is not null then 'at' end || '|' || r.fiscal_seq
    into l_s from doc_retail_receipt d join ref_cash_register r on r.id = d.cash_register_id where d.id = k1;
  eqs('ПРРО: фіскальний номер, посилання, час, лічильник 1', l_s, 'FISCALIZED|fn|url|at|1');
  select json_value(fiscal_payload, '$.total_sum') || '|' || json_value(fiscal_payload, '$.goods[0].quantity') || '|'
         || json_value(fiscal_payload, '$.goods[0].good.price') || '|' || json_value(fiscal_payload, '$.payments[0].value') || '|'
         || json_value(fiscal_payload, '$.rest') || '|' || json_value(fiscal_payload, '$.type')
    into l_s from doc_retail_receipt where id = k1;
  eqs('ПРРО: JSON-запит (копійки, кількість × 1000)', l_s, '60000|5000|12000|100000|40000|SELL');
  select count(*) into l_n from sys_audit_log where object_type = 'DocRetailReceipt' and object_id = k1 and action in ('POST', 'FISCALIZE');
  eq('Журнал: проведення й фіскалізація', l_n, 2);
  fails('Фіскалізований чек не скасовується', 'RETAIL_FISCALIZED', 'begin trade_retail.unpost(''' || k1 || '''); end;');
  fails('Повторне проведення фіскалізованого', 'RETAIL_FISCALIZED', 'begin trade_retail.post(''' || k1 || '''); end;');
  fails('Проведений чек лише для читання', 'DOCUMENT_READ_ONLY', 'update doc_retail_receipt set doc_comment = ''x'' where id = ''' || k1 || '''');
  fails('Рядки проведеного чека не змінюються', 'рядки доступні лише для читання', 'begin trade_retail.add_product(''' || k1 || ''', ''' || l_a || ''', 1); end;');
  fails('Проведений чек не видаляється', 'DOCUMENT_POSTED', 'delete from doc_retail_receipt where id = ''' || k1 || '''');
  fails('Оплата проведеного', 'RETAIL_NOT_DRAFT', 'begin trade_retail.pay(''' || k1 || ''', 1, null); end;');
  eqs('Сканування після оплати — новий чек', case when trade_retail.scan(l_reg, k1, 'T24A' || substr(t, 1, 6)) <> k1 then 'new' end, 'new');
  k2 := trade_retail.open_draft(l_reg);
  eqs('Відкрита чернетка користувача', case when k2 is not null and k2 <> k1 then 'Y' end, 'Y');
  l_c := trade_retail.last_html(k1);
  eq('РМК: останній чек — решта й ФН', case when instr(l_c, 'Решта') > 0 and instr(l_c, to_char(400, 'FM999G999G999G990D00')) > 0
                                              and instr(l_c, 'фіскальний номер') > 0 then 1 else 0 end, 1);

  -- Картка: 120 карткою на рахунок
  l_v := cash(l_bank);
  trade_retail.pay(k2, null, 120);
  eqs('Оплата карткою: решта 0', hdr(k2, 'status || ''|'' || nvl(to_char(paid_cash), ''-'') || ''|'' || paid_card || ''|'' || change_amount'),
      'POSTED|-|120|0');
  eq('Рахунок: + 120', cash(l_bank) - l_v, 120);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = k2 and place_kind = 'CASH_DESK';
  eq('Картка: руху каси немає', l_n, 0);
  select fiscal_seq into l_n from ref_cash_register where id = l_reg;
  eq('Лічильник фіскальних чеків 2', l_n, 2);
  -- Змішана: 2 × Хліб + Кава = 162.80: картка 100, готівка 100 → решта 37.20, у касу 62.80
  k3 := trade_retail.new_receipt(l_reg);
  trade_retail.add_product(k3, l_a, 1);
  trade_retail.add_product(k3, l_b, 2);
  l_v := cash(l_desk);
  trade_retail.pay(k3, 100, 100);
  eqs('Змішана оплата: решта 37.20', hdr(k3, 'change_amount'), '37.2');
  eq('Каса: + 62.80', cash(l_desk) - l_v, 62.8);
  select json_value(fiscal_payload, '$.payments[1].value') into l_s from doc_retail_receipt where id = k3;
  eqs('JSON: безготівкова оплата 10000', l_s, '10000');

  -- ---------------------------------------------------------------- нефіскальна каса, FEFO, скасування
  k4 := trade_retail.new_receipt(l_reg2);
  trade_retail.add_product(k4, l_m, 4);
  trade_retail.add_product(k4, l_a, 1);
  trade_retail.post(k4);   -- без оплати — готівкою без решти
  eqs('Нефіскальна каса: проведено, NOT_FISCAL, готівка = сума', hdr(k4, 'status || ''|'' || fiscal_status || ''|'' || paid_cash || ''|'' || nvl(fiscal_number, ''-'')'),
      'POSTED|NOT_FISCAL|280|-');
  select listagg(r.name || ':' || g.quantity, ',') within group (order by g.line_number) into l_s
    from doc_retail_receipt_goods g join ref_product_series r on r.id = g.series_id where g.document_id = k4;
  eqs('FEFO: серії M-1 (2) і M-2 (2)', l_s, 'M-1:2,M-2:2');
  eqs('FEFO: сума чека не змінилась', hdr(k4, 'total_amount'), '280');
  select count(*) into l_n from reg_stock_balance_movement where recorder_id = k4 and series_id is not null;
  eq('Рухи складу з серіями', l_n, 2);
  l_c := trade_print.document_html('RETAIL_RECEIPT', k4);
  eq('Друк: нефіскальний чек', case when instr(l_c, 'НЕФІСКАЛЬНИЙ ЧЕК') > 0 and instr(l_c, 'T24 Молоко') > 0 then 1 else 0 end, 1);
  l_v := cash(l_desk);
  trade_retail.unpost(k4);
  eqs('Скасування нефіскального', hdr(k4, 'status || ''|'' || fiscal_status'), 'DRAFT|PENDING');
  eq('Скасування: рухів немає', mv('reg_stock_balance_movement', k4) + mv('reg_sales_turnover', k4) + mv('reg_stock_cost_mv', k4)
                                 + mv('reg_cash_balance_mv', k4), 0);
  eq('Скасування: каса − 280', cash(l_desk) - l_v, -280);
  fails('Скасування непроведеного', 'NOT_POSTED', 'begin trade_retail.unpost(''' || k4 || '''); end;');
  trade_retail.post(k4);
  eq('Повторне проведення', mv('reg_stock_balance_movement', k4), 3);
  x := trade_retail.copy(k3);
  select count(*) into l_n from doc_retail_receipt_goods where document_id = x and price is not null;
  eqs('Копія: чернетка з рядками', hdr(x, 'status || ''|'' || cash_register_id || ''|'' || total_amount') || '|' || l_n,
      'DRAFT|' || l_reg || '|162.8|2');
  trade_retail.cancel_receipt(x);
  select count(*) into l_n from doc_retail_receipt where id = x;
  eq('Скасування чернетки на РМК видаляє чек', l_n, 0);
  -- Нестача
  k5 := trade_retail.new_receipt(l_reg2);
  trade_retail.add_product(k5, l_a, 50);
  fails('Нестача товару', 'INSUFFICIENT_FREE_STOCK', 'begin trade_retail.pay(''' || k5 || ''', 10000, null); end;');
  fails('Чек без рядків', 'NO_LINES', 'declare x varchar2(32) := trade_retail.new_receipt(''' || l_reg2 || '''); begin trade_retail.post(x); end;');
  -- Організація-неплатник ПДВ → «Без ПДВ»
  insert into ref_cash_register (name, cash_desk_id, warehouse_id, price_type_id, is_fiscal) values ('T24 ККМ ФОП ' || t, l_desk2, l_wh, l_pt, 'N')
    returning id into x;
  k5 := trade_retail.new_receipt(x);
  trade_retail.add_product(k5, l_a, 1);
  select vat_rate_code || '|' || vat_amount into l_s from doc_retail_receipt_goods where document_id = k5;
  eqs('Неплатник ПДВ: NOVAT', l_s, 'NOVAT|0');

  -- ---------------------------------------------------------------- друк, перерахунок, реєстратор, меню
  l_c := trade_print.document_html(trade_print.default_form(k1), k1);
  eq('Друк: фіскальний чек', case when instr(l_c, 'ФІСКАЛЬНИЙ ЧЕК') > 0 and instr(l_c, 'ФН чека') > 0 and instr(l_c, 'T24 Кава') > 0
                                      and instr(l_c, 'ПДВ А 20 %') > 0 and instr(l_c, 'РЕШТА') > 0 then 1 else 0 end, 1);
  eqs('Форми друку чека', trade_print.forms_of(k1), 'RETAIL_RECEIPT:Касовий чек');
  trade_r3.rebuild_stock_cost;
  select cost_amount into l_n from doc_retail_receipt_goods where document_id = k1;
  eq('Перерахунок собівартості враховує чеки', l_n, 300);
  eq('Перерахунок: Кава', cost(l_a), 600 - 300 - 60 - 60 - 60);
  select count(*) into l_n from v_recorder where recorder_id in (k1, k2) and recorder_type = 'DocRetailReceipt' and page_id = 651;
  eq('Реєстратор → сторінка 651', l_n, 2);
  select count(*) into l_n from v_product_card_movement where recorder_id = k1;
  eq('Картка товару бачить чек', case when l_n > 0 then 1 else 0 end, 1);
  select count(*) into l_n from v_retail_receipt_list where cash_register_id in (l_reg, l_reg2);
  eq('Список чеків', l_n, 5);
  select count(*) into l_n from v_cash_register_list where id in (l_reg, l_reg2);
  eq('Список кас ККМ', l_n, 2);
  select count(*) into l_n from sys_audit_log where object_type = 'DocRetailReceipt' and object_id = k3 and action = 'CREATE';
  eq('Журнал реєстрації: створення чека', l_n, 1);
  select count(*) into l_n from user_triggers where trigger_name in ('DOC_RETAIL_RECEIPT_EVLOG', 'REF_CASH_REGISTER_EVLOG');
  eq('Тригери журналу', l_n, 2);
  eqs('trade_org.doc_table', trade_org.doc_table('DocRetailReceipt'), 'DOC_RETAIL_RECEIPT');
  trade_core.mark_for_deletion('REF_CASH_REGISTER', l_reg2);
  fails('Чек на помічену касу', 'помічене на видалення', 'insert into doc_retail_receipt (cash_register_id) values (''' || l_reg2 || ''')');
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'DocRetailReceipt' and list_page_id = 650 and form_page_id = 651 and auth_scheme = 'Роль: продажі або каса')
      or (tech_name = 'CashierWorkplace' and list_page_id = 660 and auth_scheme = 'Роль: продажі або каса')
      or (tech_name = 'RefCashRegister' and list_page_id = 640 and form_page_id = 641);
  eq('Об''єкти меню', l_n, 3);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Sales' and f.group_name = 'Роздрібні продажі' and o.tech_name in ('DocRetailReceipt', 'CashierWorkplace');
  eq('Панель «Продажі → Роздрібні продажі»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100
     and p.page_id in (650, 651, 660) and p.authorization_scheme = 'Роль: продажі або каса';
  eq('Сторінки 650/651/660 захищені роллю «продажі або каса»', l_n, 3);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (640, 641);
  eq('Сторінки кас ККМ 640/641', l_n, 2);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
