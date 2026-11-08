-- F-SAL-07 «Оплата від покупця» DocCustomerPayment (r4): джерело коштів (рахунок / каса) і рух
-- RegCashBalance, договір, замовлення клієнта й рахунок на оплату (стан «Оплачено»), розшифровка платежу
-- FIFO за датою боргу (з пріоритетом підстави й замовлення), введення на підставі, контроль переплати,
-- правило одного платежу з банківською випискою, друк повідомлення про надходження й КО-1, делегування
-- trade_ops, меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  d0 date := trunc(sysdate) - 10;
  dp date := sysdate - 1;
  l_org varchar2(32); l_org2 varchar2(32); l_k varchar2(32); l_k2 varchar2(32); l_a varchar2(32); l_ausd varchar2(32);
  l_wh varchar2(32); l_uom varchar2(32); l_p varchar2(32); l_cus varchar2(32); l_cus2 varchar2(32); l_sup varchar2(32);
  l_ctr varchar2(32); l_ctr2 varchar2(32); l_ord varchar2(32); l_ord2 varchar2(32); l_rcp varchar2(32);
  s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); l_inv varchar2(32); l_inv2 varchar2(32); l_inv3 varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); p4 varchar2(32); x varchar2(32); st1 varchar2(32); l1 varchar2(32);
  l_iban_cus varchar2(34); i1 varchar2(34); i2 varchar2(34);
  l_n number; l_s varchar2(4000); l_c clob; r doc_customer_payment%rowtype;

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
  function debt return number is
  begin
    return trade_cash_doc.counterparty_debt(l_org, l_cus, 'RECEIVABLE');
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
  -- розшифровка: «документ:сума;…» (s1/s2/s3 — реалізації)
  function alloc (p_id varchar2) return varchar2 is
    l varchar2(4000);
  begin
    for a in (select settlement_doc_id, amount from doc_customer_payment_alloc where document_id = p_id order by line_number) loop
      l := l || case a.settlement_doc_id when s1 then 'S1' when s2 then 'S2' when s3 then 'S3' else '?' end || ':' || a.amount || ';';
    end loop;
    return l;
  end;
  function pay (p_amount number, p_form varchar2 default null, p_desk varchar2 default null,
                p_order varchar2 default null, p_invoice varchar2 default null) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at, payment_form, cash_desk_id, customer_order_id, invoice_id)
    values (l_org, l_cus, p_amount, dp, p_form, p_desk, p_order, p_invoice) returning id into l;
    return l;
  end;
  function sale (p_qty number, p_price number, p_date date) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, p_date) returning id into l;
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l, l_p, p_qty, p_price);
    trade_ops.post_goods_sale(l);
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  l_iban_cus := mk_iban('305299', substr(to_char(abs(dbms_random.random)), 1, 9) || '13');
  i1 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '51');
  i2 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '52');
  insert into ref_organization (name, org_kind, edrpou, director_name, accountant_name)
  values ('T13 ТОВ ' || t, 'LEGAL', '31234513', 'Директор Т13', 'Бухгалтер Т13') returning id into l_org;
  insert into ref_organization (name, org_kind) values ('T13 Інша ' || t, 'LEGAL') returning id into l_org2;
  insert into ref_cash_desk (name, organization_id, responsible_name) values ('T13 Каса ' || t, l_org, 'Касир Т13') returning id into l_k;
  insert into ref_cash_desk (name, organization_id) values ('T13 Каса інша ' || t, l_org2) returning id into l_k2;
  insert into ref_bank_account (organization_id, iban, bank_name, is_default) values (l_org, i1, 'T13 Банк', 'Y') returning id into l_a;
  insert into ref_bank_account (organization_id, iban, bank_name, currency_code) values (l_org, i2, 'T13 Банк USD', 'USD') returning id into l_ausd;
  trade_cash.set_opening_balance('BANK_ACCOUNT', l_a, d0, 1000);
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T13 склад ' || t) returning id into l_wh;
  insert into ref_product (name, unit_of_measure_id) values ('T13 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_counterparty (name, edrpou, iban) values ('T13 покупець ' || t, '34345613', l_iban_cus) returning id into l_cus;
  insert into ref_counterparty (name) values ('T13 інший покупець ' || t) returning id into l_cus2;
  insert into ref_counterparty (name) values ('T13 постачальник ' || t) returning id into l_sup;
  insert into ref_contract (owner_id, name, contract_number, contract_kind) values (l_cus, 'T13 Договір продажу', 'К-13', 'WITH_CUSTOMER')
    returning id into l_ctr;
  insert into ref_contract (owner_id, name, contract_kind) values (l_cus2, 'T13 Чужий договір', 'WITH_CUSTOMER') returning id into l_ctr2;
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 8)
    returning id into l_rcp;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_p, 20, 100, 0);
  trade_doc.post_goods_receipt(l_rcp);
  -- борг покупця: S1 1000 (−6 дн.), S2 600 за замовленням (−4), S3 500 (−3) = 2100; рахунок за замовленням 600
  s1 := sale(4, 250, sysdate - 6);
  insert into doc_customer_order (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, sysdate - 5)
    returning id into l_ord;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (l_ord, l_p, 2, 300, 'N');
  trade_r3.post_customer_order(l_ord);
  insert into doc_customer_order (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, sysdate - 5)
    returning id into l_ord2;   -- чернетка
  s2 := trade_r3.sale_from_order(l_ord);
  update doc_goods_sale set occurred_at = sysdate - 4 where id = s2;
  trade_ops.post_goods_sale(s2);
  l_inv := trade_r3.invoice_from_order(l_ord);
  trade_r3.issue_invoice(l_inv);
  insert into doc_invoice_for_payment (organization_id, customer_id) values (l_org, l_cus) returning id into l_inv2;   -- чернетка
  insert into doc_invoice_for_payment_goods (document_id, product_id, quantity, price) values (l_inv2, l_p, 1, 10);
  insert into doc_invoice_for_payment (organization_id, customer_id) values (l_org, l_cus2) returning id into l_inv3;  -- інший покупець
  insert into doc_invoice_for_payment_goods (document_id, product_id, quantity, price) values (l_inv3, l_p, 1, 10);
  trade_r3.issue_invoice(l_inv3);
  s3 := sale(2, 250, sysdate - 3);
  eq('Підготовка: дебіторка', debt, 2100);
  eqs('Рахунок без оплат — «Не оплачено»', trade_cust_pay.payment_state_name(l_inv), 'Не оплачено');

  -- ---------------------------------------------------------------- шапка: значення за замовчуванням і перевірки
  p1 := pay(300);
  select * into r from doc_customer_payment where id = p1;
  eqs('Форма за замовчуванням — безготівкова', r.payment_form, 'BANK');
  eqs('Рахунок — основний рахунок організації', r.bank_account_id, l_a);
  eqs('Каса для безготівкової — порожня', r.cash_desk_id, null);
  eqs('Договір — єдиний договір покупця', r.contract_id, l_ctr);
  eqs('Призначення платежу за замовчуванням', r.purpose, 'Оплата за товар згідно з договором № К-13');
  fails('Сума ≤ 0', 'PAYMENT_AMOUNT', 'update doc_customer_payment set amount = 0 where id = ''' || p1 || '''');
  fails('Рахунок у USD', 'PAYMENT_CURRENCY', 'update doc_customer_payment set bank_account_id = ''' || l_ausd || ''' where id = ''' || p1 || '''');
  fails('Каса іншої організації', 'PAYMENT_DESK_ORGANIZATION',
        'update doc_customer_payment set payment_form = ''CASH'', cash_desk_id = ''' || l_k2 || ''' where id = ''' || p1 || '''');
  fails('Договір іншого контрагента', 'CONTRACT_OWNER_MISMATCH',
        'update doc_customer_payment set contract_id = ''' || l_ctr2 || ''' where id = ''' || p1 || '''');
  fails('Рахунок іншого покупця', 'PAYMENT_INVOICE_CUSTOMER',
        'update doc_customer_payment set invoice_id = ''' || l_inv3 || ''' where id = ''' || p1 || '''');
  fails('Невиданий рахунок', 'PAYMENT_INVOICE_NOT_ISSUED',
        'update doc_customer_payment set invoice_id = ''' || l_inv2 || ''' where id = ''' || p1 || '''');
  fails('Непроведене замовлення', 'PAYMENT_ORDER_NOT_POSTED',
        'update doc_customer_payment set customer_order_id = ''' || l_ord2 || ''' where id = ''' || p1 || '''');
  fails('Замовлення іншого покупця', 'PAYMENT_ORDER_CUSTOMER',
        'insert into doc_customer_payment (organization_id, customer_id, amount, customer_order_id) values (''' || l_org || ''', '''
        || l_cus2 || ''', 10, ''' || l_ord || ''')');

  -- ---------------------------------------------------------------- проведення: рахунок, розшифровка FIFO
  trade_cust_pay.post_customer_payment(p1);
  eqs('Проведено', st(p1), 'POSTED');
  eq('Рахунок: 1000 + 300', bal(l_a), 1300);
  eq('Дебіторка: 2100 − 300', debt, 1800);
  eqs('Розшифровка FIFO: найстаріша реалізація', alloc(p1), 'S1:300;');
  trade_cust_pay.post_customer_payment(p1);
  eq('Повторне проведення замінює рухи (1 кошти + 1 розрахунки)', moves(p1), 2);
  eqs('Повторне проведення замінює розшифровку', alloc(p1), 'S1:300;');
  select count(*) into l_n from reg_counterparty_settlement_mv where recorder_id = p1 and organization_id = l_org and direction = 'RECEIVABLE';
  eq('Рух розрахунків з організацією документа', l_n, 1);
  fails('Проведений документ — лише читання', 'DOCUMENT_READ_ONLY', 'update doc_customer_payment set amount = 1 where id = ''' || p1 || '''');
  fails('Проведений документ не видаляється', 'DOCUMENT_POSTED', 'delete from doc_customer_payment where id = ''' || p1 || '''');
  p2 := pay(1000);
  trade_cust_pay.post_customer_payment(p2);
  eqs('Розшифровка на кілька документів (залишок S1, далі S2)', alloc(p2), 'S1:700;S2:300;');
  select allocated_amount into l_n from v_customer_payment_list where id = p2;
  eq('Список: розподілено', l_n, 1000);

  -- ---------------------------------------------------------------- каса й замовлення клієнта
  p3 := pay(200, p_form => 'CASH', p_order => l_ord);
  select * into r from doc_customer_payment where id = p3;
  eqs('Готівкова: каса за замовчуванням, рахунку немає', case when r.cash_desk_id = l_k and r.bank_account_id is null then 'так' end, 'так');
  eqs('Призначення за замовленням', case when r.purpose like 'Оплата за товар згідно з замовленням № %, договором № К-13' then 'так' end, 'так');
  trade_cust_pay.post_customer_payment(p3);
  eq('Каса: +200', bal(l_k), 200);
  eqs('Пріоритет реалізації замовлення (S2 раніше S3)', alloc(p3), 'S2:200;');
  eq('Сплачено за замовленням', trade_cust_pay.paid_by_order(l_ord), 200);

  -- ---------------------------------------------------------------- рахунок на оплату: стан «Оплачено»
  p4 := trade_cust_pay.payment_from_invoice(l_inv);
  select * into r from doc_customer_payment where id = p4;
  eq('Оплата за рахунком: min(сума рахунку, борг 600)', r.amount, 600);
  eqs('Підстава й рахунок — рахунок на оплату', r.base_doc_type || '/' || case when r.invoice_id = l_inv then 'i' end, 'DocInvoiceForPayment/i');
  eqs('Замовлення — з рахунку', r.customer_order_id, l_ord);
  eqs('Призначення за рахунком', case when r.purpose like 'Оплата за товар згідно з рахунком на оплату № %' then 'так' end, 'так');
  update doc_customer_payment set amount = 250 where id = p4;
  trade_cust_pay.post_customer_payment(p4);
  eqs('Розшифровка: залишок за замовленням (S2), далі S3', alloc(p4), 'S2:100;S3:150;');
  eq('Сплачено за рахунком', trade_cust_pay.invoice_paid(l_inv), 250);
  eqs('Рахунок — «Частково оплачено»', trade_cust_pay.payment_state_name(l_inv), 'Частково оплачено');
  x := trade_cash_doc.receipt_from_invoice(l_inv);
  update doc_cash_receipt set amount = 350 where id = x;
  trade_cash_doc.post_receipt(x);
  eq('Сплачено за рахунком (+ ПКО на підставі рахунку)', trade_cust_pay.invoice_paid(l_inv), 600);
  eqs('Рахунок — «Оплачено»', trade_cust_pay.payment_state(l_inv), 'PAID');
  select count(*) into l_n from v_invoice_payment where invoice_id = l_inv;
  eq('Оплати за рахунком (оплата + ПКО)', l_n, 2);
  eq('Дебіторка погашена', debt, 0);

  -- ---------------------------------------------------------------- переплата й введення на підставі
  x := pay(0.01);
  fails('Переплата покупця (аванс заборонено)', 'SETTLEMENT_NEGATIVE', 'begin trade_cust_pay.post_customer_payment(''' || x || '''); end;');
  delete from doc_customer_payment where id = x;
  fails('На підставі реалізації без боргу', 'PAYMENT_NOTHING_TO_PAY',
        'declare v varchar2(32); begin v := trade_cust_pay.payment_from_sale(''' || s1 || '''); end;');
  fails('На підставі сплаченого рахунку', 'PAYMENT_NOTHING_TO_PAY',
        'declare v varchar2(32); begin v := trade_cust_pay.payment_from_invoice(''' || l_inv || '''); end;');
  fails('На підставі невиданого рахунку', 'PAYMENT_BASE_NOT_POSTED',
        'declare v varchar2(32); begin v := trade_cust_pay.payment_from_invoice(''' || l_inv2 || '''); end;');
  fails('На підставі непроведеного замовлення', 'PAYMENT_BASE_NOT_POSTED',
        'declare v varchar2(32); begin v := trade_cust_pay.payment_from_customer_order(''' || l_ord2 || '''); end;');
  trade_cust_pay.unpost_customer_payment(p2);
  eq('Скасування: рахунок 2550 − 1000', bal(l_a), 1550);
  eq('Скасування повертає борг', debt, 1000);
  eqs('Скасування прибирає розшифровку', alloc(p2), null);
  x := trade_cust_pay.payment_from_sale(s3);
  select * into r from doc_customer_payment where id = x;
  eq('Оплата за реалізацією: сума реалізації', r.amount, 500);
  eqs('Підстава — реалізація, договір з реалізації', r.base_doc_type || '/' || case when r.contract_id = l_ctr then 'c' end, 'DocGoodsSale/c');
  trade_cust_pay.post_customer_payment(x);
  eqs('Пріоритет документа-підстави (S3)', alloc(x), 'S3:500;');
  trade_cust_pay.unpost_customer_payment(x);
  delete from doc_customer_payment where id = x;
  x := trade_cust_pay.payment_from_customer_order(l_ord);
  select amount into l_n from doc_customer_payment where id = x;
  eq('Оплата за замовленням: 600 − сплачено 450 (p3 + p4)', l_n, 150);
  delete from doc_customer_payment where id = x;

  -- ---------------------------------------------------------------- делегування trade_ops (API r2)
  trade_ops.unpost_customer_payment(p3);
  eq('trade_ops.unpost_customer_payment повертає касу (550 − 200)', bal(l_k), 350);
  trade_ops.post_customer_payment(p3);
  eq('trade_ops.post_customer_payment рухає касу', bal(l_k), 550);
  x := trade_ops.copy_customer_payment(p4);
  select * into r from doc_customer_payment where id = x;
  eqs('Копія: форма, рахунок, замовлення, договір', r.payment_form || '/' || case when r.invoice_id = l_inv then 'i' end
      || case when r.customer_order_id = l_ord then 'o' end || case when r.contract_id = l_ctr then 'c' end, 'BANK/ioc');
  eqs('Копія — чернетка без розшифровки', r.status || alloc(x), 'DRAFT');
  delete from doc_customer_payment where id = x;

  -- ---------------------------------------------------------------- банківська виписка: правило одного платежу
  -- рахунок 1550 (1000 + p1 300 + p4 250), дебіторка 1000
  insert into doc_bank_statement (organization_id, bank_account_id, occurred_at) values (l_org, l_a, trunc(sysdate) - 1 + 18/24)
    returning id into st1;
  l1 := trade_bank_doc.add_line(st1, 'IN', 300, 'Оплата за товар', 'T13 покупець', '34345613', l_iban_cus, '901', trunc(sysdate) - 1);
  trade_bank_doc.post(st1);
  select count(*) into l_n from doc_bank_statement_line where id = l1 and payment_doc_id = p1 and payment_doc_type = 'DocCustomerPayment';
  eq('Рядок «Оплата від покупця» автоматично прив''язано до оплати', l_n, 1);
  eq('Виписка не пише рухів за прив''язаним рядком', moves(st1), 0);
  eq('Рахунок не змінився (рух уже записала оплата)', bal(l_a), 1550);
  eq('Дебіторка не змінилась', debt, 1000);
  fails('Скасування оплати, прив''язаної до проведеної виписки', 'PAYMENT_LINKED_TO_STATEMENT',
        'begin trade_cust_pay.unpost_customer_payment(''' || p1 || '''); end;');
  select statement_number into l_s from v_customer_payment_list where id = p1;
  eqs('Список оплат показує виписку', case when l_s is not null then 'так' end, 'так');
  trade_bank_doc.unpost(st1);
  trade_cust_pay.unpost_customer_payment(p1);
  fails('Проведення виписки з непроведеною оплатою', 'BANK_PAYMENT_NOT_POSTED', 'begin trade_bank_doc.post(''' || st1 || '''); end;');
  fails('Видалення оплати, вказаної у виписці', 'PAYMENT_LINKED_TO_STATEMENT', 'delete from doc_customer_payment where id = ''' || p1 || '''');
  fails('Рядок і оплата — різні суми', 'BANK_PAYMENT_AMOUNT', 'update doc_bank_statement_line set amount = 301 where id = ''' || l1 || '''');
  fails('У виписці — лише безготівкова оплата', 'BANK_PAYMENT_FORM',
        'update doc_bank_statement_line set payment_doc_id = ''' || p3 || ''' where id = ''' || l1 || '''');
  update doc_bank_statement_line set payment_doc_id = null where id = l1;
  trade_bank_doc.post(st1);   -- p1 чернетка: рядок рухає рахунок і борг
  eq('Неприв''язаний рядок провела виписка', bal(l_a), 1550);
  fails('Надходження вже відображено випискою', 'PAYMENT_ALREADY_IN_STATEMENT', 'begin trade_cust_pay.post_customer_payment(''' || p1 || '''); end;');
  eq('Дебіторка рахується один раз', debt, 1000);
  trade_bank_doc.unpost(st1);
  trade_cust_pay.post_customer_payment(p1);
  trade_bank_doc.post(st1);
  select count(*) into l_n from doc_bank_statement_line where id = l1 and payment_doc_id = p1;
  eq('Після проведення оплати рядок прив''язано знову', l_n, 1);
  eq('Рахунок після перепроведення (без подвійного руху)', bal(l_a), 1550);

  -- ---------------------------------------------------------------- друк
  eqs('Форма друку безготівкової оплати', trade_print.default_form(p1), 'PAY_NOTICE');
  l_c := trade_print.document_html('PAY_NOTICE', p1);
  eqs('Повідомлення: заголовок і розшифровка', case when instr(l_c, 'ПОВІДОМЛЕННЯ ПРО НАДХОДЖЕННЯ') > 0
       and instr(l_c, 'Розшифровка платежу') > 0 then 'так' end, 'так');
  eqs('Повідомлення: IBAN отримувача й платника, ЄДРПОУ', case when instr(l_c, i1) > 0 and instr(l_c, l_iban_cus) > 0
       and instr(l_c, '34345613') > 0 then 'так' end, 'так');
  eqs('Повідомлення: сума прописом', case when instr(lower(l_c), 'триста') > 0 then 'так' end, 'так');
  eqs('Форма друку готівкової оплати', trade_print.default_form(p3), 'PAY_KO1');
  eqs('Перелік форм готівкової оплати', trade_print.forms_of(p3), 'PAY_KO1:Прибутковий касовий ордер (КО-1)');
  l_c := trade_print.document_html('PAY_KO1', p3);
  eqs('КО-1: заголовок, квитанція, касир', case when instr(l_c, 'Прибутковий касовий ордер') > 0 and instr(l_c, 'Квитанція') > 0
       and instr(l_c, 'Касир Т13') > 0 then 'так' end, 'так');
  eqs('КО-1: проведений без водяного знака', case when instr(l_c, 'ЧЕРНЕТКА') = 0 then 'так' end, 'так');
  l_c := trade_print.document_html('PAY_NOTICE', p3);
  eqs('Повідомлення для готівкової — відмова', case when instr(l_c, 'лише для безготівкової') > 0 then 'так' end, 'так');
  l_c := trade_cash_doc.cash_book_html(l_k, trunc(sysdate) - 1, trunc(sysdate) - 1);
  eqs('Касова книга містить готівкову оплату від покупця', case when instr(l_c, 'Оплата від покупця №') > 0 then 'так' end, 'так');

  -- ---------------------------------------------------------------- меню й права
  select max(auth_scheme) into l_s from sys_metadata_object where tech_name = 'DocCustomerPayment';
  eqs('Права: продажі або каса', l_s, 'Роль: продажі або каса');
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id where s.tech_name = 'Finance' and o.tech_name = 'DocCustomerPayment';
  eq('«Фінанси → Банк»: оплата від покупця', l_n, 1);
  select count(*) into l_n from user_objects where status = 'INVALID';
  eq('Невалідних об''єктів схеми', l_n, 0);
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
rollback;
