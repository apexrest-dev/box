-- F-WH-10 «Комплектація / розкомплектація»: специфікації наборів (RefBillOfMaterials, основна специфікація,
-- перевірки), документ DocAssembly — заповнення за специфікацією, проведення (RegStockBalance −/+,
-- RegStockCost: собівартість набору = Σ собівартості комплектуючих; розподіл при розкомплектації за
-- середньою собівартістю й за частками), контроль вільного залишку (з резервами), скасування, копія,
-- перерахунок собівартості, друк, меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_wh varchar2(32); l_uom varchar2(32); l_sup varchar2(32); l_cus varchar2(32);
  l_k varchar2(32); l_a varchar2(32); l_b varchar2(32); l_srv varchar2(32); l_k2 varchar2(32);
  r1 varchar2(32); r2 varchar2(32); bom1 varchar2(32); bom2 varchar2(32); bomx varchar2(32);
  d1 varchar2(32); d2 varchar2(32); d3 varchar2(32); d4 varchar2(32); d5 varchar2(32); x varchar2(32); l_ord varchar2(32);
  l_n number; l_s varchar2(4000); l_c clob; l_q number; l_v number;

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
  function stock (p_prd varchar2) return number is
  begin
    return trade_r3.stock_qty(l_wh, p_prd);
  end;
  function cost (p_prd varchar2) return number is
    l number;
  begin
    select coalesce(sum(cost_amount), 0) into l from reg_stock_cost_tot where warehouse_id = l_wh and product_id = p_prd;
    return l;
  end;
  function st (p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    select status into l from doc_assembly where id = p_id;
    return l;
  end;
  function line_cost (p_id varchar2, p_prd varchar2) return number is
    l number;
  begin
    select sum(cost_amount) into l from doc_assembly_goods where document_id = p_id and product_id = p_prd;
    return l;
  end;
  function line_qty (p_id varchar2, p_prd varchar2) return number is
    l number;
  begin
    select sum(quantity) into l from doc_assembly_goods where document_id = p_id and product_id = p_prd;
    return l;
  end;
  function asm (p_op varchar2, p_qty number, p_date date, p_kit varchar2 default null, p_bom varchar2 default null) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_assembly (organization_id, occurred_at, operation_kind, warehouse_id, kit_product_id, bom_id, quantity)
    values (l_org, p_date, p_op, l_wh, coalesce(p_kit, l_k), p_bom, p_qty) returning id into l;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T14 ТОВ ' || t, 'LEGAL', '14141414') returning id into l_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T14 склад ' || t) returning id into l_wh;
  insert into ref_product (name, unit_of_measure_id) values ('T14 Подарунковий набір ' || t, l_uom) returning id into l_k;
  insert into ref_product (name, unit_of_measure_id) values ('T14 Набір 2 ' || t, l_uom) returning id into l_k2;
  insert into ref_product (name, unit_of_measure_id) values ('T14 Кава ' || t, l_uom) returning id into l_a;
  insert into ref_product (name, unit_of_measure_id) values ('T14 Чашка ' || t, l_uom) returning id into l_b;
  insert into ref_product (name, unit_of_measure_id, product_kind) values ('T14 Пакування (послуга) ' || t, l_uom, 'SERVICE') returning id into l_srv;
  insert into ref_counterparty (name) values ('T14 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T14 покупець ' || t) returning id into l_cus;
  -- Кава 10 × 30 + 10 × 36 → 20 / 660 (середня 33); Чашка 20 × 5 → 20 / 100
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 3)
    returning id into r1;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r1, 1, l_a, 10, 30, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r1, 2, l_b, 20, 5, 0);
  trade_doc.post_goods_receipt(r1);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 2.9)
    returning id into r2;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r2, 1, l_a, 10, 36, 0);
  trade_doc.post_goods_receipt(r2);
  eq('Підготовка: Кава вартість', cost(l_a), 660);
  eq('Підготовка: Чашка вартість', cost(l_b), 100);

  -- ---------------------------------------------------------------- специфікації наборів
  insert into ref_bill_of_materials (product_id, quantity, is_main) values (l_k, 1, 'Y') returning id into bom1;
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (bom1, l_a, 2);
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (bom1, l_b, 3);
  select name into l_s from ref_bill_of_materials where id = bom1;
  eqs('Найменування специфікації за замовчуванням', l_s, 'Специфікація: T14 Подарунковий набір ' || t);
  select listagg(line_number, ',') within group (order by line_number) into l_s from ref_bill_of_materials_items where bom_id = bom1;
  eqs('Нумерація комплектуючих', l_s, '1,2');
  eqs('Основна специфікація набору', trade_assembly.main_bom(l_k), bom1);
  fails('Набір-послуга', 'PRODUCT_SERVICE_NOT_ALLOWED',
        'insert into ref_bill_of_materials (product_id) values (''' || l_srv || ''')');
  fails('Набір як власна комплектуюча', 'BOM_KIT_IN_COMPONENTS',
        'insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (''' || bom1 || ''', ''' || l_k || ''', 1)');
  fails('Комплектуюча-послуга', 'PRODUCT_SERVICE_NOT_ALLOWED',
        'insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (''' || bom1 || ''', ''' || l_srv || ''', 1)');
  fails('Кількість набору 0', 'більшою за нуль',
        'update ref_bill_of_materials set quantity = 0 where id = ''' || bom1 || '''');
  fails('Фізичне видалення специфікації', 'видалення',
        'delete from ref_bill_of_materials where id = ''' || bom1 || '''');
  -- друга специфікація (на 2 набори, з частками вартості) стає основною — перша знімає ознаку
  insert into ref_bill_of_materials (name, product_id, quantity, is_main) values ('T14 Варіант на 2 шт', l_k, 2, 'Y') returning id into bom2;
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity, cost_share) values (bom2, l_a, 4, 75);
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity, cost_share) values (bom2, l_b, 6, 25);
  select count(*) into l_n from ref_bill_of_materials where product_id = l_k and is_main = 'Y';
  eq('Лише одна основна специфікація', l_n, 1);
  eqs('Основна — нова специфікація', trade_assembly.main_bom(l_k), bom2);
  update ref_bill_of_materials set is_main = 'Y' where id = bom1;
  eqs('Повернення основної першій', trade_assembly.main_bom(l_k), bom1);
  insert into ref_bill_of_materials (product_id) values (l_k2) returning id into bomx;
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (bomx, l_a, 1);
  eq('Орієнтовна собівартість набору за специфікацією (2×33 + 3×5)', trade_assembly.bom_cost(bom1, l_wh), 81);
  select count(*) into l_n from v_bill_of_materials_list where product_id = l_k;
  eq('Список специфікацій', l_n, 2);

  -- ---------------------------------------------------------------- комплектація
  d1 := asm('ASSEMBLY', 4, sysdate - 2);
  select bom_id into x from doc_assembly where id = d1;
  eqs('Специфікація за замовчуванням — основна', x, bom1);
  trade_assembly.fill_by_bom(d1);
  eq('Заповнення: Кава 4 × 2', line_qty(d1, l_a), 8);
  eq('Заповнення: Чашка 4 × 3', line_qty(d1, l_b), 12);
  eq('Вільний залишок у рядку (Кава)', trade_assembly.line_free_qty(d1, l_a), 20);
  trade_warn.clear;
  trade_assembly.post(d1);
  eqs('Комплектація проведена', st(d1), 'POSTED');
  eq('Залишок Кава 20 − 8', stock(l_a), 12);
  eq('Залишок Чашка 20 − 12', stock(l_b), 8);
  eq('Залишок набору +4', stock(l_k), 4);
  eq('Собівартість списаної Кави 660 × 8/20', line_cost(d1, l_a), 264);
  eq('Собівартість списаних Чашок 100 × 12/20', line_cost(d1, l_b), 60);
  select kit_cost_amount into l_n from doc_assembly where id = d1;
  eq('Собівартість набору = Σ комплектуючих', l_n, 324);
  eq('RegStockCost набору', cost(l_k), 324);
  eq('RegStockCost Кави', cost(l_a), 396);
  select count(*) into l_n from reg_stock_cost_mv where recorder_type = 'DocAssembly' and recorder_id = d1 and organization_id = l_org;
  eq('Рухи собівартості з організацією документа', l_n, 3);
  trade_assembly.post(d1);   -- повторне проведення
  select count(*) into l_n from reg_stock_balance_movement where recorder_id = d1;
  eq('Повторне проведення без дублів (залишки)', l_n, 3);
  eq('Повторне проведення: собівартість набору', cost(l_k), 324);
  fails('Проведений документ лише для читання', 'DOCUMENT_READ_ONLY',
        'update doc_assembly set quantity = 5 where id = ''' || d1 || '''');
  fails('Заповнення проведеного документа', 'DOCUMENT_READ_ONLY', 'begin trade_assembly.fill_by_bom(''' || d1 || '''); end;');
  fails('Видалення проведеного', 'DOCUMENT_POSTED', 'delete from doc_assembly where id = ''' || d1 || '''');
  select count(*) into l_n from v_stock_movement where recorder_id = d1;
  eq('Звіт «Товари на складах»: рухи комплектації', l_n, 3);

  -- «Провести» без рядків — заповнення за специфікацією автоматично
  d2 := asm('ASSEMBLY', 1, sysdate - 1.9);
  trade_assembly.post(d2);
  eq('Автозаповнення при проведенні: рядків', line_qty(d2, l_a) + line_qty(d2, l_b), 5);
  eq('Собівартість 2-го набору (2 × 33 + 3 × 5)', cost(l_k) - 324, 81);
  eq('Набір: 5 шт', stock(l_k), 5);

  -- контроль вільного залишку
  x := asm('ASSEMBLY', 10, sysdate - 1.8);
  fails('Недостатньо комплектуючих', 'INSUFFICIENT_FREE_STOCK', 'begin trade_assembly.post(''' || x || '''); end;');
  insert into doc_customer_order (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, sysdate - 1.85)
    returning id into l_ord;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag) values (l_ord, l_b, 5, 10, 'Y');
  trade_r3.post_customer_order(l_ord);
  x := asm('ASSEMBLY', 1, sysdate - 1.8);
  fails('Комплектуюча в резерві (вільний залишок 0)', 'INSUFFICIENT_FREE_STOCK', 'begin trade_assembly.post(''' || x || '''); end;');
  eq('Вільний залишок Чашки у рядку з урахуванням резерву', trade_assembly.line_free_qty(x, l_b), 0);
  trade_r3.unpost_customer_order(l_ord);
  delete from doc_assembly where id = x;
  select count(*) into l_n from doc_assembly where id = x;
  eq('Видалення чернетки (з рядками)', l_n, 0);

  -- перевірки шапки й рядків
  fails('Набір-послуга в документі', 'PRODUCT_SERVICE_NOT_ALLOWED',
        'insert into doc_assembly (organization_id, warehouse_id, kit_product_id, quantity) values (''' || l_org || ''', ''' || l_wh || ''', ''' || l_srv || ''', 1)');
  fails('Специфікація іншого набору', 'ASSEMBLY_BOM_MISMATCH',
        'insert into doc_assembly (organization_id, warehouse_id, kit_product_id, bom_id, quantity) values (''' || l_org || ''', ''' || l_wh || ''', ''' || l_k || ''', ''' || bomx || ''', 1)');
  x := asm('ASSEMBLY', 1, sysdate - 1.8, l_b);
  fails('Заповнення без специфікації', 'ASSEMBLY_BOM_REQUIRED', 'begin trade_assembly.fill_by_bom(''' || x || '''); end;');
  fails('Проведення без рядків і специфікації', 'NO_LINES', 'begin trade_assembly.post(''' || x || '''); end;');
  fails('Набір у комплектуючих', 'ASSEMBLY_KIT_IN_COMPONENTS',
        'insert into doc_assembly_goods (document_id, product_id, quantity) values (''' || x || ''', ''' || l_b || ''', 1)');
  fails('Послуга в комплектуючих', 'PRODUCT_SERVICE_NOT_ALLOWED',
        'insert into doc_assembly_goods (document_id, product_id, quantity) values (''' || x || ''', ''' || l_srv || ''', 1)');
  fails('Нульова кількість наборів', 'більшою за нуль',
        'update doc_assembly set quantity = 0 where id = ''' || x || '''');
  insert into doc_assembly_goods (document_id, product_id, quantity, cost_amount) values (x, l_a, 1, 999);
  eq('Собівартість рядка вводиться лише проведенням', line_cost(x, l_a), 0);

  -- ---------------------------------------------------------------- розкомплектація
  -- Набір 5 / 405; розкомплектація 2 → вартість 162 розподіляється за середньою: Кава 4 × 33 = 132, Чашка 6 × 5 = 30
  d3 := asm('DISASSEMBLY', 2, sysdate - 1.5);
  trade_assembly.fill_by_bom(d3);
  trade_assembly.post(d3);
  eq('Розкомплектація: набір 5 − 2', stock(l_k), 3);
  eq('Розкомплектація: Кава 10 + 4', stock(l_a), 14);
  eq('Розкомплектація: Чашка 5 + 6', stock(l_b), 11);
  select kit_cost_amount into l_n from doc_assembly where id = d3;
  eq('Списана собівартість наборів 405 × 2/5', l_n, 162);
  eq('Розподіл на Каву (за середньою)', line_cost(d3, l_a), 132);
  eq('Розподіл на Чашку (за середньою)', line_cost(d3, l_b), 30);
  eq('RegStockCost набору 405 − 162', cost(l_k), 243);
  eq('RegStockCost Кави 330 + 132', cost(l_a), 462);
  -- за частками вартості специфікації 75 / 25: 1 набір (81) → 60,75 / 20,25
  d4 := asm('DISASSEMBLY', 1, sysdate - 1.4, null, bom2);
  trade_assembly.fill_by_bom(d4);
  eq('Заповнення за специфікацією на 2 шт: Кава 4 × 1/2', line_qty(d4, l_a), 2);
  trade_assembly.post(d4);
  eq('Розподіл за частками: Кава', line_cost(d4, l_a), 60.75);
  eq('Розподіл за частками: Чашка (залишок)', line_cost(d4, l_b), 20.25);
  eq('Набір після двох розкомплектацій', stock(l_k), 2);
  -- розкомплектація понад залишок
  x := asm('DISASSEMBLY', 3, sysdate - 1.3);
  fails('Розкомплектація понад залишок набору', 'INSUFFICIENT_FREE_STOCK', 'begin trade_assembly.post(''' || x || '''); end;');

  -- ---------------------------------------------------------------- скасування
  fails('Скасування комплектації, набори якої вже розкомплектовано', 'INSUFFICIENT_FREE_STOCK',
        'begin trade_assembly.unpost(''' || d1 || '''); end;');
  trade_assembly.unpost(d4);
  eqs('Скасування розкомплектації', st(d4), 'DRAFT');
  select count(*) into l_n from reg_stock_balance_movement where recorder_id = d4;
  eq('Рухи залишків видалено', l_n, 0);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = d4;
  eq('Рухи собівартості видалено', l_n, 0);
  eq('Собівартість рядків обнулено', line_cost(d4, l_a), 0);
  eq('Набір повернувся', stock(l_k), 3);
  eq('Вартість набору повернулась', cost(l_k), 243);
  fails('Повторне скасування', 'NOT_POSTED', 'begin trade_assembly.unpost(''' || d4 || '''); end;');

  -- ---------------------------------------------------------------- копія
  d5 := trade_assembly.copy(d3);
  eqs('Копія — чернетка', st(d5), 'DRAFT');
  select count(*), sum(cost_amount) into l_n, l_v from doc_assembly_goods where document_id = d5;
  eq('Копія: рядки', l_n, 2);
  eq('Копія: собівартість рядків 0', l_v, 0);
  select count(*) into l_n from doc_assembly where id = d5 and organization_id = l_org and operation_kind = 'DISASSEMBLY' and quantity = 2;
  eq('Копія: організація, вид, кількість', l_n, 1);

  -- ---------------------------------------------------------------- перерахунок собівартості
  trade_r3.rebuild_stock_cost;
  eq('Перерахунок: собівартість набору', cost(l_k), 243);
  eq('Перерахунок: Кава', cost(l_a), 462);
  select kit_cost_amount into l_n from doc_assembly where id = d1;
  eq('Перерахунок: собівартість у документі комплектації', l_n, 324);
  select count(*) into l_n from reg_stock_cost_mv where recorder_type = 'DocAssembly' and recorder_id in (d1, d2, d3);
  eq('Перерахунок: рухи комплектацій', l_n, 9);

  -- ---------------------------------------------------------------- друк, реєстратори, меню, сторінки
  eqs('Форма друку за замовчуванням', trade_print.default_form(d1), 'ASSEMBLY');
  l_c := trade_print.document_html('ASSEMBLY', d1);
  eq('Друк: акт комплектації', case when instr(l_c, 'Акт комплектації товарів') > 0 and instr(l_c, 'T14 Кава') > 0
                                     and instr(l_c, to_char(324, 'FM999G999G999G990D00')) > 0 then 1 else 0 end, 1);
  l_c := trade_print.document_html('ASSEMBLY', d5);
  eq('Друк: чернетка розкомплектації', case when instr(l_c, 'розкомплектації') > 0 and instr(l_c, 'ЧЕРНЕТКА') > 0 then 1 else 0 end, 1);
  select count(*) into l_n from v_recorder where recorder_id in (d1, d3) and recorder_type = 'DocAssembly' and page_id = 441;
  eq('Реєстратор → сторінка 441', l_n, 2);
  select count(*) into l_n from v_assembly_list where organization_id = l_org;
  eq('Список документів', l_n, 8);
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'DocAssembly' and list_page_id = 440 and form_page_id = 441 and auth_scheme = 'Роль: склад')
      or (tech_name = 'RefBillOfMaterials' and list_page_id = 430 and form_page_id = 431 and auth_scheme is null);
  eq('Об''єкти меню', l_n, 2);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Warehouse' and o.tech_name in ('DocAssembly', 'RefBillOfMaterials');
  eq('Панель «Склад»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100
     and p.page_id in (440, 441) and p.authorization_scheme = 'Роль: склад';
  eq('Сторінки 440/441 захищені роллю «склад»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (430, 431);
  eq('Сторінки специфікацій 430/431', l_n, 2);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
