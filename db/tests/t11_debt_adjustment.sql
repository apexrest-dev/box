-- F-FIN-05 «Коригування боргу / взаємозалік» DocDebtAdjustment: взаємозалік (сума ≤ min(дебіторка,
-- кредиторка) на дату документа), списання дебіторки / кредиторки, перенесення між договорами й
-- контрагентами, скасування, копіювання, друк акта, акт звірки, меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); l_wh varchar2(32); l_uom varchar2(32); l_pt varchar2(32); l_p varchar2(32);
  l_cp varchar2(32); l_cp2 varchar2(32); l_rcp varchar2(32); l_sale varchar2(32);
  l_cc1 varchar2(32); l_cc2 varchar2(32); l_cs1 varchar2(32);
  a1 varchar2(32); a2 varchar2(32); w1 varchar2(32); w2 varchar2(32); tr1 varchar2(32); tr2 varchar2(32); x varchar2(32);
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
  function debt (p_dir varchar2, p_cp varchar2) return number is
  begin
    return trade_debt_adj.debt_at(l_org, p_cp, p_dir);
  end;
  function st (p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    select status into l from doc_debt_adjustment where id = p_id;
    return l;
  end;
  function moves (p_id varchar2) return number is
    l number;
  begin
    select count(*) into l from reg_counterparty_settlement_mv where recorder_id = p_id;
    return l;
  end;
  function adj (p_op varchar2, p_cp varchar2, p_amount number, p_date date default sysdate,
                p_contract varchar2 default null, p_tcp varchar2 default null, p_tcontract varchar2 default null) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_debt_adjustment (organization_id, occurred_at, operation_kind, counterparty_id, contract_id,
                                     target_counterparty_id, target_contract_id, amount)
    values (l_org, p_date, p_op, p_cp, p_contract, p_tcp, p_tcontract, p_amount) returning id into l;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou, director_name, accountant_name)
  values ('T11 ТОВ ' || t, 'LEGAL', '12345678', 'Директор Т11', 'Бухгалтер Т11') returning id into l_org;
  insert into ref_organization (name, org_kind) values ('T11 Інша ' || t, 'LEGAL') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T11 склад ' || t) returning id into l_wh;
  insert into ref_price_type (name) values ('T11 ціни ' || t) returning id into l_pt;
  insert into ref_product (name, unit_of_measure_id) values ('T11 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_counterparty (name, edrpou) values ('T11 партнер ' || t, '30111111') returning id into l_cp;
  insert into ref_counterparty (name) values ('T11 новий боржник ' || t) returning id into l_cp2;
  -- контрагент і постачає нам (кредиторка 600), і купує в нас (дебіторка 1000)
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_cp, l_wh, sysdate - 3)
    returning id into l_rcp;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_rcp, 1, l_p, 10, 60, 0);
  trade_doc.post_goods_receipt(l_rcp);
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, price_type_id, occurred_at) values (l_org, l_cp, l_wh, l_pt, sysdate - 2)
    returning id into l_sale;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l_sale, l_p, 4, 250);
  trade_ops.post_goods_sale(l_sale);
  eq('Підготовка: дебіторка', debt('RECEIVABLE', l_cp), 1000);
  eq('Підготовка: кредиторка', debt('PAYABLE', l_cp), 600);
  eq('Сальдо розрахунків (дебіторка − кредиторка)', trade_debt_adj.saldo_at(l_org, l_cp), 400);
  insert into ref_contract (owner_id, name, contract_kind) values (l_cp, 'T11 Договір продажу 1', 'WITH_CUSTOMER') returning id into l_cc1;
  insert into ref_contract (owner_id, name, contract_kind) values (l_cp, 'T11 Договір поставки', 'WITH_SUPPLIER') returning id into l_cs1;

  -- ---------------------------------------------------------------- взаємозалік
  a1 := adj('OFFSET', l_cp, 700);
  select contract_id || '|' || target_contract_id || '|' || target_counterparty_id || '|' || currency_code || '|' || status || '|' || reason
    into l_s from doc_debt_adjustment where id = a1;
  eqs('Взаємозалік: договори за замовчуванням, валюта, підстава', l_s,
      l_cc1 || '|' || l_cs1 || '|' || l_cp || '|UAH|DRAFT|Взаємозалік заборгованостей');
  fails('Сума заліку > min(дебіторка, кредиторка)', 'DEBT_OFFSET_EXCEEDS', 'begin trade_debt_adj.post(''' || a1 || '''); end;');
  eqs('Невдале проведення: чернетка', st(a1), 'DRAFT');
  eq('Невдале проведення: без рухів', moves(a1), 0);
  update doc_debt_adjustment set amount = 400 where id = a1;
  trade_debt_adj.post(a1);
  eqs('Взаємозалік проведено', st(a1), 'POSTED');
  eq('Після заліку: дебіторка', debt('RECEIVABLE', l_cp), 600);
  eq('Після заліку: кредиторка', debt('PAYABLE', l_cp), 200);
  select count(*) into l_n from reg_counterparty_settlement_mv
   where recorder_type = 'DocDebtAdjustment' and recorder_id = a1 and organization_id = l_org and amount = -400
     and direction in ('RECEIVABLE', 'PAYABLE');
  eq('Два рухи заліку в розрізі організації', l_n, 2);
  eq('Сальдо після заліку не змінилось', trade_debt_adj.saldo_at(l_org, l_cp), 400);
  fails('Проведений документ лише для читання', 'DOCUMENT_READ_ONLY', 'update doc_debt_adjustment set amount = 1 where id = ''' || a1 || '''');
  fails('Проведений документ не видаляється', 'DOCUMENT_POSTED', 'delete from doc_debt_adjustment where id = ''' || a1 || '''');
  a2 := adj('OFFSET', l_cp, 200, sysdate - 5);
  fails('Залік на дату до виникнення боргів', 'DEBT_OFFSET_EXCEEDS', 'begin trade_debt_adj.post(''' || a2 || '''); end;');
  update doc_debt_adjustment set occurred_at = sysdate, amount = 300 where id = a2;
  fails('Другий залік понад залишок кредиторки (200)', 'DEBT_OFFSET_EXCEEDS', 'begin trade_debt_adj.post(''' || a2 || '''); end;');
  fails('Договір не того виду', 'CONTRACT_KIND_MISMATCH',
        'update doc_debt_adjustment set contract_id = ''' || l_cs1 || ''' where id = ''' || a2 || '''');
  fails('Організація з іншої організації: залік неможливий (боргів немає)', 'DEBT_OFFSET_EXCEEDS',
        'begin update doc_debt_adjustment set organization_id = ''' || l_org2 || ''', amount = 1 where id = ''' || a2 || '''; trade_debt_adj.post(''' || a2 || '''); end;');
  trade_debt_adj.unpost(a1);
  eq('Скасування заліку: дебіторка повернулась', debt('RECEIVABLE', l_cp), 1000);
  eq('Скасування заліку: кредиторка повернулась', debt('PAYABLE', l_cp), 600);
  eq('Скасування заліку: рухів немає', moves(a1), 0);
  fails('Повторне скасування', 'DOCUMENT_NOT_POSTED', 'begin trade_debt_adj.unpost(''' || a1 || '''); end;');
  trade_debt_adj.post(a1);
  eq('Повторне проведення заліку', debt('PAYABLE', l_cp), 200);

  -- ---------------------------------------------------------------- списання
  w1 := adj('WRITE_OFF_PAYABLE', l_cp, 250);
  select contract_id || '|' || nvl(target_counterparty_id, '-') into l_s from doc_debt_adjustment where id = w1;
  eqs('Списання кредиторки: договір з постачальником, без одержувача', l_s, l_cs1 || '|-');
  fails('Списання понад кредиторку', 'DEBT_AMOUNT_EXCEEDS', 'begin trade_debt_adj.post(''' || w1 || '''); end;');
  update doc_debt_adjustment set amount = 200 where id = w1;
  trade_debt_adj.post(w1);
  eq('Кредиторку списано', debt('PAYABLE', l_cp), 0);
  fails('Повторне списання вже погашеної кредиторки', 'DEBT_AMOUNT_EXCEEDS',
        'begin trade_debt_adj.post(trade_debt_adj.copy(''' || w1 || ''')); end;');
  fails('Сума має бути > 0', 'DEBT_AMOUNT', 'begin update doc_debt_adjustment set amount = 0 where id = ''' || a2 || '''; end;');

  -- ---------------------------------------------------------------- перенесення
  fails('Перенесення на той самий договір', 'DEBT_TRANSFER_SAME',
        'declare x varchar2(32); begin insert into doc_debt_adjustment (organization_id, operation_kind, counterparty_id, contract_id, amount) '
        || 'values (''' || l_org || ''', ''TRANSFER_RECEIVABLE'', ''' || l_cp || ''', ''' || l_cc1 || ''', 10); '
        || 'update doc_debt_adjustment set target_contract_id = contract_id where operation_kind = ''TRANSFER_RECEIVABLE'' and counterparty_id = ''' || l_cp || '''; end;');
  insert into ref_contract (owner_id, name, contract_kind) values (l_cp, 'T11 Договір продажу 2', 'WITH_CUSTOMER') returning id into l_cc2;
  tr1 := adj('TRANSFER_RECEIVABLE', l_cp, 100, sysdate, l_cc1, null, l_cc2);
  trade_debt_adj.post(tr1);
  eq('Перенесення між договорами: дебіторка контрагента не змінилась', debt('RECEIVABLE', l_cp), 600);
  eq('Перенесення між договорами: два рухи', moves(tr1), 2);
  tr2 := adj('TRANSFER_RECEIVABLE', l_cp, 900, sysdate, l_cc1, l_cp2);
  fails('Перенесення понад дебіторку', 'DEBT_AMOUNT_EXCEEDS', 'begin trade_debt_adj.post(''' || tr2 || '''); end;');
  update doc_debt_adjustment set amount = 300 where id = tr2;
  trade_debt_adj.post(tr2);
  eq('Перенесення на іншого контрагента: дебіторка джерела', debt('RECEIVABLE', l_cp), 300);
  eq('Перенесення на іншого контрагента: дебіторка одержувача', debt('RECEIVABLE', l_cp2), 300);
  w2 := adj('WRITE_OFF_RECEIVABLE', l_cp2, 300);
  update doc_debt_adjustment set reason = 'Безнадійний борг: ліквідація боржника' where id = w2;
  trade_debt_adj.post(w2);
  eq('Безнадійну дебіторку одержувача списано', debt('RECEIVABLE', l_cp2), 0);
  fails('Скасування перенесення, коли борг одержувача вже списано', 'SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        'begin trade_debt_adj.unpost(''' || tr2 || '''); end;');

  -- ---------------------------------------------------------------- копіювання
  x := trade_debt_adj.copy(w2);
  select status || '|' || amount || '|' || operation_kind || '|' || counterparty_id || '|' || reason into l_s from doc_debt_adjustment where id = x;
  eqs('Копія — чернетка з тими самими реквізитами', l_s, 'DRAFT|300|WRITE_OFF_RECEIVABLE|' || l_cp2 || '|Безнадійний борг: ліквідація боржника');
  delete from doc_debt_adjustment where id = x;
  select count(*) into l_n from doc_debt_adjustment where id = x;
  eq('Чернетку видалено', l_n, 0);

  -- ---------------------------------------------------------------- друк і акт звірки
  eqs('Форма друку за замовчуванням', trade_print.default_form(a1), 'DEBT_ADJ');
  l_c := trade_print.document_html('DEBT_ADJ', a1);
  eq('Акт взаємозаліку: назва, сума прописом, договори',
     case when instr(l_c, 'Акт взаємозаліку заборгованостей') > 0 and instr(l_c, 'T11 Договір поставки') > 0
           and instr(l_c, '400') > 0 and instr(l_c, 'гривень') > 0 then 1 else 0 end, 1);
  l_c := trade_print.document_html('DEBT_ADJ', tr2);
  eq('Акт перенесення: новий боржник', case when instr(l_c, 'Акт коригування заборгованості') > 0
     and instr(l_c, 'T11 новий боржник') > 0 then 1 else 0 end, 1);
  l_c := trade_debt_adj.reconciliation_html(l_org, l_cp, trunc(sysdate) - 30, trunc(sysdate));
  eq('Акт звірки: заголовок і сторони', case when instr(l_c, 'Акт звірки взаємних розрахунків') > 0
     and instr(l_c, 'T11 партнер') > 0 and instr(l_c, 'T11 ТОВ') > 0 then 1 else 0 end, 1);
  -- обороти: дебет = реалізація 1000 + залік (кредиторка −400) + списання кредиторки 200 + перенесення (договір 2) 100 = 1700;
  -- кредит = надходження 600 + залік (дебіторка −400) + перенесення (договір 1) 100 + перенесення іншому 300 = 1400
  eq('Акт звірки: обороти дебет/кредит', case when instr(l_c, '>' || to_char(1700, 'FM999G999G999G990D00') || '<') > 0
     and instr(l_c, '>' || to_char(1400, 'FM999G999G999G990D00') || '<') > 0 then 1 else 0 end, 1);
  eq('Акт звірки: сальдо на кінець на користь організації 300', case when instr(l_c, 'на користь T11 ТОВ') > 0
     and instr(l_c, '<b>' || to_char(300, 'FM999G999G999G990D00') || '</b>') > 0 then 1 else 0 end, 1);
  eq('Сальдо на кінець = дебіторка − кредиторка', trade_debt_adj.saldo_at(l_org, l_cp), 300);
  l_c := trade_debt_adj.reconciliation_html(l_org, l_cp, trunc(sysdate) - 30, trunc(sysdate) - 4);
  eq('Акт звірки до операцій: заборгованість відсутня', case when instr(l_c, 'заборгованість між сторонами відсутня') > 0 then 1 else 0 end, 1);
  eq('Акт звірки без контрагента — підказка', case when instr(trade_debt_adj.reconciliation_html(l_org, null, sysdate, sysdate), 'Виберіть') > 0 then 1 else 0 end, 1);

  -- ---------------------------------------------------------------- реєстратори, меню, сторінки
  select count(*) into l_n from v_settlement_movement where recorder_id = a1 and page_id = 411;
  eq('Звіт взаєморозрахунків: реєстратор → сторінка 411', l_n, 2);
  select count(*) into l_n from v_debt_adjustment_list where organization_id = l_org;
  eq('Список документів', l_n, 6);
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'DocDebtAdjustment' and list_page_id = 410 and form_page_id = 411 and auth_scheme = 'Роль: каса')
      or (tech_name = 'ReconciliationAct' and list_page_id = 420 and auth_scheme is null);
  eq('Об''єкти меню: документ і акт звірки', l_n, 2);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Finance' and f.group_name = 'Взаєморозрахунки';
  eq('Панель «Фінанси → Взаєморозрахунки»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100
     and p.page_id in (410, 411) and p.authorization_scheme = 'Роль: каса';
  eq('Сторінки 410/411 захищені роллю «каса»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id = 420;
  eq('Сторінка акта звірки 420', l_n, 1);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
