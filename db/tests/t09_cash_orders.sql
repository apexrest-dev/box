-- F-FIN-03 «ПКО / ВКО» DocCashReceipt / DocCashPayment: види операцій, рухи RegCashBalance і
-- RegCounterpartySettlement, контроль залишку каси/рахунку й переплати, введення на підставі,
-- друк КО-1/КО-2, касова книга, меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  d0 date := trunc(sysdate) - 10;
  l_org varchar2(32); l_org2 varchar2(32); l_k varchar2(32); l_k2 varchar2(32); l_keur varchar2(32); l_a varchar2(32);
  l_wh varchar2(32); l_uom varchar2(32); l_pt varchar2(32); l_p varchar2(32); l_cus varchar2(32); l_sup varchar2(32);
  l_rcp varchar2(32); l_sale varchar2(32); l_cret varchar2(32); l_sret varchar2(32); l_inv varchar2(32);
  r1 varchar2(32); r2 varchar2(32); p1 varchar2(32); x varchar2(32); y varchar2(32);
  l_n number; l_s varchar2(4000); l_c clob;

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
  function cash (p_place varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_tot where place_id = p_place;
    return l;
  end;
  function debt (p_dir varchar2, p_cp varchar2) return number is
  begin
    return trade_cash_doc.counterparty_debt(l_org, p_cp, p_dir);
  end;
  function st (p_type varchar2, p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    select status into l from v_cash_order where doc_type = p_type and id = p_id;
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
  insert into ref_organization (name, org_kind, edrpou, accountant_name) values ('T9 ТОВ ' || t, 'LEGAL', '12345678', 'Бухгалтер Т9')
    returning id into l_org;
  insert into ref_organization (name, org_kind) values ('T9 Інша ' || t, 'LEGAL') returning id into l_org2;
  insert into ref_cash_desk (code, name, organization_id, responsible_name) values ('T9K1' || substr(t, 1, 5), 'T9 Каса ' || t, l_org, 'Касир Т9')
    returning id into l_k;
  insert into ref_cash_desk (name, organization_id) values ('T9 Каса іншої ' || t, l_org2) returning id into l_k2;
  insert into ref_cash_desk (code, name, organization_id, currency_code) values ('T9K2' || substr(t, 1, 5), 'T9 Каса EUR ' || t, l_org, 'EUR')
    returning id into l_keur;
  insert into ref_bank_account (organization_id, iban, bank_name) values (l_org, 'UA213223130000026007233566001', 'T9 Банк')
    returning id into l_a;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T9 склад ' || t) returning id into l_wh;
  insert into ref_price_type (name) values ('T9 ціни ' || t) returning id into l_pt;
  insert into ref_product (name, unit_of_measure_id) values ('T9 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_counterparty (name) values ('T9 покупець ' || t) returning id into l_cus;
  insert into ref_counterparty (name) values ('T9 постачальник ' || t) returning id into l_sup;
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 2000);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 2)
    returning id into l_rcp;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_p, 10, 100, 0);
  trade_doc.post_goods_receipt(l_rcp);
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id, occurred_at) values (l_org, l_cus, l_wh, l_pt, sysdate - 1)
    returning id into l_sale;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale, l_p, 4, 250);
  trade_ops.post_goods_sale(l_sale);
  eq('Підготовка: дебіторка покупця', debt('RECEIVABLE', l_cus), 1000);
  eq('Підготовка: кредиторка постачальнику', debt('PAYABLE', l_sup), 1000);

  -- ---------------------------------------------------------------- ПКО на підставі реалізації
  r1 := trade_cash_doc.receipt_from_sale(l_sale);
  select operation_kind || '|' || cash_desk_id || '|' || organization_id || '|' || amount || '|' || counterparty_id || '|' || base_doc_type
         || '|' || person_name || '|' || status || '|' || currency_code
    into l_s from doc_cash_receipt where id = r1;
  eqs('ПКО на підставі реалізації: вид, каса організації, сума боргу, покупець, підстава',
      l_s, 'CUSTOMER_PAYMENT|' || l_k || '|' || l_org || '|1000|' || l_cus || '|DocGoodsSale|T9 покупець ' || t || '|DRAFT|UAH');
  select count(*) into l_n from doc_cash_receipt where id = r1 and basis like 'Оплата від покупця за видатковою накладною № %';
  eq('Підстава ПКО заповнена з документа-підстави', l_n, 1);
  update doc_cash_receipt set amount = 600 where id = r1;
  trade_cash_doc.post_receipt(r1);
  eqs('ПКО проведено', st('DocCashReceipt', r1), 'POSTED');
  eq('Каса після ПКО 600', cash(l_k), 2600);
  eq('Дебіторка після ПКО 600', debt('RECEIVABLE', l_cus), 400);
  select count(*) into l_n from reg_counterparty_settlement_mv
   where recorder_type = 'DocCashReceipt' and recorder_id = r1 and organization_id = l_org and direction = 'RECEIVABLE' and amount = -600;
  eq('Рух взаєморозрахунків ПКО в розрізі організації', l_n, 1);
  select count(*) into l_n from reg_cash_balance_mv
   where recorder_id = r1 and cash_desk_id = l_k and amount = 600 and operation_kind = 'CUSTOMER_PAYMENT' and content like 'ПКО № %';
  eq('Рух каси ПКО з видом операції й змістом', l_n, 1);
  fails('Проведений ПКО лише для читання', 'DOCUMENT_READ_ONLY', 'update doc_cash_receipt set amount = 1 where id = ''' || r1 || '''');
  fails('Проведений ПКО не видаляється', 'DOCUMENT_POSTED', 'delete from doc_cash_receipt where id = ''' || r1 || '''');

  r2 := trade_cash_doc.receipt_from_sale(l_sale);
  select amount into l_n from doc_cash_receipt where id = r2;
  eq('Другий ПКО: сума = залишок боргу', l_n, 400);
  update doc_cash_receipt set amount = 500 where id = r2;
  fails('Переплата покупця заборонена', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION', 'begin trade_cash_doc.post_receipt(''' || r2 || '''); end;');
  eqs('Невдале проведення: чернетка', st('DocCashReceipt', r2), 'DRAFT');
  eq('Невдале проведення: без рухів', moves(r2), 0);
  update doc_cash_receipt set amount = 400 where id = r2;
  trade_cash_doc.post_receipt(r2);
  eq('Дебіторку погашено', debt('RECEIVABLE', l_cus), 0);
  eq('Каса 3000', cash(l_k), 3000);

  -- ---------------------------------------------------------------- ВКО на підставі надходження
  p1 := trade_cash_doc.payment_from_goods_receipt(l_rcp);
  select operation_kind || '|' || amount || '|' || counterparty_id || '|' || base_doc_type into l_s from doc_cash_payment where id = p1;
  eqs('ВКО на підставі надходження', l_s, 'SUPPLIER_PAYMENT|1000|' || l_sup || '|DocGoodsReceipt');
  update doc_cash_payment set amount = 5000 where id = p1;
  fails('ВКО понад залишок каси', 'CASH_BALANCE_NEGATIVE', 'begin trade_cash_doc.post_payment(''' || p1 || '''); end;');
  update doc_cash_payment set amount = 1000 where id = p1;
  trade_cash_doc.post_payment(p1);
  eq('Каса після ВКО 1000', cash(l_k), 2000);
  eq('Кредиторку погашено', debt('PAYABLE', l_sup), 0);
  trade_cash_doc.unpost_payment(p1);
  eq('Скасування ВКО: кредиторка повернулась', debt('PAYABLE', l_sup), 1000);
  eq('Скасування ВКО: рухів немає', moves(p1), 0);
  trade_cash_doc.post_payment(p1);
  eq('Повторне проведення ВКО', cash(l_k), 2000);

  -- скасування ПКО, якщо гроші вже видано
  insert into doc_cash_payment (operation_kind, cash_desk_id, amount, basis) values ('OTHER', l_k, 1900, 'T9 інша видача') returning id into x;
  trade_cash_doc.post_payment(x);
  fails('Скасування ПКО, коли гроші вже видано', 'CASH_BALANCE_NEGATIVE', 'begin trade_cash_doc.unpost_receipt(''' || r2 || '''); end;');
  eqs('ПКО лишився проведеним', st('DocCashReceipt', r2), 'POSTED');
  select count(*) into l_n from reg_counterparty_settlement_mv where recorder_id = x;
  eq('«Інша видача» не змінює взаєморозрахунки', l_n, 0);
  trade_cash_doc.unpost_payment(x);

  -- ---------------------------------------------------------------- повернення коштів покупцю / постачальником
  l_cret := trade_r3.customer_return_from_sale(l_sale);
  update doc_customer_return_goods set quantity = 1 where document_id = l_cret;
  y := trade_cash_doc.payment_from_customer_return(l_cret);
  select operation_kind || '|' || amount || '|' || base_doc_type into l_s from doc_cash_payment where id = y;
  eqs('ВКО «Повернення коштів покупцю» на підставі повернення', l_s, 'CUSTOMER_REFUND|250|DocCustomerReturn');
  trade_cash_doc.post_payment(y);
  eq('Повернення коштів: дебіторка +250', debt('RECEIVABLE', l_cus), 250);
  trade_r3.post_customer_return(l_cret);
  eq('Повернення товару закриває дебіторку', debt('RECEIVABLE', l_cus), 0);
  fails('Скасування повернення коштів після повернення товару', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        'begin trade_cash_doc.unpost_payment(''' || y || '''); end;');
  eq('Каса після повернення покупцю', cash(l_k), 1750);

  l_sret := trade_r3.supplier_return_from_receipt(l_rcp);
  update doc_supplier_return_goods set quantity = 1 where document_id = l_sret;
  update doc_supplier_return set return_reason = 'T9 брак' where id = l_sret;
  x := trade_cash_doc.receipt_from_supplier_return(l_sret);
  trade_cash_doc.post_receipt(x);
  eq('ПКО «Повернення коштів постачальником»: кредиторка +100', debt('PAYABLE', l_sup), 100);
  trade_r3.post_supplier_return(l_sret);
  eq('Повернення постачальнику закриває залишок', debt('PAYABLE', l_sup), 0);
  eq('Каса 1850', cash(l_k), 1850);

  -- ---------------------------------------------------------------- рахунок на оплату → ПКО
  insert into doc_invoice_for_payment (organization_id, customer_id) values (l_org, l_cus) returning id into l_inv;
  insert into doc_invoice_for_payment_goods (document_id, product_id, quantity, price) values (l_inv, l_p, 2, 250);
  fails('ПКО на підставі невиданого рахунку', 'CASH_BASE_NOT_POSTED', 'declare v varchar2(32); begin v := trade_cash_doc.receipt_from_invoice(''' || l_inv || '''); end;');
  trade_r3.issue_invoice(l_inv);
  x := trade_cash_doc.receipt_from_invoice(l_inv);
  select amount || '|' || base_doc_type into l_s from doc_cash_receipt where id = x;
  eqs('ПКО на підставі рахунку: повна сума рахунку', l_s, '500|DocInvoiceForPayment');
  fails('Аванс за рахунком без відвантаження (переплата заборонена до APE-55/57)', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        'begin trade_cash_doc.post_receipt(''' || x || '''); end;');
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id) values (l_org, l_cus, l_wh, l_pt) returning id into y;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (y, l_p, 2, 250);
  trade_ops.post_goods_sale(y);
  trade_cash_doc.post_receipt(x);
  eq('ПКО за рахунком після відвантаження', debt('RECEIVABLE', l_cus), 0);
  eq('Каса 2350', cash(l_k), 2350);

  -- ---------------------------------------------------------------- інкасація й отримання готівки в банку
  insert into doc_cash_payment (operation_kind, cash_desk_id, amount, bank_account_id) values ('ENCASHMENT', l_k, 300, l_a) returning id into x;
  select organization_id || '|' || person_name || '|' || basis into l_s from doc_cash_payment where id = x;
  eqs('Інкасація: організація з каси, «Видати» = банк, підстава = вид операції', l_s, l_org || '|T9 Банк|Інкасація (здача готівки в банк)');
  trade_cash_doc.post_payment(x);
  eq('Інкасація: каса −300', cash(l_k), 2050);
  eq('Інкасація: рахунок +300', cash(l_a), 300);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = x and line_number = 2 and bank_account_id = l_a;
  eq('Другий рух інкасації — банківський рахунок', l_n, 1);
  insert into doc_cash_receipt (operation_kind, cash_desk_id, amount, bank_account_id) values ('BANK_WITHDRAWAL', l_k, 120, l_a) returning id into y;
  trade_cash_doc.post_receipt(y);
  eq('Отримання готівки: каса +120', cash(l_k), 2170);
  eq('Отримання готівки: рахунок −120', cash(l_a), 180);
  insert into doc_cash_receipt (operation_kind, cash_desk_id, amount, bank_account_id) values ('BANK_WITHDRAWAL', l_k, 500, l_a) returning id into y;
  fails('Отримання готівки понад залишок рахунку', 'BANK_BALANCE_NEGATIVE', 'begin trade_cash_doc.post_receipt(''' || y || '''); end;');
  delete from doc_cash_receipt where id = y;
  select count(*) into l_n from doc_cash_receipt where id = y;
  eq('Чернетку ПКО можна видалити', l_n, 0);

  -- ---------------------------------------------------------------- підзвітна особа
  fails('Видача під звіт без підзвітної особи', 'CASH_ACCOUNTABLE_REQUIRED',
        'insert into doc_cash_payment (operation_kind, cash_desk_id, amount) values (''ACCOUNTABLE_ISSUE'', ''' || l_k || ''', 100)');
  insert into doc_cash_payment (operation_kind, cash_desk_id, amount, accountable_person, counterparty_id)
  values ('ACCOUNTABLE_ISSUE', l_k, 170, ' Петренко П. П. ', l_cus) returning id into x;
  select accountable_person || '|' || person_name || '|' || nvl(counterparty_id, '-') into l_s from doc_cash_payment where id = x;
  eqs('Під звіт: ПІБ, «Видати», контрагент очищено', l_s, 'Петренко П. П.|Петренко П. П.|-');
  trade_cash_doc.post_payment(x);
  eq('Видача під звіт: каса', cash(l_k), 2000);

  -- ---------------------------------------------------------------- перевірки шапки
  fails('Оплата від покупця без контрагента', 'CASH_COUNTERPARTY_REQUIRED',
        'insert into doc_cash_receipt (operation_kind, cash_desk_id, amount) values (''CUSTOMER_PAYMENT'', ''' || l_k || ''', 10)');
  fails('Каса іншої організації', 'CASH_DESK_ORGANIZATION',
        'insert into doc_cash_receipt (organization_id, operation_kind, cash_desk_id, amount) values (''' || l_org || ''', ''OTHER'', ''' || l_k2 || ''', 10)');
  fails('Інкасація без рахунку', 'CASH_BANK_REQUIRED',
        'insert into doc_cash_payment (operation_kind, cash_desk_id, amount) values (''ENCASHMENT'', ''' || l_k || ''', 10)');
  fails('Розрахунки з контрагентом з валютної каси', 'CASH_SETTLEMENT_CURRENCY',
        'insert into doc_cash_receipt (operation_kind, cash_desk_id, amount, counterparty_id) values (''CUSTOMER_PAYMENT'', ''' || l_keur || ''', 10, ''' || l_cus || ''')');
  fails('Інкасація з EUR-каси на гривневий рахунок', 'CASH_BANK_CURRENCY',
        'insert into doc_cash_payment (operation_kind, cash_desk_id, amount, bank_account_id) values (''ENCASHMENT'', ''' || l_keur || ''', 10, ''' || l_a || ''')');
  fails('Нульова сума', 'CASH_AMOUNT',
        'insert into doc_cash_receipt (operation_kind, cash_desk_id, amount) values (''OTHER'', ''' || l_k || ''', 0)');
  fails('Вид операції ВКО в ПКО', 'CASH_OPERATION_KIND',
        'insert into doc_cash_receipt (operation_kind, cash_desk_id, amount) values (''ENCASHMENT'', ''' || l_k || ''', 10)');
  fails('Підстава іншого контрагента', 'CASH_BASE_COUNTERPARTY',
        'insert into doc_cash_receipt (operation_kind, cash_desk_id, amount, counterparty_id, base_doc_id) values (''CUSTOMER_PAYMENT'', '''
        || l_k || ''', 10, ''' || l_sup || ''', ''' || l_sale || ''')');
  insert into doc_cash_receipt (operation_kind, cash_desk_id, amount, counterparty_id) values ('OTHER', l_keur, 15, l_cus) returning id into x;
  trade_cash_doc.post_receipt(x);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = x and cash_desk_id = l_keur and currency_code = 'EUR' and amount = 15;
  eq('«Інше надходження» у валютну касу (EUR)', l_n, 1);

  -- ---------------------------------------------------------------- копіювання
  x := trade_cash_doc.copy_receipt(r1);
  select operation_kind || '|' || amount || '|' || organization_id || '|' || status || '|' || case when doc_number <> (select doc_number from doc_cash_receipt where id = r1) then 'new' end
    into l_s from doc_cash_receipt where id = x;
  eqs('Скопіювати (F9): чернетка з новим номером', l_s, 'CUSTOMER_PAYMENT|600|' || l_org || '|DRAFT|new');
  select count(*) into l_n from sys_audit_log where object_type = 'DocCashReceipt' and object_id = r1 and action = 'POST';
  eq('Аудит проведення ПКО', l_n, 1);

  -- ---------------------------------------------------------------- друк і касова книга
  eqs('Друкована форма ПКО за замовчуванням', trade_print.default_form(r1), 'KO1');
  eqs('Друкована форма ВКО за замовчуванням', trade_print.default_form(p1), 'KO2');
  l_c := trade_print.document_html('KO1', r1);
  eq('КО-1: ордер, квитанція, сума прописом, касир',
     case when instr(l_c, 'Прибутковий касовий ордер №') > 0 and instr(l_c, 'Квитанція до прибуткового касового ордера') > 0
               and instr(l_c, 'Шістсот гривень') > 0 and instr(l_c, 'Касир Т9') > 0 and instr(l_c, 'КО-1') > 0 then 1 else 0 end, 1);
  l_c := trade_print.document_html('KO2', p1);
  eq('КО-2: видатковий ордер, «Видати», підпис одержувача',
     case when instr(l_c, 'Видатковий касовий ордер №') > 0 and instr(l_c, 'Видати') > 0 and instr(l_c, 'одержувача') > 0
               and instr(l_c, 'ЧЕРНЕТКА') = 0 then 1 else 0 end, 1);
  l_c := trade_cash_doc.cash_book_html(l_k, trunc(sysdate), trunc(sysdate));
  eq('Касова книга: аркуш дня, залишок на кінець дня = залишок каси',
     case when instr(l_c, 'Вкладний аркуш касової книги') > 0 and instr(l_c, 'Залишок на кінець дня') > 0
               and instr(l_c, to_char(cash(l_k), 'FM999G999G999G990D00')) > 0 and instr(l_c, 'Аркуш 2') > 0 then 1 else 0 end, 1);
  l_c := trade_cash_doc.cash_book_html(l_k, d0 - 5, d0 - 1);
  eq('Касова книга: період без рухів', case when instr(l_c, 'рухів каси немає') > 0 then 1 else 0 end, 1);

  -- ---------------------------------------------------------------- звіти, меню, сторінки
  select count(*) into l_n from v_cash_movement m join doc_cash_receipt d on d.id = m.recorder_id
   where m.recorder_id = r1 and m.page_id = 371
     and m.recorder_name = 'Прибутковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS');
  eq('Звіт коштів: реєстратор ПКО → сторінка 371', l_n, 1);
  select count(*) into l_n from v_settlement_movement where recorder_id in (r1, p1);
  eq('Звіт взаєморозрахунків показує ПКО/ВКО', l_n, 2);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Finance' and o.auth_scheme = 'Роль: каса'
     and (o.tech_name, o.list_page_id) in (('DocCashReceipt', 370), ('DocCashPayment', 380), ('CashBook', 390));
  eq('Панель «Фінанси»: ПКО, ВКО, касова книга', l_n, 3);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100
     and p.page_id in (370, 371, 380, 381, 390) and p.authorization_scheme = 'Роль: каса';
  eq('Сторінки 370/371/380/381/390 захищені роллю «каса»', l_n, 5);
  select count(*) into l_n from apex_application_page_buttons b where b.application_id = 100
     and ((b.page_id in (111, 321, 291) and b.button_name = 'CREATE_CASH_RECEIPT')
       or (b.page_id in (51, 281) and b.button_name = 'CREATE_CASH_PAYMENT'))
     and b.authorization_scheme = 'Роль: каса';
  eq('Команди «Створити ПКО/ВКО» у документах-підставах', l_n, 5);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
