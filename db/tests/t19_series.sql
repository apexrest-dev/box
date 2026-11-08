-- F-NSI-10 «Характеристики, серії, терміни придатності»: ознаки номенклатури, довідники характеристик і
-- серій (термін придатності за замовчуванням), перевірки рядків, виміри RegStockBalance / RegStockReserve /
-- RegStockCost з рядків документів, обов'язковість і контроль залишку серії, FEFO у реалізації (поділ рядка,
-- пропуск прострочених), списанні й переміщенні, попередження про прострочену серію, повернення з рядка-підстави,
-- характеристика з замовлення, копіювання, звіт «Товари з терміном, що спливає», меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_wh varchar2(32); l_wh2 varchar2(32); l_uom varchar2(32); l_sup varchar2(32); l_cus varchar2(32);
  l_m varchar2(32); l_m2 varchar2(32); l_t varchar2(32); l_p varchar2(32); l_k varchar2(32);
  s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); sx varchar2(32); c_red varchar2(32); c_blue varchar2(32);
  r1 varchar2(32); sa1 varchar2(32); sa2 varchar2(32); sa3 varchar2(32); wo varchar2(32); tr varchar2(32);
  l_ord varchar2(32); l_ret varchar2(32); l_cp varchar2(32); l_asm varchar2(32); x varchar2(32);
  l_n number; l_s varchar2(4000); l_d date;

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
  function bal (p_wh varchar2, p_prd varchar2, p_chr varchar2, p_ser varchar2) return number is
  begin
    return trade_series.balance(p_wh, p_prd, p_chr, p_ser);
  end;
  function sale (p_date date) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_wh, p_date)
      returning id into l;
    return l;
  end;
  procedure sline (p_doc varchar2, p_prd varchar2, p_qty number, p_chr varchar2 default null, p_ser varchar2 default null) is
  begin
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price, characteristic_id, series_id)
    values (p_doc, p_prd, p_qty, 100, p_chr, p_ser);
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T19 ТОВ ' || t, 'LEGAL', '19191919') returning id into l_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T19 склад ' || t) returning id into l_wh;
  insert into ref_warehouse (name) values ('T19 склад 2 ' || t) returning id into l_wh2;
  insert into ref_product (name, unit_of_measure_id, use_series, shelf_life_days) values ('T19 Молоко ' || t, l_uom, 'Y', 10) returning id into l_m;
  insert into ref_product (name, unit_of_measure_id, use_series) values ('T19 Кефір ' || t, l_uom, 'Y') returning id into l_m2;
  insert into ref_product (name, unit_of_measure_id, use_characteristics) values ('T19 Футболка ' || t, l_uom, 'Y') returning id into l_t;
  insert into ref_product (name, unit_of_measure_id) values ('T19 Хліб ' || t, l_uom) returning id into l_p;
  insert into ref_product (name, unit_of_measure_id) values ('T19 Набір ' || t, l_uom) returning id into l_k;
  insert into ref_counterparty (name) values ('T19 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T19 покупець ' || t) returning id into l_cus;
  insert into ref_product (name, unit_of_measure_id, product_kind, use_series) values ('T19 Послуга ' || t, l_uom, 'SERVICE', 'Y') returning id into x;
  select use_series into l_s from ref_product where id = x;
  eqs('Послуга: ознака «Облік серій» знімається', l_s, 'N');

  -- ---------------------------------------------------------------- довідники
  insert into ref_product_series (name, product_id, production_date) values ('S-001', l_m, trunc(sysdate) - 5) returning id into s1;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('S-002', l_m, trunc(sysdate) - 2, trunc(sysdate) + 20)
    returning id into s2;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('S-003', l_m, trunc(sysdate) - 30, trunc(sysdate) - 3)
    returning id into s3;
  insert into ref_product_series (name, product_id) values ('K-001', l_m2) returning id into sx;
  select expiry_date into l_d from ref_product_series where id = s1;
  eq('Придатний до = дата виробництва + термін придатності товару', l_d - trunc(sysdate), 5);
  select count(*) into l_n from ref_product_series where id = s1 and code is not null and state = 'ACTIVE';
  eq('Код серії призначено автоматично', l_n, 1);
  eqs('Подання серії', trade_series.series_label(s2), 'S-002 (до ' || to_char(trunc(sysdate) + 20, 'DD.MM.YYYY') || ')');
  insert into ref_product_characteristic (name, product_id) values ('Червона, M', l_t) returning id into c_red;
  insert into ref_product_characteristic (name, product_id) values ('Синя, L', l_t) returning id into c_blue;
  fails('Серія товару без обліку серій', 'SERIES_NOT_USED',
        'insert into ref_product_series (name, product_id) values (''X'', ''' || l_p || ''')');
  fails('Характеристика товару без ознаки', 'CHARACTERISTICS_NOT_USED',
        'insert into ref_product_characteristic (name, product_id) values (''X'', ''' || l_m || ''')');
  fails('Придатний до раніше виробництва', 'SERIES_EXPIRY_BEFORE_PRODUCTION',
        'insert into ref_product_series (name, product_id, production_date, expiry_date) values (''X'', ''' || l_m
        || ''', trunc(sysdate), trunc(sysdate) - 1)');
  fails('Дубль номера серії товару', 'REF_PRODUCT_SERIES_NAME_UK',
        'insert into ref_product_series (name, product_id) values (''S-001'', ''' || l_m || ''')');
  fails('Фізичне видалення серії', 'видалення', 'delete from ref_product_series where id = ''' || s1 || '''');

  -- ---------------------------------------------------------------- надходження
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 3)
    returning id into r1;
  fails('Серія іншого товару в рядку', 'SERIES_OTHER_PRODUCT',
        'insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (''' || r1 || ''', '''
        || l_m || ''', 1, 1, ''' || sx || ''')');
  fails('Характеристика іншого товару в рядку', 'CHARACTERISTIC_OTHER_PRODUCT',
        'begin update ref_product set use_characteristics = ''Y'' where id = ''' || l_m || ''';'
        || ' insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, characteristic_id) values (''' || r1 || ''', '''
        || l_m || ''', 1, 1, ''' || c_red || '''); end;');
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r1, l_m, 10, 20, s1);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r1, l_m, 5, 22, s2);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r1, l_m, 3, 18, s3);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, characteristic_id) values (r1, l_t, 4, 150, c_red);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, characteristic_id) values (r1, l_t, 6, 150, c_blue);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r1, l_p, 10, 10, s1);
  select count(*) into l_n from doc_goods_receipt_goods where document_id = r1 and product_id = l_p and series_id is null;
  eq('Товар без обліку серій: серія в рядку очищається', l_n, 1);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (r1, l_m, 1, 20);
  fails('Проведення без серії товару з обліком серій', 'SERIES_REQUIRED', 'begin trade_doc.post_goods_receipt(''' || r1 || '''); end;');
  delete from doc_goods_receipt_goods where document_id = r1 and product_id = l_m and series_id is null;
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (r1, l_t, 1, 150);
  fails('Проведення без характеристики', 'CHARACTERISTIC_REQUIRED', 'begin trade_doc.post_goods_receipt(''' || r1 || '''); end;');
  delete from doc_goods_receipt_goods where document_id = r1 and product_id = l_t and characteristic_id is null;
  trade_doc.post_goods_receipt(r1);
  eq('RegStockBalance: серія S-001', bal(l_wh, l_m, null, s1), 10);
  eq('RegStockBalance: серія S-003', bal(l_wh, l_m, null, s3), 3);
  eq('RegStockBalance: характеристика «Червона»', bal(l_wh, l_t, c_red, null), 4);
  eq('RegStockBalance: товар без ознак — без вимірів', bal(l_wh, l_p, null, null), 10);
  eq('Залишок товару в цілому (trade_r3)', trade_r3.stock_qty(l_wh, l_m), 18);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = r1 and series_id is not null;
  eq('RegStockCost: виміри серій заповнено', l_n, 3);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = r1 and characteristic_id is not null;
  eq('RegStockCost: виміри характеристик заповнено', l_n, 2);
  fails('Зміна ознаки «Облік серій» за наявності залишку', 'SERIES_FLAGS_WITH_STOCK',
        'update ref_product set use_series = ''N'' where id = ''' || l_m || '''');
  fails('Зміна товару серії, що вже в рухах', 'SERIES_OWNER_CHANGE',
        'update ref_product_series set product_id = ''' || l_m2 || ''' where id = ''' || s1 || '''');

  -- ---------------------------------------------------------------- реалізація: FEFO
  sa1 := sale(sysdate - 2);
  sline(sa1, l_m, 12);
  sline(sa1, l_t, 2, c_red);
  sline(sa1, l_p, 1);
  trade_ops.post_goods_sale(sa1);
  select count(*) into l_n from doc_goods_sale_goods where document_id = sa1;
  eq('FEFO: рядок поділено на дві серії (4 рядки)', l_n, 4);
  select listagg(s.name || ':' || g.quantity || '@' || g.line_number, ',') within group (order by g.line_number) into l_s
    from doc_goods_sale_goods g join ref_product_series s on s.id = g.series_id where g.document_id = sa1;
  eqs('FEFO: спочатку S-001 (спливає першою), прострочену S-003 пропущено', l_s, 'S-001:10@1,S-002:2@2');
  select total_amount into l_n from doc_goods_sale where id = sa1;
  eq('Сума документа після поділу', l_n, 1500);
  eq('Залишок S-001 після реалізації', bal(l_wh, l_m, null, s1), 0);
  eq('Залишок S-002 після реалізації', bal(l_wh, l_m, null, s2), 3);
  eq('Залишок «Червона» після реалізації', bal(l_wh, l_t, c_red, null), 2);
  select count(*) into l_n from reg_stock_cost_mv where recorder_id = sa1 and series_id is not null;
  eq('Собівартість реалізації в розрізі серій', l_n, 2);
  select count(*) into l_n from reg_sales_turnover where recorder_id = sa1;
  eq('Продажі: рядки після поділу', l_n, 4);
  trade_ops.unpost_goods_sale(sa1);
  trade_ops.post_goods_sale(sa1);
  eq('Повторне проведення: залишок S-002', bal(l_wh, l_m, null, s2), 3);
  select count(*) into l_n from doc_goods_sale_goods where document_id = sa1;
  eq('Повторне проведення не ділить рядки знову', l_n, 4);

  sa2 := sale(sysdate - 1.5);
  sline(sa2, l_t, 3, c_red);
  fails('Недостатньо залишку характеристики (товару в цілому вистачає)', 'INSUFFICIENT_SERIES_STOCK',
        'begin trade_ops.post_goods_sale(''' || sa2 || '''); end;');
  update doc_goods_sale_goods set quantity = 4 where document_id = sa2;
  update doc_goods_sale_goods set characteristic_id = c_blue where document_id = sa2;
  sline(sa2, l_m, 1, null, s3);
  trade_warn.clear;
  trade_ops.post_goods_sale(sa2);
  l_s := trade_warn.take;
  eq('Попередження: продано прострочену серію', case when instr(l_s, 'S-003') > 0 and instr(l_s, 'минув') > 0 then 1 else 0 end, 1);
  eq('Залишок «Синя»', bal(l_wh, l_t, c_blue, null), 2);

  sa3 := sale(sysdate - 1.4);
  sline(sa3, l_m, 5);
  fails('FEFO: непрострочених серій не вистачає', 'SERIES_INSUFFICIENT', 'begin trade_ops.post_goods_sale(''' || sa3 || '''); end;');
  l_n := trade_series.fill_fefo('DocGoodsSale', sa3);
  eq('Підбір серій (команда): заповнено частин', l_n, 1);
  select listagg(coalesce(s.name, '-') || ':' || g.quantity, ',') within group (order by g.line_number) into l_s
    from doc_goods_sale_goods g left join ref_product_series s on s.id = g.series_id where g.document_id = sa3;
  eqs('Підбір серій: нестача окремим рядком без серії', l_s, 'S-002:3,-:2');
  delete from doc_goods_sale_goods where document_id = sa3 and series_id is null;
  trade_ops.post_goods_sale(sa3);
  eq('Залишок S-002 = 0', bal(l_wh, l_m, null, s2), 0);

  -- ---------------------------------------------------------------- списання й переміщення: FEFO з простроченими
  insert into doc_goods_write_off (organization_id, warehouse_id, reason, occurred_at) values (l_org, l_wh, 'Прострочено', sysdate - 1)
    returning id into wo;
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (wo, l_m, 2);
  trade_ops.post_goods_write_off(wo);
  select max(series_id) into x from doc_goods_write_off_goods where document_id = wo;
  eqs('Списання: FEFO бере прострочену серію', x, s3);
  eq('Залишок S-003 = 0', bal(l_wh, l_m, null, s3), 0);
  insert into doc_goods_transfer (organization_id, warehouse_from_id, warehouse_to_id, occurred_at) values (l_org, l_wh, l_wh2, sysdate - 0.9)
    returning id into tr;
  insert into doc_goods_transfer_goods (document_id, product_id, quantity) values (tr, l_t, 1);
  update doc_goods_transfer_goods set characteristic_id = c_blue where document_id = tr;
  trade_ops.post_goods_transfer(tr);
  eq('Переміщення: «Синя» на складі-отримувачі', bal(l_wh2, l_t, c_blue, null), 1);
  eq('Переміщення: «Синя» на складі-відправнику', bal(l_wh, l_t, c_blue, null), 1);

  -- ---------------------------------------------------------------- повернення, замовлення, копіювання
  l_ret := trade_r3.customer_return_from_sale(sa1);
  select count(*) into l_n from doc_customer_return_goods where document_id = l_ret and series_id is not null;
  eq('Повернення від клієнта: серії з рядків реалізації', l_n, 2);
  delete from doc_customer_return_goods where document_id = l_ret and (series_id is null or series_id <> s1);
  update doc_customer_return_goods set quantity = 4 where document_id = l_ret;
  trade_r3.post_customer_return(l_ret);
  eq('Повернення: залишок S-001', bal(l_wh, l_m, null, s1), 4);

  insert into doc_customer_order (customer_id, warehouse_id, occurred_at) values (l_cus, l_wh, sysdate - 0.8) returning id into l_ord;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, reserve_flag, characteristic_id)
  values (l_ord, l_t, 1, 160, 'Y', c_red);
  trade_r3.post_customer_order(l_ord);
  select max(characteristic_id) into x from reg_stock_reserve_mv where recorder_id = l_ord;
  eqs('RegStockReserve: характеристика з рядка замовлення', x, c_red);
  x := trade_r3.sale_from_order(l_ord);
  trade_ops.post_goods_sale(x);
  select max(characteristic_id) into l_s from doc_goods_sale_goods where document_id = x;
  eqs('Реалізація за замовленням: характеристика з замовлення', l_s, c_red);
  eq('Залишок «Червона» після відвантаження замовлення', bal(l_wh, l_t, c_red, null), 1);

  l_cp := trade_ops.copy_goods_sale(sa1);
  trade_series.copy_dims('DocGoodsSale', sa1, l_cp);
  select count(*) into l_n from doc_goods_sale_goods where document_id = l_cp and series_id is not null;
  eq('Копіювання: серії рядків перенесено', l_n, 2);

  -- комплектація: FEFO для комплектуючих
  insert into doc_assembly (organization_id, occurred_at, operation_kind, warehouse_id, kit_product_id, quantity)
  values (l_org, sysdate - 0.5, 'ASSEMBLY', l_wh, l_k, 1) returning id into l_asm;
  insert into doc_assembly_goods (document_id, product_id, quantity) values (l_asm, l_m, 1);
  trade_series.fill_fefo('DocAssembly', l_asm);
  select max(series_id) into x from doc_assembly_goods where document_id = l_asm;
  eqs('Комплектація: серію комплектуючої підібрано', x, s1);

  -- ---------------------------------------------------------------- звіт, підсумки, меню, журнал
  select count(*) into l_n from v_series_stock_balance where warehouse_id = l_wh and product_id = l_m and quantity > 0;
  eq('Звіт: серії з залишком', l_n, 1);
  select count(*) into l_n from v_series_stock_balance where warehouse_id in (l_wh, l_wh2) and product_id = l_t;
  eq('Звіт: залишки характеристик', l_n, 3);
  eqs('Стан терміну: прострочено', trade_series.expiry_state(trunc(sysdate) - 1, sysdate, 30), 'EXPIRED');
  eqs('Стан терміну: спливає', trade_series.expiry_state(trunc(sysdate) + 5, sysdate, 30), 'EXPIRING');
  eqs('Стан терміну: придатний', trade_series.expiry_state(trunc(sysdate) + 20, sysdate, 7), 'OK');
  select count(*) into l_n from reg_stock_balance_tot b
   where b.warehouse_id = l_wh and b.product_id in (l_m, l_t)
     and b.quantity = (select sum(quantity) from reg_stock_balance_movement m where m.warehouse_id = b.warehouse_id and m.product_id = b.product_id);
  eq('Підсумки RegStockBalance узгоджені (склад × товар)', l_n, 2);
  select count(*) into l_n from v_product_series_list where product_id = l_m;
  eq('Список серій', l_n, 3);
  trade_core.mark_for_deletion('REF_PRODUCT_SERIES', s3);
  select state into l_s from ref_product_series where id = s3;
  eqs('Помітка серії на видалення', l_s, 'MARKED_FOR_DELETION');
  fails('Помічену серію не можна вибрати', 'SERIES_NOT_ACTIVE',
        'insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values ((select id from doc_goods_receipt where id = '''
        || r1 || '''), ''' || l_m || ''', 1, 1, ''' || s3 || ''')');
  select count(*) into l_n from sys_audit_log where object_type = 'REF_PRODUCT_SERIES' and object_id = s1 and action = 'CREATE';
  eq('Журнал реєстрації: створення серії', l_n, 1);
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'RefProductCharacteristic' and list_page_id = 490 and form_page_id = 491)
      or (tech_name = 'RefProductSeries' and list_page_id = 500 and form_page_id = 501)
      or (tech_name = 'ExpiringGoods' and list_page_id = 510 and kind = 'REPORT');
  eq('Об''єкти меню', l_n, 3);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (490, 491, 500, 501, 510);
  eq('Сторінки 490/491, 500/501, 510', l_n, 5);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
