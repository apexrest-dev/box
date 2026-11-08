-- F-WH-11 «Ордерна схема, комірки»: ознаки складу (ордерна схема, адресне зберігання), довідник комірок,
-- регістр «Товари до надходження / до відвантаження» з рухів документів менеджера (склади без ордерної схеми —
-- без змін), прибутковий і видатковий ордери (розпорядження, заповнення, відбір по комірках, контроль «не більше
-- очікуваного», фактичного залишку й залишку комірки, серії), заборона скасування підстави з ордерами,
-- сканер, копіювання, робоче місце (ключ завдання), стан розпоряджень, звіти, реєстратори, меню, журнал.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_w1 varchar2(32); l_w2 varchar2(32); l_uom varchar2(32); l_sup varchar2(32); l_cus varchar2(32);
  l_p varchar2(32); l_m varchar2(32); s1 varchar2(32); s2 varchar2(32); b1 varchar2(32); b2 varchar2(32); bx varchar2(32);
  r0 varchar2(32); r1 varchar2(32); r2 varchar2(32); sa1 varchar2(32); sa2 varchar2(32); tr varchar2(32); wo varchar2(32);
  o1 varchar2(32); o2 varchar2(32); o3 varchar2(32); i1 varchar2(32); i2 varchar2(32); x varchar2(32);
  l_n number; l_s varchar2(4000); l_code varchar2(20);

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
  function pend (p_dir varchar2, p_wh varchar2, p_basis varchar2, p_prd varchar2, p_ser varchar2 default null) return number is
  begin
    return trade_order_scheme.pending_qty(p_dir, p_wh, p_basis, p_prd, null, p_ser);
  end;
  function receipt (p_wh varchar2, p_date date) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, p_wh, p_date)
      returning id into l;
    return l;
  end;
  function sale (p_date date) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_cus, l_w2, p_date)
      returning id into l;
    return l;
  end;
  function line_qty (p_tab varchar2, p_doc varchar2, p_prd varchar2) return number is
    l number;
  begin
    execute immediate 'select coalesce(sum(quantity), 0) from ' || p_tab || ' where document_id = :d and product_id = :p' into l using p_doc, p_prd;
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T21 ТОВ ' || t, 'LEGAL', '21212121') returning id into l_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T21 звичайний склад ' || t) returning id into l_w1;
  insert into ref_warehouse (name) values ('T21 ордерний склад ' || t) returning id into l_w2;
  insert into ref_product (name, unit_of_measure_id) values ('T21 Цукор ' || t, l_uom) returning id into l_p;
  insert into ref_product (name, unit_of_measure_id, use_series) values ('T21 Молоко ' || t, l_uom, 'Y') returning id into l_m;
  insert into ref_product_series (name, product_id) values ('T21-S1', l_m) returning id into s1;
  insert into ref_product_series (name, product_id) values ('T21-S2', l_m) returning id into s2;
  insert into ref_counterparty (name) values ('T21 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T21 покупець ' || t) returning id into l_cus;
  select code into l_code from ref_product where id = l_p;

  -- ---------------------------------------------------------------- ознаки складу
  select use_order_scheme || use_storage_bins into l_s from ref_warehouse where id = l_w1;
  eqs('Новий склад: без ордерної схеми й комірок', l_s, 'NN');
  fails('Комірки без ордерної схеми', 'STORAGE_BINS_REQUIRE_ORDERS',
        'update ref_warehouse set use_storage_bins = ''Y'' where id = ''' || l_w2 || '''');
  update ref_warehouse set use_order_scheme = 'Y' where id = l_w2;
  update ref_warehouse set use_storage_bins = 'Y' where id = l_w2;
  eqs('Ордерна схема', trade_order_scheme.uses_orders(l_w2), 'Y');
  eqs('Адресне зберігання', trade_order_scheme.uses_bins(l_w2), 'Y');

  -- ---------------------------------------------------------------- комірки
  insert into ref_storage_bin (warehouse_id, rack, tier, place) values (l_w2, 'a', '01', '01') returning id into b1;
  insert into ref_storage_bin (warehouse_id, name) values (l_w2, 'A-01-02') returning id into b2;
  eqs('Адреса комірки = стелаж-ярус-місце', trade_order_scheme.bin_label(b1), 'A-01-01');
  select count(*) into l_n from ref_storage_bin where id = b1 and code is not null and state = 'ACTIVE';
  eq('Код комірки призначено', l_n, 1);
  fails('Дубль адреси на складі', 'REF_STORAGE_BIN_NAME_UK',
        'insert into ref_storage_bin (warehouse_id, rack, tier, place) values (''' || l_w2 || ''', ''A'', ''01'', ''01'')');
  fails('Комірка без адреси', 'STORAGE_BIN_ADDRESS',
        'insert into ref_storage_bin (warehouse_id) values (''' || l_w2 || ''')');
  fails('Фізичне видалення комірки', 'видалення', 'delete from ref_storage_bin where id = ''' || b1 || '''');
  insert into ref_storage_bin (warehouse_id, name) values (l_w1, 'X-1') returning id into bx;
  trade_core.mark_for_deletion('REF_STORAGE_BIN', bx);
  select state into l_s from ref_storage_bin where id = bx;
  eqs('Помітка комірки на видалення', l_s, 'MARKED_FOR_DELETION');

  -- ---------------------------------------------------------------- звичайний склад — без змін
  r0 := receipt(l_w1, sysdate - 5);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (r0, l_p, 20, 10);
  trade_doc.post_goods_receipt(r0);
  select count(*) into l_n from reg_goods_order_mv where basis_id = r0;
  eq('Звичайний склад: рухів «до надходження» немає', l_n, 0);
  eq('Звичайний склад: залишок', trade_r3.stock_qty(l_w1, l_p), 20);
  fails('Комірки на складі з залишком', 'STORAGE_BINS_STOCK_NOT_ZERO',
        'update ref_warehouse set use_order_scheme = ''Y'', use_storage_bins = ''Y'' where id = ''' || l_w1 || '''');

  -- ---------------------------------------------------------------- надходження на ордерний склад
  r1 := receipt(l_w2, sysdate - 4);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (r1, l_p, 10, 10);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r1, l_m, 5, 20, s1);
  trade_doc.post_goods_receipt(r1);
  eq('Облік: залишок оприбутковано менеджером', trade_r3.stock_qty(l_w2, l_p), 10);
  eq('До надходження: цукор', pend('RECEIPT', l_w2, r1, l_p), 10);
  eq('До надходження: молоко серії S1', pend('RECEIPT', l_w2, r1, l_m, s1), 5);
  eq('Фактичний залишок до приймання', trade_order_scheme.physical_qty(l_w2, l_p, null, null), 0);
  select max(state) into l_s from v_goods_order_basis where basis_id = r1;
  eqs('Стан розпорядження', l_s, 'WAITING');
  select max(state_name) || ' / ' || max(basis_name) into l_s from v_goods_order_basis where basis_id = r1;
  eq('Розпорядження: назва підстави', sign(instr(l_s, 'Очікується приймання / Прибуткова накладна')), 1);

  -- ---------------------------------------------------------------- перевірки шапки
  fails('Ордер на складі без ордерної схеми', 'ORDER_SCHEME_NOT_USED',
        'insert into doc_goods_receipt_order (warehouse_id, basis_id) values (''' || l_w1 || ''', ''' || r0 || ''')');
  fails('Ордер без розпорядження', 'ORDER_BASIS_REQUIRED',
        'insert into doc_goods_receipt_order (warehouse_id) values (''' || l_w2 || ''')');
  fails('Розпорядження іншого напряму', 'ORDER_BASIS_INVALID',
        'insert into doc_goods_issue_order (warehouse_id, basis_id) values (''' || l_w2 || ''', ''' || r1 || ''')');
  fails('Комірка іншого складу', 'STORAGE_BIN_OTHER_WAREHOUSE',
        'insert into doc_goods_receipt_order (warehouse_id, basis_id, bin_id) values (''' || l_w2 || ''', ''' || r1 || ''', ''' || bx || ''')');

  -- ---------------------------------------------------------------- прибутковий ордер (частковий)
  o1 := trade_order_scheme.create_order('RECEIPT', r1);
  select count(*) into l_n from doc_goods_receipt_order_goods where document_id = o1;
  eq('Ордер за розпорядженням: рядки', l_n, 2);
  select basis_type || '/' || organization_id into l_s from doc_goods_receipt_order where id = o1;
  eqs('Тип підстави й організація з підстави', l_s, 'DocGoodsReceipt/' || l_org);
  eq('Очікується в рядку', trade_order_scheme.line_expected('RECEIPT', o1, l_p, null, null), 10);
  fails('Без комірки на складі з комірками', 'ORDER_BIN_REQUIRED', 'begin trade_order_scheme.post_receipt(''' || o1 || '''); end;');
  update doc_goods_receipt_order set bin_id = b1 where id = o1;
  update doc_goods_receipt_order_goods set quantity = 6 where document_id = o1 and product_id = l_p;
  trade_order_scheme.post_receipt(o1);
  select count(*) into l_n from doc_goods_receipt_order_goods where document_id = o1 and bin_id = b1;
  eq('Рядки отримали комірку з шапки', l_n, 2);
  eq('Прийнято частково: залишок до надходження', pend('RECEIPT', l_w2, r1, l_p), 4);
  eq('Комірка A-01-01: цукор', trade_order_scheme.bin_qty(b1, l_p), 6);
  eq('Комірка A-01-01: молоко S1', trade_order_scheme.bin_qty(b1, l_m, null, s1, 'N'), 5);
  eq('Фактичний залишок після приймання', trade_order_scheme.physical_qty(l_w2, l_p, null, null), 6);
  select max(state) into l_s from v_goods_order_basis where basis_id = r1;
  eqs('Стан розпорядження: частково', l_s, 'PARTIAL');
  eqs('Ордер у v_recorder', trade_order_scheme.state_name('RECEIPT', 'PARTIAL'), 'Прийнято частково');
  select count(*) into l_n from v_recorder where recorder_type = 'DocGoodsReceiptOrder' and recorder_id = o1 and page_id = 561
     and recorder_name like 'Прибутковий ордер на товари %';
  eq('Реєстратор прибуткового ордера', l_n, 1);
  fails('Проведений ордер лише для читання', 'DOCUMENT_READ_ONLY',
        'update doc_goods_receipt_order set doc_comment = ''x'' where id = ''' || o1 || '''');
  -- перевищення
  insert into doc_goods_receipt_order (warehouse_id, basis_id, bin_id) values (l_w2, r1, b2) returning id into o2;
  insert into doc_goods_receipt_order_goods (document_id, product_id, quantity) values (o2, l_p, 5);
  fails('Прийнято більше, ніж очікується', 'ORDER_EXCEEDS_BASIS', 'begin trade_order_scheme.post_receipt(''' || o2 || '''); end;');
  insert into doc_goods_receipt_order_goods (document_id, product_id, quantity) values (o2, l_m, 1);
  update doc_goods_receipt_order_goods set quantity = 4 where document_id = o2 and product_id = l_p;
  fails('Товар серії, якої немає в розпорядженні', 'ORDER_EXCEEDS_BASIS', 'begin trade_order_scheme.post_receipt(''' || o2 || '''); end;');
  delete from doc_goods_receipt_order_goods where document_id = o2 and product_id = l_m;
  -- заборона скасування підстави
  fails('Скасування надходження з проведеним ордером', 'ORDER_BASIS_HAS_ORDERS',
        'begin trade_doc.unpost_goods_receipt(''' || r1 || '''); end;');

  -- ---------------------------------------------------------------- реалізація й видатковий ордер
  sa1 := sale(sysdate - 3);
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (sa1, l_p, 5, 30);
  trade_ops.post_goods_sale(sa1);
  eq('До відвантаження за реалізацією', pend('SHIPMENT', l_w2, sa1, l_p), 5);
  eq('Фактичний залишок до відвантаження не змінився', trade_order_scheme.physical_qty(l_w2, l_p, null, null), 6);
  select max(state_name) into l_s from v_goods_order_basis where basis_id = sa1 and direction = 'SHIPMENT';
  eqs('Розпорядження на відвантаження: стан', l_s, 'До відбору');
  i1 := trade_order_scheme.create_task('SHIPMENT-' || l_w2 || '-' || sa1);
  select count(*), max(bin_id), sum(quantity) into l_n, x, l_s from doc_goods_issue_order_goods where document_id = i1;
  eq('Відбір по комірках: один рядок', l_n, 1);
  eqs('Відбір з комірки з залишком', x, b1);
  trade_order_scheme.post_issue(i1);
  eq('Відвантажено: залишок до відвантаження', pend('SHIPMENT', l_w2, sa1, l_p), 0);
  eq('Комірка після відбору', trade_order_scheme.bin_qty(b1, l_p), 1);
  eq('Фактичний залишок після відвантаження', trade_order_scheme.physical_qty(l_w2, l_p, null, null), 1);
  select max(state_name) into l_s from v_goods_order_basis where basis_id = sa1;
  eqs('Розпорядження відвантажено', l_s, 'Відвантажено');
  fails('Скасування реалізації з видатковим ордером', 'ORDER_BASIS_HAS_ORDERS',
        'begin trade_ops.unpost_goods_sale(''' || sa1 || '''); end;');
  -- друга реалізація: товару фізично не вистачає
  sa2 := sale(sysdate - 2);
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (sa2, l_p, 4, 30);
  trade_ops.post_goods_sale(sa2);
  i2 := trade_order_scheme.create_order('SHIPMENT', sa2);
  select count(*) into l_n from doc_goods_issue_order_goods where document_id = i2;
  eq('Відбір: комірка + рядок без комірки', l_n, 2);
  fails('Рядок без комірки', 'ORDER_BIN_REQUIRED', 'begin trade_order_scheme.post_issue(''' || i2 || '''); end;');
  update doc_goods_issue_order_goods set bin_id = b2 where document_id = i2 and bin_id is null;
  fails('Недостатньо в комірці', 'BIN_STOCK_INSUFFICIENT', 'begin trade_order_scheme.post_issue(''' || i2 || '''); end;');
  -- приймання решти в A-01-02
  trade_order_scheme.post_receipt(o2);
  eq('Надходження прийнято повністю', pend('RECEIPT', l_w2, r1, l_p), 0);
  select max(state) into l_s from v_goods_order_basis where basis_id = r1;
  eqs('Стан: прийнято', l_s, 'DONE');
  trade_order_scheme.post_issue(i2);
  eq('Друга реалізація відвантажена з двох комірок', trade_order_scheme.bin_qty(b1, l_p) + trade_order_scheme.bin_qty(b2, l_p), 1);
  eq('Фактичний = обліковий залишок після всіх ордерів', trade_order_scheme.physical_qty(l_w2, l_p, null, null), trade_r3.stock_qty(l_w2, l_p));
  fails('Скасування приймання вже відвантаженого', 'ORDER_PHYSICAL_STOCK', 'begin trade_order_scheme.unpost_receipt(''' || o2 || '''); end;');
  -- скасування й повторне проведення видаткового ордера
  trade_order_scheme.unpost_issue(i2);
  select status into l_s from doc_goods_issue_order where id = i2;
  eqs('Скасування видаткового ордера', l_s, 'DRAFT');
  eq('Після скасування знову до відвантаження', pend('SHIPMENT', l_w2, sa2, l_p), 4);
  trade_order_scheme.post_issue(i2);
  trade_order_scheme.unpost_issue(i2);
  delete from doc_goods_issue_order where id = i2;
  trade_ops.unpost_goods_sale(sa2);
  select count(*) into l_n from reg_goods_order_mv where basis_id = sa2;
  eq('Скасування реалізації без ордерів: рухи регістру видалено', l_n, 0);

  -- ---------------------------------------------------------------- сканер
  r2 := receipt(l_w2, sysdate - 1);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (r2, l_p, 3, 10);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price, series_id) values (r2, l_m, 2, 20, s2);
  trade_doc.post_goods_receipt(r2);
  insert into doc_goods_receipt_order (warehouse_id, basis_id, bin_id) values (l_w2, r2, b2) returning id into o3;
  trade_order_scheme.scan('RECEIPT', o3, l_code);
  trade_order_scheme.scan('RECEIPT', o3, l_code);
  eq('Сканер: кількість додається в рядок', line_qty('doc_goods_receipt_order_goods', o3, l_p), 2);
  trade_order_scheme.scan('RECEIPT', o3, 'T21 Молоко ' || t);
  select max(series_id) into x from doc_goods_receipt_order_goods where document_id = o3 and product_id = l_m;
  eqs('Сканер: серія з розпорядження', x, s2);
  fails('Сканер: невідомий штрихкод', 'BARCODE_NOT_FOUND', 'begin trade_order_scheme.scan(''RECEIPT'', ''' || o3 || ''', ''NO-SUCH-' || t || '''); end;');
  update doc_goods_receipt_order_goods set series_id = null where document_id = o3 and product_id = l_m;
  trade_order_scheme.post_receipt(o3);
  select max(series_id) into x from doc_goods_receipt_order_goods where document_id = o3 and product_id = l_m;
  eqs('Проведення: серія підставлена з розпорядження', x, s2);
  eq('Сканер-ордер: до надходження залишилось', pend('RECEIPT', l_w2, r2, l_p), 1);
  x := trade_order_scheme.copy('RECEIPT', o3);
  select count(*) into l_n from doc_goods_receipt_order_goods where document_id = x;
  eq('Копія ордера: рядки', l_n, 2);
  select status into l_s from doc_goods_receipt_order where id = x;
  eqs('Копія — чернетка', l_s, 'DRAFT');
  delete from doc_goods_receipt_order where id = x;

  -- ---------------------------------------------------------------- переміщення й списання
  tr := null;
  insert into doc_goods_transfer (warehouse_from_id, warehouse_to_id, occurred_at) values (l_w1, l_w2, sysdate - 1) returning id into tr;
  insert into doc_goods_transfer_goods (document_id, product_id, quantity) values (tr, l_p, 7);
  trade_ops.post_goods_transfer(tr);
  eq('Переміщення: до надходження на ордерний склад', pend('RECEIPT', l_w2, tr, l_p), 7);
  select count(*) into l_n from reg_goods_order_mv where basis_id = tr and warehouse_id = l_w1;
  eq('Переміщення: склад-відправник без ордерної схеми — без рухів', l_n, 0);
  x := trade_order_scheme.create_order('RECEIPT', tr);
  select warehouse_id into l_s from doc_goods_receipt_order where id = x;
  eqs('Ордер за переміщенням: склад-отримувач', l_s, l_w2);
  insert into doc_goods_write_off (warehouse_id, reason, occurred_at) values (l_w2, 'Бій', sysdate) returning id into wo;
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (wo, l_p, 1);
  trade_ops.post_goods_write_off(wo);
  eq('Списання: до відвантаження', pend('SHIPMENT', l_w2, wo, l_p), 1);

  -- ---------------------------------------------------------------- ознаки складу в роботі
  fails('Вимкнення ордерної схеми з незакритими розпорядженнями', 'ORDER_SCHEME_IN_USE',
        'update ref_warehouse set use_order_scheme = ''N'', use_storage_bins = ''N'' where id = ''' || l_w2 || '''');
  fails('Вимкнення комірок із залишком у комірках', 'STORAGE_BINS_IN_USE',
        'update ref_warehouse set use_storage_bins = ''N'' where id = ''' || l_w2 || '''');
  fails('Зміна складу комірки з рухами', 'STORAGE_BIN_IN_USE',
        'update ref_storage_bin set warehouse_id = ''' || l_w1 || ''' where id = ''' || b1 || '''');

  -- ---------------------------------------------------------------- звіти
  select count(*) into l_n from v_goods_order_basis where warehouse_id = l_w2 and remaining_qty > 0;
  eq('Незакриті розпорядження (надходження r2, переміщення, списання)', l_n, 3);
  select max(physical_qty), max(book_qty), max(to_receive_qty), max(to_ship_qty) into l_n, x, l_s, l_code
    from v_order_scheme_stock where warehouse_id = l_w2 and product_id = l_p;
  eqs('Облік / до надходження / до відвантаження / фактично', x || '/' || l_s || '/' || l_code || '/' || l_n, '14/8/1/7');
  select count(*) into l_n from v_bin_stock where warehouse_id = l_w2;
  eq('Товари в комірках: ключі', l_n, 4);
  select count(*) into l_n from v_goods_order_list where warehouse_id = l_w2 and kind = 'RECEIPT';
  eq('Список прибуткових ордерів', l_n, 4);
  select count(*) into l_n from v_goods_order_movement where warehouse_name = 'T21 ордерний склад ' || t and register_name = 'Товари в комірках';
  eq('Рухи «Товари в комірках»', l_n, 6);
  select count(*) into l_n from v_storage_bin_list where warehouse_id = l_w2 and products_count > 0;
  eq('Комірки з товарами', l_n, 2);

  -- ---------------------------------------------------------------- друк
  eqs('Друкована форма за замовчуванням', trade_print.default_form(o1), 'RECEIPT_ORDER');
  l_s := dbms_lob.substr(trade_print.document_html('RECEIPT_ORDER', o1), 4000, 1);
  eq('Друк прибуткового ордера', sign(instr(l_s, 'Прибутковий ордер на товари №')), 1);
  l_s := dbms_lob.substr(trade_print.document_html('ISSUE_ORDER', i1), 4000, 1);
  eq('Друк видаткового ордера: розпорядження', sign(instr(l_s, 'Реалізація товарів')), 1);

  -- ---------------------------------------------------------------- журнал, меню, сторінки
  select count(*) into l_n from sys_audit_log where object_type in ('DocGoodsReceiptOrder', 'DocGoodsIssueOrder')
     and object_id in (o1, o2, o3, i1) and action = 'POST';
  eq('Аудит проведення ордерів', l_n, 4);
  select count(*) into l_n from user_triggers
   where trigger_name in ('DOC_GOODS_RECEIPT_ORDER_EVLOG', 'DOC_GOODS_ISSUE_ORDER_EVLOG', 'REF_STORAGE_BIN_EVLOG') and status = 'ENABLED';
  eq('Тригери журналу реєстрації', l_n, 3);
  eqs('Організація ордера (trade_org.doc_table)', trade_org.doc_table('DocGoodsIssueOrder'), 'DOC_GOODS_ISSUE_ORDER');
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'RefStorageBin' and list_page_id = 550 and form_page_id = 551)
      or (tech_name = 'DocGoodsReceiptOrder' and list_page_id = 560 and auth_scheme = 'Роль: склад')
      or (tech_name = 'DocGoodsIssueOrder' and list_page_id = 570 and auth_scheme = 'Роль: склад')
      or (tech_name = 'RegGoodsOrderScheme' and list_page_id = 580)
      or (tech_name = 'StorekeeperWorkplace' and list_page_id = 590);
  eq('Об''єкти меню', l_n, 5);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (550, 551, 560, 561, 570, 571, 580, 590);
  eq('Сторінки 550/551, 560/561, 570/571, 580, 590', l_n, 8);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
