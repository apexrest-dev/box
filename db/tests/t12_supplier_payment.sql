-- F-PUR-05 «Оплата постачальнику» DocSupplierPayment (r4): джерело коштів (рахунок / каса) і рух
-- RegCashBalance, договір і замовлення постачальнику, введення на підставі, контроль залишку й переплати,
-- правило одного платежу з банківською випискою (автозв'язок, заборона подвійного проведення, захист
-- прив'язаної оплати), друк платіжної інструкції й КО-2, делегування trade_doc, меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  d0 date := trunc(sysdate) - 10;
  l_org varchar2(32); l_org2 varchar2(32); l_k varchar2(32); l_k2 varchar2(32); l_a varchar2(32); l_ausd varchar2(32);
  l_wh varchar2(32); l_uom varchar2(32); l_p varchar2(32); l_sup varchar2(32); l_sup2 varchar2(32);
  l_ctr varchar2(32); l_ctr2 varchar2(32); l_ord varchar2(32); l_ord2 varchar2(32); l_rcp varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); p4 varchar2(32); x varchar2(32); s1 varchar2(32); s2 varchar2(32); l1 varchar2(32);
  l_iban_sup varchar2(34); i1 varchar2(34); i2 varchar2(34);
  l_n number; l_s varchar2(4000); l_c clob; r doc_supplier_payment%rowtype;

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
  function mk_iban (p_mfo varchar2, p_acc varchar2) return varchar2 is
    l_bban varchar2(25) := p_mfo || lpad(p_acc, 19, '0');
  begin
    return 'UA' || lpad(98 - mod(to_number(l_bban || '301000'), 97), 2, '0') || l_bban;
  end;
  function bal (p_place varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_mv where coalesce(cash_desk_id, bank_account_id) = p_place;
    return l;
  end;
  function debt (p_cp varchar2 default null) return number is
  begin
    return trade_cash_doc.counterparty_debt(l_org, coalesce(p_cp, l_sup), 'PAYABLE');
  end;
  function moves (p_id varchar2) return number is
    l number; l2 number;
  begin
    select count(*) into l from reg_cash_balance_mv where recorder_id = p_id;
    select count(*) into l2 from reg_counterparty_settlement_mv where recorder_id = p_id;
    return l + l2;
  end;
  function st (p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    select max(status) into l from v_payment_doc where id = p_id;
    if l is null then select max(status) into l from doc_bank_statement where id = p_id; end if;
    return l;
  end;
  function pay (p_amount number, p_date date default sysdate - 1, p_form varchar2 default null,
                p_desk varchar2 default null, p_order varchar2 default null, p_cp varchar2 default null) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_supplier_payment (organization_id, supplier_id, amount, occurred_at, payment_form, cash_desk_id, supplier_order_id)
    values (l_org, coalesce(p_cp, l_sup), p_amount, p_date, p_form, p_desk, p_order) returning id into l;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  l_iban_sup := mk_iban('305299', substr(to_char(abs(dbms_random.random)), 1, 9) || '12');
  i1 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '41');
  i2 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '42');
  insert into ref_organization (name, org_kind, edrpou, director_name, accountant_name)
  values ('T12 ТОВ ' || t, 'LEGAL', '31234567', 'Директор Т12', 'Бухгалтер Т12') returning id into l_org;
  insert into ref_organization (name, org_kind) values ('T12 Інша ' || t, 'LEGAL') returning id into l_org2;
  insert into ref_cash_desk (name, organization_id, responsible_name) values ('T12 Каса ' || t, l_org, 'Касир Т12') returning id into l_k;
  insert into ref_cash_desk (name, organization_id) values ('T12 Каса інша ' || t, l_org2) returning id into l_k2;
  insert into ref_bank_account (organization_id, iban, bank_name, is_default) values (l_org, i1, 'T12 Банк', 'Y') returning id into l_a;
  insert into ref_bank_account (organization_id, iban, bank_name, currency_code) values (l_org, i2, 'T12 Банк USD', 'USD') returning id into l_ausd;
  trade_cash.set_opening_balance('BANK_ACCOUNT', l_a, d0, 3000);
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 500);
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T12 склад ' || t) returning id into l_wh;
  insert into ref_product (name, unit_of_measure_id) values ('T12 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_counterparty (name, edrpou, iban) values ('T12 постачальник ' || t, '32345678', l_iban_sup) returning id into l_sup;
  insert into ref_counterparty (name) values ('T12 інший постачальник ' || t) returning id into l_sup2;
  insert into ref_contract (owner_id, name, contract_number, contract_kind) values (l_sup, 'T12 Договір поставки', 'П-12', 'WITH_SUPPLIER')
    returning id into l_ctr;
  insert into ref_contract (owner_id, name, contract_kind) values (l_sup2, 'T12 Чужий договір', 'WITH_SUPPLIER') returning id into l_ctr2;
  -- замовлення 10 × 400 = 4000, надходження за ним 10 × 400 (кредиторка 4000)
  insert into doc_supplier_order (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 5)
    returning id into l_ord;
  insert into doc_supplier_order_goods (document_id, product_id, quantity, price) values (l_ord, l_p, 10, 400);
  trade_r3.post_supplier_order(l_ord);
  insert into doc_supplier_order (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 5)
    returning id into l_ord2;   -- чернетка
  l_rcp := trade_r3.receipt_from_order(l_ord);
  update doc_goods_receipt set occurred_at = sysdate - 4 where id = l_rcp;
  trade_doc.post_goods_receipt(l_rcp);
  eq('Підготовка: кредиторка', debt, 4000);

  -- ---------------------------------------------------------------- шапка: значення за замовчуванням і перевірки
  p1 := pay(300);
  select * into r from doc_supplier_payment where id = p1;
  eqs('Форма за замовчуванням — безготівкова', r.payment_form, 'BANK');
  eqs('Рахунок — основний рахунок організації', r.bank_account_id, l_a);
  eqs('Каса для безготівкової — порожня', r.cash_desk_id, null);
  eqs('IBAN отримувача — з довідника контрагентів', r.recipient_iban, l_iban_sup);
  eqs('Договір — єдиний договір постачальника', r.contract_id, l_ctr);
  eqs('Призначення платежу за замовчуванням', r.purpose, 'Оплата за товар згідно з договором № П-12');
  fails('Сума ≤ 0', 'PAYMENT_AMOUNT', 'update doc_supplier_payment set amount = 0 where id = ''' || p1 || '''');
  fails('Рахунок у USD', 'PAYMENT_CURRENCY', 'update doc_supplier_payment set bank_account_id = ''' || l_ausd || ''' where id = ''' || p1 || '''');
  fails('Каса іншої організації', 'PAYMENT_DESK_ORGANIZATION',
        'update doc_supplier_payment set payment_form = ''CASH'', cash_desk_id = ''' || l_k2 || ''' where id = ''' || p1 || '''');
  fails('Договір іншого контрагента', 'CONTRACT_OWNER_MISMATCH',
        'update doc_supplier_payment set contract_id = ''' || l_ctr2 || ''' where id = ''' || p1 || '''');
  fails('Замовлення іншого постачальника', 'PAYMENT_ORDER_SUPPLIER',
        'insert into doc_supplier_payment (organization_id, supplier_id, amount, supplier_order_id) values (''' || l_org || ''', '''
        || l_sup2 || ''', 10, ''' || l_ord || ''')');
  fails('Непроведене замовлення', 'PAYMENT_ORDER_NOT_POSTED',
        'update doc_supplier_payment set supplier_order_id = ''' || l_ord2 || ''' where id = ''' || p1 || '''');
  fails('Некоректний IBAN отримувача', 'BANK_ACCOUNT_IBAN',
        'update doc_supplier_payment set recipient_iban = ''UA000000000000000000000000000'' where id = ''' || p1 || '''');

  -- ---------------------------------------------------------------- проведення: рахунок
  trade_pay_doc.post_supplier_payment(p1);
  eqs('Проведено', st(p1), 'POSTED');
  eq('Рахунок: 3000 − 300', bal(l_a), 2700);
  eq('Кредиторка: 4000 − 300', debt, 3700);
  trade_pay_doc.post_supplier_payment(p1);
  eq('Повторне проведення замінює рухи (1 кошти + 1 розрахунки)', moves(p1), 2);
  eq('Рахунок після повторного проведення', bal(l_a), 2700);
  select count(*) into l_n from reg_counterparty_settlement_mv where recorder_id = p1 and organization_id = l_org and direction = 'PAYABLE';
  eq('Рух розрахунків з організацією документа', l_n, 1);
  fails('Проведений документ — лише читання', 'DOCUMENT_READ_ONLY', 'update doc_supplier_payment set amount = 1 where id = ''' || p1 || '''');
  fails('Проведений документ не видаляється', 'DOCUMENT_POSTED', 'delete from doc_supplier_payment where id = ''' || p1 || '''');
  p2 := pay(2800);
  fails('Недостатньо коштів на рахунку (2700 < 2800)', 'BANK_BALANCE_NEGATIVE', 'begin trade_pay_doc.post_supplier_payment(''' || p2 || '''); end;');
  eqs('Після помилки — чернетка', st(p2), 'DRAFT');
  delete from doc_supplier_payment where id = p2;

  -- ---------------------------------------------------------------- проведення: каса
  p2 := pay(200, p_form => 'CASH');
  select cash_desk_id, bank_account_id, recipient_iban into r.cash_desk_id, r.bank_account_id, r.recipient_iban from doc_supplier_payment where id = p2;
  eqs('Готівкова: каса за замовчуванням', r.cash_desk_id, l_k);
  eqs('Готівкова: рахунку й IBAN немає', r.bank_account_id || r.recipient_iban, null);
  trade_doc.post_supplier_payment(p2);   -- r1-API делегує в trade_pay_doc
  eq('trade_doc.post_supplier_payment рухає касу: 500 − 200', bal(l_k), 300);
  eq('Кредиторка: 3700 − 200', debt, 3500);
  p3 := pay(301, p_form => 'CASH');
  fails('Недостатньо готівки в касі', 'CASH_BALANCE_NEGATIVE', 'begin trade_pay_doc.post_supplier_payment(''' || p3 || '''); end;');
  delete from doc_supplier_payment where id = p3;
  trade_doc.unpost_supplier_payment(p2);
  eq('Скасування повертає готівку', bal(l_k), 500);
  eq('Скасування повертає борг', debt, 3700);
  x := trade_doc.copy_supplier_payment(p2);
  select * into r from doc_supplier_payment where id = x;
  eqs('Копія: форма, каса, договір', r.payment_form || '/' || case when r.cash_desk_id = l_k then 'k' end || '/' || case when r.contract_id = l_ctr then 'c' end, 'CASH/k/c');
  eqs('Копія — чернетка', r.status, 'DRAFT');
  delete from doc_supplier_payment where id = x;
  delete from doc_supplier_payment where id = p2;

  -- ---------------------------------------------------------------- переплата
  p3 := pay(2000);
  trade_pay_doc.post_supplier_payment(p3);   -- кредиторка 1700, рахунок 700
  p4 := pay(1700.01, p_form => 'CASH');
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 5000);
  fails('Переплата постачальнику (аванс заборонено)', 'SETTLEMENT_NEGATIVE', 'begin trade_pay_doc.post_supplier_payment(''' || p4 || '''); end;');
  delete from doc_supplier_payment where id = p4;

  -- ---------------------------------------------------------------- введення на підставі
  x := trade_pay_doc.payment_from_goods_receipt(l_rcp);
  select * into r from doc_supplier_payment where id = x;
  eq('Оплата за накладною: залишок боргу', r.amount, 1700);
  eqs('Підстава — накладна', r.base_doc_type, 'DocGoodsReceipt');
  eqs('Замовлення — з накладної', r.supplier_order_id, l_ord);
  eqs('Організація — з підстави', r.organization_id, l_org);
  eqs('Призначення за накладною й договором', case when r.purpose like 'Оплата за товар згідно з прибутковою накладною № %, договором № П-12' then 'так' end, 'так');
  delete from doc_supplier_payment where id = x;
  update doc_supplier_payment set supplier_order_id = l_ord where id = p3 and status = 'DRAFT';
  -- оплата за замовленням: сума замовлення 4000 − сплачено за замовленням (0), не більше боргу 1700
  x := trade_pay_doc.payment_from_supplier_order(l_ord);
  select * into r from doc_supplier_payment where id = x;
  eq('Оплата за замовленням: не більше боргу', r.amount, 1700);
  eqs('Підстава — замовлення, замовлення заповнено', r.base_doc_type || '/' || case when r.supplier_order_id = l_ord then 'o' end, 'DocSupplierOrder/o');
  update doc_supplier_payment set amount = 1000, payment_form = 'CASH' where id = x;
  trade_pay_doc.post_supplier_payment(x);
  eq('Сплачено за замовленням', trade_pay_doc.paid_by_order(l_ord), 1000);
  fails('Оплата за непроведеним замовленням', 'PAYMENT_BASE_NOT_POSTED',
        'declare v varchar2(32); begin v := trade_pay_doc.payment_from_supplier_order(''' || l_ord2 || '''); end;');
  trade_pay_doc.unpost_supplier_payment(x);
  delete from doc_supplier_payment where id = x;

  -- ---------------------------------------------------------------- банківська виписка: правило одного платежу
  -- рахунок 700 (3000 − 300 − 2000), кредиторка 1700
  eq('Перед випискою: рахунок', bal(l_a), 700);
  insert into doc_bank_statement (organization_id, bank_account_id, occurred_at) values (l_org, l_a, trunc(sysdate) - 1 + 18/24)
    returning id into s1;
  l1 := trade_bank_doc.add_line(s1, 'OUT', 300, 'Оплата за товар', 'T12 постачальник', '32345678', l_iban_sup, '777', trunc(sysdate) - 1);
  l1 := trade_bank_doc.add_line(s1, 'OUT', 2000, 'Оплата за товар', 'T12 постачальник', '32345678', l_iban_sup, '778', trunc(sysdate) - 1);
  trade_bank_doc.post(s1);
  select count(*) into l_n from doc_bank_statement_line where document_id = s1 and payment_doc_id in (p1, p3);
  eq('Рядки виписки автоматично прив''язані до оплат', l_n, 2);
  eq('Виписка не пише рухів за прив''язаними рядками', moves(s1), 0);
  eq('Рахунок не змінився (рух уже записала оплата)', bal(l_a), 700);
  eq('Кредиторка не змінилась', debt, 1700);
  fails('Скасування оплати, прив''язаної до проведеної виписки', 'PAYMENT_LINKED_TO_STATEMENT',
        'begin trade_pay_doc.unpost_supplier_payment(''' || p1 || '''); end;');
  select statement_number into l_s from v_supplier_payment_list where id = p1;
  eqs('Список оплат показує виписку', case when l_s is not null then 'так' end, 'так');
  trade_bank_doc.unpost(s1);
  trade_pay_doc.unpost_supplier_payment(p1);
  fails('Проведення виписки з непроведеною оплатою', 'BANK_PAYMENT_NOT_POSTED', 'begin trade_bank_doc.post(''' || s1 || '''); end;');
  fails('Видалення оплати, вказаної у виписці', 'PAYMENT_LINKED_TO_STATEMENT', 'delete from doc_supplier_payment where id = ''' || p1 || '''');
  select id into l1 from doc_bank_statement_line where document_id = s1 and payment_doc_id = p1;
  fails('Рядок і оплата — різні суми', 'BANK_PAYMENT_AMOUNT', 'update doc_bank_statement_line set amount = 301 where id = ''' || l1 || '''');
  p2 := pay(50, p_form => 'CASH');
  fails('У виписці — лише безготівкова оплата', 'BANK_PAYMENT_FORM',
        'update doc_bank_statement_line set payment_doc_id = ''' || p2 || ''' where id = ''' || l1 || '''');
  delete from doc_supplier_payment where id = p2;
  fails('Одна оплата — один рядок виписки', 'ORA-00001',
        'insert into doc_bank_statement_line (document_id, operation_kind, direction, amount, counterparty_id, payment_doc_id) values ('''
        || s1 || ''', ''SUPPLIER_PAYMENT'', ''OUT'', 2000, ''' || l_sup || ''', ''' || p3 || ''')');
  -- рядок без оплати проводить сама виписка; повторне оформлення того ж платежу документом заборонене
  update doc_bank_statement_line set payment_doc_id = null where id = l1;
  trade_bank_doc.post(s1);   -- p1 чернетка: автозв'язок не спрацьовує, рядок рухає рахунок і борг
  select count(*) into l_n from doc_bank_statement_line where id = l1 and payment_doc_id is null;
  eq('Чернетку оплати не прив''язано', l_n, 1);
  eq('Неприв''язаний рядок провела виписка (рахунок 700 + 300 − 300)', bal(l_a), 700);
  fails('Платіж уже відображено випискою', 'PAYMENT_ALREADY_IN_STATEMENT', 'begin trade_pay_doc.post_supplier_payment(''' || p1 || '''); end;');
  eq('Кредиторка рахується один раз', debt, 1700);
  trade_bank_doc.unpost(s1);
  trade_pay_doc.post_supplier_payment(p1);
  trade_bank_doc.post(s1);
  select count(*) into l_n from doc_bank_statement_line where id = l1 and payment_doc_id = p1;
  eq('Після проведення оплати рядок прив''язано знову', l_n, 1);
  eq('Рахунок після перепроведення (без подвійного руху)', bal(l_a), 700);

  -- ---------------------------------------------------------------- друк
  eqs('Форма друку безготівкової оплати', trade_print.default_form(p1), 'PAYMENT_ORDER');
  l_c := trade_print.document_html('PAYMENT_ORDER', p1);
  eqs('Платіжна інструкція: заголовок', case when instr(l_c, 'ПЛАТІЖНА ІНСТРУКЦІЯ') > 0 then 'так' end, 'так');
  eqs('Платіжна інструкція: IBAN платника й отримувача', case when instr(l_c, i1) > 0 and instr(l_c, l_iban_sup) > 0 then 'так' end, 'так');
  eqs('Платіжна інструкція: коди ЄДРПОУ', case when instr(l_c, '31234567') > 0 and instr(l_c, '32345678') > 0 then 'так' end, 'так');
  eqs('Платіжна інструкція: сума й прописом', case when instr(l_c, to_char(300, 'FM999G999G999G990D00')) > 0
       and instr(lower(l_c), 'триста') > 0 then 'так' end, 'так');
  eqs('Платіжна інструкція: проведений документ без водяного знака', case when instr(l_c, 'ЧЕРНЕТКА') = 0 then 'так' end, 'так');
  p2 := pay(10, p_form => 'CASH');
  eqs('Форма друку готівкової оплати', trade_print.default_form(p2), 'PAY_KO2');
  eqs('Перелік форм готівкової оплати', trade_print.forms_of(p2), 'PAY_KO2:Видатковий касовий ордер (КО-2)');
  l_c := trade_print.document_html('PAY_KO2', p2);
  eqs('КО-2: заголовок і касир', case when instr(l_c, 'Видатковий касовий ордер') > 0 and instr(l_c, 'Касир Т12') > 0 then 'так' end, 'так');
  eqs('КО-2: чернетка з водяним знаком', case when instr(l_c, 'ЧЕРНЕТКА') > 0 then 'так' end, 'так');
  l_c := trade_print.document_html('PAYMENT_ORDER', p2);
  eqs('Платіжна інструкція для готівкової — відмова', case when instr(l_c, 'лише для безготівкової') > 0 then 'так' end, 'так');
  trade_pay_doc.post_supplier_payment(p2);
  l_c := trade_cash_doc.cash_book_html(l_k, trunc(sysdate) - 1, trunc(sysdate) - 1);
  eqs('Касова книга містить готівкову оплату постачальнику', case when instr(l_c, 'Оплата постачальнику №') > 0 then 'так' end, 'так');

  -- ---------------------------------------------------------------- меню й права
  select max(auth_scheme) into l_s from sys_metadata_object where tech_name = 'DocSupplierPayment';
  eqs('Права: закупівлі або каса', l_s, 'Роль: закупівлі або каса');
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id where s.tech_name = 'Finance' and o.tech_name = 'DocSupplierPayment';
  eq('«Фінанси → Банк»: оплата постачальнику', l_n, 1);
  select count(*) into l_n from user_objects where status = 'INVALID';
  eq('Невалідних об''єктів схеми', l_n, 0);
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
rollback;
