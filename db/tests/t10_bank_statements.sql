-- F-FIN-04 «Банківські виписки» DocBankStatement: рядки операцій, рухи RegCashBalance (рахунок) і
-- RegCounterpartySettlement, контроль залишку рахунку й переплати, автопошук контрагента за ЄДРПОУ / IBAN
-- / історією, API імпорту add_line (дублі), рядки інкасації / зняття готівки з прив'язкою до ВКО/ПКО
-- (без повторного руху рахунку), меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  d0 date := trunc(sysdate) - 10;
  l_org varchar2(32); l_org2 varchar2(32); l_k varchar2(32); l_a varchar2(32); l_a2 varchar2(32); l_ausd varchar2(32);
  l_wh varchar2(32); l_uom varchar2(32); l_pt varchar2(32); l_p varchar2(32); l_cus varchar2(32); l_sup varchar2(32); l_cus2 varchar2(32);
  l_rcp varchar2(32); l_sale varchar2(32);
  s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); s4 varchar2(32); x varchar2(32); y varchar2(32); enc varchar2(32); wdr varchar2(32);
  l1 varchar2(32); l2 varchar2(32);
  l_iban_cus varchar2(34); l_iban_sup varchar2(34); l_iban_x varchar2(34); i1 varchar2(34); i2 varchar2(34); i3 varchar2(34);
  l_n number; l_s varchar2(4000);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or p_got is null and p_exp is null then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got);
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
  -- Коректний український IBAN: UA + контрольні цифри + МФО (6) + рахунок (19)
  function mk_iban (p_mfo varchar2, p_acc varchar2) return varchar2 is
    l_bban varchar2(25) := p_mfo || lpad(p_acc, 19, '0');
  begin
    return 'UA' || lpad(98 - mod(to_number(l_bban || '301000'), 97), 2, '0') || l_bban;
  end;
  function bal (p_place varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_tot where place_id = p_place;
    return l;
  end;
  function debt (p_dir varchar2, p_cp varchar2) return number is
  begin
    return trade_cash_doc.counterparty_debt(l_org, p_cp, p_dir);
  end;
  function st (p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    select status into l from doc_bank_statement where id = p_id;
    return l;
  end;
  function moves (p_id varchar2) return number is
    l number; l2 number;
  begin
    select count(*) into l from reg_cash_balance_mv where recorder_id = p_id;
    select count(*) into l2 from reg_counterparty_settlement_mv where recorder_id = p_id;
    return l + l2;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  l_iban_cus := mk_iban('300335', substr(to_char(abs(dbms_random.random)), 1, 9) || '11');
  l_iban_sup := mk_iban('305299', substr(to_char(abs(dbms_random.random)), 1, 9) || '22');
  l_iban_x   := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '33');
  i1 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '01');
  i2 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '02');
  i3 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '03');
  eqs('Генератор IBAN дає коректний IBAN', trade_fin.is_valid_ua_iban(l_iban_cus), 'Y');
  insert into ref_organization (name, org_kind) values ('T10 ТОВ ' || t, 'LEGAL') returning id into l_org;
  insert into ref_organization (name, org_kind) values ('T10 Інша ' || t, 'LEGAL') returning id into l_org2;
  insert into ref_cash_desk (name, organization_id) values ('T10 Каса ' || t, l_org) returning id into l_k;
  insert into ref_bank_account (organization_id, iban, bank_name) values (l_org, i1, 'T10 Банк')
    returning id into l_a;
  insert into ref_bank_account (organization_id, iban, bank_name) values (l_org2, i2, 'T10 Банк 2')
    returning id into l_a2;
  insert into ref_bank_account (organization_id, iban, bank_name, currency_code) values (l_org, i3, 'T10 Банк USD', 'USD')
    returning id into l_ausd;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T10 склад ' || t) returning id into l_wh;
  insert into ref_price_type (name) values ('T10 ціни ' || t) returning id into l_pt;
  insert into ref_product (name, unit_of_measure_id) values ('T10 Товар ' || t, l_uom) returning id into l_p;
  -- реквізити контрагентів (нові поля ref_counterparty)
  insert into ref_counterparty (name, edrpou) values ('T10 покупець ' || t, '9' || translate(substr(t, 1, 7), 'ABCDEF', '123456'))
    returning id into l_cus;
  insert into ref_counterparty (name, iban) values ('T10 постачальник ' || t, substr(l_iban_sup, 1, 4) || ' ' || substr(l_iban_sup, 5))
    returning id into l_sup;
  insert into ref_counterparty (name) values ('T10 покупець-2 ' || t) returning id into l_cus2;
  select iban into l_s from ref_counterparty where id = l_sup;
  eqs('IBAN контрагента нормалізовано (без пробілів)', l_s, l_iban_sup);
  fails('ЄДРПОУ контрагента — 8/10 цифр', 'COUNTERPARTY_EDRPOU', 'update ref_counterparty set edrpou = ''12AB'' where id = ''' || l_cus || '''');
  fails('IBAN контрагента з контрольною сумою', 'BANK_ACCOUNT_IBAN_CHECKSUM',
        'update ref_counterparty set iban = ''UA000000000000000000000000000'' where id = ''' || l_cus || '''');
  trade_cash.set_opening_balance('BANK_ACCOUNT', l_a, d0, 1000);
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 5000);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 3)
    returning id into l_rcp;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_p, 10, 100, 0);
  trade_doc.post_goods_receipt(l_rcp);
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id, occurred_at) values (l_org, l_cus, l_wh, l_pt, sysdate - 2)
    returning id into l_sale;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale, l_p, 4, 500);
  trade_ops.post_goods_sale(l_sale);
  eq('Підготовка: дебіторка покупця', debt('RECEIVABLE', l_cus), 2000);
  eq('Підготовка: кредиторка постачальнику', debt('PAYABLE', l_sup), 1000);

  -- ---------------------------------------------------------------- шапка
  insert into doc_bank_statement (bank_account_id, occurred_at) values (l_a, trunc(sysdate) - 1 + 9/24) returning id into s1;
  select organization_id || '|' || currency_code || '|' || status || '|' || source_format into l_s from doc_bank_statement where id = s1;
  eqs('Шапка: організація й валюта з рахунку, чернетка, ручне введення', l_s, l_org || '|UAH|DRAFT|MANUAL');
  fails('Рахунок іншої організації', 'BANK_ACCOUNT_ORGANIZATION',
        'insert into doc_bank_statement (organization_id, bank_account_id) values (''' || l_org || ''', ''' || l_a2 || ''')');
  fails('Рахунок обов''язковий', 'BANK_ACCOUNT_REQUIRED', 'insert into doc_bank_statement (organization_id) values (''' || l_org || ''')');
  fails('Порожня виписка не проводиться', 'BANK_NO_LINES', 'begin trade_bank_doc.post(''' || s1 || '''); end;');

  -- ---------------------------------------------------------------- рядки й автопошук
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose, cp_name, cp_edrpou)
  values (s1, 'CUSTOMER_PAYMENT', 1500, 'Оплата за товар згідно рах. № 1', 'ТОВ Покупець', (select edrpou from ref_counterparty where id = l_cus))
  returning id into l1;
  select counterparty_id || '|' || matched_by || '|' || direction || '|' || line_number into l_s from doc_bank_statement_line where id = l1;
  eqs('Автопошук контрагента за ЄДРПОУ', l_s, l_cus || '|EDRPOU|IN|1');
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose, cp_iban)
  values (s1, 'SUPPLIER_PAYMENT', 800, 'Оплата за товар', lower(l_iban_sup)) returning id into l2;
  select counterparty_id || '|' || matched_by || '|' || direction || '|' || cp_iban into l_s from doc_bank_statement_line where id = l2;
  eqs('Автопошук за IBAN (нормалізований)', l_s, l_sup || '|IBAN|OUT|' || l_iban_sup);
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose) values (s1, 'BANK_FEE', 20, 'Комісія банку');
  select total_in || '|' || total_out into l_s from doc_bank_statement where id = s1;
  eqs('Підсумки виписки: надходження / списання', l_s, '1500|820');
  fails('Сума рядка > 0', 'BANK_AMOUNT', 'insert into doc_bank_statement_line (document_id, operation_kind, amount) values (''' || s1 || ''', ''OTHER_IN'', 0)');
  fails('Розрахунки з контрагентом — лише UAH-рахунок', 'BANK_SETTLEMENT_CURRENCY',
        'declare s varchar2(32); begin insert into doc_bank_statement (bank_account_id) values (''' || l_ausd || ''') returning id into s;'
        || ' insert into doc_bank_statement_line (document_id, operation_kind, amount, counterparty_id) values (s, ''CUSTOMER_PAYMENT'', 1, ''' || l_cus || '''); end;');
  fails('Касовий ордер лише для рядків готівки', 'BANK_CASH_ORDER_NOT_ALLOWED',
        'update doc_bank_statement_line set cash_order_id = ''' || l_rcp || ''' where id = ''' || l1 || '''');

  -- ---------------------------------------------------------------- проведення
  trade_bank_doc.post(s1);
  eqs('Виписку проведено', st(s1), 'POSTED');
  eq('Рахунок: 1000 + 1500 − 800 − 20', bal(l_a), 1680);
  eq('Дебіторка після надходження', debt('RECEIVABLE', l_cus), 500);
  eq('Кредиторка після оплати постачальнику', debt('PAYABLE', l_sup), 200);
  select count(*) into l_n from reg_cash_balance_mv
   where recorder_type = 'DocBankStatement' and recorder_id = s1 and bank_account_id = l_a and place_kind = 'BANK_ACCOUNT'
     and organization_id = l_org and content like 'Виписка № %';
  eq('Рухи рахунку — по рядку на операцію', l_n, 3);
  select count(*) into l_n from reg_counterparty_settlement_mv
   where recorder_type = 'DocBankStatement' and recorder_id = s1 and organization_id = l_org
     and ((direction = 'RECEIVABLE' and amount = -1500 and counterparty_id = l_cus) or (direction = 'PAYABLE' and amount = -800 and counterparty_id = l_sup));
  eq('Рухи взаєморозрахунків по рядках з контрагентом', l_n, 2);
  fails('Проведена виписка лише для читання', 'DOCUMENT_READ_ONLY', 'update doc_bank_statement set doc_comment = ''x'' where id = ''' || s1 || '''');
  fails('Рядки проведеної виписки лише для читання', 'DOCUMENT_READ_ONLY', 'update doc_bank_statement_line set amount = 1 where id = ''' || l1 || '''');
  fails('Проведена виписка не видаляється', 'DOCUMENT_POSTED', 'delete from doc_bank_statement where id = ''' || s1 || '''');
  eq('Залишок на початок дня виписки', trade_bank_doc.opening_balance(s1), 1000);
  eq('Залишок на кінець дня виписки', trade_bank_doc.closing_balance(s1), 1680);

  -- переплата й від'ємний залишок
  insert into doc_bank_statement (bank_account_id, occurred_at) values (l_a, trunc(sysdate) - 1 + 15/24) returning id into s2;
  insert into doc_bank_statement_line (document_id, operation_kind, amount, counterparty_id) values (s2, 'CUSTOMER_PAYMENT', 600, l_cus);
  fails('Переплата покупця заборонена', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION', 'begin trade_bank_doc.post(''' || s2 || '''); end;');
  eqs('Невдале проведення: чернетка', st(s2), 'DRAFT');
  eq('Невдале проведення: без рухів', moves(s2), 0);
  update doc_bank_statement_line set operation_kind = 'OTHER_OUT', amount = 5000 where document_id = s2;
  fails('Списання понад залишок рахунку', 'BANK_BALANCE_NEGATIVE', 'begin trade_bank_doc.post(''' || s2 || '''); end;');
  select count(*) into l_n from doc_bank_statement_line where document_id = s2 and contract_id is null and direction = 'OUT';
  eq('Зміна виду операції: напрям перераховано', l_n, 1);

  -- скасування проведення
  fails('Скасування надходження, коли гроші вже витрачено', 'BANK_BALANCE_NEGATIVE',
        'begin update doc_bank_statement_line set amount = 1600 where document_id = ''' || s2 || '''; trade_bank_doc.post(''' || s2
        || '''); trade_bank_doc.unpost(''' || s1 || '''); end;');
  trade_bank_doc.unpost(s1);
  eqs('Скасування проведення: чернетка', st(s1), 'DRAFT');
  eq('Скасування: рухів немає', moves(s1), 0);
  eq('Скасування: дебіторка повернулась', debt('RECEIVABLE', l_cus), 2000);
  eq('Скасування: рахунок 1000', bal(l_a), 1000);
  trade_bank_doc.post(s1);
  eq('Повторне проведення', bal(l_a), 1680);
  fails('Скасування непроведеної виписки', 'DOCUMENT_NOT_POSTED', 'begin trade_bank_doc.unpost(''' || s2 || '''); end;');

  -- ---------------------------------------------------------------- імпорт (API add_line) і історія IBAN
  insert into doc_bank_statement (bank_account_id, occurred_at, source_format, source_name) values (l_a, trunc(sysdate) + 9/24, 'CSV', 't10.csv')
    returning id into s3;
  x := trade_bank_doc.add_line(s3, 'IN', 300, 'Оплата від покупця-2', 'Покупець-2', null, l_iban_cus, 'П-101', trunc(sysdate));
  select counterparty_id || '|' || operation_kind || '|' || ext_doc_number || '|' || cp_iban into l_s from doc_bank_statement_line where id = x;
  eqs('Імпорт: невідомий IBAN — без контрагента, вид за напрямом', l_s, '|CUSTOMER_PAYMENT|П-101|' || l_iban_cus);
  y := trade_bank_doc.add_line(s3, 'IN', 300, 'Оплата від покупця-2', 'Покупець-2', null, l_iban_cus, 'П-101', trunc(sysdate));
  eqs('Імпорт: дубль платіжки не додається', y, null);
  y := trade_bank_doc.add_line(s3, 'OUT', 100, 'Оплата постачальнику', null, null, l_iban_sup, 'П-102', trunc(sysdate));
  select counterparty_id || '|' || matched_by || '|' || operation_kind into l_s from doc_bank_statement_line where id = y;
  eqs('Імпорт: списання, автопошук за IBAN', l_s, l_sup || '|IBAN|SUPPLIER_PAYMENT');
  fails('Імпорт: рядок без контрагента не проводиться', 'BANK_COUNTERPARTY_REQUIRED', 'begin trade_bank_doc.post(''' || s3 || '''); end;');
  eq('Заповнити контрагентів: невідомий IBAN не знайдено', trade_bank_doc.fill_counterparties(s3), 0);
  -- вручну вказали контрагента → наступна виписка з тим самим IBAN знаходить його за історією
  update doc_bank_statement_line set counterparty_id = l_cus2 where id = x;
  insert into doc_bank_statement (bank_account_id, occurred_at) values (l_a, trunc(sysdate) + 10/24) returning id into s4;
  insert into doc_bank_statement_line (document_id, operation_kind, amount, cp_iban) values (s4, 'OTHER_IN', 50, l_iban_cus) returning id into y;
  select nvl(counterparty_id, '-') into l_s from doc_bank_statement_line where id = y;
  eqs('Тригер рядка шукає лише в довіднику (історія — командою)', l_s, '-');
  eq('Заповнити контрагентів: знайдено за історією', trade_bank_doc.fill_counterparties(s4), 1);
  select counterparty_id || '|' || matched_by into l_s from doc_bank_statement_line where id = y;
  eqs('Контрагент за історією виписок', l_s, l_cus2 || '|HISTORY');
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id, occurred_at) values (l_org, l_cus2, l_wh, l_pt, sysdate - 1)
    returning id into l_sale;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale, l_p, 1, 300);
  trade_ops.post_goods_sale(l_sale);
  trade_bank_doc.post(s3);
  eq('Імпортовану виписку проведено: рахунок 1680 + 300 − 100', bal(l_a), 1880);
  eq('Дебіторка покупця-2 погашена', debt('RECEIVABLE', l_cus2), 0);

  -- ---------------------------------------------------------------- готівка: інкасація і зняття з прив'язкою до ВКО/ПКО
  insert into doc_cash_payment (organization_id, operation_kind, cash_desk_id, amount, bank_account_id, occurred_at)
  values (l_org, 'ENCASHMENT', l_k, 700, l_a, trunc(sysdate) + 8/24) returning id into enc;
  trade_cash_doc.post_payment(enc);
  eq('ВКО «Інкасація» рухає рахунок', bal(l_a), 2580);
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose) values (s4, 'CASH_DEPOSIT', 700, 'Внесення готівки')
    returning id into l1;
  insert into doc_cash_receipt (organization_id, operation_kind, cash_desk_id, amount, bank_account_id, occurred_at)
  values (l_org, 'BANK_WITHDRAWAL', l_k, 200, l_a, trunc(sysdate) + 11/24) returning id into wdr;
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose) values (s4, 'CASH_WITHDRAWAL', 200, 'Зняття готівки')
    returning id into l2;
  fails('Рядок зняття без проведеного ПКО не проводиться', 'BANK_CASH_ORDER_REQUIRED', 'begin trade_bank_doc.post(''' || s4 || '''); end;');
  fails('ПКО замість ВКО для інкасації', 'BANK_CASH_ORDER_KIND',
        'update doc_bank_statement_line set cash_order_id = ''' || wdr || ''' where id = ''' || l1 || '''');
  fails('Сума рядка ≠ сума ордера', 'BANK_CASH_ORDER_AMOUNT',
        'begin update doc_bank_statement_line set amount = 1 where id = ''' || l1 || '''; update doc_bank_statement_line set cash_order_id = ''' || enc || ''' where id = ''' || l1 || '''; end;');
  update doc_bank_statement_line set cash_order_id = wdr where id = l2;
  fails('Прив''язаний ордер має бути проведений', 'BANK_CASH_ORDER_NOT_POSTED', 'begin trade_bank_doc.post(''' || s4 || '''); end;');
  trade_cash_doc.post_receipt(wdr);
  eq('ПКО «Отримання готівки» рухає рахунок', bal(l_a), 2380);
  eq('Автозв''язок: ВКО інкасації знайдено за рахунком і сумою', trade_bank_doc.link_cash_orders(s4), 1);
  select cash_order_id || '|' || cash_order_type into l_s from doc_bank_statement_line where id = l1;
  eqs('Рядок інкасації прив''язано до ВКО', l_s, enc || '|DocCashPayment');
  trade_bank_doc.post(s4);
  eq('Виписка не рухає рахунок повторно для готівки (лише +50)', bal(l_a), 2430);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = s4;
  eq('Рухи виписки з готівкою: лише рядок «інше надходження»', l_n, 1);
  fails('ВКО, прив''язаний до проведеної виписки, не скасовується', 'BANK_CASH_ORDER_LINKED',
        'begin trade_cash_doc.unpost_payment(''' || enc || '''); end;');
  fails('Один ордер — один рядок виписки', 'DOC_BANK_STMT_LINE_CASH_UK',
        'begin trade_bank_doc.unpost(''' || s4 || '''); insert into doc_bank_statement_line (document_id, operation_kind, amount, cash_order_id) values (''' || s4 || ''', ''CASH_WITHDRAWAL'', 200, ''' || wdr || '''); end;');
  trade_bank_doc.unpost(s4);
  trade_cash_doc.unpost_payment(enc);
  eqs('Після скасування виписки ВКО можна скасувати', 'ok', 'ok');
  fails('Чернетку ордера з рядка виписки не видалити', 'BANK_CASH_ORDER_LINKED', 'delete from doc_cash_payment where id = ''' || enc || '''');

  -- ---------------------------------------------------------------- копіювання
  x := trade_bank_doc.copy(s1);
  select count(*) into l_n from doc_bank_statement_line where document_id = x;
  eq('Копія: рядки скопійовано', l_n, 3);
  eqs('Копія — чернетка', st(x), 'DRAFT');
  y := trade_bank_doc.copy(s4);
  select count(*) into l_n from doc_bank_statement_line where document_id = y and cash_order_id is null and operation_kind like 'CASH%';
  eq('Копія: касові ордери не копіюються', l_n, 2);
  delete from doc_bank_statement where id = x;
  select count(*) into l_n from doc_bank_statement_line where document_id = x;
  eq('Видалення чернетки видаляє рядки', l_n, 0);

  -- ---------------------------------------------------------------- звіти, меню, сторінки
  select count(*) into l_n from v_cash_movement m join doc_bank_statement d on d.id = m.recorder_id
   where m.recorder_id = s1 and m.page_id = 401
     and m.recorder_name = 'Банківська виписка ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS');
  eq('Звіт коштів: реєстратор виписки → сторінка 401', l_n, 3);
  select count(*) into l_n from v_settlement_movement where recorder_id = s1;
  eq('Звіт взаєморозрахунків показує виписку', l_n, 2);
  select count(*) into l_n from v_bank_statement_list where id in (s1, s3, s4) and organization_id = l_org;
  eq('Список виписок', l_n, 3);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Finance' and o.auth_scheme = 'Роль: каса' and o.tech_name = 'DocBankStatement' and o.list_page_id = 400;
  eq('Панель «Фінанси → Банк»: виписки', l_n, 1);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100
     and p.page_id in (400, 401) and p.authorization_scheme = 'Роль: каса';
  eq('Сторінки 400/401 захищені роллю «каса»', l_n, 2);
  select count(*) into l_n from apex_application_page_items i where i.application_id = 100 and i.page_id = 41
     and i.item_name in ('P41_EDRPOU', 'P41_IBAN');
  eq('Форма контрагента: ЄДРПОУ і IBAN', l_n, 2);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
