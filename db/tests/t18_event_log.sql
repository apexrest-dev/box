-- F-SRV-05 «Журнал реєстрації» (r4): групи й назви подій, вид і подання об'єкта, посилання для переходу,
-- журнал CREATE / UPDATE / DELETE з тригерів (раз на об'єкт у транзакції, без службових змін і помітки),
-- POST / UNPOST усіх документів r4 (ПКО, ВКО, виписка, коригування боргу, оплати, комплектація),
-- LINK_CASH_ORDERS / LINK_PAYMENTS виписки, помітка специфікації (виправлення catalog_table), меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_k varchar2(32); l_a varchar2(32); l_uom varchar2(32); l_wh varchar2(32); l_p varchar2(32); l_kit varchar2(32);
  l_sup varchar2(32); l_cus varchar2(32); l_iban_sup varchar2(34); i1 varchar2(34);
  rc varchar2(32); rc2 varchar2(32); sl varchar2(32); bom varchar2(32); asm varchar2(32);
  ko1 varchar2(32); ko2 varchar2(32); enc varchar2(32); sp varchar2(32); cp varchar2(32); adj varchar2(32); st varchar2(32); x varchar2(32);
  l_n number; l_s varchar2(4000); l_s2 varchar2(4000); l_num varchar2(30);
  e v_event_log%rowtype;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  function cnt (p_type varchar2, p_id varchar2, p_action varchar2) return number is
    l number;
  begin
    select count(*) into l from sys_audit_log where object_type = p_type and object_id = p_id and action = p_action;
    return l;
  end;
  function mk_iban (p_mfo varchar2, p_acc varchar2) return varchar2 is
    l_bban varchar2(25) := p_mfo || lpad(p_acc, 19, '0');
  begin
    return 'UA' || lpad(98 - mod(to_number(l_bban || '301000'), 97), 2, '0') || l_bban;
  end;
  -- проведення / скасування документа r4: POST і UNPOST у журналі, службові зміни шапки не журналюються
  procedure post_unpost (p_name varchar2, p_type varchar2, p_id varchar2, p_post varchar2, p_unpost varchar2 default null) is
  begin
    trade_event_log.reset_txn;
    execute immediate 'begin ' || p_post || '(:i); end;' using p_id;
    eq(p_name || ': POST у журналі', cnt(p_type, p_id, 'POST'), 1);
    if p_unpost is not null then
      execute immediate 'begin ' || p_unpost || '(:i); end;' using p_id;
      eq(p_name || ': UNPOST у журналі', cnt(p_type, p_id, 'UNPOST'), 1);
      execute immediate 'begin ' || p_post || '(:i); end;' using p_id;
    end if;
    eq(p_name || ': проведення не пише UPDATE', cnt(p_type, p_id, 'UPDATE'), 0);
  end;
begin
  -- ---------------------------------------------------------------- довідник подій і видів об'єктів
  eqs('Група POST', trade_event_log.event_group('POST'), 'POST');
  eqs('Група: видача рахунку — проведення', trade_event_log.event_group('ISSUE'), 'POST');
  eqs('Група: анулювання — скасування', trade_event_log.event_group('CANCEL'), 'UNPOST');
  eqs('Група: помітка на видалення — видалення', trade_event_log.event_group('MARK_FOR_DELETION'), 'DELETE');
  eqs('Група DELETE', trade_event_log.event_group('DELETE'), 'DELETE');
  eqs('Група PRINT', trade_event_log.event_group('PRINT'), 'PRINT');
  eqs('Група WARN → WARNING', trade_event_log.event_group('WARN'), 'WARNING');
  eqs('Група: копіювання — запис', trade_event_log.event_group('COPY'), 'WRITE');
  eqs('Група: закриття замовлення — інші', trade_event_log.event_group('CLOSE'), 'OTHER');
  eqs('Назва групи', trade_event_log.event_group_name('WARNING'), 'Попередження');
  eqs('Назва події UNPOST', trade_event_log.event_name('UNPOST'), 'Скасування проведення');
  eqs('Назва невідомої події = код', trade_event_log.event_name('XYZ'), 'XYZ');
  eqs('Вид: таблиця довідника → техім''я', trade_event_log.object_kind('REF_BILL_OF_MATERIALS'), 'RefBillOfMaterials');
  eqs('Вид: Register.Barcode → RegBarcode', trade_event_log.object_kind('Register.Barcode'), 'RegBarcode');
  eqs('Вид документа без змін', trade_event_log.object_kind('DocGoodsReceipt'), 'DocGoodsReceipt');
  eqs('Назва виду: довідник', trade_event_log.object_type_name('REF_WAREHOUSE'), 'Довідник. Склади');
  eqs('Назва виду: документ', trade_event_log.object_type_name('DocCashReceipt'), 'Документ. Прибуткові касові ордери');
  eqs('Назва виду: регістр', trade_event_log.object_type_name('RegCashBalance'), 'Регістр. Залишки й обороти коштів');
  eqs('Назва виду: звіт', trade_event_log.object_type_name('ReconciliationAct'), 'Звіт. Акт звірки взаєморозрахунків');
  eqs('Назва виду: попередження', trade_event_log.object_type_name('Warning'), 'Попередження');

  -- ---------------------------------------------------------------- довідники: створення, зміна, помітка
  trade_event_log.reset_txn;
  insert into ref_organization (name, org_kind, edrpou) values ('T18 ТОВ ' || t, 'LEGAL', '18181818') returning id into l_org;
  eq('Організація: CREATE', cnt('REF_ORGANIZATION', l_org, 'CREATE'), 1);
  insert into ref_warehouse (name) values ('T18 склад ' || t) returning id into l_wh;
  eq('Склад: CREATE', cnt('REF_WAREHOUSE', l_wh, 'CREATE'), 1);
  select max(details) into l_s from sys_audit_log where object_type = 'REF_WAREHOUSE' and object_id = l_wh and action = 'CREATE';
  select code || ' ' || name into l_s2 from ref_warehouse where id = l_wh;
  eqs('Подання в CREATE: код і назва', l_s, l_s2);
  update ref_warehouse set name = 'T18 склад змінений ' || t where id = l_wh;
  eq('Зміна в тій самій транзакції не дублюється', cnt('REF_WAREHOUSE', l_wh, 'UPDATE'), 0);
  trade_event_log.reset_txn;
  update ref_warehouse set name = 'T18 склад ' || t where id = l_wh;
  update ref_warehouse set name = 'T18 склад ' || t where id = l_wh;
  eq('Зміна в новій транзакції: один UPDATE', cnt('REF_WAREHOUSE', l_wh, 'UPDATE'), 1);
  trade_event_log.reset_txn;
  trade_core.mark_for_deletion('REF_WAREHOUSE', l_wh);
  eq('Помітка на видалення: MARK_FOR_DELETION', cnt('REF_WAREHOUSE', l_wh, 'MARK_FOR_DELETION'), 1);
  eq('Помітка не пише UPDATE', cnt('REF_WAREHOUSE', l_wh, 'UPDATE'), 1);
  select * into e from v_event_log where object_type = 'REF_WAREHOUSE' and object_id = l_wh and action = 'MARK_FOR_DELETION';
  eqs('Журнал: вид, група, подія', e.object_kind || '|' || e.event_group || '|' || e.event_name || '|' || e.object_type_name,
      'RefWarehouse|DELETE|Помітка на видалення|Довідник. Склади');
  select code || ' ' || name into l_s2 from ref_warehouse where id = l_wh;
  eqs('Журнал: подання й перехід у форму довідника', e.object_name || '|' || e.link_page || '|' || e.link_item, l_s2 || '|31|P31_ID');
  trade_core.restore('REF_WAREHOUSE', l_wh);
  eq('Відновлення: RESTORE', cnt('REF_WAREHOUSE', l_wh, 'RESTORE'), 1);

  -- ---------------------------------------------------------------- підготовка
  l_iban_sup := mk_iban('305299', substr(to_char(abs(dbms_random.random)), 1, 9) || '18');
  i1 := mk_iban('322001', substr(to_char(abs(dbms_random.random)), 1, 9) || '81');
  insert into ref_cash_desk (name, organization_id) values ('T18 Каса ' || t, l_org) returning id into l_k;
  insert into ref_bank_account (organization_id, iban, bank_name, is_default) values (l_org, i1, 'T18 Банк', 'Y') returning id into l_a;
  trade_cash.set_opening_balance('BANK_ACCOUNT', l_a, trunc(sysdate) - 10, 5000);
  trade_cash.set_opening_balance('CASH_DESK', l_k, trunc(sysdate) - 10, 1000);
  eq('Початковий залишок: OPENING_BALANCE', cnt('RegCashBalance', l_a, 'OPENING_BALANCE'), 1);
  select * into e from v_event_log where object_type = 'RegCashBalance' and object_id = l_a and action = 'OPENING_BALANCE';
  eqs('Журнал: регістр коштів → сторінка 360 без ключа', e.event_group || '|' || e.link_page || '|' || e.link_item, 'OTHER|360|');
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_product (name, unit_of_measure_id) values ('T18 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_product (name, unit_of_measure_id) values ('T18 Набір ' || t, l_uom) returning id into l_kit;
  insert into ref_counterparty (name, edrpou, iban) values ('T18 постачальник ' || t, '38181818', l_iban_sup) returning id into l_sup;
  insert into ref_counterparty (name) values ('T18 покупець ' || t) returning id into l_cus;

  -- ---------------------------------------------------------------- документ: створення, проведення, видалення
  trade_event_log.reset_txn;
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 5)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 1, l_p, 10, 100, 0);
  eq('Надходження: CREATE', cnt('DocGoodsReceipt', rc, 'CREATE'), 1);
  eq('Перерахунок суми шапки рядком не дублює запис', cnt('DocGoodsReceipt', rc, 'UPDATE'), 0);
  post_unpost('Прибуткова накладна', 'DocGoodsReceipt', rc, 'trade_doc.post_goods_receipt', 'trade_doc.unpost_goods_receipt');
  select * into e from v_event_log where object_type = 'DocGoodsReceipt' and object_id = rc and action = 'POST' and rownum = 1;
  eqs('Журнал документа: подання з v_recorder і перехід у форму',
      case when e.object_name like 'Прибуткова накладна % від %' then 'ok' end || '|' || e.link_page || '|' || e.link_item
      || '|' || e.event_group_name, 'ok|51|P51_ID|Проведення');
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id) values (l_org, l_sup, l_wh) returning id into rc2;
  select doc_number into l_num from doc_goods_receipt where id = rc2;
  delete from doc_goods_receipt where id = rc2;
  eq('Видалення чернетки: DELETE', cnt('DocGoodsReceipt', rc2, 'DELETE'), 1);
  select * into e from v_event_log where object_type = 'DocGoodsReceipt' and object_id = rc2 and action = 'DELETE';
  eqs('Журнал: видалений документ — подання з запису, без переходу',
      case when e.object_name like '№ ' || l_num || ' від % (видалено)' then 'ok' end || '|' || e.link_page || '|' || e.event_group, 'ok||DELETE');

  -- ---------------------------------------------------------------- документи r4: проведення / скасування
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, sysdate - 3) returning id into sl;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (sl, l_p, 2, 200);
  trade_ops.post_goods_sale(sl);

  insert into doc_cash_receipt (organization_id, operation_kind, cash_desk_id, amount, basis) values (l_org, 'OTHER', l_k, 50, 'T18')
    returning id into ko1;
  post_unpost('ПКО', 'DocCashReceipt', ko1, 'trade_cash_doc.post_receipt', 'trade_cash_doc.unpost_receipt');
  insert into doc_cash_payment (organization_id, operation_kind, cash_desk_id, amount, basis) values (l_org, 'OTHER', l_k, 40, 'T18')
    returning id into ko2;
  post_unpost('ВКО', 'DocCashPayment', ko2, 'trade_cash_doc.post_payment', 'trade_cash_doc.unpost_payment');
  x := trade_cash_doc.copy_receipt(ko1);
  eq('Копія ПКО: COPY', cnt('DocCashReceipt', x, 'COPY'), 1);
  eq('Копія ПКО: CREATE', cnt('DocCashReceipt', x, 'CREATE'), 1);

  insert into doc_supplier_payment (organization_id, supplier_id, amount, occurred_at) values (l_org, l_sup, 300, sysdate - 1)
    returning id into sp;
  post_unpost('Оплата постачальнику', 'DocSupplierPayment', sp, 'trade_pay_doc.post_supplier_payment', 'trade_pay_doc.unpost_supplier_payment');
  insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at) values (l_org, l_cus, 400, sysdate - 1)
    returning id into cp;
  post_unpost('Оплата від покупця', 'DocCustomerPayment', cp, 'trade_cust_pay.post_customer_payment', 'trade_cust_pay.unpost_customer_payment');
  insert into doc_debt_adjustment (organization_id, occurred_at, operation_kind, counterparty_id, amount)
  values (l_org, sysdate, 'WRITE_OFF_PAYABLE', l_sup, 50) returning id into adj;
  post_unpost('Коригування боргу', 'DocDebtAdjustment', adj, 'trade_debt_adj.post', 'trade_debt_adj.unpost');

  insert into ref_bill_of_materials (product_id, quantity, is_main) values (l_kit, 1, 'Y') returning id into bom;
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (bom, l_p, 2);
  eq('Специфікація: CREATE', cnt('REF_BILL_OF_MATERIALS', bom, 'CREATE'), 1);
  insert into doc_assembly (organization_id, occurred_at, operation_kind, warehouse_id, kit_product_id, bom_id, quantity)
  values (l_org, sysdate - 1, 'ASSEMBLY', l_wh, l_kit, bom, 1) returning id into asm;
  trade_assembly.fill_by_bom(asm);
  eq('Комплектація: FILL_BY_BOM', cnt('DocAssembly', asm, 'FILL_BY_BOM'), 1);
  post_unpost('Комплектація', 'DocAssembly', asm, 'trade_assembly.post', 'trade_assembly.unpost');

  -- виписка: рядок оплати постачальнику → LINK_PAYMENTS, рядок інкасації → LINK_CASH_ORDERS
  insert into doc_cash_payment (organization_id, operation_kind, cash_desk_id, amount, bank_account_id, occurred_at)
  values (l_org, 'ENCASHMENT', l_k, 700, l_a, trunc(sysdate) - 1 + 8/24) returning id into enc;
  trade_cash_doc.post_payment(enc);
  insert into doc_bank_statement (organization_id, bank_account_id, occurred_at) values (l_org, l_a, trunc(sysdate) - 1 + 18/24)
    returning id into st;
  x := trade_bank_doc.add_line(st, 'OUT', 300, 'Оплата за товар', 'T18 постачальник', '38181818', l_iban_sup, '18', trunc(sysdate) - 1);
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose) values (st, 'CASH_DEPOSIT', 700, 'Внесення готівки');
  insert into doc_bank_statement_line (document_id, operation_kind, amount, purpose) values (st, 'BANK_FEE', 15, 'Комісія');
  post_unpost('Банківська виписка', 'DocBankStatement', st, 'trade_bank_doc.post', 'trade_bank_doc.unpost');
  eq('Виписка: LINK_PAYMENTS (автозв''язок при проведенні)', cnt('DocBankStatement', st, 'LINK_PAYMENTS'), 1);
  eq('Виписка: LINK_CASH_ORDERS (автозв''язок при проведенні)', cnt('DocBankStatement', st, 'LINK_CASH_ORDERS'), 1);
  select max(details) into l_s from sys_audit_log where object_type = 'DocBankStatement' and object_id = st and action = 'LINK_PAYMENTS';
  eqs('LINK_PAYMENTS: кількість у коментарі', l_s, 'Прив''язано документів оплати: 1');
  eq('Повторний підбір без нових зв''язків не журналюється',
     trade_bank_doc.link_cash_orders(st) + cnt('DocBankStatement', st, 'LINK_CASH_ORDERS'), 1);

  -- ---------------------------------------------------------------- помітка специфікації (виправлення catalog_table)
  trade_core.mark_for_deletion('REF_BILL_OF_MATERIALS', bom);
  select state into l_s from ref_bill_of_materials where id = bom;
  eqs('Специфікацію помічено на видалення', l_s, 'MARKED_FOR_DELETION');
  select * into e from v_event_log where object_type = 'REF_BILL_OF_MATERIALS' and object_id = bom and action = 'MARK_FOR_DELETION';
  eqs('Журнал специфікації: вид і перехід у форму 431', e.object_kind || '|' || e.link_page || '|' || e.link_item,
      'RefBillOfMaterials|431|P431_ID');

  -- ---------------------------------------------------------------- акт звірки й відбори журналу
  select * into e from v_event_log where object_type = 'ReconciliationAct' and rownum = 1;
  eqs('Акт звірки → сторінка 420 з контрагентом', e.link_page || '|' || e.link_item, '420|P420_CP');
  select count(*) into l_n from v_event_log
   where event_group = 'POST' and object_id in (rc, ko1, ko2, sp, cp, adj, asm, st) and occurred_at >= trunc(sysdate);
  eq('Відбір «Проведення» за об''єктами тесту (8 документів × 2)', l_n, 16);
  select count(*) into l_n from v_event_log where object_kind = 'RefWarehouse' and object_id = l_wh and event_group = 'DELETE';
  eq('Відбір за видом об''єкта й групою «Видалення» (помітка + відновлення)', l_n, 2);
  select count(*) into l_n from v_event_log where user_name = trade_core.current_user_name and object_id = l_wh;
  eq('Відбір за користувачем', l_n, 4);

  -- ---------------------------------------------------------------- меню й права
  select count(*) into l_n from sys_metadata_object
   where tech_name = 'EventLog' and list_page_id = 480 and auth_scheme = 'Роль: адміністратор';
  eq('Меню: «Журнал реєстрації» лише для адміністратора', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id where s.tech_name = 'Reference' and o.tech_name = 'EventLog' and f.group_name = 'Сервіс';
  eq('Панель функцій «НСІ та адміністрування → Сервіс»', l_n, 1);
  select count(*) into l_n from user_triggers where trigger_name like '%\_EVLOG' escape '\' and status = 'ENABLED';
  eq('Тригери журналу на 23 документах і 18 довідниках (r5: характеристики, серії, знижки, ордери, комірки, валюти, ПН, чеки й каси ККМ; r7: точки доставки)', l_n, 41);

  rollback;
exception when others then
  dbms_output.put_line('FAIL виняток: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
