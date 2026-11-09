set define off
-- F-INT-04 «EDI з торговими мережами»: GLN (контрольна цифра, дублікати), точки доставки, вхідне ORDERS
-- (зіставлення за GLN / штрихкодом / упаковкою / кодом постачальника, помилки рядків і шапки, дублікати, повторне
-- зіставлення), замовлення клієнта з ORDERS (ціни, точка доставки, № мережі), ORDRSP (прийнято / змінено / відхилено),
-- DESADV, INVOIC (ПДВ), RECADV (звірка з реалізацією), транспорт (STUB / FILE), скасування, HTML, меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); w1 varchar2(32); l_uom varchar2(32); l_sup varchar2(32); cp varchar2(32); cp2 varchar2(32);
  l_pt varchar2(32); p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); dp1 varchar2(32); dp2 varchar2(32);
  g_org varchar2(13); g_cp varchar2(13); g_dp1 varchar2(13); g_dp2 varchar2(13); g_dp3 varchar2(13);
  e1 varchar2(13); e1p varchar2(13); e3 varchar2(13); e_bad varchar2(13);
  m1 varchar2(32); m2 varchar2(32); l_ord varchar2(32); l_rsp varchar2(32); l_rsp2 varchar2(32); l_sale varchar2(32);
  l_des varchar2(32); l_inv varchar2(32); l_rec varchar2(32); l_id varchar2(32); rc varchar2(32);
  l_n number; l_s varchar2(4000); l_c clob; l_x clob;
  r sys_edi_message%rowtype;
  k6 varchar2(6); k6b varchar2(6); l_b blob;

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
  procedure has (p_name varchar2, p_html clob, p_text varchar2, p_times number default 1) is
    l number := 0; p number := 1;
  begin
    loop
      p := dbms_lob.instr(p_html, p_text, p);
      exit when p = 0 or p is null;
      l := l + 1; p := p + 1;
    end loop;
    dbms_output.put_line(case when l = p_times then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || l || ' × «' || p_text || '»');
  end;
  procedure err (p_name varchar2, p_code varchar2) is
  begin
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || sqlerrm);
  end;
  function msg (p_id varchar2) return sys_edi_message%rowtype is
    l sys_edi_message%rowtype;
  begin
    select * into l from sys_edi_message where id = p_id;
    return l;
  end;
  -- значення XPath з payload повідомлення
  function xv (p_id varchar2, p_path varchar2) return varchar2 is
    l varchar2(4000);
  begin
    select xmlcast(xmlquery(p_path passing xmltype(payload) returning content) as varchar2(4000)) into l
      from sys_edi_message where id = p_id;
    return l;
  end;
  function xcnt (p_id varchar2, p_path varchar2) return number is
    l number;
  begin
    select xmlcast(xmlquery(('count(' || p_path || ')') passing xmltype(payload) returning content) as number) into l
      from sys_edi_message where id = p_id;
    return l;
  end;
  function orders (p_number varchar2, p_sup varchar2, p_buyer varchar2, p_dp varchar2, p_lines varchar2) return clob is
  begin
    return '<?xml version="1.0" encoding="UTF-8"?><ORDER><DOCUMENTNAME>220</DOCUMENTNAME><NUMBER>' || p_number || '</NUMBER>'
        || '<DATE>' || to_char(sysdate, 'YYYY-MM-DD') || '</DATE><DELIVERYDATE>' || to_char(sysdate + 3, 'YYYY-MM-DD') || '</DELIVERYDATE>'
        || '<CURRENCY>UAH</CURRENCY><INFO>Т28 &amp; коментар</INFO><HEAD><SUPPLIER>' || p_sup || '</SUPPLIER><BUYER>' || p_buyer || '</BUYER>'
        || '<DELIVERYPLACE>' || p_dp || '</DELIVERYPLACE><SENDER>' || p_buyer || '</SENDER><RECIPIENT>' || p_sup || '</RECIPIENT>'
        || p_lines || '</HEAD></ORDER>';
  end;
  function pos (n number, p_ean varchar2, p_qty varchar2, p_price varchar2 default null, p_sup varchar2 default null,
                p_buyer varchar2 default null) return varchar2 is
  begin
    return '<POSITION><POSITIONNUMBER>' || n || '</POSITIONNUMBER>' || case when p_ean is not null then '<PRODUCT>' || p_ean || '</PRODUCT>' end
        || case when p_buyer is not null then '<PRODUCTIDBUYER>' || p_buyer || '</PRODUCTIDBUYER>' end
        || case when p_sup is not null then '<PRODUCTIDSUPPLIER>' || p_sup || '</PRODUCTIDSUPPLIER>' end
        || '<DESCRIPTION>Рядок ' || n || '</DESCRIPTION><ORDEREDQUANTITY>' || p_qty || '</ORDEREDQUANTITY><ORDERUNIT>PCE</ORDERUNIT>'
        || case when p_price is not null then '<ORDERPRICE>' || p_price || '</ORDERPRICE>' end || '</POSITION>';
  end;
begin
  select lpad(mod(ora_hash(t), 1000000), 6, '0'), lpad(mod(ora_hash(t || 'a'), 1000000), 6, '0') into k6, k6b from dual;
  -- ---------------------------------------------------------------- GLN
  eqs('GLN: контрольна цифра 482000100000 → 4820001000009', trade_edi.gln_with_check('482000100000'), '4820001000009');
  eqs('GLN: валідний', trade_edi.is_valid_gln('4820001000009'), 'Y');
  eqs('GLN: невірна контрольна цифра', trade_edi.is_valid_gln('4820001000008'), 'N');
  eqs('GLN: не 13 цифр', trade_edi.is_valid_gln('48200010000'), 'N');
  eqs('GLN: пробіли прибираються', trade_edi.normalize_gln(' 4820 0010-00009 '), '4820001000009');
  eqs('Назва типу', trade_edi.type_name('DESADV'), 'DESADV — повідомлення про відвантаження');
  eqs('Назва стану', trade_edi.status_name('SENT'), 'Надіслано');
  eqs('Провайдер за замовчуванням — імітація', trade_edi.default_provider, 'STUB');

  g_org := trade_edi.gln_with_check('48202' || k6 || '1');
  g_cp  := trade_edi.gln_with_check('48202' || k6 || '2');
  g_dp1 := trade_edi.gln_with_check('48202' || k6 || '3');
  g_dp2 := trade_edi.gln_with_check('48202' || k6 || '4');
  g_dp3 := trade_edi.gln_with_check('48202' || k6 || '5');
  e1  := trade_edi.gln_with_check('48299' || k6b || '1');
  e1p := trade_edi.gln_with_check('48299' || k6b || '2');
  e3  := trade_edi.gln_with_check('48299' || k6b || '3');
  e_bad := trade_edi.gln_with_check('48299' || k6b || '9');

  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou, vat_payer, vat_number, gln)
  values ('T28 ТОВ Постачальник ' || t, 'LEGAL', '28282828', 'Y', '282828282828', g_org) returning id into l_org;
  select gln into l_s from ref_organization where id = l_org;
  eqs('GLN організації', l_s, g_org);
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T28 склад ' || t) returning id into w1;
  insert into ref_counterparty (name) values ('T28 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name, vat_payer, vat_number, gln, edrpou) values ('T28 Мережа ' || t, 'Y', '282828282829', g_cp, '28282829')
    returning id into cp;
  insert into ref_counterparty (name) values ('T28 інший покупець ' || t) returning id into cp2;
  insert into ref_price_type (name, price_includes_vat) values ('T28 опт ' || t, 'Y') returning id into l_pt;
  insert into ref_product (name, unit_of_measure_id, article) values ('T28 Цукор ' || t, l_uom, 'T28A' || substr(t, 1, 6)) returning id into p1;
  insert into ref_product (name, unit_of_measure_id, article) values ('T28 Олія ' || t, l_uom, 'T28B' || substr(t, 1, 6)) returning id into p2;
  insert into ref_product (name, unit_of_measure_id) values ('T28 Чай ' || t, l_uom) returning id into p3;
  insert into reg_barcode (barcode, product_id, unit_quantity) values (e1, p1, 1);
  insert into reg_barcode (barcode, product_id, unit_quantity) values (e1p, p1, 6);
  insert into reg_barcode (barcode, product_id, unit_quantity) values (e3, p3, 1);
  eqs('EAN товару — штрихкод одиниці, не упаковки', trade_edi.product_ean(p1), e1);
  eqs('Код одиниці «шт» → PCE', trade_edi.unit_code(p1), 'PCE');
  insert into doc_price_setting (occurred_at, price_type_id) values (sysdate - 10, l_pt) returning id into rc;
  insert into doc_price_setting_prices (document_id, product_id, price) values (rc, p1, 30);
  insert into doc_price_setting_prices (document_id, product_id, price) values (rc, p2, 50);
  insert into doc_price_setting_prices (document_id, product_id, price) values (rc, p3, 100);
  trade_ops.post_price_setting(rc);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, w1, sysdate - 5)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 1, p1, 100, 20, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 2, p2, 100, 30, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 3, p3, 100, 60, 0);
  trade_doc.post_goods_receipt(rc);

  -- точки доставки
  insert into ref_delivery_point (name, counterparty_id, gln, address, warehouse_id, price_type_id)
  values ('T28 Магазин 1', cp, g_dp1, 'Київ', w1, l_pt) returning id into dp1;
  select code, gln into l_s, r.delivery_gln from ref_delivery_point where id = dp1;
  eq('Точка доставки: код призначено', case when l_s is not null then 1 else 0 end, 1);
  eqs('Точка доставки: GLN', r.delivery_gln, g_dp1);
  insert into ref_delivery_point (name, counterparty_id, gln) values ('T28 РЦ', cp, g_dp2) returning id into dp2;
  begin
    insert into ref_delivery_point (name, counterparty_id, gln) values ('T28 без GLN', cp, null);
    eq('Точка доставки без GLN — помилка', 0, 1);
  exception when others then err('Точка доставки без GLN — помилка', 'GLN_REQUIRED');
  end;
  begin
    insert into ref_delivery_point (name, counterparty_id, gln) values ('T28 погана', cp, substr(g_dp3, 1, 12) || mod(to_number(substr(g_dp3, 13)) + 1, 10));
    eq('Точка доставки з невірним GLN — помилка', 0, 1);
  exception when others then err('Точка доставки з невірним GLN — помилка', 'GLN_CHECKSUM');
  end;
  begin
    insert into ref_delivery_point (name, counterparty_id, gln) values ('T28 = GLN мережі', cp, g_cp);
    eq('GLN точки = GLN контрагента — помилка', 0, 1);
  exception when others then err('GLN точки = GLN контрагента — помилка', 'GLN_DUPLICATE');
  end;
  begin
    update ref_counterparty set gln = g_dp2 where id = cp2;
    eq('GLN контрагента = GLN чужої точки — помилка', 0, 1);
  exception when others then err('GLN контрагента = GLN чужої точки — помилка', 'GLN_DUPLICATE');
  end;
  begin
    update ref_counterparty set gln = '1234567890123' where id = cp2;
    eq('Невірний GLN контрагента — помилка', 0, 1);
  exception when others then err('Невірний GLN контрагента — помилка', 'GLN_CHECKSUM');
  end;
  begin
    update ref_organization set gln = '12345' where id = l_org;
    eq('GLN організації не 13 цифр — помилка', 0, 1);
  exception when others then err('GLN організації не 13 цифр — помилка', 'GLN_FORMAT');
  end;
  select count(*) into l_n from v_delivery_point_list where counterparty_id = cp;
  eq('v_delivery_point_list: 2 точки мережі', l_n, 2);
  select count(*) into l_n from user_triggers where trigger_name = 'REF_DELIVERY_POINT_EVLOG' and status = 'ENABLED';
  eq('Тригер журналу реєстрації на точках доставки', l_n, 1);

  -- ---------------------------------------------------------------- вхідне ORDERS
  l_x := orders('T28-' || substr(t, 1, 8), g_org, g_cp, g_dp1,
                pos(1, e1, '10', '30.00', p_buyer => 'B-1') || pos(2, e1p, '2', '180,00') || pos(3, null, '5', null, 'T28B' || substr(t, 1, 6))
                || pos(4, e_bad, '1', '10') || pos(5, e3, '3', '99.00'));
  m1 := trade_edi.load_xml('orders1.xml', l_x);
  r := msg(m1);
  eqs('ORDERS: тип', r.msg_type, 'ORDERS');
  eqs('ORDERS: напрям', r.direction, 'IN');
  eqs('ORDERS: стан «Нове»', r.status, 'NEW');
  eq('ORDERS: 5 рядків', r.line_count, 5);
  eq('ORDERS: 1 помилка рядка', r.error_count, 1);
  eqs('ORDERS: організація за GLN постачальника', r.organization_id, l_org);
  eqs('ORDERS: покупець за GLN', r.counterparty_id, cp);
  eqs('ORDERS: точка доставки за GLN', r.delivery_point_id, dp1);
  eqs('ORDERS: № замовлення мережі = NUMBER', r.order_number, 'T28-' || substr(t, 1, 8));
  eqs('ORDERS: дата поставки', to_char(r.delivery_date, 'YYYYMMDD'), to_char(sysdate + 3, 'YYYYMMDD'));
  eqs('ORDERS: коментар (сутність XML розкодовано)', r.comment_text, 'Т28 & коментар');
  select count(*) into l_n from sys_edi_message_line where message_id = m1 and product_id = p1 and matched_by = 'BARCODE';
  eq('Рядки 1–2 зіставлено за штрихкодом', l_n, 2);
  select base_quantity into l_n from sys_edi_message_line where message_id = m1 and line_no = 2;
  eq('Рядок 2: упаковка 2 × 6 = 12 шт', l_n, 12);
  select price into l_n from sys_edi_message_line where message_id = m1 and line_no = 2;
  eq('Рядок 2: ціна з комою 180,00', l_n, 180);
  select count(*) into l_n from sys_edi_message_line where message_id = m1 and line_no = 3 and product_id = p2 and matched_by = 'SUPPLIER_CODE';
  eq('Рядок 3 зіставлено за кодом постачальника (артикул)', l_n, 1);
  select line_status into l_s from sys_edi_message_line where message_id = m1 and line_no = 4;
  eqs('Рядок 4: невідомий штрихкод — помилка', l_s, 'ERROR');
  select buyer_code into l_s from sys_edi_message_line where message_id = m1 and line_no = 1;
  eqs('Рядок 1: код покупця', l_s, 'B-1');

  -- помилки шапки
  m2 := trade_edi.load_xml('bad.xml', '<ORDER><NUMBER>1</NUMBER');
  r := msg(m2);
  eqs('Некоректний XML — стан «Помилка»', r.status, 'ERROR');
  eq('Некоректний XML — текст помилки', case when r.error_text like 'Файл не є коректним XML%' then 1 else 0 end, 1);
  m2 := trade_edi.load_xml('inv.xml', '<INVOICE><NUMBER>1</NUMBER></INVOICE>');
  eq('Непідтримуваний вхідний тип INVOICE — помилка', case when msg(m2).error_text like 'Непідтримуваний тип%INVOICE%' then 1 else 0 end, 1);
  m2 := trade_edi.load_xml('o2.xml', orders('T28-X', e_bad, g_cp, g_dp1, pos(1, e1, '1')));
  eq('Невідомий GLN постачальника — помилка', case when msg(m2).status = 'ERROR' and msg(m2).error_text like '%Організацію-постачальника%' then 1 else 0 end, 1);
  m2 := trade_edi.load_xml('o3.xml', orders('T28-Y', g_org, g_cp, g_dp3, pos(1, e1, '1')));
  r := msg(m2);
  eq('Невідома точка доставки — помилка', case when r.status = 'ERROR' and r.error_text like '%Точку доставки з GLN%' then 1 else 0 end, 1);
  begin
    l_id := trade_edi.create_order(m2);
    eq('Замовлення з помилкового ORDERS — помилка', 0, 1);
  exception when others then err('Замовлення з помилкового ORDERS — помилка', 'EDI_HAS_ERRORS');
  end;
  -- точку додано → повторне зіставлення
  insert into ref_delivery_point (name, counterparty_id, gln) values ('T28 Магазин 3', cp, g_dp3);
  trade_edi.reprocess(m2);
  eqs('Повторне зіставлення після додавання точки — «Нове»', msg(m2).status, 'NEW');
  update ref_counterparty set gln = null where id = cp2;
  m2 := trade_edi.load_xml('o4.xml', orders('T28-Z', g_org, g_cp, g_dp1, pos(1, null, 'abc')));
  eq('Некоректна кількість → помилка рядка й повідомлення', case when msg(m2).status = 'ERROR' then 1 else 0 end, 1);
  -- точка доставки іншого контрагента
  update ref_counterparty set gln = trade_edi.gln_with_check('48202' || k6 || '6') where id = cp2;
  m2 := trade_edi.load_xml('o5.xml', orders('T28-W', g_org, trade_edi.gln_with_check('48202' || k6 || '6'),
                                            g_dp1, pos(1, e1, '1')));
  eq('Точка доставки іншого контрагента — помилка', case when msg(m2).error_text like '%належить іншому контрагенту%' then 1 else 0 end, 1);
  -- завантаження файлу (BLOB, UTF-8 з BOM)
  l_b := utl_raw.concat(hextoraw('EFBBBF'), utl_i18n.string_to_raw(
          '<?xml version="1.0" encoding="UTF-8"?><ORDER><NUMBER>T28-F</NUMBER><DATE>2026-11-08</DATE><HEAD><SUPPLIER>' || g_org
          || '</SUPPLIER><BUYER>' || g_cp || '</BUYER><POSITION><PRODUCT>' || e3 || '</PRODUCT><DESCRIPTION>Чай</DESCRIPTION>'
          || '<ORDEREDQUANTITY>4</ORDEREDQUANTITY></POSITION></HEAD></ORDER>', 'AL32UTF8'));
  m2 := trade_edi.load_file('o6.xml', l_b);
  r := msg(m2);
  eqs('load_file: BLOB з BOM розібрано', r.status, 'NEW');
  eqs('load_file: без точки доставки — покупець за GLN', r.counterparty_id, cp);
  select description into l_s from sys_edi_message_line where message_id = m2;
  eqs('load_file: кирилиця', l_s, 'Чай');
  begin
    m2 := trade_edi.load_xml('empty.xml', null);
    eq('Порожній файл — помилка', 0, 1);
  exception when others then err('Порожній файл — помилка', 'EDI_FILE_EMPTY');
  end;

  -- ---------------------------------------------------------------- замовлення клієнта з ORDERS
  l_ord := trade_edi.create_order(m1);
  r := msg(m1);
  eqs('ORDERS оброблено', r.status, 'PROCESSED');
  eqs('ORDERS → замовлення клієнта', r.customer_order_id, l_ord);
  for o in (select * from doc_customer_order where id = l_ord) loop
    eqs('Замовлення: покупець', o.customer_id, cp);
    eqs('Замовлення: організація', o.organization_id, l_org);
    eqs('Замовлення: склад точки доставки', o.warehouse_id, w1);
    eqs('Замовлення: вид цін точки доставки', o.price_type_id, l_pt);
    eqs('Замовлення: точка доставки', o.delivery_point_id, dp1);
    eqs('Замовлення: № мережі', o.ext_order_number, 'T28-' || substr(t, 1, 8));
    eqs('Замовлення: відвантажити до', to_char(o.shipment_date, 'YYYYMMDD'), to_char(sysdate + 3, 'YYYYMMDD'));
    eqs('Замовлення: чернетка', o.status, 'DRAFT');
    eq('Замовлення: коментар з № EDI', case when o.doc_comment like 'EDI ORDERS № T28-%' then 1 else 0 end, 1);
  end loop;
  select count(*), sum(quantity) into l_n, l_s from doc_customer_order_goods where document_id = l_ord;
  eq('Замовлення: 4 рядки (без помилкового)', l_n, 4);
  eq('Замовлення: 10 + 12 + 5 + 3 = 30 шт', to_number(l_s), 30);
  select max(price) into l_n from doc_customer_order_goods where document_id = l_ord and product_id = p2;
  eq('Ціна без ціни у файлі — за видом цін (50)', l_n, 50);
  select max(price) into l_n from doc_customer_order_goods where document_id = l_ord and product_id = p1;
  eq('Ціна — за видом цін (30)', l_n, 30);
  select line_status into l_s from sys_edi_message_line where message_id = m1 and line_no = 5;
  eqs('Ціна мережі 99 ≠ 100 — попередження рядка', l_s, 'WARNING');
  select line_status into l_s from sys_edi_message_line where message_id = m1 and line_no = 2;
  eqs('Ціна упаковки 180 / 6 = 30 — без попередження', l_s, 'OK');
  select count(*) into l_n from sys_audit_log where object_id = l_ord and action = 'CREATE_BASED_ON';
  eq('Аудит створення на підставі EDI', l_n, 1);
  begin
    l_id := trade_edi.create_order(m1);
    eq('Повторне створення замовлення — помилка', 0, 1);
  exception when others then err('Повторне створення замовлення — помилка', 'EDI_ALREADY_PROCESSED');
  end;
  m2 := trade_edi.load_xml('orders1-again.xml', l_x);
  eq('Повторний файл того самого замовлення — помилка-дубль', case when msg(m2).error_text like '%уже оброблено%' then 1 else 0 end, 1);
  begin
    update doc_customer_order set delivery_point_id = (select id from ref_delivery_point where gln = g_dp1) , customer_id = cp2 where id = l_ord;
    eq('Точка доставки іншого покупця в замовленні — помилка', 0, 1);
  exception when others then err('Точка доставки іншого покупця в замовленні — помилка', 'DELIVERY_POINT_CUSTOMER');
  end;

  -- ---------------------------------------------------------------- ORDRSP
  begin
    l_id := trade_edi.ordrsp_from_order(l_ord);
    eq('ORDRSP з непроведеного замовлення — помилка', 0, 1);
  exception when others then err('ORDRSP з непроведеного замовлення — помилка', 'EDI_ORDER_NOT_POSTED');
  end;
  update doc_customer_order_goods set quantity = 2 where document_id = l_ord and product_id = p3;
  trade_r3.post_customer_order(l_ord);
  l_rsp := trade_edi.ordrsp_from_order(l_ord);
  r := msg(l_rsp);
  eqs('ORDRSP: вихідне, сформовано', r.direction || ' ' || r.status, 'OUT GENERATED');
  eqs('ORDRSP: відповідь 4 — зі змінами', r.action_code, '4');
  eqs('ORDRSP: посилання на ORDERS', r.ref_message_id, m1);
  eq('ORDRSP: 5 позицій', xcnt(l_rsp, '/ORDRSP/HEAD/POSITION'), 5);
  eqs('ORDRSP: ACTION у XML', xv(l_rsp, '/ORDRSP/ACTION/text()'), '4');
  eqs('ORDRSP: ORDERNUMBER = № мережі', xv(l_rsp, '/ORDRSP/ORDERNUMBER/text()'), 'T28-' || substr(t, 1, 8));
  eqs('ORDRSP: SUPPLIER = GLN організації', xv(l_rsp, '/ORDRSP/HEAD/SUPPLIER/text()'), g_org);
  eqs('ORDRSP: DELIVERYPLACE', xv(l_rsp, '/ORDRSP/HEAD/DELIVERYPLACE/text()'), g_dp1);
  eqs('ORDRSP: рядок 5 прийнято 2 з 3', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="5"]/ACCEPTEDQUANTITY/text()'), '2');
  eqs('ORDRSP: рядок 5 — змінено (2)', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="5"]/PRODUCTTYPE/text()'), '2');
  eqs('ORDRSP: рядок 4 — відхилено (3)', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="4"]/PRODUCTTYPE/text()'), '3');
  eqs('ORDRSP: рядок 2 — упаковки 2', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="2"]/ACCEPTEDQUANTITY/text()'), '2');
  eqs('ORDRSP: рядок 1 — прийнято (1)', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="1"]/PRODUCTTYPE/text()'), '1');
  eqs('ORDRSP: код покупця', xv(l_rsp, '/ORDRSP/HEAD/POSITION[POSITIONNUMBER="1"]/PRODUCTIDBUYER/text()'), 'B-1');
  l_rsp2 := trade_edi.ordrsp_from_order(l_ord);
  eqs('ORDRSP: повторне формування оновлює не надіслане', l_rsp2, l_rsp);
  trade_edi.send(l_rsp);
  r := msg(l_rsp);
  eqs('Надіслано через імітацію провайдера', r.status || ' ' || r.provider_code, 'SENT STUB');
  eq('Ідентифікатор провайдера STUB-…', case when r.ext_id like 'STUB-%' then 1 else 0 end, 1);
  begin
    trade_edi.send(l_rsp);
    eq('Повторне надсилання — помилка', 0, 1);
  exception when others then err('Повторне надсилання — помилка', 'EDI_NOT_GENERATED');
  end;
  begin
    trade_edi.send(m1);
    eq('Надсилання вхідного — помилка', 0, 1);
  exception when others then err('Надсилання вхідного — помилка', 'EDI_NOT_OUTGOING');
  end;
  begin
    trade_edi.cancel(l_rsp);
    eq('Скасування надісланого — помилка', 0, 1);
  exception when others then err('Скасування надісланого — помилка', 'EDI_NOT_CANCELLABLE');
  end;
  l_rsp2 := trade_edi.ordrsp_from_order(l_ord);
  eq('ORDRSP після надсилання — нове повідомлення', case when l_rsp2 <> l_rsp then 1 else 0 end, 1);
  trade_edi.cancel(l_rsp2);
  eqs('Скасування сформованого', msg(l_rsp2).status, 'CANCELLED');

  -- ---------------------------------------------------------------- DESADV / INVOIC
  l_sale := trade_r3.sale_from_order(l_ord);
  begin
    l_id := trade_edi.desadv_from_sale(l_sale);
    eq('DESADV з непроведеної реалізації — помилка', 0, 1);
  exception when others then err('DESADV з непроведеної реалізації — помилка', 'EDI_SALE_NOT_POSTED');
  end;
  trade_ops.post_goods_sale(l_sale);
  l_des := trade_edi.desadv_from_sale(l_sale);
  r := msg(l_des);
  eqs('DESADV: реалізація', r.sale_id, l_sale);
  eqs('DESADV: точка доставки з замовлення', r.delivery_point_id, dp1);
  select count(*) into l_n from doc_goods_sale_goods where document_id = l_sale;
  eq('DESADV: позицій = рядків реалізації', xcnt(l_des, '/DESADV/HEAD/PACKINGSEQUENCE/POSITION'), l_n);
  eqs('DESADV: ORDERNUMBER', xv(l_des, '/DESADV/ORDERNUMBER/text()'), 'T28-' || substr(t, 1, 8));
  eqs('DESADV: NUMBER = № реалізації', xv(l_des, '/DESADV/NUMBER/text()'), r.doc_number);
  eqs('DESADV: BUYER', xv(l_des, '/DESADV/HEAD/BUYER/text()'), g_cp);
  eq('DESADV: відвантажено цукру 22', to_number(xv(l_des, 'sum(/DESADV/HEAD/PACKINGSEQUENCE/POSITION[PRODUCT="' || e1 || '"]/DELIVEREDQUANTITY)')), 22);
  eqs('DESADV: код покупця для цукру', xv(l_des, '(/DESADV/HEAD/PACKINGSEQUENCE/POSITION[PRODUCT="' || e1 || '"]/PRODUCTIDBUYER)[1]/text()'), 'B-1');
  eqs('DESADV: ставка ПДВ 20', xv(l_des, '(/DESADV/HEAD/PACKINGSEQUENCE/POSITION/TAXRATE)[1]/text()'), '20');
  l_inv := trade_edi.invoic_from_sale(l_sale);
  r := msg(l_inv);
  for s in (select total_amount, vat_amount from doc_goods_sale where id = l_sale) loop
    eq('INVOIC: AMOUNTWITHVAT = сума реалізації', to_number(xv(l_inv, '/INVOICE/SUMMARY/AMOUNTWITHVAT/text()'), '999999999990.99'), s.total_amount);
    eq('INVOIC: TAXAMOUNT = ПДВ реалізації', to_number(xv(l_inv, '/INVOICE/SUMMARY/TAXAMOUNT/text()'), '999999999990.99'), s.vat_amount);
    eq('INVOIC: сума повідомлення', r.total_amount, s.total_amount);
    eq('INVOIC: ПДВ > 0', case when s.vat_amount > 0 then 1 else 0 end, 1);
  end loop;
  eqs('INVOIC: DOCUMENTNAME 380', xv(l_inv, '/INVOICE/DOCUMENTNAME/text()'), '380');
  eqs('INVOIC: посилання на DESADV', r.ref_message_id, l_des);
  eqs('INVOIC: BUYERCODE (ЄДРПОУ)', xv(l_inv, '/INVOICE/HEAD/BUYERCODE/text()'), '28282829');
  eq('Ім''я файлу DESADV_№_….xml', case when trade_edi.file_name_of(l_des) like 'DESADV\_%.xml' escape '\' then 1 else 0 end, 1);
  trade_edi.send(l_inv, 'FILE');
  r := msg(l_inv);
  eqs('INVOIC: файловий провайдер — надіслано без ідентифікатора', r.status || ' ' || r.provider_code || ' ' || nvl(r.ext_id, '-'), 'SENT FILE -');

  -- ---------------------------------------------------------------- RECADV
  l_rec := trade_edi.load_xml('recadv.xml', trade_edi.sample_recadv_xml(l_des, 1));
  r := msg(l_rec);
  eqs('RECADV: тип', r.msg_type, 'RECADV');
  eqs('RECADV: оброблено', r.status, 'PROCESSED');
  eqs('RECADV: реалізація знайдена через DESADV', r.sale_id, l_sale);
  eqs('RECADV: посилання на DESADV', r.ref_message_id, l_des);
  eq('RECADV: 1 розбіжність (нестача 1 шт)', r.diff_count, 1);
  l_c := trade_edi.message_html(l_rec);
  has('HTML RECADV: звірка', l_c, 'Звірка з реалізацією');
  has('HTML RECADV: різниця −1', l_c, '<b class="u-danger-text">-1</b>');
  l_rec := trade_edi.load_xml('recadv2.xml', replace(trade_edi.sample_recadv_xml(l_des, 0), '<DESADVNUMBER>', '<DESADVNUMBER>X'));
  eq('RECADV з невідомим DESADV — помилка', case when msg(l_rec).status = 'ERROR' and msg(l_rec).error_text like 'Відвантаження%' then 1 else 0 end, 1);
  l_rec := trade_edi.load_xml('recadv3.xml', trade_edi.sample_recadv_xml(l_des, 0));
  eq('RECADV без нестачі — 0 розбіжностей', msg(l_rec).diff_count, 0);

  -- ---------------------------------------------------------------- HTML, журнал, демо-файли
  l_c := trade_edi.message_html(m1);
  has('HTML ORDERS: GLN точки доставки', l_c, g_dp1 || ' — T28 Магазин 1, Київ');
  has('HTML ORDERS: помилка рядка', l_c, 'Товар не знайдено');
  has('HTML ORDERS: XML', l_c, '<details><summary>XML');
  has('HTML ORDERS: замовлення клієнта', l_c, 'Замовлення клієнта');
  eq('HTML без повідомлення — null', case when trade_edi.message_html(null) is null then 1 else 0 end, 1);
  select count(*) into l_n from v_edi_message where counterparty_id = cp;
  eq('v_edi_message: повідомлення мережі', case when l_n >= 10 then 1 else 0 end, 1);
  select count(*) into l_n from sys_audit_log where object_type = 'EDI' and object_id = l_rsp and action in ('EDI_GENERATE', 'EDI_SEND');
  eq('Аудит формування й надсилання', l_n, 3);
  l_x := trade_edi.sample_orders_xml('T28-SAMPLE', g_dp1);
  m2 := trade_edi.load_xml('sample.xml', l_x);
  eqs('Демо-ORDERS для точки доставки: покупець', msg(m2).counterparty_id, cp);
  l_id := trade_edi.load_sample('RECADV', l_sale);
  eqs('load_sample RECADV', msg(l_id).msg_type || ' ' || msg(l_id).status, 'RECADV PROCESSED');

  -- точка доставки помічена на видалення
  trade_core.mark_for_deletion('REF_DELIVERY_POINT', dp2);
  m2 := trade_edi.load_xml('o7.xml', orders('T28-V', g_org, g_cp, g_dp2, pos(1, e1, '1')));
  eq('Точка доставки на видаленні не зіставляється', case when msg(m2).status = 'ERROR' then 1 else 0 end, 1);

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'EdiExchange' and list_page_id = 700 and auth_scheme = 'Роль: продажі';
  eq('Об''єкт метаданих «EDI: обмін з торговими мережами»', l_n, 1);
  select count(*) into l_n from sys_metadata_object where tech_name = 'RefDeliveryPoint' and list_page_id = 710 and form_page_id = 711;
  eq('Об''єкт метаданих «Точки доставки (GLN)»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'EdiExchange';
  eq('Панель функцій: Продажі → EDI', l_n, 1);
  select count(*) into l_n from sys_edi_provider where code in ('STUB', 'FILE');
  eq('Провайдери STUB і FILE', l_n, 2);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
